// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");
const builtin = @import("builtin");
const build_config = @import("build_config");
const Fingerprint = @import("browser/Fingerprint.zig");

const cli = @import("cli.zig");
const dump = @import("browser/dump.zig");

const WebBotAuthConfig = @import("network/WebBotAuth.zig").Config;

const log = lp.log;
const crypto = @import("sys/libcrypto.zig");
const Allocator = std.mem.Allocator;

// TCP keepalive parameters applied to accepted CDP connections.
// Detection window ≈ IDLE + CNT * INTVL = 4 + 3*2 = 10s.
pub const CDP_KEEPALIVE_IDLE_S: c_int = 4;
pub const CDP_KEEPALIVE_INTVL_S: c_int = 2;
pub const CDP_KEEPALIVE_CNT: c_int = 3;
pub const CDP_TCP_USER_TIMEOUT_MS: c_int = 10_000;

const Config = @This();

/// Runtime limits tuned either for desktop throughput or for small ARM boards.
/// The Pi profile deliberately trades Web API breadth and concurrency for a
/// lower retained memory and bounded major defaults; clients can still opt
/// individual features back in through LP.configureLoading after a CDP
/// session is created.
///
/// `slot` keeps the same lean V8 flags and heap floor as `pi`, but concurrency
/// defaults assume one live virtual-browser process rather than a shared
/// multi-session server. Use it when scaling out with many one-session
/// processes (T3 / agent pools).
pub const ResourceProfile = enum {
    standard,
    pi,
    slot,
};

/// Marginal RSS a concurrent `serve` session adds to the process. Deriving the
/// *default* concurrency cap from physical memory makes a small board refuse
/// the session up front rather than OOM half-way through one. An explicit
/// --cdp-max-connections / --max-connections / --max-sessions bypasses this
/// entirely.
///
/// Measured with `bench/sessions.sh` (least-squares slope over N = 1,2,4,8,16,32
/// simultaneous CDP sessions in one process, each holding a 12k-node DOM), pi
/// profile: 6.0 MiB/session, on a 23.3 MiB fixed intercept. The split by stage
/// is 1.3 MiB for the isolate itself, +0.5 for an attached about:blank page,
/// +4.5 for the DOM — V8 costs little per session because all isolates in the
/// process share one IsolateGroup (read-only heap, pointer-compression cage
/// and code range), so only the DOM scales.
///
/// The old 22 MiB here was the *whole-process* floor of a single `fetch`
/// (bench/run.sh), which charges every session for fixed overhead that
/// `reserved_system_memory` already holds back. 12 MiB keeps a ~2x margin over
/// the measurement for pages heavier than the fixture.
const session_memory_floor = 12 * 1024 * 1024;

/// Held back for the OS, the shared snapshot mapping and everything that is not
/// a session.
/// ponytail: physical memory, not free memory — a co-tenant process is
/// invisible here. Read /proc/meminfo MemAvailable if that starts to matter.
const reserved_system_memory = 256 * 1024 * 1024;

fn memoryCappedSessions(default: u16) u16 {
    const total = std.process.totalSystemMemory() catch return default;
    const affordable = (total -| reserved_system_memory) / session_memory_floor;
    if (affordable == 0) return 1;
    return @min(default, std.math.lossyCast(u16, affordable));
}

fn logFilterScopesValidator(allocator: Allocator, args: *std.process.Args.Iterator, list: *std.ArrayList(log.FilterRule)) !void {
    const str = args.next() orelse return error.InvalidOption;

    var it = std.mem.splitScalar(u8, str, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;

        // `+X` filters in, `-X` filters out, bare `X` is an alias for `-X`
        // (backward compatible). `all` targets every scope.
        var name = part;
        var enable = false;
        switch (part[0]) {
            '+' => {
                enable = true;
                name = part[1..];
            },
            '-' => name = part[1..],
            else => {},
        }

        if (std.mem.eql(u8, name, "all")) {
            try list.append(allocator, .{ .scope = null, .enable = enable });
            continue;
        }

        const v = std.meta.stringToEnum(log.Scope, name) orelse {
            log.fatal(.app, "invalid option choice", .{ .arg = "--log-filter-scopes", .value = part });
            return error.InvalidOption;
        };

        try list.append(allocator, .{ .scope = v, .enable = enable });
    }
}

fn logLevelValidator(_: Allocator, args: *std.process.Args.Iterator, target: *?log.Level) !void {
    const str = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, str, "error")) {
        target.* = .err;
        return;
    }

    target.* = std.meta.stringToEnum(log.Level, str) orelse {
        log.fatal(.app, "invalid option choice", .{ .arg = "--log-level", .value = str });
        return error.InvalidArgument;
    };
}

const Cert = struct {
    /// On successful CLI argument parsing phase, ownership of this transferred
    /// to `Network`. Consider it as invalid.
    store: ?*crypto.X509_STORE = null,
    // Number of certificate sources loaded into `store`.
    count: usize = 0,

    fn deinit(self: *Cert) void {
        if (self.store) |store| {
            crypto.X509_STORE_free(store);
        }
        self.* = .{};
    }

    /// Returns the store, creating it on first use. The store is shared by
    /// every `--ca-cert`/`--ca-path` occurrence.
    fn getOrCreate(self: *Cert) !*crypto.X509_STORE {
        if (self.store) |store| {
            return store;
        }
        const store = crypto.X509_STORE_new() orelse
            return error.FailedToCreateCertStore;
        self.store = store;
        return store;
    }
};

fn caCertValidator(
    _: Allocator,
    args: *std.process.Args.Iterator,
    cert: *Cert,
) !void {
    const file_name = args.next() orelse return error.MissingArgument;
    const store = try cert.getOrCreate();
    errdefer cert.deinit();

    if (crypto.X509_STORE_load_locations(store, file_name, null) != 1) {
        log.fatal(.app, "Invalid CA cert", .{ .arg = "--ca-cert", .value = file_name });
        return error.InvalidArgument;
    }
    cert.count += 1;
}

fn caPathValidator(
    allocator: Allocator,
    args: *std.process.Args.Iterator,
    cert: *Cert,
) !void {
    const dir_path = args.next() orelse return error.MissingArgument;

    var dir = std.Io.Dir.cwd().openDir(lp.io, dir_path, .{ .iterate = true }) catch {
        log.fatal(.app, "Invalid CA path", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    };
    defer dir.close(lp.io);

    const store = try cert.getOrCreate();
    errdefer cert.deinit();

    // Eagerly load every certificate in the directory rather than
    // registering a lazy hashed lookup: the directory doesn't need to be
    // c_rehash'ed, bad entries surface at startup and `count` reflects
    // what was actually loaded.
    const count_before = cert.count;
    var it = dir.iterate();
    while (it.next(lp.io) catch {
        log.fatal(.app, "Invalid CA path", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    }) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const path = try std.fs.path.joinZ(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);

        if (crypto.X509_STORE_load_locations(store, path, null) != 1) {
            log.warn(.app, "Skipping invalid CA cert", .{ .arg = "--ca-path", .value = path });
            continue;
        }
        cert.count += 1;
    }

    // An empty directory (or one with no readable certificates) is
    // indistinguishable from a typo; treat it as an error.
    if (cert.count == count_before) {
        log.fatal(.app, "No certificates loaded", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    }
}

/// Common CLI args.
const CommonOptions = .{
    .{ .name = "resource_profile", .type = ?ResourceProfile },
    .{ .name = "obey_robots", .type = bool },
    .{ .name = "proxy_bearer_token", .type = ?[:0]const u8 },
    .{ .name = "http_proxy", .type = ?[:0]const u8 },
    .{ .name = "http_max_concurrent", .type = ?u8 },
    .{ .name = "http_max_host_open", .type = ?u8 },
    .{ .name = "http_timeout", .type = ?u31 },
    .{ .name = "http_connect_timeout", .type = ?u31 },
    .{ .name = "http_max_response_size", .type = ?usize },
    .{ .name = "ws_max_concurrent", .type = ?u8 },
    .{ .name = "insecure_disable_tls_host_verification", .type = bool },
    .{ .name = "log_level", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_format", .type = ?log.Format },
    .{ .name = "log_filter_scopes", .type = log.FilterRule, .multiple = true, .validator = logFilterScopesValidator },
    .{ .name = "user_agent_suffix", .type = ?[]const u8 },
    .{ .name = "http_cache_dir", .type = ?[]const u8 },
    .{ .name = "http_cache_entry_limit", .type = ?u32, .default = 1000 },
    .{ .name = "web_bot_auth_key_file", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_keyid", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_domain", .type = ?[]const u8 },
    .{ .name = "user_agent", .type = ?[]const u8 },
    // Retained as a no-op so existing invocations do not break now that the
    // Chrome-compatible identity is the default.
    .{ .name = "stealth", .type = bool },
    // Opt out of the default Chrome-compatible identity and identify honestly
    // as Lightpanda.
    .{ .name = "no_stealth", .type = bool },
    // Deterministic fingerprint seed. Same seed → same GPU/screen/hw identity.
    .{ .name = "fingerprint", .type = ?u64 },
    // Platform reported to JS: windows|macos|linux. Defaults to host OS on
    // macOS, windows elsewhere.
    .{ .name = "fingerprint_platform", .type = ?[]const u8 },
    .{ .name = "block_private_networks", .type = bool },
    .{ .name = "block_cidrs", .type = ?[]const u8 },
    .{ .name = "block_urls", .type = ?[]const u8 },
    .{ .name = "cookie", .type = ?[]const u8 },
    .{ .name = "cookie_jar", .type = ?[]const u8 },
    .{ .name = "disable_subframes", .type = bool },
    .{ .name = "disable_workers", .type = bool },
    .{ .name = "enable_external_stylesheets", .type = bool },
    .{ .name = "v8_flags_unsafe", .type = ?[]const u8 },
    .{ .name = "v8_max_heap_mb", .type = ?u32 },
    .{ .name = "v8_thread_pool_size", .type = ?u8 },
    .{ .name = "disable_v8_idle_tasks", .type = bool },
    .{ .name = "watchdog_ms", .type = ?u32 },
    .{
        .name = "ca_cert",
        .field_name = "cert",
        .type = .{
            .cli = [:0]const u8,
            .memory = Cert,
        },
        .default = Cert{},
        .validator = caCertValidator,
    },
    .{
        .name = "ca_path",
        .field_name = "cert",
        .type = .{
            .cli = []const u8,
            .memory = Cert,
        },
        .default = Cert{},
        .validator = caPathValidator,
    },
};

fn dumpValidator(_: Allocator, args: *std.process.Args.Iterator, target: *?DumpFormat) !void {
    // Peek next argument.
    var peek_args = args.*;
    if (peek_args.next()) |next_arg| {
        const mode = std.meta.stringToEnum(DumpFormat, next_arg) orelse {
            target.* = .html;
            return;
        };

        // Skip the argument we peek if successful.
        _ = args.next();
        target.* = mode;
        return;
    }

    // Means we couldn't get something like `--dump html` but we do have
    // `--dump`; which should fall to `html` by default.
    target.* = .html;
}

pub const AiProvider = std.meta.Tag(zenai.provider.Client);

/// Per-turn reasoning budget for `agent` mode, mirroring Claude's effort
/// levels. Maps to each provider's native thinking/reasoning knob. Resolved
/// in `Agent.init` (explicit flag > remembered > mode default), so there is
/// no Config-level accessor like `agentVerbosity`.
pub const Effort = zenai.provider.Effort;

/// Controls how chatty `agent` mode is on stderr.
pub const AgentVerbosity = enum {
    /// REPL: spinner + per-turn summary. Non-REPL: final answer + errors only.
    low,
    /// + one `● [tool: …]` line per tool call.
    medium,
    /// + the matching `[result: …]` body for each call.
    high,

    pub fn atLeast(self: AgentVerbosity, min: AgentVerbosity) bool {
        return @intFromEnum(self) >= @intFromEnum(min);
    }
};

fn waitScriptFileValidator(allocator: Allocator, args: *std.process.Args.Iterator, target: *?[:0]const u8) !void {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--wait-script-file" });
        return error.InvalidArgument;
    };

    target.* = std.Io.Dir.cwd().readFileAllocOptions(lp.io, path, allocator, .limited(1024 * 1024), .of(u8), 0) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--wait-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };
}

fn injectScriptFileValidator(
    allocator: Allocator,
    args: *std.process.Args.Iterator,
    list: *std.ArrayList([]const u8),
) !void {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--inject-script-file" });
        return error.InvalidArgument;
    };

    const bytes = std.Io.Dir.cwd().readFileAllocOptions(lp.io, path, allocator, .unlimited, .of(u8), null) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--inject-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };

    return list.append(allocator, bytes);
}

/// Definition for all the commands and its arguments. See @cli.zig for further.
const Commands = cli.Builder(.{
    .{
        .name = "serve",
        .options = .{
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "port", .type = u16, .default = 9222 },
            .{ .name = "advertise_host", .type = ?[]const u8 },
            .{ .name = "timeout", .type = ?u31 },
            .{ .name = "cdp_max_connections", .type = ?u16 },
            .{ .name = "cdp_max_pending_connections", .type = ?u16 },
            .{ .name = "cdp_max_message_size", .type = ?u32 },
            // Don't widen this without growing the reader buffer in the HTTP path.
            .{ .name = "cdp_max_http_message_size", .type = u14, .default = 4096 },
            .{ .name = "disable_metrics", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "fetch",
        // One or more URLs; can be given out of order, interleaved with options.
        .positional = .{ .name = "url", .type = [:0]const u8, .multiple = true },
        .options = .{
            .{ .name = "dump", .type = ?DumpFormat, .validator = dumpValidator },
            .{ .name = "with_base", .type = bool },
            .{ .name = "with_frames", .type = bool },
            .{ .name = "strip_mode", .type = dump.Opts.Strip, .default = dump.Opts.Strip{} },
            .{ .name = "wait_ms", .type = u32, .default = 5_000 },
            .{ .name = "wait_until", .type = ?WaitUntil },
            .{
                .name = "wait_script",
                .type = ?[:0]const u8,
                .variants = .{
                    .{ .name = "wait_script_file", .validator = waitScriptFileValidator },
                },
            },
            .{ .name = "wait_selector", .type = ?[:0]const u8 },
            .{
                .name = "inject_script",
                .type = []const u8,
                .multiple = true,
                .variants = .{
                    .{ .name = "inject_script_file", .validator = injectScriptFileValidator },
                },
            },
            .{ .name = "terminate_ms", .type = ?u32 },
            .{ .name = "json", .type = bool },
            .{ .name = "metrics", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "mcp",
        .options = .{
            .{ .name = "port", .type = ?u16 },
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "cdp_port", .type = ?u16 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "agent",
        .positional = .{ .name = "script_file", .type = ?[:0]const u8 },
        .options = .{
            .{ .name = "provider", .type = ?AiProvider },
            .{ .name = "model", .type = ?[:0]const u8 },
            .{ .name = "base_url", .type = ?[:0]const u8 },
            .{ .name = "system_prompt", .type = ?[:0]const u8 },
            .{ .name = "task", .type = ?[]const u8 },
            .{ .name = "save", .type = ?[]const u8 },
            .{ .name = "attach", .short = 'a', .type = []const u8, .multiple = true },
            .{ .name = "verbosity", .type = ?AgentVerbosity },
            .{ .name = "effort", .type = ?Effort },
            .{ .name = "list_models", .type = bool },
            .{ .name = "no_llm", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        // Normalized to `.agent` in `parseArgs`; intentionally no LLM options.
        .name = "run",
        .positional = .{ .name = "script_file", .type = ?[:0]const u8 },
        .options = .{},
        .shared_options = CommonOptions,
    },
    .{ .name = "version", .options = .{
        .{ .name = "check", .type = bool },
    } },
});

pub const RunMode = Commands.Enum;
pub const Mode = Commands.Union;
pub const Agent = @FieldType(Mode, "agent");

mode: Mode,
// The command as typed. Mirrors `mode`, except `run` normalizes to `.agent`
// for execution while this keeps `.run` for telemetry.
command: RunMode,
exec_name: []const u8,
http_headers: HttpHeaders,
/// Seed-derived device identity (GPU/screen/cores/memory). Always set; the
/// stock profile when --no-stealth is set without --fingerprint.
fingerprint_profile: Fingerprint.Profile = .stock,

fn modeNeedsHttp(mode: Mode) bool {
    return switch (mode) {
        .help => false,
        .version => |opts| opts.check,
        else => true,
    };
}

pub fn init(allocator: Allocator, exec_name: []const u8, mode: Mode) !Config {
    var config = Config{
        .mode = mode,
        .command = std.meta.activeTag(mode),
        .exec_name = exec_name,
        .http_headers = undefined,
        .fingerprint_profile = .stock,
    };
    if (modeNeedsHttp(mode)) {
        // Resolved first: the Chrome User-Agent's OS token derives from it.
        config.fingerprint_profile = resolveFingerprintProfile(&config);
        config.http_headers = try HttpHeaders.init(allocator, &config);
    }
    return config;
}

/// Build the profile from the identity and fingerprint options.
fn resolveFingerprintProfile(config: *const Config) Fingerprint.Profile {
    const seed = config.fingerprintSeed();
    if (seed == null and !config.stealth()) return .stock;

    const platform: Fingerprint.Platform = blk: {
        if (config.fingerprintPlatform()) |s| {
            break :blk Fingerprint.Platform.fromString(s) orelse .windows;
        }
        break :blk if (builtin.os.tag == .macos) .macos else .windows;
    };

    if (seed) |s| return Fingerprint.Profile.fromSeed(s, platform);
    return Fingerprint.Profile.random(platform);
}

pub fn deinit(self: *const Config, allocator: Allocator) void {
    if (modeNeedsHttp(self.mode)) {
        self.http_headers.deinit(allocator);
    }
}

pub fn interactive(self: *const Config) bool {
    return switch (self.mode) {
        .fetch => false,
        .serve, .mcp => true,
        .agent => |opts| opts.script_file == null,
        else => unreachable,
    };
}

pub fn tlsVerifyHost(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| !opts.insecure_disable_tls_host_verification,
        // `version --check` talks to the release endpoint; always verify.
        .version => true,
        else => unreachable,
    };
}

pub fn obeyRobots(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.obey_robots,
        else => unreachable,
    };
}

pub fn disableSubframes(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.disable_subframes,
        else => unreachable,
    };
}

pub fn resourceProfile(self: *const Config) ResourceProfile {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.resource_profile orelse
            if (build_config.low_resource_default) .pi else .standard,
        else => unreachable,
    };
}

/// `pi` and `slot` share the lean V8/network defaults. `slot` additionally
/// tightens process-level concurrency for dedicated one-session processes.
pub fn leanProfile(self: *const Config) bool {
    return switch (self.resourceProfile()) {
        .pi, .slot => true,
        .standard => false,
    };
}

pub fn disableWorkers(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.disable_workers,
        else => unreachable,
    };
}

pub fn watchdogMs(self: *const Config) ?u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| {
            const default_ms: u32 = if (self.leanProfile()) 10_000 else 30_000;
            const ms = opts.watchdog_ms orelse default_ms;
            return if (ms == 0) null else ms;
        },
        else => unreachable,
    };
}

pub fn enableExternalStylesheets(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.enable_external_stylesheets,
        else => unreachable,
    };
}

pub fn v8Flags(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_flags_unsafe,
        else => unreachable,
    };
}

// Memory-oriented V8 flags applied before --v8-flags-unsafe (so a user flag
// with the same name still wins). Measured on a 1.4 MB DOM + JS page load
// (peak RSS, median of 7):
//   --optimize-for-size            68.4 -> 66.4 MB, CPU unchanged
//   --no-concurrent-recompilation  66.3 -> 61.6 MB, CPU +0.01s
pub const pi_v8_flags = "--optimize-for-size --no-concurrent-recompilation";

pub fn v8ProfileFlags(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => if (self.leanProfile()) pi_v8_flags else null,
        else => null,
    };
}

pub fn v8MaxHeapMb(self: *const Config) ?u32 {
    return switch (self.mode) {
        // Keep 64 MiB for both lean profiles. Lower growth caps do not reduce
        // peak RSS after --optimize-for-size and OOMs common SPAs.
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_max_heap_mb orelse
            if (self.leanProfile()) 64 else null,
        else => unreachable,
    };
}

pub fn speculativePreloading(self: *const Config) bool {
    return !self.leanProfile();
}

pub fn v8ThreadPoolSize(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_thread_pool_size orelse
            if (self.leanProfile()) 1 else 0,
        else => unreachable,
    };
}

pub fn v8IdleTasks(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| !opts.disable_v8_idle_tasks and !self.leanProfile(),
        else => unreachable,
    };
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_proxy,
        .version => null,
        else => unreachable,
    };
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.proxy_bearer_token,
        else => null,
    };
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_concurrent orelse
            if (self.leanProfile()) 8 else 40,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_host_open orelse
            if (self.leanProfile()) 2 else 6,
        else => unreachable,
    };
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_connect_timeout orelse 0,
        .version => 0,
        else => unreachable,
    };
}

pub fn httpTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_timeout orelse 5000,
        .version => 5000,
        else => unreachable,
    };
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 10;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_response_size orelse
            if (self.leanProfile()) 32 * 1024 * 1024 else null,
        else => unreachable,
    };
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.ws_max_concurrent orelse
            if (self.leanProfile()) 2 else 8,
        else => unreachable,
    };
}

pub fn logLevel(self: *const Config) ?log.Level {
    return switch (self.mode) {
        // Agent mode quiets page-driven `console.error` noise unless verbosity=high.
        .agent => |opts| opts.log_level orelse switch (agentVerbosity(opts)) {
            .low, .medium => .err,
            .high => null,
        },
        inline .serve, .fetch, .mcp => |opts| opts.log_level,
        else => unreachable,
    };
}

/// Resolve --verbosity. Explicit value wins. Else: --task with stderr
/// captured (pipe/file) defaults to .high so benchmark harnesses and
/// other programmatic consumers get the [tool/result] trace; REPL and
/// --task on a TTY default to .low.
pub fn agentVerbosity(opts: Agent) AgentVerbosity {
    if (opts.verbosity) |v| return v;
    const piped_one_shot = opts.task != null and !stderrIsTty();
    return if (piped_one_shot) .high else .low;
}

/// `isatty(STDERR)` is a syscall and `agentVerbosity` is on the log hot
/// path (every gate check resolves through it). Cache once — the fd
/// doesn't change after process start.
var stderr_tty_cached: bool = undefined;
var stderr_tty_once = lp.once(initStderrTty);
fn initStderrTty() void {
    stderr_tty_cached = std.Io.File.stderr().isTty(lp.io) catch false;
}
fn stderrIsTty() bool {
    stderr_tty_once.call();
    return stderr_tty_cached;
}

pub fn logFormat(self: *const Config) ?log.Format {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.log_format,
        else => unreachable,
    };
}

pub fn logFilterScopes(self: *const Config) std.ArrayList(log.FilterRule) {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.log_filter_scopes,
        else => unreachable,
    };
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.user_agent_suffix,
        else => null,
    };
}

pub fn userAgent(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.user_agent,
        else => null,
    };
}

pub fn httpCacheDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_cache_dir,
        else => null,
    };
}

pub fn httpCacheEntryLimit(self: *const Config) u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_cache_entry_limit.?,
        else => 1000,
    };
}

pub fn cookieFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.cookie,
        else => null,
    };
}

pub fn cookieJarFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .fetch, .mcp, .agent => |opts| opts.cookie_jar,
        else => null,
    };
}

pub fn port(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.port,
        .mcp => |opts| opts.cdp_port orelse 0,
        else => unreachable,
    };
}

pub fn advertiseHost(self: *const Config) []const u8 {
    return switch (self.mode) {
        .serve => |opts| opts.advertise_host orelse opts.host,
        .mcp => "127.0.0.1",
        else => unreachable,
    };
}

pub fn webBotAuth(self: *const Config) ?WebBotAuthConfig {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| WebBotAuthConfig{
            .key_file = opts.web_bot_auth_key_file orelse return null,
            .keyid = opts.web_bot_auth_keyid orelse return null,
            .domain = opts.web_bot_auth_domain orelse return null,
        },
        else => null,
    };
}

pub fn blockPrivateNetworks(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_private_networks,
        else => unreachable,
    };
}

pub fn blockCidrs(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_cidrs,
        else => unreachable,
    };
}

pub fn blockedUrlPatterns(self: *const Config) ?std.mem.SplitIterator(u8, .scalar) {
    const patterns = switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_urls,
        else => unreachable,
    } orelse return null;
    return std.mem.splitScalar(u8, patterns, ',');
}

// Dedicated one-session process: keep a second HTTP/CDP slot so health checks
// or a reconnect can coexist with the live session.
const pi_max_sessions = 32;
const slot_max_connections = 2;

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections orelse switch (self.resourceProfile()) {
            .slot => slot_max_connections,
            .pi => memoryCappedSessions(pi_max_sessions),
            .standard => memoryCappedSessions(16),
        },
        .mcp => switch (self.resourceProfile()) {
            .slot => slot_max_connections,
            .pi => memoryCappedSessions(pi_max_sessions),
            .standard => memoryCappedSessions(16),
        },
        else => unreachable,
    };
}

pub fn maxPendingConnections(self: *const Config) u31 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_pending_connections orelse switch (self.resourceProfile()) {
            .slot => 2,
            .pi => 16,
            .standard => 128,
        },
        .mcp => switch (self.resourceProfile()) {
            .slot => 2,
            .pi => 16,
            .standard => 128,
        },
        else => unreachable,
    };
}

pub fn cdpMaxMessageSize(self: *const Config) u32 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_message_size orelse if (self.leanProfile()) 256 * 1024 else 1024 * 1024,
        else => unreachable,
    };
}

pub fn metricsEndpointEnabled(self: *const Config) bool {
    return switch (self.mode) {
        .serve => |opts| !opts.disable_metrics,
        else => unreachable,
    };
}

pub fn dumpMetricsOnExit(self: *const Config) bool {
    return switch (self.mode) {
        .fetch => |opts| opts.metrics,
        else => false,
    };
}

pub fn cdpMaxHTTPMessageSize(self: *const Config) u14 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_http_message_size,
        else => unreachable,
    };
}

/// Returns the user-supplied certificate store (`--ca-cert`/`--ca-path`),
/// if any was loaded during argument parsing. The caller takes ownership.
pub fn customCertStore(self: *const Config) ?*crypto.X509_STORE {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| {
            const store = opts.cert.store orelse return null;
            // Validators guarantee a created store loaded something.
            lp.assert(opts.cert.count > 0, "empty custom cert store", .{});
            return store;
        },
        else => null,
    };
}

pub const DumpFormat = enum {
    html,
    markdown,
    wpt,
    semantic_tree,
    semantic_tree_text,
};

pub const WaitUntil = enum {
    load,
    domcontentloaded,
    networkalmostidle,
    networkidle,
    done,
};

/// HTTP header values shared across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub fn stealth(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| !opts.no_stealth,
        else => false,
    };
}

pub fn fingerprintSeed(self: *const Config) ?u64 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.fingerprint,
        else => null,
    };
}

pub fn fingerprintPlatform(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.fingerprint_platform,
        else => null,
    };
}

pub const HttpHeaders = struct {
    pub const product_version: [:0]const u8 = "1.0";
    const user_agent_base: [:0]const u8 = "Lightpanda/" ++ product_version;

    pub const Brand = struct {
        brand: [:0]const u8,
        version: [:0]const u8,
    };

    pub const brands = [_]Brand{
        .{ .brand = "Lightpanda", .version = "1" },
    };
    pub const full_brands = [_]Brand{
        .{ .brand = "Lightpanda", .version = product_version },
    };

    pub const stealth_chrome_version: [:0]const u8 = "151";
    pub const stealth_ua_full_version: [:0]const u8 = "151.0.7922.77";

    /// Chrome GREASE + Chromium + Google Chrome brands used by default.
    pub const brands_stealth = [_]Brand{
        .{ .brand = "Not=A?Brand", .version = "99" },
        .{ .brand = "Google Chrome", .version = stealth_chrome_version },
        .{ .brand = "Chromium", .version = stealth_chrome_version },
    };
    pub const full_brands_stealth = [_]Brand{
        .{ .brand = "Not=A?Brand", .version = "99.0.0.0" },
        .{ .brand = "Google Chrome", .version = stealth_ua_full_version },
        .{ .brand = "Chromium", .version = stealth_ua_full_version },
    };

    /// Chrome-aligned default UA. The OS token has to agree with the
    /// resolved fingerprint platform: a Windows UA next to a "MacIntel"
    /// navigator.platform is a louder tell than no stealth at all.
    pub fn stealthUserAgent(platform: Fingerprint.Platform) [:0]const u8 {
        const prefix = "Mozilla/5.0 (";
        // Chrome's reduced UA pins the last three version components to zero;
        // the real build number only travels over UA-CH.
        const suffix = ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" ++
            stealth_chrome_version ++ ".0.0.0 Safari/537.36";
        return switch (platform) {
            .windows => prefix ++ "Windows NT 10.0; Win64; x64" ++ suffix,
            .macos => prefix ++ "Macintosh; Intel Mac OS X 10_15_7" ++ suffix,
            .linux => prefix ++ "X11; Linux x86_64" ++ suffix,
        };
    }

    fn secChUa(comptime brand_list: []const Brand) [:0]const u8 {
        comptime {
            var out: [:0]const u8 = "";
            for (brand_list, 0..) |b, i| {
                const sep = if (i == 0) "" else ", ";
                out = out ++ sep ++ "\"" ++ b.brand ++ "\";v=\"" ++ b.version ++ "\"";
            }
            return out;
        }
    }

    pub const sec_ch_ua: [:0]const u8 = secChUa(&brands);
    pub const sec_ch_ua_stealth: [:0]const u8 = secChUa(&brands_stealth);
    pub const sec_ch_ua_full_version_list_stealth: [:0]const u8 = secChUa(&full_brands_stealth);
    pub const sec_ch_ua_full_version_stealth: [:0]const u8 = "\"" ++ stealth_ua_full_version ++ "\"";

    pub fn secChUaPlatformVersion(platform: Fingerprint.Platform) []const u8 {
        return switch (platform) {
            .windows => "\"15.0.0\"",
            // The reduced User-Agent keeps its frozen 10_15_7 token, but
            // UA-CH reports the actual OS generation. Chrome 150 cannot run
            // on Catalina, so pairing it with 10.15.7 is self-contradictory.
            .macos => "\"26.5.2\"",
            .linux => "\"6.6.0\"",
        };
    }

    pub const sec_ch_ua_arch: []const u8 = switch (builtin.cpu.arch) {
        .x86, .x86_64 => "\"x86\"",
        .aarch64, .aarch64_be, .arm, .armeb => "\"arm\"",
        else => "\"\"",
    };
    pub const sec_ch_ua_bitness: []const u8 = switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .powerpc64, .powerpc64le, .riscv64 => "\"64\"",
        else => "\"32\"",
    };

    // Some bot-protection frontends (e.g. Akamai on canada.ca) RST the HTTP/2
    // stream when a client sends Accept-Encoding without Accept-Language,
    // treating it as a bot signal. Ship a neutral default so we look like a
    // normal client.
    pub const accept_language: [:0]const u8 = "en-US,en;q=0.9";

    // Document-navigation Accept value Chrome sends.
    pub const navigation_accept: [:0]const u8 = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";

    pub const chrome_channel: []const u8 = "stable";
    pub const chrome_copyright: []const u8 = "Copyright 2026 Google LLC. All Rights Reserved.";
    pub const chrome_validation_macos_arm64: []const u8 = "Ujp3LPhx528Wqnzml3jZrVzknis=";
    pub const chrome_client_data: []const u8 = "CJ6WywE=";

    user_agent: [:0]const u8, // User agent value (e.g. "Lightpanda/1.0")
    /// Sec-Ch-Ua header value (brand list), stealth-aware.
    sec_ch_ua_header: [:0]const u8,
    /// Quoted low-entropy UA-CH platform value sent on every request.
    sec_ch_ua_platform_header: []const u8,
    /// Brand list for navigator.userAgentData (same source as Sec-Ch-Ua).
    brand_list: []const Brand,
    /// True when this process presents itself as Chrome.
    stealth: bool = false,
    /// False when user_agent is a comptime literal rather than an allocation.
    user_agent_owned: bool = false,

    proxy_bearer_header: ?[:0]const u8,

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const is_stealth = config.stealth();
        const owned = config.userAgent() != null or (!is_stealth and config.userAgentSuffix() != null);

        const user_agent: [:0]const u8 = if (config.userAgent()) |ua|
            try allocator.dupeZ(u8, ua)
        else if (is_stealth)
            stealthUserAgent(config.fingerprint_profile.platform)
        else if (config.userAgentSuffix()) |suffix|
            try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ user_agent_base, suffix }, 0)
        else
            user_agent_base;
        errdefer if (owned) allocator.free(user_agent);

        const proxy_bearer_header: ?[:0]const u8 = if (config.proxyBearerToken()) |token|
            try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{token}, 0)
        else
            null;

        return .{
            .user_agent = user_agent,
            .sec_ch_ua_header = if (is_stealth) sec_ch_ua_stealth else sec_ch_ua,
            .sec_ch_ua_platform_header = switch (config.fingerprint_profile.platform) {
                .windows => "\"Windows\"",
                .macos => "\"macOS\"",
                .linux => "\"Linux\"",
            },
            .brand_list = if (is_stealth) &brands_stealth else &brands,
            .stealth = is_stealth,
            .user_agent_owned = owned,
            .proxy_bearer_header = proxy_bearer_header,
        };
    }

    pub fn deinit(self: *const HttpHeaders, allocator: Allocator) void {
        if (self.proxy_bearer_header) |hdr| {
            allocator.free(hdr);
        }
        if (self.user_agent_owned) {
            allocator.free(self.user_agent);
        }
    }
};

pub fn printUsageAndExit(self: *const Config, allocator: Allocator, help_for: RunMode, success: bool) !void {
    const exec_name = self.exec_name;
    const Help = @import("help.zon");
    const info_or_warn = if (comptime lp.IS_DEBUG) "info" else "warn";
    const pretty_or_logfmt = if (comptime lp.IS_DEBUG) "pretty" else "logfmt";
    const comptimePrint = std.fmt.comptimePrint;

    const text = switch (help_for) {
        // Requested help for everything.
        .help => text: {
            const template = comptimePrint(
                \\{s}
                \\
            , .{Help.general});
            break :text try std.fmt.allocPrint(allocator, template, .{exec_name});
        },
        inline .fetch, .serve, .mcp, .agent, .run => |tag| text: {
            const template = comptimePrint(
                \\{s}
                \\
                \\{s}
                \\
            , .{ @field(Help, @tagName(tag)), Help.common_options });
            break :text try std.fmt.allocPrint(allocator, template, .{ exec_name, info_or_warn, pretty_or_logfmt });
        },
        .version => text: {
            const template = Help.version ++ "\n";
            break :text try std.fmt.allocPrint(allocator, template, .{exec_name});
        },
    };
    defer allocator.free(text);

    if (success) {
        printPaged(allocator, text);
        return std.process.cleanExit(lp.io);
    }
    var stderr = std.Io.File.stderr().writerStreaming(lp.io, &.{});
    stderr.interface.writeAll(text) catch {};
    std.process.exit(1);
}

fn printPlain(text: []const u8) void {
    var stdout = std.Io.File.stdout().writerStreaming(lp.io, &.{});
    stdout.interface.writeAll(text) catch {};
}

/// Pages explicitly requested help through $PAGER (fallback: less) when
/// stdout is an interactive terminal; prints plainly otherwise.
fn printPaged(allocator: Allocator, text: []const u8) void {
    const is_tty = std.Io.File.stdout().isTty(lp.io) catch false;
    if (!is_tty) {
        return printPlain(text);
    }
    const term = if (std.c.getenv("TERM")) |t| std.mem.span(t) else "";
    if (term.len == 0 or std.mem.eql(u8, term, "dumb")) {
        return printPlain(text);
    }

    const pager = if (std.c.getenv("PAGER")) |p| std.mem.span(p) else "";
    const argv: []const []const u8 = if (pager.len > 0)
        &.{ "/bin/sh", "-c", pager }
    else
        &.{ "less", "-FIRX" };

    // Pass the real environment so the pager sees TERM/LESS.
    var environ_map = lp.environMap(allocator) catch return printPlain(text);
    defer environ_map.deinit();

    // lp.io cannot spawn children: failing allocator, empty environ (no PATH).
    var pager_threaded: std.Io.Threaded = .init(allocator, .{ .environ = lp.environ() });
    defer pager_threaded.deinit();
    const pager_io = pager_threaded.io();

    var child = std.process.spawn(pager_io, .{
        .argv = argv,
        .environ_map = &environ_map,
        .stdin = .pipe,
    }) catch return printPlain(text);

    if (child.stdin) |stdin| {
        var writer = stdin.writerStreaming(pager_io, &.{});
        // A write error here is the pager exiting early (user quit, or the
        // command failed) — wait() below decides which.
        writer.interface.writeAll(text) catch {};
        stdin.close(pager_io);
        child.stdin = null;
    }

    const term_result = child.wait(pager_io) catch return printPlain(text);
    const clean_exit = term_result == .exited and term_result.exited == 0;
    // Quitting the pager early is still exit 0; a non-zero exit means the
    // pager failed (e.g. $PAGER not found) and the help was never shown.
    if (!clean_exit) {
        printPlain(text);
    }
}

pub fn parseArgs(allocator: Allocator, proc_args: std.process.Args) !Config {
    const exec_name, var command = try Commands.parse(allocator, proc_args);
    if (command == .serve and command.serve.timeout != null) {
        log.warn(.app, "--timeout is deprecated", .{});
    }
    const invoked = std.meta.activeTag(command);
    // Rewrite `run` to `.agent` so nothing downstream needs a `.run` case.
    if (command == .run) {
        const run = command.run;
        if (run.script_file == null) {
            log.fatal(.app, "missing script file", .{ .hint = "usage: lightpanda run <script.js>" });
            return error.MissingArgument;
        }
        // run's fields are a strict subset of Agent's (compile error otherwise).
        var agent_opts: Agent = .{};
        inline for (@typeInfo(@TypeOf(run)).@"struct".fields) |f| {
            @field(agent_opts, f.name) = @field(run, f.name);
        }
        command = .{ .agent = agent_opts };
    }
    var config = try Config.init(allocator, exec_name, command);
    config.command = invoked;
    return config;
}

test "Config: blockedUrlPatterns splits comma-separated patterns" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .block_urls = "*doubleclick*,*://*/*.png",
    } });
    defer config.deinit(std.testing.allocator);

    var patterns = config.blockedUrlPatterns().?;
    try std.testing.expectEqualStrings("*doubleclick*", patterns.next().?);
    try std.testing.expectEqualStrings("*://*/*.png", patterns.next().?);
    try std.testing.expectEqual(null, patterns.next());
}

pub fn validateUserAgent(ua: []const u8) !void {
    for (ua) |c| {
        if (!std.ascii.isPrint(c)) {
            return error.NonPrintable;
        }
    }

    if (std.ascii.indexOfIgnoreCase(ua, "mozilla") != null) {
        return error.Reserved;
    }
}

/// Tag names of a Zig enum, so a command's allowed values can't drift from the
/// enum it sets.
pub fn tagNames(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, &names) |f, *n| n.* = f.name;
    const frozen = names;
    return &frozen;
}

/// `<a|b|c>` ghost-text hint built from the same enum's tag names.
pub fn tagHint(comptime E: type) []const u8 {
    var s: []const u8 = "<";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) f.name else "|" ++ f.name);
    }
    return s ++ ">";
}

/// JSON array `["a","b","c"]` representation of the enum tag names.
pub fn tagJsonArray(comptime E: type) []const u8 {
    var s: []const u8 = "[";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) "\"" else ",\"") ++ f.name ++ "\"";
    }
    return s ++ "]";
}

test "Config: Chrome identity is default and --no-stealth opts out" {
    var default_config = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
    defer default_config.deinit(std.testing.allocator);
    try std.testing.expect(default_config.stealth());
    try std.testing.expect(default_config.fingerprint_profile.seed != 0);

    var honest_config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .no_stealth = true,
    } });
    defer honest_config.deinit(std.testing.allocator);
    try std.testing.expect(!honest_config.stealth());
    try std.testing.expectEqual(@as(u64, 0), honest_config.fingerprint_profile.seed);
}

test "Config: CLI accepts identity flags" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    {
        const argv = [_][*:0]const u8{ "lightpanda", "serve", "--no-stealth" };
        var config = try parseArgs(std.testing.allocator, .{ .vector = &argv });
        defer config.deinit(std.testing.allocator);
        try std.testing.expect(!config.stealth());
    }
    {
        const argv = [_][*:0]const u8{ "lightpanda", "serve", "--stealth", "--fingerprint", "42" };
        var config = try parseArgs(std.testing.allocator, .{ .vector = &argv });
        defer config.deinit(std.testing.allocator);
        try std.testing.expect(config.stealth());
        try std.testing.expectEqual(@as(?u64, 42), config.fingerprintSeed());
    }

    var seeded = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .fingerprint = 7,
        .fingerprint_platform = "macos",
    } });
    defer seeded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("macos", seeded.fingerprintPlatform().?);
    try std.testing.expectEqual(Fingerprint.Platform.macos, seeded.fingerprint_profile.platform);
}

test "Config: pi resource profile bounds expensive defaults" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .resource_profile = .pi,
    } });
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResourceProfile.pi, config.resourceProfile());
    try std.testing.expect(config.leanProfile());
    try std.testing.expectEqualStrings(pi_v8_flags, config.v8ProfileFlags().?);
    try std.testing.expectEqual(@as(?u32, 64), config.v8MaxHeapMb());
    try std.testing.expectEqual(@as(u8, 1), config.v8ThreadPoolSize());
    try std.testing.expect(!config.v8IdleTasks());
    try std.testing.expectEqual(@as(u8, 8), config.httpMaxConcurrent());
    try std.testing.expectEqual(@as(u8, 2), config.httpMaxHostOpen());
    try std.testing.expectEqual(@as(?usize, 32 * 1024 * 1024), config.httpMaxResponseSize());
    try std.testing.expectEqual(@as(?u32, 10_000), config.watchdogMs());
}

test "Config: only lean profiles set V8 memory flags" {
    var standard = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .resource_profile = .standard,
    } });
    defer standard.deinit(std.testing.allocator);
    try std.testing.expect(standard.v8ProfileFlags() == null);
    try std.testing.expect(standard.v8MaxHeapMb() == null);

    var pi = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .resource_profile = .pi,
    } });
    defer pi.deinit(std.testing.allocator);
    try std.testing.expect(pi.v8ProfileFlags() != null);
}

test "Config: slot resource profile is a lean single-session process" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .resource_profile = .slot,
    } });
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResourceProfile.slot, config.resourceProfile());
    try std.testing.expect(config.leanProfile());
    try std.testing.expectEqualStrings(pi_v8_flags, config.v8ProfileFlags().?);
    try std.testing.expectEqual(@as(?u32, 64), config.v8MaxHeapMb());
    try std.testing.expectEqual(@as(u8, 1), config.v8ThreadPoolSize());
    try std.testing.expectEqual(@as(u16, slot_max_connections), config.maxConnections());
    try std.testing.expectEqual(@as(u31, 2), config.maxPendingConnections());
    try std.testing.expectEqual(@as(?u32, 10_000), config.watchdogMs());
    try std.testing.expectEqual(@as(u32, 256 * 1024), config.cdpMaxMessageSize());

    config.mode.serve.cdp_max_connections = 8;
    try std.testing.expectEqual(@as(u16, 8), config.maxConnections());
}

test "Config: CLI parses slot profile" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][*:0]const u8{ "lightpanda", "serve", "--resource-profile", "slot" };
    var config = try parseArgs(std.testing.allocator, .{ .vector = &argv });
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResourceProfile.slot, config.resourceProfile());
}

test "Config: CLI parses pi profile and explicit resource limits" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][*:0]const u8{
        "lightpanda",
        "serve",
        "--resource-profile",
        "pi",
        "--cdp-max-connections",
        "4",
        "--v8-max-heap-mb",
        "128",
    };
    var config = try parseArgs(std.testing.allocator, .{ .vector = &argv });
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResourceProfile.pi, config.resourceProfile());
    try std.testing.expectEqual(@as(u16, 4), config.maxConnections());
    try std.testing.expectEqual(@as(?u32, 128), config.v8MaxHeapMb());
}

test "Config: CLI rejects an invalid resource profile" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][*:0]const u8{ "lightpanda", "serve", "--resource-profile", "potato" };
    try std.testing.expectError(
        error.InvalidArgument,
        parseArgs(std.testing.allocator, .{ .vector = &argv }),
    );
}

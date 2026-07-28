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

const cli = @import("cli.zig");
const dump = @import("browser/dump.zig");

const Storage = @import("storage/Storage.zig");
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
    .{ .name = "web_bot_auth_key_file", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_keyid", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_domain", .type = ?[]const u8 },
    .{ .name = "user_agent", .type = ?[]const u8 },
    .{ .name = "block_private_networks", .type = bool },
    .{ .name = "block_cidrs", .type = ?[]const u8 },
    .{ .name = "block_urls", .type = ?[]const u8 },
    .{ .name = "cookie", .type = ?[]const u8 },
    .{ .name = "cookie_jar", .type = ?[]const u8 },
    .{ .name = "storage_engine", .type = ?Storage.EngineType },
    .{ .name = "storage_sqlite_path", .type = ?[:0]const u8 },
    .{ .name = "disable_subframes", .type = bool },
    .{ .name = "disable_workers", .type = bool },
    .{ .name = "enable_external_stylesheets", .type = bool },
    .{ .name = "v8_flags_unsafe", .type = ?[]const u8 },
    .{ .name = "v8_max_heap_mb", .type = ?u32 },
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
            .{ .name = "cdp_max_connections", .type = u16, .default = 16 },
            .{ .name = "cdp_max_pending_connections", .type = u16, .default = 128 },
            .{ .name = "cdp_max_message_size", .type = u32, .default = 1024 * 1024 },
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
    };
    if (modeNeedsHttp(mode)) {
        config.http_headers = try HttpHeaders.init(allocator, &config);
    }
    return config;
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

pub fn disableWorkers(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.disable_workers,
        else => unreachable,
    };
}

pub fn watchdogMs(self: *const Config) ?u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| {
            const ms = opts.watchdog_ms orelse 30000;
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

pub fn v8MaxHeapMb(self: *const Config) ?u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_max_heap_mb,
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
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_concurrent orelse 40,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_host_open orelse 6,
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
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_response_size,
        else => unreachable,
    };
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.ws_max_concurrent orelse 8,
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

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections,
        .mcp => 16,
        .fetch, .agent => 0,
        else => unreachable,
    };
}

pub fn maxPendingConnections(self: *const Config) u31 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_pending_connections,
        .mcp => 128,
        else => unreachable,
    };
}

pub fn cdpMaxMessageSize(self: *const Config) u32 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_message_size,
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

pub fn storageEngine(self: *const Config) ?Storage.EngineType {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.storage_engine,
        else => unreachable,
    };
}

pub fn storageSqlitePath(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.storage_sqlite_path,
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

/// Pre-formatted HTTP headers for reuse across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub const HttpHeaders = struct {
    const user_agent_base: [:0]const u8 = "Lightpanda/1.0";

    const Brand = struct {
        brand: [:0]const u8,
        version: [:0]const u8,
    };

    /// Source of truth for client-hints brand data. Both the Sec-Ch-Ua
    /// HTTP header and navigator.userAgentData.brands derive from this
    /// list, so the two sides cannot drift.
    pub const brands = [_]Brand{
        .{ .brand = "Lightpanda", .version = "1" },
    };

    pub const sec_ch_ua: [:0]const u8 = blk: {
        var out: [:0]const u8 = "Sec-Ch-Ua:";
        for (brands, 0..) |b, i| {
            const sep = if (i == 0) " " else ", ";
            out = out ++ sep ++ "\"" ++ b.brand ++ "\";v=\"" ++ b.version ++ "\"";
        }
        break :blk out;
    };

    // Some bot-protection frontends (e.g. Akamai on canada.ca) RST the HTTP/2
    // stream when a client sends Accept-Encoding without Accept-Language,
    // treating it as a bot signal. Ship a neutral default so we look like a
    // normal client.
    pub const accept_language: [:0]const u8 = "Accept-Language: en-US,en;q=0.9";

    // Document-navigation Accept value Chrome sends.
    pub const navigation_accept: [:0]const u8 = "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";

    user_agent: [:0]const u8, // User agent value (e.g. "Lightpanda/1.0")
    user_agent_header: [:0]const u8,

    proxy_bearer_header: ?[:0]const u8,

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const user_agent: [:0]const u8 = if (config.userAgent()) |ua|
            try allocator.dupeZ(u8, ua)
        else if (config.userAgentSuffix()) |suffix|
            try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ user_agent_base, suffix }, 0)
        else
            user_agent_base;
        errdefer if (config.userAgent() != null or config.userAgentSuffix() != null) allocator.free(user_agent);

        const user_agent_header = try std.fmt.allocPrintSentinel(allocator, "User-Agent: {s}", .{user_agent}, 0);
        errdefer allocator.free(user_agent_header);

        const proxy_bearer_header: ?[:0]const u8 = if (config.proxyBearerToken()) |token|
            try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{token}, 0)
        else
            null;

        return .{
            .user_agent = user_agent,
            .user_agent_header = user_agent_header,
            .proxy_bearer_header = proxy_bearer_header,
        };
    }

    pub fn deinit(self: *const HttpHeaders, allocator: Allocator) void {
        if (self.proxy_bearer_header) |hdr| {
            allocator.free(hdr);
        }
        allocator.free(self.user_agent_header);
        if (self.user_agent.ptr != user_agent_base.ptr) {
            allocator.free(self.user_agent);
        }
    }
};

pub fn printUsageAndExit(self: *const Config, allocator: Allocator, help_for: RunMode, success: bool) !void {
    const exec_name = self.exec_name;
    const Help = @import("help.zon");
    const is_debug = builtin.mode == .Debug;
    const info_or_warn = if (comptime is_debug) "info" else "warn";
    const pretty_or_logfmt = if (comptime is_debug) "pretty" else "logfmt";
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

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
const lp = @import("lightpanda");
const log = lp.log;
const builtin = @import("builtin");

const cli = @import("cli.zig");
const dump = @import("browser/dump.zig");

const mcp = @import("mcp.zig");
const Storage = @import("storage/Storage.zig");
const WebBotAuthConfig = @import("network/WebBotAuth.zig").Config;

const Allocator = std.mem.Allocator;

pub const CDP_MAX_HTTP_REQUEST_SIZE = 4096;

// max message size
// +14 for max websocket payload overhead
// +140 for the max control packet that might be interleaved in a message
pub const CDP_MAX_MESSAGE_SIZE = 512 * 1024 + 14 + 140;

// TCP keepalive parameters applied to accepted CDP connections.
// Detection window ≈ IDLE + CNT * INTVL = 4 + 3*2 = 10s.
pub const CDP_KEEPALIVE_IDLE_S: c_int = 4;
pub const CDP_KEEPALIVE_INTVL_S: c_int = 2;
pub const CDP_KEEPALIVE_CNT: c_int = 3;

const Config = @This();

fn logFilterScopesValidator(allocator: Allocator, args: *std.process.ArgIterator, list: *std.ArrayList(log.Scope)) !void {
    const str = args.next() orelse return error.InvalidOption;

    var it = std.mem.splitScalar(u8, str, ',');
    while (it.next()) |part| {
        const v = std.meta.stringToEnum(log.Scope, part) orelse {
            log.fatal(.app, "invalid option choice", .{ .arg = "--log-filter-scopes", .value = part });
            return error.InvalidOption;
        };

        try list.append(allocator, v);
    }
}

fn logLevelValidator(_: Allocator, args: *std.process.ArgIterator) !?log.Level {
    const str = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, str, "error")) {
        return .err;
    }

    return std.meta.stringToEnum(log.Level, str) orelse {
        log.fatal(.app, "invalid option choice", .{ .arg = "--log-level", .value = str });
        return error.InvalidArgument;
    };
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
    .{ .name = "log_filter_scopes", .type = log.Scope, .multiple = true, .validator = logFilterScopesValidator },
    .{ .name = "user_agent_suffix", .type = ?[]const u8 },
    .{ .name = "http_cache_dir", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_key_file", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_keyid", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_domain", .type = ?[]const u8 },
    .{ .name = "user_agent", .type = ?[]const u8 },
    .{ .name = "block_private_networks", .type = bool },
    .{ .name = "block_cidrs", .type = ?[]const u8 },
    .{ .name = "cookie", .type = ?[]const u8 },
    .{ .name = "cookie_jar", .type = ?[]const u8 },
    .{ .name = "storage_engine", .type = ?Storage.EngineType },
    .{ .name = "storage_sqlite_path", .type = ?[:0]const u8 },
};

fn dumpValidator(_: Allocator, args: *std.process.ArgIterator) !?DumpFormat {
    // Peek next argument.
    var peek_args = args.*;
    if (peek_args.next()) |next_arg| {
        const mode = std.meta.stringToEnum(DumpFormat, next_arg) orelse {
            return .html;
        };

        // Skip the argument we peek if successful.
        _ = args.next();
        return mode;
    }

    // Means we couldn't get something like `--dump html` but we do have
    // `--dump`; which should fall to `html` by default.
    return .html;
}

fn waitScriptFileValidator(allocator: Allocator, args: *std.process.ArgIterator) !?[:0]const u8 {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--wait-script-file" });
        return error.InvalidArgument;
    };

    return std.fs.cwd().readFileAllocOptions(allocator, path, 1024 * 1024, null, .of(u8), 0) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--wait-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };
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
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "fetch",
        // This argument can be given out of order.
        .positional = .{ .name = "url", .type = ?[:0]const u8 },
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
            .{ .name = "terminate_ms", .type = ?u32 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "mcp",
        .options = .{
            .{ .name = "cdp_port", .type = ?u16 },
        },
        .shared_options = CommonOptions,
    },
    .{ .name = "version", .options = .{} },
    .{ .name = "help", .options = .{} },
});

pub const RunMode = Commands.Enum;
pub const Mode = Commands.Union;

mode: Mode,
exec_name: []const u8,
http_headers: HttpHeaders,

pub fn init(allocator: Allocator, exec_name: []const u8, mode: Mode) !Config {
    var config = Config{
        .mode = mode,
        .exec_name = exec_name,
        .http_headers = undefined,
    };
    config.http_headers = try HttpHeaders.init(allocator, &config);
    return config;
}

pub fn deinit(self: *const Config, allocator: Allocator) void {
    self.http_headers.deinit(allocator);
}

pub fn tlsVerifyHost(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| !opts.insecure_disable_tls_host_verification,
        else => unreachable,
    };
}

pub fn obeyRobots(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.obey_robots,
        else => unreachable,
    };
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_proxy,
        else => unreachable,
    };
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.proxy_bearer_token,
        .help, .version => null,
    };
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_max_concurrent orelse 10,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_max_host_open orelse 4,
        else => unreachable,
    };
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_connect_timeout orelse 0,
        else => unreachable,
    };
}

pub fn httpTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_timeout orelse 5000,
        else => unreachable,
    };
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 10;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_max_response_size,
        else => unreachable,
    };
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.ws_max_concurrent orelse 8,
        else => unreachable,
    };
}

pub fn logLevel(self: *const Config) ?log.Level {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_level,
        else => unreachable,
    };
}

pub fn logFormat(self: *const Config) ?log.Format {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_format,
        else => unreachable,
    };
}

pub fn logFilterScopes(self: *const Config) std.ArrayList(log.Scope) {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.log_filter_scopes,
        else => unreachable,
    };
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.user_agent_suffix,
        .help, .version => null,
    };
}

pub fn userAgent(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.user_agent,
        .help, .version => null,
    };
}

pub fn httpCacheDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.http_cache_dir,
        else => null,
    };
}

pub fn cookieFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.cookie,
        else => null,
    };
}

pub fn cookieJarFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .fetch, .mcp => |opts| opts.cookie_jar,
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
        inline .serve, .fetch, .mcp => |opts| WebBotAuthConfig{
            .key_file = opts.web_bot_auth_key_file orelse return null,
            .keyid = opts.web_bot_auth_keyid orelse return null,
            .domain = opts.web_bot_auth_domain orelse return null,
        },
        .help, .version => null,
    };
}

pub fn blockPrivateNetworks(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.block_private_networks,
        else => unreachable,
    };
}

pub fn blockCidrs(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.block_cidrs,
        else => unreachable,
    };
}

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections,
        .mcp => 16,
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

pub fn storageEngine(self: *const Config) ?Storage.EngineType {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.storage_engine,
        else => unreachable,
    };
}

pub fn storageSqlitePath(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp => |opts| opts.storage_sqlite_path,
        else => unreachable,
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

pub fn printUsageAndExit(self: *const Config, success: bool) void {
    //                                                                     MAX_HELP_LEN|
    const common_options =
        \\
        \\--insecure-disable-tls-host-verification
        \\                Disables host verification on all HTTP requests. This is an
        \\                advanced option which should only be set if you understand
        \\                and accept the risk of disabling host verification.
        \\
        \\--obey-robots
        \\                Fetches and obeys the robots.txt (if available) of the web pages
        \\                we make requests towards.
        \\                Defaults to false.
        \\
        \\--block-private-networks
        \\                Blocks HTTP requests to private/internal IP addresses
        \\                after DNS resolution. Useful for sandboxing, multi-tenant
        \\                deployments, and preventing access to internal infrastructure
        \\                regardless of what triggers the request (JavaScript, HTML
        \\                resources, redirects, etc.).
        \\                Defaults to false.
        \\
        \\--block-cidrs
        \\                Additional CIDR ranges to block, comma-separated.
        \\                Prefix with '-' to allow (exempt from blocking).
        \\                e.g. --block-cidrs 169.254.169.254/32,fd00:ec2::254/128
        \\                e.g. --block-cidrs 10.0.0.0/8,-10.0.0.42/32
        \\                Can be used standalone or combined with --block-private-networks.
        \\
        \\--http-proxy    The HTTP proxy to use for all HTTP requests.
        \\                A username:password can be included for basic authentication.
        \\                Defaults to none.
        \\
        \\--proxy-bearer-token
        \\                The <token> to send for bearer authentication with the proxy
        \\                Proxy-Authorization: Bearer <token>
        \\
        \\--http-max-concurrent
        \\                The maximum number of concurrent HTTP requests.
        \\                Defaults to 10.
        \\
        \\--http-max-host-open
        \\                The maximum number of open connection to a given host:port.
        \\                Defaults to 4.
        \\
        \\--http-connect-timeout
        \\                The time, in milliseconds, for establishing an HTTP connection
        \\                before timing out. 0 means it never times out.
        \\                Defaults to 0.
        \\
        \\--http-timeout
        \\                The maximum time, in milliseconds, the transfer is allowed
        \\                to complete. 0 means it never times out.
        \\                Defaults to 10000.
        \\
        \\--http-max-response-size
        \\                Limits the acceptable response size for any request
        \\                (e.g. XHR, fetch, script loading, ...).
        \\                Defaults to no limit.
        \\
        \\--ws-max-concurrent
        \\                The maximum number of concurrent WebSocket connections.
        \\                Defaults to 8.
        \\
        \\--log-level     The log level: debug, info, warn, error or fatal.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " info." else "warn.") ++
        \\
        \\
        \\--log-format    The log format: pretty or logfmt.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " pretty." else " logfmt.") ++
        \\
        \\
        \\--log-filter-scopes
        \\                Filter out too verbose logs per scope:
        \\                http, unknown_prop, event, ...
        \\
        \\--user-agent    Override the User-Agent header entirely
        \\                User-Agent mustn't impersonate other browser.
        \\                Any value containing "Mozilla" is forbidden.
        \\                The browser will continue to send Sec-Ch-Ua header.
        \\                Incompatible with --user-agent-suffix
        \\
        \\--user-agent-suffix
        \\                Suffix to append to the Lightpanda/X.Y User-Agent
        \\
        \\--web-bot-auth-key-file
        \\                Path to the Ed25519 private key PEM file.
        \\
        \\--web-bot-auth-keyid
        \\                The JWK thumbprint of your public key.
        \\
        \\--web-bot-auth-domain
        \\                Your domain e.g. yourdomain.com
        \\
        \\--http-cache-dir
        \\                Path to a directory to use as a Filesystem Cache for network resources.
        \\                Omitting this will result is no caching.
        \\                Defaults to no caching.
        \\
        \\--storage-engine
        \\                The storage engine to use. Choices are: none, sqlite.
        \\                Default to none.
        \\
        \\--storage-sqlite-path
        \\                Path to SQLite database file for persistent storage.
        \\                Use ":memory:" for in-memory storage.
    ;

    //                                                                     MAX_HELP_LEN|
    const usage =
        \\usage: {0s} command [options] [URL]
        \\
        \\Command can be either 'fetch', 'serve', 'mcp' or 'help'
        \\
        \\fetch command
        \\Fetches the specified URL
        \\Example: {0s} fetch --dump html https://lightpanda.io/
        \\
        \\Options:
        \\--dump          Dumps document to stdout.
        \\                Argument must be 'html', 'markdown', 'semantic_tree', or 'semantic_tree_text'.
        \\                Defaults to no dump.
        \\
        \\--strip-mode    Comma separated list of tag groups to remove from dump
        \\                the dump. e.g. --strip-mode js,css
        \\                  - "js" script and link[as=script, rel=preload]
        \\                  - "ui" includes img, picture, video, css and svg
        \\                  - "css" includes style and link[rel=stylesheet]
        \\                  - "full" includes js, ui and css
        \\
        \\--with-base     Add a <base> tag in dump. Defaults to false.
        \\
        \\--with-frames   Includes the contents of iframes. Defaults to false.
        \\
        \\--wait-ms       Wait time in milliseconds. Supersedes all other --wait
        \\                parameters.
        \\                Defaults to 5000.
        \\
        \\--wait-until    Wait until the specified event. Checked before the other
        \\                --wait- options. Supported events: load, domcontentloaded,
        \\                networkidle, done.
        \\                Defaults to 'done'. If --wait-selector, --wait-script or
        \\                --wait-script-file are specified, defaults to none.
        \\
        \\--wait-selector Wait for an element matching the CSS selector to appear.
        \\                Checked after --wait-until condition is met.
        \\
        \\--wait-script   Wait for a JavaScript expression to return truthy.
        \\                Checked after --wait-until condition is met.
        \\
        \\--wait-script-file
        \\                Like --wait-script, but reads the script from a file.
        \\
        \\--terminate-ms  Hard deadline in milliseconds. After this time elapses,
        \\                JavaScript execution is forcibly terminated (e.g. for
        \\                pages with endless scripts). Unlike --wait-ms, which
        \\                only stops waiting, --terminate-ms aborts the page.
        \\                Defaults to no terminate.
        \\
        \\--cookie        Path to a JSON file to load cookies from (read-only).
        \\                Defaults to no cookie loading.
        \\
        \\--cookie-jar    Path to a JSON file to save cookies to on exit (write-only).
        \\                Available for fetch and mcp commands.
        \\                Defaults to no cookie saving.
        \\
    ++ common_options ++
        \\
        \\serve command
        \\Starts a websocket CDP server
        \\Example: {0s} serve --host 127.0.0.1 --port 9222
        \\
        \\Options:
        \\--host          Host of the CDP server
        \\                Defaults to "127.0.0.1"
        \\
        \\--port          Port of the CDP server
        \\                Defaults to 9222
        \\
        \\--advertise-host
        \\                The host to advertise, e.g. in the /json/version response.
        \\                Useful, for example, when --host is 0.0.0.0.
        \\                Defaults to --host value
        \\
        \\--cdp-max-connections
        \\                Maximum number of simultaneous CDP connections.
        \\                Defaults to 16.
        \\
        \\--cdp-max-pending-connections
        \\                Maximum pending connections in the accept queue.
        \\                Defaults to 128.
        \\
        \\--cookie        Path to a JSON file to load cookies from (read-only).
        \\                Defaults to no cookie loading.
        \\
    ++ common_options ++
        \\
        \\mcp command
        \\Starts an MCP (Model Context Protocol) server over stdio
        \\Example: {0s} mcp
        \\
        \\--cookie        Path to a JSON file to load cookies from (read-only).
        \\                Defaults to no cookie loading.
        \\
        \\--cookie-jar    Path to a JSON file to save cookies to on exit (write-only).
        \\                Available for fetch and mcp commands.
        \\                Defaults to no cookie saving.
        \\
    ++ common_options ++
        \\
        \\version command
        \\Displays the version of {0s}
        \\
        \\help command
        \\Displays this message
        \\
    ;
    std.debug.print(usage, .{self.exec_name});
    if (success) {
        return std.process.cleanExit();
    }
    std.process.exit(1);
}

pub fn parseArgs(allocator: Allocator) !Config {
    const exec_name, const command = try Commands.parse(allocator);
    if (command == .serve and command.serve.timeout != null) {
        log.warn(.app, "--timeout is deprecated", .{});
    }
    return .init(allocator, exec_name, command);
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

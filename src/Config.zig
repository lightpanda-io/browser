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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const dump = @import("browser/dump.zig");

pub const RunMode = enum {
    help,
    fetch,
    serve,
    version,
};

pub const CDP_MAX_HTTP_REQUEST_SIZE = 4096;

// max message size
// +14 for max websocket payload overhead
// +140 for the max control packet that might be interleaved in a message
pub const CDP_MAX_MESSAGE_SIZE = 512 * 1024 + 14 + 140;

mode: Mode,
exec_name: []const u8,
http_headers: HttpHeaders,

const Config = @This();

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
        inline .serve, .fetch => |opts| opts.common.tls_verify_host,
        else => unreachable,
    };
}

pub fn obeyRobots(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.obey_robots,
        else => unreachable,
    };
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_proxy,
        else => unreachable,
    };
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.proxy_bearer_token,
        .help, .version => null,
    };
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_max_concurrent orelse 10,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_max_host_open orelse 4,
        else => unreachable,
    };
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_connect_timeout orelse 0,
        else => unreachable,
    };
}

pub fn httpTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_timeout orelse 5000,
        else => unreachable,
    };
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 10;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.http_max_response_size,
        else => unreachable,
    };
}

pub fn logLevel(self: *const Config) ?log.Level {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.log_level,
        else => unreachable,
    };
}

pub fn logFormat(self: *const Config) ?log.Format {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.log_format,
        else => unreachable,
    };
}

pub fn logFilterScopes(self: *const Config) ?[]const log.Scope {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.log_filter_scopes,
        else => unreachable,
    };
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch => |opts| opts.common.user_agent_suffix,
        .help, .version => null,
    };
}

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections,
        else => unreachable,
    };
}

pub fn maxPendingConnections(self: *const Config) u31 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_pending_connections,
        else => unreachable,
    };
}

pub const Mode = union(RunMode) {
    help: bool, // false when being printed because of an error
    fetch: Fetch,
    serve: Serve,
    version: void,
};

pub const Serve = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9222,
    timeout: u31 = 10,
    cdp_max_connections: u16 = 16,
    cdp_max_pending_connections: u16 = 128,
    common: Common = .{},
};

pub const DumpFormat = enum {
    html,
    markdown,
};

pub const Fetch = struct {
    url: [:0]const u8,
    dump_mode: ?DumpFormat = null,
    common: Common = .{},
    withbase: bool = false,
    strip: dump.Opts.Strip = .{},
};

pub const Common = struct {
    obey_robots: bool = false,
    proxy_bearer_token: ?[:0]const u8 = null,
    http_proxy: ?[:0]const u8 = null,
    http_max_concurrent: ?u8 = null,
    http_max_host_open: ?u8 = null,
    http_timeout: ?u31 = null,
    http_connect_timeout: ?u31 = null,
    http_max_response_size: ?usize = null,
    tls_verify_host: bool = true,
    log_level: ?log.Level = null,
    log_format: ?log.Format = null,
    log_filter_scopes: ?[]log.Scope = null,
    user_agent_suffix: ?[]const u8 = null,
};

/// Pre-formatted HTTP headers for reuse across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub const HttpHeaders = struct {
    const user_agent_base: [:0]const u8 = "Lightpanda/1.0";

    user_agent: [:0]const u8, // User agent value (e.g. "Lightpanda/1.0")
    user_agent_header: [:0]const u8,

    proxy_bearer_header: ?[:0]const u8,

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const user_agent: [:0]const u8 = if (config.userAgentSuffix()) |suffix|
            try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ user_agent_base, suffix }, 0)
        else
            user_agent_base;
        errdefer if (config.userAgentSuffix() != null) allocator.free(user_agent);

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
        \\--insecure_disable_tls_host_verification
        \\                Disables host verification on all HTTP requests. This is an
        \\                advanced option which should only be set if you understand
        \\                and accept the risk of disabling host verification.
        \\
        \\--obey_robots
        \\                Fetches and obeys the robots.txt (if available) of the web pages
        \\                we make requests towards.
        \\                Defaults to false.
        \\
        \\--http_proxy    The HTTP proxy to use for all HTTP requests.
        \\                A username:password can be included for basic authentication.
        \\                Defaults to none.
        \\
        \\--proxy_bearer_token
        \\                The <token> to send for bearer authentication with the proxy
        \\                Proxy-Authorization: Bearer <token>
        \\
        \\--http_max_concurrent
        \\                The maximum number of concurrent HTTP requests.
        \\                Defaults to 10.
        \\
        \\--http_max_host_open
        \\                The maximum number of open connection to a given host:port.
        \\                Defaults to 4.
        \\
        \\--http_connect_timeout
        \\                The time, in milliseconds, for establishing an HTTP connection
        \\                before timing out. 0 means it never times out.
        \\                Defaults to 0.
        \\
        \\--http_timeout
        \\                The maximum time, in milliseconds, the transfer is allowed
        \\                to complete. 0 means it never times out.
        \\                Defaults to 10000.
        \\
        \\--http_max_response_size
        \\                Limits the acceptable response size for any request
        \\                (e.g. XHR, fetch, script loading, ...).
        \\                Defaults to no limit.
        \\
        \\--log_level     The log level: debug, info, warn, error or fatal.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " info." else "warn.") ++
        \\
        \\
        \\--log_format    The log format: pretty or logfmt.
        \\                Defaults to
    ++ (if (builtin.mode == .Debug) " pretty." else " logfmt.") ++
        \\
        \\
        \\--log_filter_scopes
        \\                Filter out too verbose logs per scope:
        \\                http, unknown_prop, event, ...
        \\
        \\--user_agent_suffix
        \\                Suffix to append to the Lightpanda/X.Y User-Agent
        \\
    ;

    //                                                                     MAX_HELP_LEN|
    const usage =
        \\usage: {s} command [options] [URL]
        \\
        \\Command can be either 'fetch', 'serve' or 'help'
        \\
        \\fetch command
        \\Fetches the specified URL
        \\Example: {s} fetch --dump html https://lightpanda.io/
        \\
        \\Options:
        \\--dump          Dumps document to stdout.
        \\                Argument must be 'html' or 'markdown'.
        \\                Defaults to no dump.
        \\
        \\--strip_mode    Comma separated list of tag groups to remove from dump
        \\                the dump. e.g. --strip_mode js,css
        \\                  - "js" script and link[as=script, rel=preload]
        \\                  - "ui" includes img, picture, video, css and svg
        \\                  - "css" includes style and link[rel=stylesheet]
        \\                  - "full" includes js, ui and css
        \\
        \\--with_base     Add a <base> tag in dump. Defaults to false.
        \\
    ++ common_options ++
        \\
        \\serve command
        \\Starts a websocket CDP server
        \\Example: {s} serve --host 127.0.0.1 --port 9222
        \\
        \\Options:
        \\--host          Host of the CDP server
        \\                Defaults to "127.0.0.1"
        \\
        \\--port          Port of the CDP server
        \\                Defaults to 9222
        \\
        \\--timeout       Inactivity timeout in seconds before disconnecting clients
        \\                Defaults to 10 (seconds). Limited to 604800 (1 week).
        \\
        \\--cdp_max_connections
        \\                Maximum number of simultaneous CDP connections.
        \\                Defaults to 16.
        \\
        \\--cdp_max_pending_connections
        \\                Maximum pending connections in the accept queue.
        \\                Defaults to 128.
        \\
    ++ common_options ++
        \\
        \\version command
        \\Displays the version of {s}
        \\
        \\help command
        \\Displays this message
        \\
    ;
    std.debug.print(usage, .{ self.exec_name, self.exec_name, self.exec_name, self.exec_name });
    if (success) {
        return std.process.cleanExit();
    }
    std.process.exit(1);
}

pub fn parseArgs(allocator: Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const exec_name = try allocator.dupe(u8, std.fs.path.basename(args.next().?));

    const mode_string = args.next() orelse "";
    const run_mode = std.meta.stringToEnum(RunMode, mode_string) orelse blk: {
        const inferred_mode = inferMode(mode_string) orelse
            return init(allocator, exec_name, .{ .help = false });
        // "command" wasn't a command but an option. We can't reset args, but
        // we can create a new one. Not great, but this fallback is temporary
        // as we transition to this command mode approach.
        args.deinit();

        args = try std.process.argsWithAllocator(allocator);
        // skip the exec_name
        _ = args.skip();

        break :blk inferred_mode;
    };

    const mode: Mode = switch (run_mode) {
        .help => .{ .help = true },
        .serve => .{ .serve = parseServeArgs(allocator, &args) catch
            return init(allocator, exec_name, .{ .help = false }) },
        .fetch => .{ .fetch = parseFetchArgs(allocator, &args) catch
            return init(allocator, exec_name, .{ .help = false }) },
        .version => .{ .version = {} },
    };
    return init(allocator, exec_name, mode);
}

fn inferMode(opt: []const u8) ?RunMode {
    if (opt.len == 0) {
        return .serve;
    }

    if (std.mem.startsWith(u8, opt, "--") == false) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--dump")) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--noscript")) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--strip_mode")) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--with_base")) {
        return .fetch;
    }

    if (std.mem.eql(u8, opt, "--host")) {
        return .serve;
    }

    if (std.mem.eql(u8, opt, "--port")) {
        return .serve;
    }

    if (std.mem.eql(u8, opt, "--timeout")) {
        return .serve;
    }

    return null;
}

fn parseServeArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Serve {
    var serve: Serve = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--host", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--host" });
                return error.InvalidArgument;
            };
            serve.host = try allocator.dupe(u8, str);
            continue;
        }

        if (std.mem.eql(u8, "--port", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--port" });
                return error.InvalidArgument;
            };

            serve.port = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.fatal(.app, "invalid argument value", .{ .arg = "--port", .err = err });
                return error.InvalidArgument;
            };
            continue;
        }

        if (std.mem.eql(u8, "--timeout", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--timeout" });
                return error.InvalidArgument;
            };

            serve.timeout = std.fmt.parseInt(u31, str, 10) catch |err| {
                log.fatal(.app, "invalid argument value", .{ .arg = "--timeout", .err = err });
                return error.InvalidArgument;
            };
            continue;
        }

        if (std.mem.eql(u8, "--cdp_max_connections", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--cdp_max_connections" });
                return error.InvalidArgument;
            };

            serve.cdp_max_connections = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.fatal(.app, "invalid argument value", .{ .arg = "--cdp_max_connections", .err = err });
                return error.InvalidArgument;
            };
            continue;
        }

        if (std.mem.eql(u8, "--cdp_max_pending_connections", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--cdp_max_pending_connections" });
                return error.InvalidArgument;
            };

            serve.cdp_max_pending_connections = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.fatal(.app, "invalid argument value", .{ .arg = "--cdp_max_pending_connections", .err = err });
                return error.InvalidArgument;
            };
            continue;
        }

        if (try parseCommonArg(allocator, opt, args, &serve.common)) {
            continue;
        }

        log.fatal(.app, "unknown argument", .{ .mode = "serve", .arg = opt });
        return error.UnkownOption;
    }

    return serve;
}

fn parseFetchArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Fetch {
    var dump_mode: ?DumpFormat = null;
    var withbase: bool = false;
    var url: ?[:0]const u8 = null;
    var common: Common = .{};
    var strip: dump.Opts.Strip = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            var peek_args = args.*;
            if (peek_args.next()) |next_arg| {
                if (std.meta.stringToEnum(DumpFormat, next_arg)) |mode| {
                    dump_mode = mode;
                    _ = args.next();
                } else {
                    dump_mode = .html;
                }
            } else {
                dump_mode = .html;
            }
            continue;
        }

        if (std.mem.eql(u8, "--noscript", opt)) {
            log.warn(.app, "deprecation warning", .{
                .feature = "--noscript argument",
                .hint = "use '--strip_mode js' instead",
            });
            strip.js = true;
            continue;
        }

        if (std.mem.eql(u8, "--with_base", opt)) {
            withbase = true;
            continue;
        }

        if (std.mem.eql(u8, "--strip_mode", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--strip_mode" });
                return error.InvalidArgument;
            };

            var it = std.mem.splitScalar(u8, str, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
                if (std.mem.eql(u8, trimmed, "js")) {
                    strip.js = true;
                } else if (std.mem.eql(u8, trimmed, "ui")) {
                    strip.ui = true;
                } else if (std.mem.eql(u8, trimmed, "css")) {
                    strip.css = true;
                } else if (std.mem.eql(u8, trimmed, "full")) {
                    strip.js = true;
                    strip.ui = true;
                    strip.css = true;
                } else {
                    log.fatal(.app, "invalid option choice", .{ .arg = "--strip_mode", .value = trimmed });
                }
            }
            continue;
        }

        if (try parseCommonArg(allocator, opt, args, &common)) {
            continue;
        }

        if (std.mem.startsWith(u8, opt, "--")) {
            log.fatal(.app, "unknown argument", .{ .mode = "fetch", .arg = opt });
            return error.UnkownOption;
        }

        if (url != null) {
            log.fatal(.app, "duplicate fetch url", .{ .help = "only 1 URL can be specified" });
            return error.TooManyURLs;
        }
        url = try allocator.dupeZ(u8, opt);
    }

    if (url == null) {
        log.fatal(.app, "missing fetch url", .{ .help = "URL to fetch must be provided" });
        return error.MissingURL;
    }

    return .{
        .url = url.?,
        .dump_mode = dump_mode,
        .strip = strip,
        .common = common,
        .withbase = withbase,
    };
}

fn parseCommonArg(
    allocator: Allocator,
    opt: []const u8,
    args: *std.process.ArgIterator,
    common: *Common,
) !bool {
    if (std.mem.eql(u8, "--insecure_disable_tls_host_verification", opt)) {
        common.tls_verify_host = false;
        return true;
    }

    if (std.mem.eql(u8, "--obey_robots", opt)) {
        common.obey_robots = true;
        return true;
    }

    if (std.mem.eql(u8, "--http_proxy", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_proxy" });
            return error.InvalidArgument;
        };
        common.http_proxy = try allocator.dupeZ(u8, str);
        return true;
    }

    if (std.mem.eql(u8, "--proxy_bearer_token", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--proxy_bearer_token" });
            return error.InvalidArgument;
        };
        common.proxy_bearer_token = try allocator.dupeZ(u8, str);
        return true;
    }

    if (std.mem.eql(u8, "--http_max_concurrent", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_max_concurrent" });
            return error.InvalidArgument;
        };

        common.http_max_concurrent = std.fmt.parseInt(u8, str, 10) catch |err| {
            log.fatal(.app, "invalid argument value", .{ .arg = "--http_max_concurrent", .err = err });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--http_max_host_open", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_max_host_open" });
            return error.InvalidArgument;
        };

        common.http_max_host_open = std.fmt.parseInt(u8, str, 10) catch |err| {
            log.fatal(.app, "invalid argument value", .{ .arg = "--http_max_host_open", .err = err });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--http_connect_timeout", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_connect_timeout" });
            return error.InvalidArgument;
        };

        common.http_connect_timeout = std.fmt.parseInt(u31, str, 10) catch |err| {
            log.fatal(.app, "invalid argument value", .{ .arg = "--http_connect_timeout", .err = err });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--http_timeout", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_timeout" });
            return error.InvalidArgument;
        };

        common.http_timeout = std.fmt.parseInt(u31, str, 10) catch |err| {
            log.fatal(.app, "invalid argument value", .{ .arg = "--http_timeout", .err = err });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--http_max_response_size", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--http_max_response_size" });
            return error.InvalidArgument;
        };

        common.http_max_response_size = std.fmt.parseInt(usize, str, 10) catch |err| {
            log.fatal(.app, "invalid argument value", .{ .arg = "--http_max_response_size", .err = err });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--log_level", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--log_level" });
            return error.InvalidArgument;
        };

        common.log_level = std.meta.stringToEnum(log.Level, str) orelse blk: {
            if (std.mem.eql(u8, str, "error")) {
                break :blk .err;
            }
            log.fatal(.app, "invalid option choice", .{ .arg = "--log_level", .value = str });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--log_format", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--log_format" });
            return error.InvalidArgument;
        };

        common.log_format = std.meta.stringToEnum(log.Format, str) orelse {
            log.fatal(.app, "invalid option choice", .{ .arg = "--log_format", .value = str });
            return error.InvalidArgument;
        };
        return true;
    }

    if (std.mem.eql(u8, "--log_filter_scopes", opt)) {
        if (builtin.mode != .Debug) {
            log.fatal(.app, "experimental", .{ .help = "log scope filtering is only available in debug builds" });
            return false;
        }

        const str = args.next() orelse {
            // disables the default filters
            common.log_filter_scopes = &.{};
            return true;
        };

        var arr: std.ArrayList(log.Scope) = .empty;

        var it = std.mem.splitScalar(u8, str, ',');
        while (it.next()) |part| {
            try arr.append(allocator, std.meta.stringToEnum(log.Scope, part) orelse {
                log.fatal(.app, "invalid option choice", .{ .arg = "--log_filter_scopes", .value = part });
                return false;
            });
        }
        common.log_filter_scopes = arr.items;
        return true;
    }

    if (std.mem.eql(u8, "--user_agent_suffix", opt)) {
        const str = args.next() orelse {
            log.fatal(.app, "missing argument value", .{ .arg = "--user_agent_suffix" });
            return error.InvalidArgument;
        };
        for (str) |c| {
            if (!std.ascii.isPrint(c)) {
                log.fatal(.app, "not printable character", .{ .arg = "--user_agent_suffix" });
                return error.InvalidArgument;
            }
        }
        common.user_agent_suffix = try allocator.dupe(u8, str);
        return true;
    }

    return false;
}

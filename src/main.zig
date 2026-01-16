// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = lp.log;
const App = lp.App;
const SigHandler = @import("Sighandler.zig");
pub const panic = lp.crash_handler.panic;

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    const gpa = if (builtin.mode == .Debug) gpa_instance.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa_instance.detectLeaks()) std.posix.exit(1);
    };

    // arena for main-specific allocations
    var main_arena_instance = std.heap.ArenaAllocator.init(gpa);
    const main_arena = main_arena_instance.allocator();
    defer main_arena_instance.deinit();

    var sighandler = SigHandler{ .arena = main_arena };
    try sighandler.install();

    run(gpa, main_arena, &sighandler) catch |err| {
        log.fatal(.app, "exit", .{ .err = err });
        std.posix.exit(1);
    };
}

fn run(allocator: Allocator, main_arena: Allocator, sighandler: *SigHandler) !void {
    const args = try parseArgs(main_arena);

    switch (args.mode) {
        .help => {
            args.printUsageAndExit(args.mode.help);
            return std.process.cleanExit();
        },
        .version => {
            std.debug.print("{s}\n", .{lp.build_config.git_commit});
            return std.process.cleanExit();
        },
        else => {},
    }

    if (args.logLevel()) |ll| {
        log.opts.level = ll;
    }
    if (args.logFormat()) |lf| {
        log.opts.format = lf;
    }
    if (args.logFilterScopes()) |lfs| {
        log.opts.filter_scopes = lfs;
    }

    const user_agent = blk: {
        const USER_AGENT = "User-Agent: Lightpanda/1.0";
        if (args.userAgentSuffix()) |suffix| {
            break :blk try std.fmt.allocPrintSentinel(main_arena, "{s} {s}", .{ USER_AGENT, suffix }, 0);
        }
        break :blk USER_AGENT;
    };

    // _app is global to handle graceful shutdown.
    var app = try App.init(allocator, .{
        .run_mode = args.mode,
        .http_proxy = args.httpProxy(),
        .proxy_bearer_token = args.proxyBearerToken(),
        .tls_verify_host = args.tlsVerifyHost(),
        .http_timeout_ms = args.httpTimeout(),
        .http_connect_timeout_ms = args.httpConnectTiemout(),
        .http_max_host_open = args.httpMaxHostOpen(),
        .http_max_concurrent = args.httpMaxConcurrent(),
        .user_agent = user_agent,
    });

    defer app.deinit();
    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            log.debug(.app, "startup", .{ .mode = "serve", .snapshot = app.snapshot.fromEmbedded() });
            const address = std.net.Address.parseIp(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return args.printUsageAndExit(false);
            };

            // _server is global to handle graceful shutdown.
            var server = try lp.Server.init(app, address);
            defer server.deinit();

            try sighandler.on(lp.Server.stop, .{&server});

            // max timeout of 1 week.
            const timeout = if (opts.timeout > 604_800) 604_800_000 else @as(u32, opts.timeout) * 1000;
            server.run(address, timeout) catch |err| {
                log.fatal(.app, "server run error", .{ .err = err });
                return err;
            };
        },
        .fetch => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{ .mode = "fetch", .dump = opts.dump, .url = url, .snapshot = app.snapshot.fromEmbedded() });

            var fetch_opts = lp.FetchOpts{
                .wait_ms = 5000,
                .dump = .{
                    .strip = opts.strip,
                    .with_base = opts.withbase,
                },
            };

            var stdout = std.fs.File.stdout();
            var writer = stdout.writer(&.{});
            if (opts.dump) {
                fetch_opts.writer = &writer.interface;
            }

            lp.fetch(app, url, fetch_opts) catch |err| {
                log.fatal(.app, "fetch error", .{ .err = err, .url = url });
                return err;
            };
        },
        else => unreachable,
    }
}

const Command = struct {
    mode: Mode,
    exec_name: []const u8,

    fn tlsVerifyHost(self: *const Command) bool {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.tls_verify_host,
            else => unreachable,
        };
    }

    fn httpProxy(self: *const Command) ?[:0]const u8 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_proxy,
            else => unreachable,
        };
    }

    fn proxyBearerToken(self: *const Command) ?[:0]const u8 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.proxy_bearer_token,
            else => unreachable,
        };
    }

    fn httpMaxConcurrent(self: *const Command) ?u8 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_max_concurrent,
            else => unreachable,
        };
    }

    fn httpMaxHostOpen(self: *const Command) ?u8 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_max_host_open,
            else => unreachable,
        };
    }

    fn httpConnectTiemout(self: *const Command) ?u31 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_connect_timeout,
            else => unreachable,
        };
    }

    fn httpTimeout(self: *const Command) ?u31 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_timeout,
            else => unreachable,
        };
    }

    fn logLevel(self: *const Command) ?log.Level {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.log_level,
            else => unreachable,
        };
    }

    fn logFormat(self: *const Command) ?log.Format {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.log_format,
            else => unreachable,
        };
    }

    fn logFilterScopes(self: *const Command) ?[]const log.Scope {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.log_filter_scopes,
            else => unreachable,
        };
    }

    fn userAgentSuffix(self: *const Command) ?[]const u8 {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.user_agent_suffix,
            else => unreachable,
        };
    }

    const Mode = union(App.RunMode) {
        help: bool, // false when being printed because of an error
        fetch: Fetch,
        serve: Serve,
        version: void,
    };

    const Serve = struct {
        host: []const u8,
        port: u16,
        timeout: u31,
        common: Common,
    };

    const Fetch = struct {
        url: [:0]const u8,
        dump: bool = false,
        common: Common,
        withbase: bool = false,
        strip: lp.dump.Opts.Strip = .{},
    };

    const Common = struct {
        proxy_bearer_token: ?[:0]const u8 = null,
        http_proxy: ?[:0]const u8 = null,
        http_max_concurrent: ?u8 = null,
        http_max_host_open: ?u8 = null,
        http_timeout: ?u31 = null,
        http_connect_timeout: ?u31 = null,
        tls_verify_host: bool = true,
        log_level: ?log.Level = null,
        log_format: ?log.Format = null,
        log_filter_scopes: ?[]log.Scope = null,
        user_agent_suffix: ?[]const u8 = null,
    };

    fn printUsageAndExit(self: *const Command, success: bool) void {
        //                                                                     MAX_HELP_LEN|
        const common_options =
            \\
            \\--insecure_disable_tls_host_verification
            \\                Disables host verification on all HTTP requests. This is an
            \\                advanced option which should only be set if you understand
            \\                and accept the risk of disabling host verification.
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
            \\Example: {s} fetch --dump https://lightpanda.io/
            \\
            \\Options:
            \\--dump          Dumps document to stdout.
            \\                Defaults to false.
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
};

fn parseArgs(allocator: Allocator) !Command {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const exec_name = std.fs.path.basename(args.next().?);

    var cmd = Command{
        .mode = .{ .help = false },
        .exec_name = try allocator.dupe(u8, exec_name),
    };

    const mode_string = args.next() orelse "";
    const mode = std.meta.stringToEnum(App.RunMode, mode_string) orelse blk: {
        const inferred_mode = inferMode(mode_string) orelse return cmd;
        // "command" wasn't a command but an option. We can't reset args, but
        // we can create a new one. Not great, but this fallback is temporary
        // as we transition to this command mode approach.
        args.deinit();

        args = try std.process.argsWithAllocator(allocator);
        // skip the exec_name
        _ = args.skip();

        break :blk inferred_mode;
    };

    cmd.mode = switch (mode) {
        .help => .{ .help = true },
        .serve => .{ .serve = parseServeArgs(allocator, &args) catch return cmd },
        .fetch => .{ .fetch = parseFetchArgs(allocator, &args) catch return cmd },
        .version => .{ .version = {} },
    };
    return cmd;
}

fn inferMode(opt: []const u8) ?App.RunMode {
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
) !Command.Serve {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 9222;
    var timeout: u31 = 10;
    var common: Command.Common = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--host", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--host" });
                return error.InvalidArgument;
            };
            host = try allocator.dupe(u8, str);
            continue;
        }

        if (std.mem.eql(u8, "--port", opt)) {
            const str = args.next() orelse {
                log.fatal(.app, "missing argument value", .{ .arg = "--port" });
                return error.InvalidArgument;
            };

            port = std.fmt.parseInt(u16, str, 10) catch |err| {
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

            timeout = std.fmt.parseInt(u31, str, 10) catch |err| {
                log.fatal(.app, "invalid argument value", .{ .arg = "--timeout", .err = err });
                return error.InvalidArgument;
            };
            continue;
        }

        if (try parseCommonArg(allocator, opt, args, &common)) {
            continue;
        }

        log.fatal(.app, "unknown argument", .{ .mode = "serve", .arg = opt });
        return error.UnkownOption;
    }

    return .{
        .host = host,
        .port = port,
        .common = common,
        .timeout = timeout,
    };
}

fn parseFetchArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Command.Fetch {
    var dump: bool = false;
    var withbase: bool = false;
    var url: ?[:0]const u8 = null;
    var common: Command.Common = .{};
    var strip: lp.dump.Opts.Strip = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            dump = true;
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
        .dump = dump,
        .strip = strip,
        .common = common,
        .withbase = withbase,
    };
}

fn parseCommonArg(
    allocator: Allocator,
    opt: []const u8,
    args: *std.process.ArgIterator,
    common: *Command.Common,
) !bool {
    if (std.mem.eql(u8, "--insecure_disable_tls_host_verification", opt)) {
        common.tls_verify_host = false;
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

        var arr: std.ArrayListUnmanaged(log.Scope) = .empty;

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

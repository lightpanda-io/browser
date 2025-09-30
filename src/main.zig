// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const App = @import("app.zig").App;
const Server = @import("server.zig").Server;
const Browser = @import("browser/browser.zig").Browser;
const DumpStripMode = @import("browser/dump.zig").Opts.StripMode;

const build_config = @import("build_config");

var _app: ?*App = null;
var _server: ?Server = null;

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks()) std.posix.exit(1);
    };

    run(alloc) catch |err| {
        // If explicit filters were set, they won't be valid anymore because
        // the args_arena is gone. We need to set it to something that's not
        // invalid. (We should just move the args_arena up to main)
        log.opts.filter_scopes = &.{};
        log.fatal(.app, "exit", .{ .err = err });
        std.posix.exit(1);
    };
}

// Handle app shutdown gracefuly on signals.
fn shutdown() void {
    const sigaction: std.posix.Sigaction = .{
        .handler = .{
            .handler = struct {
                pub fn handler(_: c_int) callconv(.c) void {
                    // Shutdown service gracefuly.
                    if (_server) |server| {
                        server.deinit();
                    }
                    if (_app) |app| {
                        app.deinit();
                    }
                    std.posix.exit(0);
                }
            }.handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    // Exit the program on SIGINT signal. When running the browser in a Docker
    // container, sending a CTRL-C (SIGINT) signal is catched but doesn't exit
    // the program. Here we force exiting on SIGINT.
    std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &sigaction, null);
}

fn run(alloc: Allocator) !void {
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try parseArgs(args_arena.allocator());

    switch (args.mode) {
        .help => {
            args.printUsageAndExit(args.mode.help);
            return std.process.cleanExit();
        },
        .version => {
            std.debug.print("{s}\n", .{build_config.git_commit});
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
            break :blk try std.fmt.allocPrintSentinel(args_arena.allocator(), "{s} {s}", .{ USER_AGENT, suffix }, 0);
        }
        break :blk USER_AGENT;
    };

    // _app is global to handle graceful shutdown.
    _app = try App.init(alloc, .{
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

    const app = _app.?;
    defer app.deinit();
    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            log.debug(.app, "startup", .{ .mode = "serve" });
            const address = std.net.Address.parseIp4(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return args.printUsageAndExit(false);
            };

            // _server is global to handle graceful shutdown.
            _server = try Server.init(app, address);
            const server = &_server.?;
            defer server.deinit();

            // max timeout of 1 week.
            const timeout = if (opts.timeout > 604_800) 604_800_000 else @as(i32, opts.timeout) * 1000;
            server.run(address, timeout) catch |err| {
                log.fatal(.app, "server run error", .{ .err = err });
                return err;
            };
        },
        .fetch => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{ .mode = "fetch", .dump = opts.dump, .url = url });

            // browser
            var browser = try Browser.init(app);
            defer browser.deinit();

            var session = try browser.newSession();

            // page
            const page = try session.createPage();

            _ = page.navigate(url, .{}) catch |err| switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => {
                    log.fatal(.app, "invalid fetch URL", .{ .err = err, .url = url });
                    return args.printUsageAndExit(false);
                },
                else => {
                    log.fatal(.app, "fetch error", .{ .err = err, .url = url });
                    return err;
                },
            };

            _ = session.fetchWait(5000); // 5 seconds

            // dump
            if (opts.dump) {
                var stdout = std.fs.File.stdout();
                var writer = stdout.writer(&.{});
                try page.dump(.{
                    .page = page,
                    .with_base = opts.withbase,
                    .strip_mode = opts.strip_mode,
                }, &writer.interface);
                try writer.interface.flush();
            }
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
        url: []const u8,
        dump: bool = false,
        common: Common,
        withbase: bool = false,
        strip_mode: DumpStripMode = .{},
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
            \\ --user_agent_suffix
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
    var url: ?[]const u8 = null;
    var common: Command.Common = .{};
    var strip_mode: DumpStripMode = .{};

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
            strip_mode.js = true;
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
                    strip_mode.js = true;
                } else if (std.mem.eql(u8, trimmed, "ui")) {
                    strip_mode.ui = true;
                } else if (std.mem.eql(u8, trimmed, "css")) {
                    strip_mode.css = true;
                } else if (std.mem.eql(u8, trimmed, "full")) {
                    strip_mode.js = true;
                    strip_mode.ui = true;
                    strip_mode.css = true;
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
        url = try allocator.dupe(u8, opt);
    }

    if (url == null) {
        log.fatal(.app, "missing fetch url", .{ .help = "URL to fetch must be provided" });
        return error.MissingURL;
    }

    return .{
        .url = url.?,
        .dump = dump,
        .common = common,
        .withbase = withbase,
        .strip_mode = strip_mode,
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

const testing = @import("testing.zig");
test {
    std.testing.refAllDecls(@This());
}

const TestHTTPServer = @import("TestHTTPServer.zig");

var test_cdp_server: ?Server = null;
var test_http_server: ?TestHTTPServer = null;

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;
    try testing.setup();
    var wg: std.Thread.WaitGroup = .{};
    wg.startMany(2);

    {
        const thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});
        thread.detach();
    }

    test_http_server = TestHTTPServer.init(testHTTPHandler);
    {
        const thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });
        thread.detach();
    }

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    wg.wait();
}

test "tests:afterAll" {
    if (test_cdp_server) |*server| {
        server.deinit();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }
    testing.shutdown();
}

fn serveCDP(wg: *std.Thread.WaitGroup) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 9583);
    test_cdp_server = try Server.init(testing.test_app, address);

    var server = try Server.init(testing.test_app, address);
    defer server.deinit();
    wg.finish();

    test_cdp_server.?.run(address, 5) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

fn testHTTPHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (std.mem.eql(u8, path, "/loader")) {
        return req.respond("Hello!", .{
            .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
        });
    }

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond("1234567890" ** 10, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\"}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/tests/")) {
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});

    unreachable;
}

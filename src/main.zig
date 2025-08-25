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
const Http = @import("http/Http.zig");
const Platform = @import("runtime/js.zig").Platform;
const Browser = @import("browser/browser.zig").Browser;

const build_config = @import("build_config");
const parser = @import("browser/netsurf.zig");

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

    const platform = try Platform.init();
    defer platform.deinit();

    var app = try App.init(alloc, .{
        .run_mode = args.mode,
        .platform = &platform,
        .http_proxy = args.httpProxy(),
        .proxy_bearer_token = args.proxyBearerToken(),
        .tls_verify_host = args.tlsVerifyHost(),
        .http_timeout_ms = args.httpTimeout(),
        .http_connect_timeout_ms = args.httpConnectTiemout(),
        .http_max_host_open = args.httpMaxHostOpen(),
        .http_max_concurrent = args.httpMaxConcurrent(),
    });
    defer app.deinit();
    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            log.debug(.app, "startup", .{ .mode = "serve" });
            const address = std.net.Address.parseIp4(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return args.printUsageAndExit(false);
            };

            var server = try Server.init(app, address);
            defer server.deinit();

            server.run(address, opts.timeout) catch |err| {
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

            session.wait(5); // 5 seconds

            // dump
            if (opts.dump) {
                try page.dump(.{
                    .page = page,
                    .with_base = opts.withbase,
                    .exclude_scripts = opts.noscript,
                }, std.io.getStdOut());
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

    const Mode = union(App.RunMode) {
        help: bool, // false when being printed because of an error
        fetch: Fetch,
        serve: Serve,
        version: void,
    };

    const Serve = struct {
        host: []const u8,
        port: u16,
        timeout: u16,
        common: Common,
    };

    const Fetch = struct {
        url: []const u8,
        dump: bool = false,
        common: Common,
        noscript: bool = false,
        withbase: bool = false,
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
            \\--noscript      Exclude <script> tags in dump. Defaults to false.
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
            \\                Defaults to 10 (seconds)
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
    var timeout: u16 = 10;
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

            timeout = std.fmt.parseInt(u16, str, 10) catch |err| {
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
    var noscript: bool = false;
    var withbase: bool = false;
    var url: ?[]const u8 = null;
    var common: Command.Common = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            dump = true;
            continue;
        }

        if (std.mem.eql(u8, "--noscript", opt)) {
            noscript = true;
            continue;
        }

        if (std.mem.eql(u8, "--with_base", opt)) {
            withbase = true;
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
        .noscript = noscript,
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

    return false;
}

test {
    std.testing.refAllDecls(@This());
}

var test_wg: std.Thread.WaitGroup = .{};
test "tests:beforeAll" {
    try parser.init();
    log.opts.level = .err;
    log.opts.format = .logfmt;

    test_wg.startMany(2);
    const platform = try Platform.init();

    {
        const address = try std.net.Address.parseIp("127.0.0.1", 9582);
        const thread = try std.Thread.spawn(.{}, serveHTTP, .{address});
        thread.detach();
    }

    {
        const address = try std.net.Address.parseIp("127.0.0.1", 9583);
        const thread = try std.Thread.spawn(.{}, serveCDP, .{ address, &platform });
        thread.detach();
    }

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    test_wg.wait();
}

test "tests:afterAll" {
    parser.deinit();
}

fn serveHTTP(address: std.net.Address) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    test_wg.finish();

    var read_buffer: [1024]u8 = undefined;
    while (true) {
        var conn = try listener.accept();
        defer conn.stream.close();
        var http_server = std.http.Server.init(conn, &read_buffer);

        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            else => {
                std.debug.print("Test HTTP Server error: {}\n", .{err});
                return err;
            },
        };

        const path = request.head.target;

        if (std.mem.eql(u8, path, "/loader")) {
            try request.respond("Hello!", .{
                .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
            });
        } else if (std.mem.eql(u8, path, "/xhr")) {
            try request.respond("1234567890" ** 10, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                    .{ .name = "Connection", .value = "Close" },
                },
            });
        } else if (std.mem.eql(u8, path, "/xhr/json")) {
            try request.respond("{\"over\":\"9000!!!\"}", .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Connection", .value = "Close" },
                },
            });
        } else {
            // should not have an unknown path
            unreachable;
        }
    }
}

fn serveCDP(address: std.net.Address, platform: *const Platform) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var app = try App.init(gpa.allocator(), .{
        .run_mode = .serve,
        .tls_verify_host = false,
        .platform = platform,
        .http_max_concurrent = 2,
    });
    defer app.deinit();

    test_wg.finish();
    var server = try Server.init(app, address);
    defer server.deinit();
    server.run(address, 5) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

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
const server = @import("server.zig");
const App = @import("app.zig").App;
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
        .http_proxy = args.httpProxy(),
        .tls_verify_host = args.tlsVerifyHost(),
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

            const timeout = std.time.ns_per_s * @as(u64, opts.timeout);
            server.run(app, address, timeout) catch |err| {
                log.fatal(.app, "server run error", .{ .err = err });
                return err;
            };
        },
        .fetch => |opts| {
            log.debug(.app, "startup", .{ .mode = "fetch", .dump = opts.dump, .url = opts.url });
            const url = try @import("url.zig").URL.parse(opts.url, null);

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

            try page.wait();

            // dump
            if (opts.dump) {
                try page.dump(std.io.getStdOut());
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

    fn httpProxy(self: *const Command) ?std.Uri {
        return switch (self.mode) {
            inline .serve, .fetch => |opts| opts.common.http_proxy,
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
    };

    const Common = struct {
        http_proxy: ?std.Uri = null,
        tls_verify_host: bool = true,
        log_level: ?log.Level = null,
        log_format: ?log.Format = null,
        log_filter_scopes: ?[]log.Scope = null,
    };

    fn printUsageAndExit(self: *const Command, success: bool) void {
        const common_options =
            \\
            \\--insecure_disable_tls_host_verification
            \\                Disables host verification on all HTTP requests.
            \\                This is an advanced option which should only be
            \\                set if you understand and accept the risk of
            \\                disabling host verification.
            \\
            \\--http_proxy    The HTTP proxy to use for all HTTP requests.
            \\                Defaults to none.
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
        ;

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
            \\                Defaults to 3 (seconds)
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

    if (std.mem.eql(u8, opt, "--dump")) {
        return .fetch;
    }
    if (std.mem.startsWith(u8, opt, "--") == false) {
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
    var timeout: u16 = 3;
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
    var url: ?[]const u8 = null;
    var common: Command.Common = .{};

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            dump = true;
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
        common.http_proxy = try std.Uri.parse(try allocator.dupe(u8, str));
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
                log.fatal(.app, "invalid option choice", .{ .arg = "--log_scope_filter", .value = part });
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

    test_wg.startMany(3);
    _ = try Platform.init();

    {
        const address = try std.net.Address.parseIp("127.0.0.1", 9582);
        const thread = try std.Thread.spawn(.{}, serveHTTP, .{address});
        thread.detach();
    }

    {
        const address = try std.net.Address.parseIp("127.0.0.1", 9581);
        const thread = try std.Thread.spawn(.{}, serveHTTPS, .{address});
        thread.detach();
    }

    {
        const address = try std.net.Address.parseIp("127.0.0.1", 9583);
        const thread = try std.Thread.spawn(.{}, serveCDP, .{address});
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
    ACCEPT: while (true) {
        defer _ = arena.reset(.{ .free_all = {} });
        const aa = arena.allocator();

        var conn = try listener.accept();
        defer conn.stream.close();
        var http_server = std.http.Server.init(conn, &read_buffer);

        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue :ACCEPT,
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
        } else if (std.mem.eql(u8, path, "/http_client/simple")) {
            try request.respond("", .{
                .extra_headers = &.{.{ .name = "Connection", .value = "close" }},
            });
        } else if (std.mem.eql(u8, path, "/http_client/redirect")) {
            try request.respond("", .{
                .status = .moved_permanently,
                .extra_headers = &.{
                    .{ .name = "Connection", .value = "close" },
                    .{ .name = "LOCATION", .value = "../http_client/echo" },
                },
            });
        } else if (std.mem.eql(u8, path, "/http_client/redirect/secure")) {
            try request.respond("", .{
                .status = .moved_permanently,
                .extra_headers = &.{ .{ .name = "Connection", .value = "close" }, .{ .name = "LOCATION", .value = "https://127.0.0.1:9581/http_client/body" } },
            });
        } else if (std.mem.eql(u8, path, "/http_client/gzip")) {
            const body = &.{ 0x1f, 0x8b, 0x08, 0x08, 0x01, 0xc6, 0x19, 0x68, 0x00, 0x03, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x68, 0x74, 0x6d, 0x6c, 0x00, 0x73, 0x54, 0xc8, 0x4b, 0x2d, 0x57, 0x48, 0x2a, 0xca, 0x2f, 0x2f, 0x4e, 0x2d, 0x52, 0x48, 0x2a, 0xcd, 0xcc, 0x29, 0x51, 0x48, 0xcb, 0x2f, 0x52, 0xc8, 0x4d, 0x4c, 0xce, 0xc8, 0xcc, 0x4b, 0x2d, 0xe6, 0x02, 0x00, 0xe7, 0xc3, 0x4b, 0x27, 0x21, 0x00, 0x00, 0x00 };
            try request.respond(body, .{
                .extra_headers = &.{ .{ .name = "Connection", .value = "close" }, .{ .name = "Content-Encoding", .value = "gzip" } },
            });
        } else if (std.mem.eql(u8, path, "/http_client/echo")) {
            var headers: std.ArrayListUnmanaged(std.http.Header) = .{};

            var it = request.iterateHeaders();
            while (it.next()) |hdr| {
                try headers.append(aa, .{
                    .name = try std.fmt.allocPrint(aa, "_{s}", .{hdr.name}),
                    .value = hdr.value,
                });
            }
            try headers.append(aa, .{ .name = "Connection", .value = "Close" });

            try request.respond("over 9000!", .{
                .status = .created,
                .extra_headers = headers.items,
            });
        }
    }
}

// This is a lot of work for testing TLS, but the TLS (async) code is complicated
// This "server" is written specifically to test the client. It assumes the client
// isn't a jerk.
fn serveHTTPS(address: std.net.Address) !void {
    const tls = @import("tls");

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    test_wg.finish();

    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    var r = std.Random.DefaultPrng.init(seed);
    const rand = r.random();

    var read_buffer: [1024]u8 = undefined;
    while (true) {
        const stream = blk: {
            const conn = try listener.accept();
            break :blk conn.stream;
        };
        defer stream.close();

        var conn = try tls.server(stream, .{ .auth = null });
        defer conn.close() catch {};

        var pos: usize = 0;
        while (true) {
            const n = try conn.read(read_buffer[pos..]);
            if (n == 0) {
                break;
            }
            pos += n;
            const header_end = std.mem.indexOf(u8, read_buffer[0..pos], "\r\n\r\n") orelse {
                continue;
            };
            var it = std.mem.splitScalar(u8, read_buffer[0..header_end], ' ');
            _ = it.next() orelse unreachable; // method
            const path = it.next() orelse unreachable;

            var fragment = false;
            var response: []const u8 = undefined;
            if (std.mem.eql(u8, path, "/http_client/simple")) {
                fragment = true;
                response = "HTTP/1.1 200 \r\nContent-Length: 0\r\nConnection: Close\r\n\r\n";
            } else if (std.mem.eql(u8, path, "/http_client/body")) {
                fragment = true;
                response = "HTTP/1.1 201 CREATED\r\nContent-Length: 20\r\nConnection: Close\r\n   Another :  HEaDer  \r\n\r\n1234567890abcdefhijk";
            } else if (std.mem.eql(u8, path, "/http_client/redirect/insecure")) {
                fragment = true;
                response = "HTTP/1.1 307 GOTO\r\nLocation: http://127.0.0.1:9582/http_client/redirect\r\nConnection: Close\r\n\r\n";
            } else if (std.mem.eql(u8, path, "/xhr")) {
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 100\r\nConnection: Close\r\n\r\n" ++ ("1234567890" ** 10);
            } else if (std.mem.eql(u8, path, "/xhr/json")) {
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\nConnection: Close\r\n\r\n{\"over\":\"9000!!!\"}";
            } else {
                // should not have an unknown path
                unreachable;
            }

            var unsent = response;
            while (unsent.len > 0) {
                const to_send = if (fragment) rand.intRangeAtMost(usize, 1, unsent.len) else unsent.len;
                const sent = try conn.write(unsent[0..to_send]);
                unsent = unsent[sent..];
                std.time.sleep(std.time.ns_per_us * 5);
            }
            break;
        }
    }
}

fn serveCDP(address: std.net.Address) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var app = try App.init(gpa.allocator(), .{
        .run_mode = .serve,
        .tls_verify_host = false,
    });
    defer app.deinit();

    test_wg.finish();
    server.run(app, address, std.time.ns_per_s * 2) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

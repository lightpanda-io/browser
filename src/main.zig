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

const server = @import("server.zig");
const App = @import("app.zig").App;
const Platform = @import("runtime/js.zig").Platform;
const Browser = @import("browser/browser.zig").Browser;

const parser = @import("browser/netsurf.zig");
const version = @import("build_info").git_commit;

const log = std.log.scoped(.cli);

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = logFn,
};

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks()) std.posix.exit(1);
    };

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try parseArgs(args_arena.allocator());

    switch (args.mode) {
        .help => {
            args.printUsageAndExit(args.mode.help);
            return std.process.cleanExit();
        },
        .version => {
            std.debug.print("{s}\n", .{version});
            return std.process.cleanExit();
        },
        else => {},
    }

    const platform = Platform.init();
    defer platform.deinit();

    var app = try App.init(alloc, .{
        .run_mode = args.mode,
        .gc_hints = args.gcHints(),
        .tls_verify_host = args.tlsVerifyHost(),
    });
    defer app.deinit();
    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            const address = std.net.Address.parseIp4(opts.host, opts.port) catch |err| {
                log.err("address (host:port) {any}\n", .{err});
                return args.printUsageAndExit(false);
            };

            const timeout = std.time.ns_per_s * @as(u64, opts.timeout);
            server.run(app, address, timeout) catch |err| {
                log.err("Server error", .{});
                return err;
            };
        },
        .fetch => |opts| {
            log.debug("Fetch mode: url {s}, dump {any}", .{ opts.url, opts.dump });
            const url = try @import("url.zig").URL.parse(opts.url, null);

            // browser
            var browser = try Browser.init(app);
            defer browser.deinit();

            var session = try browser.newSession({});

            // page
            const page = try session.createPage(null);

            _ = page.navigate(url, null) catch |err| switch (err) {
                error.UnsupportedUriScheme, error.UriMissingHost => {
                    log.err("'{s}' is not a valid URL ({any})\n", .{ url, err });
                    return args.printUsageAndExit(false);
                },
                else => {
                    log.err("'{s}' fetching error ({any})\n", .{ url, err });
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

    fn gcHints(self: *const Command) bool {
        return switch (self.mode) {
            .serve => |opts| opts.gc_hints,
            else => false,
        };
    }

    fn tlsVerifyHost(self: *const Command) bool {
        return switch (self.mode) {
            .serve => |opts| opts.tls_verify_host,
            .fetch => |opts| opts.tls_verify_host,
            else => true,
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
        gc_hints: bool,
        tls_verify_host: bool,
    };

    const Fetch = struct {
        url: []const u8,
        dump: bool = false,
        tls_verify_host: bool,
    };

    fn printUsageAndExit(self: *const Command, success: bool) void {
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
            \\--insecure_disable_tls_host_verification
            \\                Disables host verification on all HTTP requests.
            \\                This is an advanced option which should only be
            \\                set if you understand and accept the risk of
            \\                disabling host verification.
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
            \\--gc_hints      Encourage V8 to cleanup garbage for each new browser context.
            \\                Defaults to false
            \\
            \\--insecure_disable_tls_host_verification
            \\                Disables host verification on all HTTP requests.
            \\                This is an advanced option which should only be
            \\                set if you understand and accept the risk of
            \\                disabling host verification.
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

    if (std.mem.eql(u8, opt, "--gc_hints")) {
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
    var gc_hints = false;
    var tls_verify_host = true;

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--host", opt)) {
            const str = args.next() orelse {
                log.err("--host argument requires an value", .{});
                return error.InvalidMissingHost;
            };
            host = try allocator.dupe(u8, str);
            continue;
        }

        if (std.mem.eql(u8, "--port", opt)) {
            const str = args.next() orelse {
                log.err("--port argument requires an value", .{});
                return error.InvalidMissingPort;
            };

            port = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.err("--port value is invalid: {}", .{err});
                return error.InvalidPort;
            };
            continue;
        }

        if (std.mem.eql(u8, "--timeout", opt)) {
            const str = args.next() orelse {
                log.err("--timeout argument requires an value", .{});
                return error.MissingTimeout;
            };

            timeout = std.fmt.parseInt(u16, str, 10) catch |err| {
                log.err("--timeout value is invalid: {}", .{err});
                return error.InvalidTimeout;
            };
            continue;
        }

        if (std.mem.eql(u8, "--insecure_tls_verify_host", opt)) {
            tls_verify_host = false;
            continue;
        }

        if (std.mem.eql(u8, "--gc_hints", opt)) {
            gc_hints = true;
            continue;
        }

        log.err("Unknown option to serve command: '{s}'", .{opt});
        return error.UnkownOption;
    }

    return .{
        .host = host,
        .port = port,
        .timeout = timeout,
        .gc_hints = gc_hints,
        .tls_verify_host = tls_verify_host,
    };
}

fn parseFetchArgs(
    allocator: Allocator,
    args: *std.process.ArgIterator,
) !Command.Fetch {
    var dump: bool = false;
    var url: ?[]const u8 = null;
    var tls_verify_host = true;

    while (args.next()) |opt| {
        if (std.mem.eql(u8, "--dump", opt)) {
            dump = true;
            continue;
        }

        if (std.mem.eql(u8, "--insecure_disable_tls_host_verification", opt)) {
            tls_verify_host = false;
            continue;
        }

        if (std.mem.startsWith(u8, opt, "--")) {
            log.err("Unknown option to serve command: '{s}'", .{opt});
            return error.UnkownOption;
        }

        if (url != null) {
            log.err("Can only fetch 1 URL", .{});
            return error.TooManyURLs;
        }
        url = try allocator.dupe(u8, opt);
    }

    if (url == null) {
        log.err("A URL must be provided to the fetch command", .{});
        return error.MissingURL;
    }

    return .{
        .url = url.?,
        .dump = dump,
        .tls_verify_host = tls_verify_host,
    };
}

var verbose: bool = builtin.mode == .Debug; // In debug mode, force verbose.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!verbose) {
        // hide all messages with level greater of equal to debug level.
        if (@intFromEnum(level) >= @intFromEnum(std.log.Level.debug)) return;
    }
    // default std log function.
    std.log.defaultLog(level, scope, format, args);
}

test {
    std.testing.refAllDecls(@This());
}

var test_wg: std.Thread.WaitGroup = .{};
test "tests:beforeAll" {
    try parser.init();
    test_wg.startMany(3);
    _ = Platform.init();

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

        while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :ACCEPT,
                else => {
                    std.debug.print("Test HTTP Server error: {}\n", .{err});
                    return err;
                },
            };

            const path = request.head.target;
            if (std.mem.eql(u8, path, "/loader")) {
                try request.respond("Hello!", .{});
            } else if (std.mem.eql(u8, path, "/http_client/simple")) {
                try request.respond("", .{});
            } else if (std.mem.eql(u8, path, "/http_client/redirect")) {
                try request.respond("", .{
                    .status = .moved_permanently,
                    .extra_headers = &.{.{ .name = "LOCATION", .value = "../http_client/echo" }},
                });
            } else if (std.mem.eql(u8, path, "/http_client/redirect/secure")) {
                try request.respond("", .{
                    .status = .moved_permanently,
                    .extra_headers = &.{.{ .name = "LOCATION", .value = "https://127.0.0.1:9581/http_client/body" }},
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

                try request.respond("over 9000!", .{
                    .status = .created,
                    .extra_headers = headers.items,
                });
            }
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    test_wg.finish();

    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    var r = std.Random.DefaultPrng.init(seed);
    const rand = r.random();

    var read_buffer: [1024]u8 = undefined;
    while (true) {
        // defer _ = arena.reset(.{ .retain_with_limit = 1024 });
        // const aa = arena.allocator();

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
                response = "HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n";
            } else if (std.mem.eql(u8, path, "/http_client/body")) {
                fragment = true;
                response = "HTTP/1.1 201 CREATED\r\nContent-Length: 20\r\n   Another :  HEaDer  \r\n\r\n1234567890abcdefhijk";
            } else if (std.mem.eql(u8, path, "/http_client/redirect/insecure")) {
                fragment = true;
                response = "HTTP/1.1 307 GOTO\r\nLocation: http://127.0.0.1:9582/http_client/redirect\r\n\r\n";
            } else if (std.mem.eql(u8, path, "/xhr")) {
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 100\r\n\r\n" ++ ("1234567890" ** 10);
            } else if (std.mem.eql(u8, path, "/xhr/json")) {
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"over\":\"9000!!!\"}";
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

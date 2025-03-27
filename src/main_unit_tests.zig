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
const parser = @import("netsurf");
const tls = @import("tls");

const Allocator = std.mem.Allocator;

test {
    std.testing.refAllDecls(@import("url/query.zig"));
    std.testing.refAllDecls(@import("browser/dump.zig"));
    std.testing.refAllDecls(@import("browser/mime.zig"));
    std.testing.refAllDecls(@import("css/css.zig"));
    std.testing.refAllDecls(@import("css/libdom_test.zig"));
    std.testing.refAllDecls(@import("css/match_test.zig"));
    std.testing.refAllDecls(@import("css/parser.zig"));
    std.testing.refAllDecls(@import("generate.zig"));
    std.testing.refAllDecls(@import("http/client.zig"));
    std.testing.refAllDecls(@import("storage/storage.zig"));
    std.testing.refAllDecls(@import("storage/cookie.zig"));
    std.testing.refAllDecls(@import("iterator/iterator.zig"));
    std.testing.refAllDecls(@import("server.zig"));
    std.testing.refAllDecls(@import("cdp/cdp.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    std.testing.refAllDecls(@import("datetime.zig"));
    std.testing.refAllDecls(@import("telemetry/telemetry.zig"));
    std.testing.refAllDecls(@import("http/client.zig"));
}

var wg: std.Thread.WaitGroup = .{};
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
test "tests:beforeAll" {
    try parser.init();
    wg.startMany(3);

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
    wg.wait();
}

test "tests:afterAll" {
    parser.deinit();
}

fn serveHTTP(address: std.net.Address) !void {
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    wg.finish();

    var read_buffer: [1024]u8 = undefined;
    ACCEPT: while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 });
        const aa = arena.allocator();

        var conn = try listener.accept();
        defer conn.stream.close();
        var server = std.http.Server.init(conn, &read_buffer);

        while (server.state == .ready) {
            var request = server.receiveHead() catch |err| switch (err) {
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
    const allocator = gpa.allocator();

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    wg.finish();

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

            var response: []const u8 = undefined;
            if (std.mem.eql(u8, path, "/http_client/simple")) {
                response = "HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n";
            } else if (std.mem.eql(u8, path, "/http_client/body")) {
                response = "HTTP/1.1 201 CREATED\r\nContent-Length: 20\r\n   Another :  HEaDer  \r\n\r\n1234567890abcdefhijk";
            } else if (std.mem.eql(u8, path, "/http_client/redirect/insecure")) {
                response = "HTTP/1.1 307 GOTO\r\nLocation: http://127.0.0.1:9582/http_client/redirect\r\n\r\n";
            } else {
                // should not have an unknown path
                unreachable;
            }

            var unsent = response;
            while (unsent.len > 0) {
                const to_send = rand.intRangeAtMost(usize, 1, unsent.len);
                const sent = try conn.write(unsent[0..to_send]);
                unsent = unsent[sent..];
                std.time.sleep(std.time.ns_per_us * 5);
            }
            break;
        }
    }
}

fn serveCDP(address: std.net.Address) !void {
    const App = @import("app.zig").App;
    var app = try App.init(gpa.allocator(), .{.run_mode = .serve});
    defer app.deinit();

    const server = @import("server.zig");
    wg.finish();
    server.run(app, address, std.time.ns_per_s * 2) catch |err| {
        std.debug.print("CDP server error: {}", .{err});
        return err;
    };
}

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
const URL = @import("browser/URL.zig");

const TestHTTPServer = @This();

shutdown: std.atomic.Value(bool),
listener: ?std.net.Server,
handler: Handler,
next_conn_id: std.atomic.Value(u64),
live_handlers: std.atomic.Value(i64),

const Handler = *const fn (req: *std.http.Server.Request) anyerror!void;

pub fn init(handler: Handler) TestHTTPServer {
    return .{
        .shutdown = .init(true),
        .listener = null,
        .handler = handler,
        .next_conn_id = .init(0),
        .live_handlers = .init(0),
    };
}

fn dlog(conn_id: u64, comptime fmt: []const u8, args: anytype) void {
    const ms = std.time.milliTimestamp();
    std.debug.print("[TestHTTP t={d} c={d}] " ++ fmt ++ "\n", .{ ms, conn_id } ++ args);
}

pub fn deinit(self: *TestHTTPServer) void {
    self.listener = null;
}

pub fn stop(self: *TestHTTPServer) void {
    self.shutdown.store(true, .release);
    if (self.listener) |*listener| {
        switch (@import("builtin").target.os.tag) {
            .linux => std.posix.shutdown(listener.stream.handle, .recv) catch {},
            else => std.posix.close(listener.stream.handle),
        }
    }
}

pub fn run(self: *TestHTTPServer, wg: *std.Thread.WaitGroup) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 9582);

    self.listener = try address.listen(.{ .reuse_address = true });
    var listener = &self.listener.?;
    self.shutdown.store(false, .release);

    wg.finish();
    dlog(0, "listener ready on 127.0.0.1:9582", .{});

    while (true) {
        const conn = listener.accept() catch |err| {
            if (self.shutdown.load(.acquire) or err == error.SocketNotListening) {
                dlog(0, "accept loop exiting cleanly (shutdown={}, err={s})", .{
                    self.shutdown.load(.acquire),
                    @errorName(err),
                });
                return;
            }
            dlog(0, "accept loop exiting on error: {s}", .{@errorName(err)});
            return err;
        };
        const conn_id = self.next_conn_id.fetchAdd(1, .monotonic) + 1;
        const live_before = self.live_handlers.load(.monotonic);
        dlog(conn_id, "accepted (live_handlers_before_spawn={d})", .{live_before});
        const thrd = std.Thread.spawn(.{}, handleConnection, .{ self, conn, conn_id }) catch |err| {
            dlog(conn_id, "thread spawn failed: {s}", .{@errorName(err)});
            conn.stream.close();
            return err;
        };
        thrd.detach();
    }
}

fn handleConnection(self: *TestHTTPServer, conn: std.net.Server.Connection, conn_id: u64) !void {
    const live_after_inc = self.live_handlers.fetchAdd(1, .monotonic) + 1;
    dlog(conn_id, "handler start (live_handlers={d})", .{live_after_inc});
    defer {
        const live_after_dec = self.live_handlers.fetchSub(1, .monotonic) - 1;
        dlog(conn_id, "handler exit (live_handlers={d})", .{live_after_dec});
        conn.stream.close();
    }

    var req_buf: [2048]u8 = undefined;
    var conn_reader = conn.stream.reader(&req_buf);
    var conn_writer = conn.stream.writer(&req_buf);

    var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

    var request_count: u32 = 0;
    while (true) {
        dlog(conn_id, "receiveHead #{d} waiting...", .{request_count});
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.ReadFailed, error.HttpConnectionClosing => {
                dlog(conn_id, "receiveHead #{d} -> {s} (closing)", .{ request_count, @errorName(err) });
                return;
            },
            else => {
                dlog(conn_id, "receiveHead #{d} -> {s} (fatal)", .{ request_count, @errorName(err) });
                std.debug.print("Test HTTP Server error: {}\n", .{err});
                return err;
            },
        };
        request_count += 1;
        // Copy target before invoking handler: req.head.target is a slice
        // into req_buf, which respond() will overwrite (conn_writer shares
        // the same backing buffer).
        var target_buf: [512]u8 = undefined;
        const raw_target = req.head.target;
        const target_len = @min(raw_target.len, target_buf.len);
        @memcpy(target_buf[0..target_len], raw_target[0..target_len]);
        const target = target_buf[0..target_len];
        dlog(conn_id, "req #{d} {s} {s}", .{ request_count, @tagName(req.head.method), target });

        var timer = std.time.Timer.start() catch unreachable;
        self.handler(&req) catch |err| {
            dlog(conn_id, "handler '{s}' err {s}", .{ target, @errorName(err) });
            std.debug.print("test http error '{s}': {}\n", .{ target, err });
            try req.respond("server error", .{ .status = .internal_server_error });
            return;
        };
        dlog(conn_id, "handler '{s}' done in {d}us", .{ target, timer.read() / std.time.ns_per_us });
    }
}

pub fn sendFile(req: *std.http.Server.Request, file_path: []const u8) !void {
    var url_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&url_buf);
    var unescaped_file_path = try URL.unescape(fba.allocator(), file_path);
    if (std.mem.indexOfScalarPos(u8, unescaped_file_path, 0, '?')) |pos| {
        unescaped_file_path = unescaped_file_path[0..pos];
    }
    var file = std.fs.cwd().openFile(unescaped_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return req.respond("server error", .{ .status = .not_found }),
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    var send_buffer: [4096]u8 = undefined;

    var res = try req.respondStreaming(&send_buffer, .{
        .content_length = stat.size,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = getContentType(unescaped_file_path) },
            },
        },
    });

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);
    _ = try res.writer.sendFileAll(&reader, .unlimited);
    try res.writer.flush();
    try res.end();
}

fn getContentType(file_path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, file_path, ".js")) {
        return "application/json";
    }

    if (std.mem.endsWith(u8, file_path, ".GB2312.html")) {
        return "text/html; charset=GB2312";
    }

    if (std.mem.endsWith(u8, file_path, ".html")) {
        return "text/html";
    }

    if (std.mem.endsWith(u8, file_path, ".htm")) {
        return "text/html";
    }

    if (std.mem.endsWith(u8, file_path, ".xml")) {
        // some wpt tests do this
        return "text/xml";
    }

    if (std.mem.endsWith(u8, file_path, ".mjs")) {
        // mjs are ECMAScript modules
        return "application/json";
    }

    std.debug.print("TestHTTPServer asked to serve an unknown file type: {s}\n", .{file_path});
    return "text/html";
}

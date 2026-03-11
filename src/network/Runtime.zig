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
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const Config = @import("../Config.zig");
const libcurl = @import("../sys/libcurl.zig");

const net_http = @import("http.zig");
const RobotStore = @import("Robots.zig").RobotStore;
const Cache = @import("../browser/cache/Cache.zig");

const Runtime = @This();

const Listener = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    onAccept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
};

allocator: Allocator,

config: *const Config,
ca_blob: ?net_http.Blob,
robot_store: RobotStore,

cache: Cache,

pollfds: []posix.pollfd,
listener: ?Listener = null,

// Wakeup pipe: workers write to [1], main thread polls [0]
wakeup_pipe: [2]posix.fd_t = .{ -1, -1 },

shutdown: std.atomic.Value(bool) = .init(false),

fn globalInit() void {
    libcurl.curl_global_init(.{ .ssl = true }) catch |err| {
        lp.assert(false, "curl global init", .{ .err = err });
    };
}

fn globalDeinit() void {
    libcurl.curl_global_cleanup();
}

pub fn init(allocator: Allocator, config: *const Config) !Runtime {
    globalInit();
    errdefer globalDeinit();

    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

    // 0 is wakeup, 1 is listener
    const pollfds = try allocator.alloc(posix.pollfd, 2);
    errdefer allocator.free(pollfds);

    @memset(pollfds, .{ .fd = -1, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    var ca_blob: ?net_http.Blob = null;
    if (config.tlsVerifyHost()) {
        ca_blob = try loadCerts(allocator);
    }

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .robot_store = RobotStore.init(allocator),
        .cache = 
        .pollfds = pollfds,
        .wakeup_pipe = pipe,
    };
}

pub fn deinit(self: *Runtime) void {
    for (&self.wakeup_pipe) |*fd| {
        if (fd.* >= 0) {
            posix.close(fd.*);
            fd.* = -1;
        }
    }

    self.allocator.free(self.pollfds);

    if (self.ca_blob) |ca_blob| {
        const data: [*]u8 = @ptrCast(ca_blob.data);
        self.allocator.free(data[0..ca_blob.len]);
    }

    self.robot_store.deinit();

    globalDeinit();
}

pub fn bind(
    self: *Runtime,
    address: net.Address,
    ctx: *anyopaque,
    on_accept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
) !void {
    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    errdefer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, self.config.maxPendingConnections());

    if (self.listener != null) return error.TooManyListeners;

    self.listener = .{
        .socket = listener,
        .ctx = ctx,
        .onAccept = on_accept,
    };
    self.pollfds[1] = .{
        .fd = listener,
        .events = posix.POLL.IN,
        .revents = 0,
    };
}

pub fn run(self: *Runtime) void {
    while (!self.shutdown.load(.acquire)) {
        const listener = self.listener orelse return;

        _ = posix.poll(self.pollfds, -1) catch |err| {
            lp.log.err(.app, "poll", .{ .err = err });
            continue;
        };

        // check wakeup socket
        if (self.pollfds[0].revents != 0) {
            self.pollfds[0].revents = 0;

            // If we were woken up, perhaps everything was cancelled and the iteration can be completed.
            if (self.shutdown.load(.acquire)) break;
        }

        // check new connections;
        if (self.pollfds[1].revents == 0) continue;
        self.pollfds[1].revents = 0;

        const socket = posix.accept(listener.socket, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.SocketNotListening, error.ConnectionAborted => {
                    self.pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
                    self.listener = null;
                },
                error.WouldBlock => {},
                else => {
                    lp.log.err(.app, "accept", .{ .err = err });
                },
            }
            continue;
        };

        listener.onAccept(listener.ctx, socket);
    }

    if (self.listener) |listener| {
        posix.shutdown(listener.socket, .both) catch |err| {
            lp.log.warn(.app, "listener shutdown", .{ .err = err });
        };
        posix.close(listener.socket);
    }
}

pub fn stop(self: *Runtime) void {
    self.shutdown.store(true, .release);
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

pub fn newConnection(self: *Runtime) !net_http.Connection {
    return net_http.Connection.init(self.ca_blob, self.config);
}

// Wraps lines @ 64 columns. A PEM is basically a base64 encoded DER (which is
// what Zig has), with lines wrapped at 64 characters and with a basic header
// and footer
const LineWriter = struct {
    col: usize = 0,
    inner: std.ArrayList(u8).Writer,

    pub fn writeAll(self: *LineWriter, data: []const u8) !void {
        var writer = self.inner;

        var col = self.col;
        const len = 64 - col;

        var remain = data;
        if (remain.len > len) {
            col = 0;
            try writer.writeAll(data[0..len]);
            try writer.writeByte('\n');
            remain = data[len..];
        }

        while (remain.len > 64) {
            try writer.writeAll(remain[0..64]);
            try writer.writeByte('\n');
            remain = data[len..];
        }
        try writer.writeAll(remain);
        self.col = col + remain.len;
    }
};

// TODO: on BSD / Linux, we could just read the PEM file directly.
// This whole rescan + decode is really just needed for MacOS. On Linux
// bundle.rescan does find the .pem file(s) which could be in a few different
// places, so it's still useful, just not efficient.
fn loadCerts(allocator: Allocator) !libcurl.CurlBlob {
    var bundle: std.crypto.Certificate.Bundle = .{};
    try bundle.rescan(allocator);
    defer bundle.deinit(allocator);

    const bytes = bundle.bytes.items;
    if (bytes.len == 0) {
        lp.log.warn(.app, "No system certificates", .{});
        return .{
            .len = 0,
            .flags = 0,
            .data = bytes.ptr,
        };
    }

    const encoder = std.base64.standard.Encoder;
    var arr: std.ArrayList(u8) = .empty;

    const encoded_size = encoder.calcSize(bytes.len);
    const buffer_size = encoded_size +
        (bundle.map.count() * 75) + // start / end per certificate + extra, just in case
        (encoded_size / 64) // newline per 64 characters
    ;
    try arr.ensureTotalCapacity(allocator, buffer_size);
    errdefer arr.deinit(allocator);
    var writer = arr.writer(allocator);

    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        const cert = try std.crypto.Certificate.der.Element.parse(bytes, index.*);

        try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
        var line_writer = LineWriter{ .inner = writer };
        try encoder.encodeWriter(&line_writer, bytes[index.*..cert.slice.end]);
        try writer.writeAll("\n-----END CERTIFICATE-----\n");
    }

    // Final encoding should not be larger than our initial size estimate
    lp.assert(buffer_size > arr.items.len, "Http loadCerts", .{ .estimate = buffer_size, .len = arr.items.len });

    // Allocate exactly the size needed and copy the data
    const result = try allocator.dupe(u8, arr.items);
    // Free the original oversized allocation
    arr.deinit(allocator);

    return .{
        .len = result.len,
        .data = result.ptr,
        .flags = 0,
    };
}

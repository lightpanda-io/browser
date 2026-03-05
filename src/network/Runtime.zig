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

pollfds: [Config.MAX_LISTENERS]posix.pollfd = @splat(.{ .fd = -1, .events = 0, .revents = 0 }),
listeners: [Config.MAX_LISTENERS]?Listener = @splat(null),

shutdown: std.atomic.Value(bool) = .init(false),
listener_count: std.atomic.Value(usize) = .init(0),

fn globalInit() void {
    libcurl.curl_global_init(.{ .ssl = true }) catch |err| {
        lp.assert(false, "curl global init", .{ .err = err });
    };
}

fn globalDeinit() void {
    libcurl.curl_global_cleanup();
}

var global_init_once = std.once(globalInit);
var global_deinit_once = std.once(globalDeinit);

pub fn init(allocator: Allocator, config: *const Config) !Runtime {
    global_init_once.call();
    errdefer global_deinit_once.call();

    var ca_blob: ?net_http.Blob = null;
    if (config.tlsVerifyHost()) {
        ca_blob = try loadCerts(allocator);
    }

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .robot_store = RobotStore.init(allocator),
    };
}

pub fn deinit(self: *Runtime) void {
    if (self.ca_blob) |ca_blob| {
        const data: [*]u8 = @ptrCast(ca_blob.data);
        self.allocator.free(data[0..ca_blob.len]);
    }

    global_deinit_once.call();
}

pub fn bind(
    self: *Runtime,
    address: net.Address,
    ctx: *anyopaque,
    onAccept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
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

    for (&self.listeners, &self.pollfds) |*slot, *pfd| {
        if (slot.* == null) {
            slot.* = .{
                .socket = listener,
                .ctx = ctx,
                .onAccept = onAccept,
            };
            pfd.* = .{
                .fd = listener,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            _ = self.listener_count.fetchAdd(1, .release);
            return;
        }
    }

    return error.TooManyListeners;
}

pub fn run(self: *Runtime) void {
    while (!self.shutdown.load(.acquire) and self.listener_count.load(.acquire) > 0) {
        _ = posix.poll(&self.pollfds, -1) catch |err| {
            lp.log.err(.app, "poll", .{ .err = err });
            continue;
        };

        for (&self.listeners, &self.pollfds) |*slot, *pfd| {
            if (pfd.revents == 0) continue;
            pfd.revents = 0;
            const listener = slot.* orelse continue;

            const socket = posix.accept(listener.socket, null, null, posix.SOCK.NONBLOCK) catch |err| {
                switch (err) {
                    error.SocketNotListening, error.ConnectionAborted => {
                        pfd.* = .{ .fd = -1, .events = 0, .revents = 0 };
                        slot.* = null;
                        _ = self.listener_count.fetchSub(1, .release);
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
    }
}

pub fn stop(self: *Runtime) void {
    self.shutdown.store(true, .release);

    // Linux and BSD/macOS handle canceling a socket blocked on accept differently.
    // For Linux, we use posix.shutdown, which will cause accept to return error.SocketNotListening (EINVAL).
    // For BSD, shutdown will return an error. Instead we call posix.close, which will result with error.ConnectionAborted (EBADF).
    for (&self.listeners, &self.pollfds) |*slot, *pfd| {
        if (slot.*) |listener| {
            switch (builtin.target.os.tag) {
                .linux => posix.shutdown(listener.socket, .recv) catch |err| {
                    lp.log.warn(.app, "listener shutdown", .{ .err = err });
                },
                .macos, .freebsd, .netbsd, .openbsd => posix.close(listener.socket),
                else => unreachable,
            }

            pfd.* = .{ .fd = -1, .events = 0, .revents = 0 };
            slot.* = null;
            _ = self.listener_count.fetchSub(1, .release);
        }
    }
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

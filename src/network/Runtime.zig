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
const WebBotAuth = @import("WebBotAuth.zig");

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
web_bot_auth: ?WebBotAuth,

connections: []net_http.Connection,
available: std.DoublyLinkedList = .{},
conn_mutex: std.Thread.Mutex = .{},

pollfds: []posix.pollfd,
listener: ?Listener = null,

// Wakeup pipe: workers write to [1], main thread polls [0]
wakeup_pipe: [2]posix.fd_t = .{ -1, -1 },

shutdown: std.atomic.Value(bool) = .init(false),

const ZigToCurlAllocator = struct {
    // C11 requires malloc to return memory aligned to max_align_t (16 bytes on x86_64).
    // We match this guarantee since libcurl expects malloc-compatible alignment.
    const alignment = 16;

    const Block = extern struct {
        size: usize = 0,
        _padding: [alignment - @sizeOf(usize)]u8 = .{0} ** (alignment - @sizeOf(usize)),

        inline fn fullsize(bytes: usize) usize {
            return alignment + bytes;
        }

        inline fn fromPtr(ptr: *anyopaque) *Block {
            const raw: [*]u8 = @ptrCast(ptr);
            return @ptrCast(@alignCast(raw - @sizeOf(Block)));
        }

        inline fn data(self: *Block) [*]u8 {
            const ptr: [*]u8 = @ptrCast(self);
            return ptr + @sizeOf(Block);
        }

        inline fn slice(self: *Block) []align(alignment) u8 {
            const base: [*]align(alignment) u8 = @ptrCast(@alignCast(self));
            return base[0 .. alignment + self.size];
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Block) == alignment);
    }

    var instance: ?ZigToCurlAllocator = null;

    allocator: Allocator,

    pub fn init(allocator: Allocator) void {
        lp.assert(instance == null, "Initialization of curl must happen only once", .{});
        instance = .{ .allocator = allocator };
    }

    pub fn interface() libcurl.CurlAllocator {
        return .{
            .free = free,
            .strdup = strdup,
            .malloc = malloc,
            .calloc = calloc,
            .realloc = realloc,
        };
    }

    fn _allocBlock(size: usize) ?*Block {
        const slice = instance.?.allocator.alignedAlloc(u8, .fromByteUnits(alignment), Block.fullsize(size)) catch return null;
        const block: *Block = @ptrCast(@alignCast(slice.ptr));
        block.size = size;
        return block;
    }

    fn _freeBlock(header: *Block) void {
        instance.?.allocator.free(header.slice());
    }

    fn malloc(size: usize) ?*anyopaque {
        const block = _allocBlock(size) orelse return null;
        return @ptrCast(block.data());
    }

    fn calloc(nmemb: usize, size: usize) ?*anyopaque {
        const total = nmemb * size;
        const block = _allocBlock(total) orelse return null;
        const ptr = block.data();
        @memset(ptr[0..total], 0); // for historical reasons, calloc zeroes memory, but malloc does not.
        return @ptrCast(ptr);
    }

    fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
        const p = ptr orelse return malloc(size);
        const block = Block.fromPtr(p);

        const old_size = block.size;
        if (size == old_size) return ptr;

        if (instance.?.allocator.resize(block.slice(), alignment + size)) {
            block.size = size;
            return ptr;
        }

        const copy_size = @min(old_size, size);
        const new_block = _allocBlock(size) orelse return null;
        @memcpy(new_block.data()[0..copy_size], block.data()[0..copy_size]);
        _freeBlock(block);
        return @ptrCast(new_block.data());
    }

    fn free(ptr: ?*anyopaque) void {
        const p = ptr orelse return;
        _freeBlock(Block.fromPtr(p));
    }

    fn strdup(str: [*:0]const u8) ?[*:0]u8 {
        const len = std.mem.len(str);
        const header = _allocBlock(len + 1) orelse return null;
        const ptr = header.data();
        @memcpy(ptr[0..len], str[0..len]);
        ptr[len] = 0;
        return ptr[0..len :0];
    }
};

fn globalInit(allocator: Allocator) void {
    ZigToCurlAllocator.init(allocator);

    libcurl.curl_global_init(.{ .ssl = true }, ZigToCurlAllocator.interface()) catch |err| {
        lp.assert(false, "curl global init", .{ .err = err });
    };
}

fn globalDeinit() void {
    libcurl.curl_global_cleanup();
}

pub fn init(allocator: Allocator, config: *const Config) !Runtime {
    globalInit(allocator);
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

    const count: usize = config.httpMaxConcurrent();
    const connections = try allocator.alloc(net_http.Connection, count);
    errdefer allocator.free(connections);

    var available: std.DoublyLinkedList = .{};
    for (0..count) |i| {
        connections[i] = try net_http.Connection.init(ca_blob, config);
        available.append(&connections[i].node);
    }

    const web_bot_auth = if (config.webBotAuth()) |wba_cfg|
        try WebBotAuth.fromConfig(allocator, &wba_cfg)
    else
        null;

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .robot_store = RobotStore.init(allocator),
        .connections = connections,
        .available = available,
        .web_bot_auth = web_bot_auth,
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

    for (self.connections) |*conn| {
        conn.deinit();
    }
    self.allocator.free(self.connections);

    self.robot_store.deinit();
    if (self.web_bot_auth) |wba| {
        wba.deinit(self.allocator);
    }

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
        posix.shutdown(listener.socket, .both) catch |err| blk: {
            if (err == error.SocketNotConnected and builtin.os.tag != .linux) {
                // This error is normal/expected on BSD/MacOS. We probably
                // shouldn't bother calling shutdown at all, but I guess this
                // is safer.
                break :blk;
            }
            lp.log.warn(.app, "listener shutdown", .{ .err = err });
        };
        posix.close(listener.socket);
    }
}

pub fn stop(self: *Runtime) void {
    self.shutdown.store(true, .release);
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

pub fn getConnection(self: *Runtime) ?*net_http.Connection {
    self.conn_mutex.lock();
    defer self.conn_mutex.unlock();

    const node = self.available.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}

pub fn releaseConnection(self: *Runtime, conn: *net_http.Connection) void {
    conn.reset() catch |err| {
        lp.assert(false, "couldn't reset curl easy", .{ .err = err });
    };

    self.conn_mutex.lock();
    defer self.conn_mutex.unlock();

    self.available.append(&conn.node);
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

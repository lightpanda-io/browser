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

pub const WorkerId = usize;
pub const HandleList = std.DoublyLinkedList;

pub const Request = struct {
    node: std.DoublyLinkedList.Node = .{},
    worker_id: WorkerId,
    conn: *net_http.Connection,
    err: ?anyerror = null,
};

pub const WorkerSlot = struct {
    // TODO: when CDP moves to the shared event loop, replace semaphore
    // with a pollable fd so workers can wait on completions and CDP
    // socket simultaneously.
    semaphore: std.Thread.Semaphore = .{},
    completion_mutex: std.Thread.Mutex = .{},
    completion_queue: std.DoublyLinkedList = .{},
};

allocator: Allocator,

config: *const Config,
ca_blob: ?net_http.Blob,
robot_store: RobotStore,

pollfds: []posix.pollfd,
listeners: [Config.MAX_LISTENERS]?Listener = @splat(null),

shutdown: std.atomic.Value(bool) = .init(false),
listener_count: std.atomic.Value(usize) = .init(0),

// Wakeup pipe: workers write to [1], main thread polls [0]
wakeup_pipe: [2]posix.fd_t = .{ -1, -1 },

// Protects submit_queue and workers
mutex: std.Thread.Mutex = .{},

// Submit queue: workers push, main thread drains
submit_queue: std.DoublyLinkedList = .{},

// Worker slots keyed by WorkerId
workers: std.AutoHashMapUnmanaged(WorkerId, WorkerSlot) = .empty,
next_worker_id: WorkerId = 0,

// curl_multi + connection pool (moved from Handles)
multi: *libcurl.CurlM,
connections: []net_http.Connection,
available: HandleList = .{},
in_use: HandleList = .{},

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

    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

    const multi = libcurl.curl_multi_init() orelse return error.FailedToInitializeMulti;
    errdefer libcurl.curl_multi_cleanup(multi) catch {};

    try libcurl.curl_multi_setopt(multi, .max_host_connections, config.httpMaxHostOpen());

    const count: usize = config.httpMaxConcurrent();
    const connections = try allocator.alloc(net_http.Connection, count);
    errdefer allocator.free(connections);

    var available: HandleList = .{};
    for (0..count) |i| {
        connections[i] = try net_http.Connection.init(ca_blob, config);
        available.append(&connections[i].node);
    }

    const pollfds = try allocator.alloc(posix.pollfd, 1 + Config.MAX_LISTENERS + count);
    errdefer allocator.free(pollfds);

    @memset(pollfds, .{ .fd = -1, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .robot_store = RobotStore.init(allocator),
        .pollfds = pollfds,
        .wakeup_pipe = pipe,
        .multi = multi,
        .connections = connections,
        .available = available,
    };
}

pub fn deinit(self: *Runtime) void {
    for (self.connections) |*conn| {
        conn.deinit();
    }
    self.allocator.free(self.connections);
    libcurl.curl_multi_cleanup(self.multi) catch {};

    for (&self.wakeup_pipe) |*fd| {
        if (fd.* >= 0) {
            posix.close(fd.*);
            fd.* = -1;
        }
    }

    self.workers.deinit(self.allocator);
    self.allocator.free(self.pollfds);

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

    const listener_fds = self.pollfds[1..1 + Config.MAX_LISTENERS];
    for (&self.listeners, listener_fds) |*slot, *pfd| {
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
    comptime std.debug.assert(@sizeOf(posix.pollfd) == @sizeOf(libcurl.CurlWaitFd));

    const curl_pollfds = self.pollfds[1 + Config.MAX_LISTENERS ..];
    const curl_waitfds: []libcurl.CurlWaitFd = @ptrCast(curl_pollfds);

    while (!self.shutdown.load(.acquire) and self.listener_count.load(.acquire) > 0) {
        self.processSubmitQueue();

        var curl_count: c_uint = 0;
        libcurl.curl_multi_waitfds(self.multi, curl_waitfds, &curl_count) catch {};

        var timeout_ms: c_long = -1;
        libcurl.curl_multi_timeout(self.multi, &timeout_ms) catch {};
        if (timeout_ms > 200) timeout_ms = 200;

        const poll_len = 1 + Config.MAX_LISTENERS + curl_count;
        _ = posix.poll(self.pollfds[0..poll_len], @intCast(timeout_ms)) catch |err| {
            lp.log.err(.app, "poll", .{ .err = err });
            continue;
        };

        if (self.pollfds[0].revents != 0) {
            self.pollfds[0].revents = 0;
            self.drainWakeupPipe();
        }

        _ = self.curlPerform();
        self.processCompletions();

        const listener_fds = self.pollfds[1..1 + Config.MAX_LISTENERS];
        for (&self.listeners, listener_fds) |*slot, *pfd| {
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

    // Linux and BSD/macOS handle canceling a socket blocked on accept differently.
    // For Linux, we use posix.shutdown, which will cause accept to return error.SocketNotListening (EINVAL).
    // For BSD, shutdown will return an error. Instead we call posix.close, which will result with error.ConnectionAborted (EBADF).
    const cleanup_fds = self.pollfds[1..1 + Config.MAX_LISTENERS];
    for (&self.listeners, cleanup_fds) |*slot, *pfd| {
        if (slot.*) |listener| {
            posix.close(listener.socket);
            pfd.* = .{ .fd = -1, .events = 0, .revents = 0 };
            slot.* = null;
            _ = self.listener_count.fetchSub(1, .release);
        }
    }
}

pub fn stop(self: *Runtime) void {
    self.shutdown.store(true, .release);
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

pub fn registerWorker(self: *Runtime) !WorkerId {
    self.mutex.lock();
    defer self.mutex.unlock();

    const id = self.next_worker_id;
    try self.workers.put(self.allocator, id, .{});
    self.next_worker_id += 1;
    return id;
}

pub fn unregisterWorker(self: *Runtime, id: WorkerId) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    _ = self.workers.remove(id);
}

/// Thread-safe: called by workers to submit a transfer.
pub fn submit(self: *Runtime, node: *std.DoublyLinkedList.Node) void {
    self.mutex.lock();
    self.submit_queue.append(node);
    self.mutex.unlock();

    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

fn processSubmitQueue(self: *Runtime) void {
    var queue = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();

        const q = self.submit_queue;
        self.submit_queue = .{};
        break :blk q;
    };

    while (queue.popFirst()) |node| {
        const request: *Request = @fieldParentPtr("node", node);

        libcurl.curl_multi_add_handle(self.multi, request.conn.easy) catch |err| {
            lp.log.err(.http, "curl_multi_add_handle", .{ .err = err });
            request.err = err;
            self.notifyWorker(request);
        };
    }
}

fn notifyWorker(self: *Runtime, request: *Request) void {
    self.mutex.lock();
    const slot = self.workers.getPtr(request.worker_id);
    self.mutex.unlock();

    if (slot) |s| {
        s.completion_mutex.lock();
        defer s.completion_mutex.unlock();

        s.completion_queue.append(&request.node);
        s.semaphore.post();
    }
}

pub fn getConnection(self: *Runtime) ?*net_http.Connection {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.available.popFirst()) |node| {
        self.in_use.append(node);
        return @as(*net_http.Connection, @fieldParentPtr("node", node));
    }
    return null;
}

pub fn releaseConnection(self: *Runtime, conn: *net_http.Connection) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.in_use.remove(&conn.node);
    self.available.append(&conn.node);
}

fn processCompletions(self: *Runtime) void {
    var msgs_count: c_int = 0;
    while (libcurl.curl_multi_info_read(self.multi, &msgs_count)) |msg| {
        switch (msg.data) {
            .done => |err| {
                // Remove from multi while on main thread. The easy handle
                // retains response data (headers, status) for the worker
                // to read after wakeup.
                libcurl.curl_multi_remove_handle(self.multi, msg.easy_handle) catch {};

                const conn: net_http.Connection = .{ .easy = msg.easy_handle };
                const private = conn.getPrivate() catch continue;
                const request: *Request = @ptrCast(@alignCast(private));
                request.err = err;
                self.notifyWorker(request);
            },
            else => {},
        }
    }
}

fn curlPerform(self: *Runtime) c_int {
    var running: c_int = 0;
    libcurl.curl_multi_perform(self.multi, &running) catch |err| {
        lp.log.err(.http, "curl_multi_perform", .{ .err = err });
    };
    return running;
}

fn drainWakeupPipe(self: *Runtime) void {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = posix.read(self.wakeup_pipe[0], &buf) catch break;
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

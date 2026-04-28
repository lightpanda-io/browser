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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const log = lp.log;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Config = @import("../Config.zig");
const libcurl = @import("../sys/libcurl.zig");

const http = @import("http.zig");
const IpFilter = @import("IpFilter.zig");
const RobotStore = @import("Robots.zig").RobotStore;
const WebBotAuth = @import("WebBotAuth.zig");

const Cache = @import("cache/Cache.zig");
const FsCache = @import("cache/FsCache.zig");

const App = @import("../App.zig");
const Network = @This();

const Listener = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    onAccept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
};

const Error = libcurl.Error;

// Number of fixed pollfds entries (wakeup pipe + listener).
const PSEUDO_POLLFDS = 2;

const MAX_TICK_CALLBACKS = 16;

allocator: Allocator,

app: *App,
config: *const Config,
ca_blob: ?http.Blob,

robot_store: RobotStore,
web_bot_auth: ?WebBotAuth,
cache: ?Cache,

connections: []http.Connection,
available: std.DoublyLinkedList = .{},
conn_mutex: std.Thread.Mutex = .{},

ws_pool: std.heap.MemoryPool(http.Connection),
ws_count: usize = 0,
ws_max: u8,
ws_mutex: std.Thread.Mutex = .{},

pollfds: []posix.pollfd,
listener: ?Listener = null,
accept: std.atomic.Value(bool) = .init(true),
shutdown: std.atomic.Value(bool) = .init(false),

// Wakeup pipe: workers write to [1], main thread polls [0]
wakeup_pipe: [2]posix.fd_t = .{ -1, -1 },

// Multi is a heavy structure that can consume up to 2MB of RAM.
// Currently, Network is used sparingly, and we only create it on demand.
// When Network becomes truly shared, it should become a regular field.
multi: ?*libcurl.CurlM = null,

// Cross-thread submission to the network thread.
//
// Workers push via submit*; the network thread pops in drainQueue.
// `conn.node` is shared across pending_add/pending_remove (mutually
// exclusive); `conn._op_node` is independent and only ever lives in
// pending_ops. All transitions of `conn._submission` and list
// membership happen together under `submission_mutex`.
submission_mutex: std.Thread.Mutex = .{},
pending_add: std.DoublyLinkedList = .{},
pending_remove: std.DoublyLinkedList = .{},
pending_ops: std.DoublyLinkedList = .{},

callbacks: [MAX_TICK_CALLBACKS]TickCallback = undefined,
callbacks_len: usize = 0,
callbacks_mutex: std.Thread.Mutex = .{},

/// Optional IP filter for blocking requests to private/internal networks (--block-private-networks).
ip_filter: ?*IpFilter = null,

const TickCallback = struct {
    ctx: *anyopaque,
    fun: *const fn (*anyopaque) void,
};

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

pub fn init(allocator: Allocator, app: *App, config: *const Config) !Network {
    globalInit(allocator);
    errdefer globalDeinit();

    const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

    // 0 is wakeup, 1 is listener, rest for curl fds
    const pollfds = try allocator.alloc(posix.pollfd, PSEUDO_POLLFDS + config.httpMaxConcurrent());
    errdefer allocator.free(pollfds);

    @memset(pollfds, .{ .fd = -1, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    var ca_blob: ?http.Blob = null;
    if (config.tlsVerifyHost()) {
        ca_blob = try loadCerts(allocator);
    }

    // IP filter for blocking requests to private/internal networks.
    const block_private = config.blockPrivateNetworks();
    const cidrs: ?IpFilter.Cidrs = blk: {
        const s = config.blockCidrs() orelse break :blk null;
        break :blk try IpFilter.parseCidrList(allocator, s);
    };
    const has_cidrs = if (cidrs) |c| c.v4.len > 0 or c.v6.len > 0 or c.allow_v4.len > 0 or c.allow_v6.len > 0 else false;
    const ip_filter: ?*IpFilter = blk: {
        if (!block_private and !has_cidrs) break :blk null;
        const f = try allocator.create(IpFilter);
        f.* = IpFilter.init(block_private, cidrs);
        break :blk f;
    };
    errdefer if (ip_filter) |f| {
        f.deinit(allocator);
        allocator.destroy(f);
    };

    const count: usize = config.httpMaxConcurrent();
    const connections = try allocator.alloc(http.Connection, count);
    errdefer allocator.free(connections);

    var available: std.DoublyLinkedList = .{};
    for (0..count) |i| {
        connections[i] = try http.Connection.init(ca_blob, config, ip_filter);
        available.append(&connections[i].node);
    }

    const web_bot_auth = if (config.webBotAuth()) |wba_cfg|
        try WebBotAuth.fromConfig(allocator, &wba_cfg)
    else
        null;

    const cache = if (config.httpCacheDir()) |cache_dir_path|
        Cache{
            .kind = .{
                .fs = FsCache.init(cache_dir_path) catch |e| {
                    log.err(.cache, "failed to init", .{
                        .kind = "FsCache",
                        .path = cache_dir_path,
                        .err = e,
                    });
                    return e;
                },
            },
        }
    else
        null;

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,

        .pollfds = pollfds,
        .wakeup_pipe = pipe,

        .available = available,
        .connections = connections,

        .app = app,

        .robot_store = RobotStore.init(allocator),
        .web_bot_auth = web_bot_auth,
        .cache = cache,

        .ws_pool = .init(allocator),
        .ws_max = config.wsMaxConcurrent(),

        .ip_filter = ip_filter,
    };
}

pub fn deinit(self: *Network) void {
    if (self.multi) |multi| {
        libcurl.curl_multi_cleanup(multi) catch {};
    }

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

    self.ws_pool.deinit();

    self.robot_store.deinit();
    if (self.web_bot_auth) |wba| {
        wba.deinit(self.allocator);
    }

    if (self.cache) |*cache| cache.deinit();

    if (self.ip_filter) |f| {
        f.deinit(self.allocator);
        self.allocator.destroy(f);
    }

    globalDeinit();
}

pub fn getHandle(self: *Network) !Handle {
    return try Handle.init(self);
}

pub fn bind(
    self: *Network,
    address: *net.Address,
    ctx: *anyopaque,
    on_accept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
) !void {
    if (self.listener != null) return error.TooManyListeners;

    self.accept.store(true, .release);

    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    errdefer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, self.config.maxPendingConnections());

    // When the caller requests port 0, the OS assigns an ephemeral port; read
    // the actual bound address back so callers (e.g. logging) see the real port.
    var bound: posix.sockaddr.storage = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(listener, @ptrCast(&bound), &bound_len);
    address.* = net.Address.initPosix(@ptrCast(@alignCast(&bound)));

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

pub fn unbind(self: *Network) void {
    self.accept.store(false, .release);
    self.wakeupPoll();
}

pub fn onTick(self: *Network, ctx: *anyopaque, callback: *const fn (*anyopaque) void) void {
    self.callbacks_mutex.lock();
    defer self.callbacks_mutex.unlock();

    lp.assert(self.callbacks_len < MAX_TICK_CALLBACKS, "too many ticks", .{});

    self.callbacks[self.callbacks_len] = .{
        .ctx = ctx,
        .fun = callback,
    };
    self.callbacks_len += 1;

    self.wakeupPoll();
}

pub fn fireTicks(self: *Network) void {
    self.callbacks_mutex.lock();
    defer self.callbacks_mutex.unlock();

    for (self.callbacks[0..self.callbacks_len]) |*callback| {
        callback.fun(callback.ctx);
    }
}

pub fn run(self: *Network) void {
    var drain_buf: [64]u8 = undefined;
    var running_handles: c_int = 0;

    const poll_fd = &self.pollfds[0];
    const listen_fd = &self.pollfds[1];

    // Please note that receiving a shutdown command does not terminate all connections.
    // When gracefully shutting down a server, we at least want to send the remaining
    // telemetry, but we stop accepting new connections. It is the responsibility
    // of external code to terminate its requests upon shutdown.
    while (true) {
        if (self.listener != null and !self.accept.load(.acquire)) {
            posix.close(self.listener.?.socket);
            self.listener = null;
            self.pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
        }

        self.drainQueue();

        if (self.multi) |multi| {
            // Kickstart newly added handles (DNS/connect) so that
            // curl registers its sockets before we poll.
            libcurl.curl_multi_perform(multi, &running_handles) catch |err| {
                lp.log.err(.app, "curl perform", .{ .err = err });
            };
            self.processCompletions(multi);
        }

        // for ontick to work, you need to wake up periodically
        const timeout = blk: {
            const min_timeout = 250; // 250ms
            if (self.multi == null) {
                break :blk min_timeout;
            }

            const curl_timeout = self.getCurlTimeout();
            if (curl_timeout == 0) {
                break :blk 0;
            }

            break :blk @min(min_timeout, curl_timeout);
        };

        if (self.multi != null and running_handles > 0) {
            // Use curl_multi_poll: lets libcurl monitor its own
            // sockets while we add the wakeup + listener as extra fds.
            const multi = self.multi.?;
            var extra_fds: [PSEUDO_POLLFDS]libcurl.CurlWaitFd = undefined;
            var extra_len: usize = 0;
            extra_fds[extra_len] = .{
                .fd = poll_fd.fd,
                .events = .{ .pollin = true },
                .revents = .{},
            };
            const wake_idx = extra_len;
            extra_len += 1;
            const listen_idx: ?usize = if (listen_fd.fd >= 0) blk: {
                const idx = extra_len;
                extra_fds[extra_len] = .{
                    .fd = listen_fd.fd,
                    .events = .{ .pollin = true },
                    .revents = .{},
                };
                extra_len += 1;
                break :blk idx;
            } else null;

            libcurl.curl_multi_poll(multi, extra_fds[0..extra_len], timeout, null) catch |err| {
                lp.log.err(.app, "curl poll", .{ .err = err });
                continue;
            };
            poll_fd.revents = if (extra_fds[wake_idx].revents.pollin) posix.POLL.IN else 0;
            if (listen_idx) |idx| {
                listen_fd.revents = if (extra_fds[idx].revents.pollin) posix.POLL.IN else 0;
            }
        } else {
            _ = posix.poll(self.pollfds[0..PSEUDO_POLLFDS], timeout) catch |err| {
                lp.log.err(.app, "poll", .{ .err = err });
                continue;
            };
        }

        // check wakeup pipe
        if (poll_fd.revents != 0) {
            poll_fd.revents = 0;
            while (true)
                _ = posix.read(self.wakeup_pipe[0], &drain_buf) catch break;
        }

        // accept new connections
        if (listen_fd.revents != 0) {
            listen_fd.revents = 0;
            self.acceptConnections();
        }

        if (self.multi) |multi| {
            // Drive transfers and process completions.
            libcurl.curl_multi_perform(multi, &running_handles) catch |err| {
                lp.log.err(.app, "curl perform", .{ .err = err });
            };
            self.processCompletions(multi);
        }

        self.fireTicks();

        if (self.shutdown.load(.acquire) and running_handles == 0) {
            // Check if fireTicks submitted new requests (e.g. telemetry flush).
            // If so, continue the loop to drain and send them before exiting.
            self.submission_mutex.lock();
            const has_pending = self.pending_add.first != null or
                self.pending_remove.first != null or
                self.pending_ops.first != null;
            self.submission_mutex.unlock();
            if (!has_pending) break;
        }
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

pub const Op = union(enum) {
    unpause,
    tls_verify: http.Connection.TlsVerifyOp,
};

// Hand off conn to the network thread for adding to the multi.
pub fn submitRequest(self: *Network, conn: *http.Connection) void {
    {
        self.submission_mutex.lock();
        defer self.submission_mutex.unlock();
        lp.assert(conn._submission == .idle, "submitRequest: conn not idle", .{});
        conn._submission = .pending_add;
        self.pending_add.append(&conn.node);
    }
    self.wakeupPoll();
}

// Cancel a conn. If it never reached the multi (still in pending_add),
// short-circuit: deliver the canceled completion synchronously via
// on_complete. Otherwise queue a remove for the network thread.
pub fn submitRemove(self: *Network, conn: *http.Connection) void {
    var local_cancel: bool = false;
    {
        self.submission_mutex.lock();
        defer self.submission_mutex.unlock();
        switch (conn._submission) {
            .pending_add => {
                self.pending_add.remove(&conn.node);
                conn._submission = .idle;
                self.removeFromOpsLocked(conn);
                local_cancel = true;
            },
            .in_multi => {
                conn._submission = .pending_remove;
                self.pending_remove.append(&conn.node);
            },
            .idle, .pending_remove => {
                lp.log.warn(.app, "submitRemove bad state", .{ .state = @tagName(conn._submission) });
                return;
            },
        }
    }
    if (local_cancel) {
        if (conn.on_complete) |cb| {
            cb(conn, error.Canceled);
        } else {
            self.releaseConnection(conn);
        }
        return;
    }
    self.wakeupPoll();
}

// Fire-and-forget op queued for the network thread to apply on a conn
// that's currently in (or about to enter) the multi. Dropped if the
// conn isn't in flight.
pub fn submitOp(self: *Network, conn: *http.Connection, op: Op) void {
    {
        self.submission_mutex.lock();
        defer self.submission_mutex.unlock();
        switch (conn._submission) {
            .pending_add, .in_multi => {},
            .idle, .pending_remove => return,
        }
        switch (op) {
            .unpause => conn._op_unpause = true,
            .tls_verify => |t| conn._op_tls_verify = t,
        }
        if (!conn._op_in_list) {
            conn._op_in_list = true;
            self.pending_ops.append(&conn._op_node);
        }
    }
    self.wakeupPoll();
}

// Caller holds submission_mutex. Called on every transition out of
// .pending_add/.in_multi.
fn removeFromOpsLocked(self: *Network, conn: *http.Connection) void {
    if (conn._op_in_list) {
        self.pending_ops.remove(&conn._op_node);
        conn._op_in_list = false;
    }
    conn._op_unpause = false;
    conn._op_tls_verify = null;
}

fn wakeupPoll(self: *Network) void {
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

fn drainQueue(self: *Network) void {
    // add/remove are queued for execution outside the lock so that
    // on_complete / releaseConnection can run unblocked. Ops execute
    // *under* the lock — that's what keeps the conn alive (every path
    // that releases the conn first transitions out of .in_multi here).
    // pause/setopt only flip libcurl flags, no callbacks fire.
    var to_add: std.DoublyLinkedList = .{};
    var to_remove: std.DoublyLinkedList = .{};
    {
        self.submission_mutex.lock();
        defer self.submission_mutex.unlock();

        while (self.pending_remove.popFirst()) |node| {
            const conn: *http.Connection = @fieldParentPtr("node", node);
            lp.assert(conn._submission == .pending_remove, "drainQueue: conn not in pending_remove", .{});
            conn._submission = .idle;
            self.removeFromOpsLocked(conn);
            to_remove.append(node);
        }
        while (self.pending_add.popFirst()) |node| {
            const conn: *http.Connection = @fieldParentPtr("node", node);
            lp.assert(conn._submission == .pending_add, "drainQueue: conn not in pending_add", .{});
            // .in_multi is the target; handleAdd may roll back to .idle on failure.
            conn._submission = .in_multi;
            to_add.append(node);
        }
        while (self.pending_ops.popFirst()) |node| {
            const conn: *http.Connection = @fieldParentPtr("_op_node", node);
            conn._op_in_list = false;
            // Conn raced out of multi between submitOp and now; drop ops.
            if (conn._submission != .in_multi) {
                conn._op_unpause = false;
                conn._op_tls_verify = null;
                continue;
            }
            if (conn._op_unpause) {
                conn._op_unpause = false;
                conn.pause(.{ .cont = true }) catch |err| {
                    lp.log.warn(.app, "curl pause", .{ .err = err });
                };
            }
            if (conn._op_tls_verify) |t| {
                conn._op_tls_verify = null;
                conn.setTlsVerify(t.verify, t.use_proxy) catch |err| {
                    lp.log.warn(.app, "curl setTlsVerify", .{ .err = err });
                };
            }
        }
    }

    // Process removes before adds: cancellations should take effect
    // before we admit new transfers.
    while (to_remove.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        self.handleRemove(conn);
    }
    while (to_add.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        self.handleAdd(conn);
    }
}

// Caller has already set conn._submission = .in_multi. On failure we
// roll back to .idle and either fire on_complete or release.
fn handleAdd(self: *Network, conn: *http.Connection) void {
    const multi = self.multi orelse blk: {
        const m = libcurl.curl_multi_init() orelse {
            lp.assert(false, "curl multi init failed", .{});
            unreachable;
        };
        self.multi = m;
        break :blk m;
    };

    conn.setPrivate(conn) catch |err| {
        lp.log.err(.app, "curl set private", .{ .err = err });
        self.handleAddFailure(conn, err);
        return;
    };
    libcurl.curl_multi_add_handle(multi, conn._easy) catch |err| {
        lp.log.err(.app, "curl multi add", .{ .err = err });
        self.handleAddFailure(conn, err);
    };
}

fn handleAddFailure(self: *Network, conn: *http.Connection, err: anyerror) void {
    {
        self.submission_mutex.lock();
        defer self.submission_mutex.unlock();
        conn._submission = .idle;
        self.removeFromOpsLocked(conn);
    }
    if (conn.on_complete) |cb| {
        cb(conn, err);
    } else {
        self.releaseConnection(conn);
    }
}

// Caller has already set conn._submission = .idle and the conn is no
// longer in any submission list. The conn may still be in the multi
// (normal cancel path).
fn handleRemove(self: *Network, conn: *http.Connection) void {
    if (self.multi) |multi| {
        _ = libcurl.curl_multi_remove_handle(multi, conn._easy) catch {};
    }
    if (conn.on_complete) |cb| {
        cb(conn, error.Canceled);
    } else {
        self.releaseConnection(conn);
    }
}

// Caller guarantees Network.run is not executing. Used to drive
// late-cancel completions through after Network.stop()+join().
pub fn drainPendingForShutdown(self: *Network) void {
    self.drainQueue();
    if (self.multi) |multi| {
        self.processCompletions(multi);
    }
}

pub fn stop(self: *Network) void {
    self.shutdown.store(true, .release);
    self.wakeupPoll();
}

fn acceptConnections(self: *Network) void {
    if (self.shutdown.load(.acquire)) {
        return;
    }
    const listener = self.listener orelse return;

    while (true) {
        const socket = posix.accept(listener.socket, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                error.SocketNotListening => {
                    self.pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
                    self.listener = null;
                    return;
                },
                error.ConnectionAborted => {
                    lp.log.warn(.app, "accept connection aborted", .{});
                    continue;
                },
                else => {
                    lp.log.err(.app, "accept error", .{ .err = err });
                    continue;
                },
            }
        };

        // Liveness is enforced at the TCP layer via keepalive probes sent by the
        // kernel. This is transparent to CDP clients — unlike a WebSocket ping, which
        // go-rod panics on and chromedp logs as "malformed". Tunables in Config.zig.
        posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
            log.warn(.app, "SO_KEEPALIVE", .{ .err = err });
            return;
        };

        const option = switch (@import("builtin").os.tag) {
            .macos, .ios => posix.TCP.KEEPALIVE,
            else => posix.TCP.KEEPIDLE,
        };
        posix.setsockopt(socket, posix.IPPROTO.TCP, option, &std.mem.toBytes(Config.CDP_KEEPALIVE_IDLE_S)) catch |err| {
            log.warn(.app, "TCP_KEEPIDLE", .{ .err = err });
        };
        posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(Config.CDP_KEEPALIVE_INTVL_S)) catch |err| {
            log.warn(.app, "TCP_KEEPINTVL", .{ .err = err });
        };
        posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(Config.CDP_KEEPALIVE_CNT)) catch |err| {
            log.warn(.app, "TCP_KEEPCNT", .{ .err = err });
        };

        listener.onAccept(listener.ctx, socket);
    }
}

fn preparePollFds(self: *Network, multi: *libcurl.CurlM) void {
    const curl_fds = self.pollfds[PSEUDO_POLLFDS..];
    @memset(curl_fds, .{ .fd = -1, .events = 0, .revents = 0 });

    var fd_count: c_uint = 0;
    const wait_fds: []libcurl.CurlWaitFd = @ptrCast(curl_fds);
    libcurl.curl_multi_waitfds(multi, wait_fds, &fd_count) catch |err| {
        lp.log.err(.app, "curl waitfds", .{ .err = err });
    };
}

fn getCurlTimeout(self: *Network) i32 {
    const multi = self.multi orelse return -1;
    var timeout_ms: c_long = -1;
    libcurl.curl_multi_timeout(multi, &timeout_ms) catch return -1;
    return @intCast(@min(timeout_ms, std.math.maxInt(i32)));
}

fn processCompletions(self: *Network, multi: *libcurl.CurlM) void {
    var msgs_in_queue: c_int = 0;
    while (libcurl.curl_multi_info_read(multi, &msgs_in_queue)) |msg| {
        const maybe_err: ?anyerror = switch (msg.data) {
            .done => |e| e,
            else => continue,
        };
        if (maybe_err) |err| {
            lp.log.warn(.app, "curl transfer error", .{ .err = err });
        }

        const easy: *libcurl.Curl = msg.easy_handle;
        var ptr: *anyopaque = undefined;
        libcurl.curl_easy_getinfo(easy, .private, &ptr) catch
            lp.assert(false, "curl getinfo private", .{});
        const conn: *http.Connection = @ptrCast(@alignCast(ptr));

        libcurl.curl_multi_remove_handle(multi, easy) catch {};

        // Race with worker submitRemove: if a remove was queued just
        // before the completion fired, absorb it (cancel-after-complete
        // is a no-op).
        {
            self.submission_mutex.lock();
            defer self.submission_mutex.unlock();
            switch (conn._submission) {
                .in_multi => {},
                .pending_remove => self.pending_remove.remove(&conn.node),
                else => lp.assert(false, "completion bad state", .{ .state = @tagName(conn._submission) }),
            }
            conn._submission = .idle;
            self.removeFromOpsLocked(conn);
        }

        if (conn.on_complete) |cb| {
            cb(conn, maybe_err);
        } else {
            self.releaseConnection(conn);
        }
    }
}

comptime {
    if (@sizeOf(posix.pollfd) != @sizeOf(libcurl.CurlWaitFd)) {
        @compileError("pollfd and CurlWaitFd size mismatch");
    }
    if (@offsetOf(posix.pollfd, "fd") != @offsetOf(libcurl.CurlWaitFd, "fd") or
        @offsetOf(posix.pollfd, "events") != @offsetOf(libcurl.CurlWaitFd, "events") or
        @offsetOf(posix.pollfd, "revents") != @offsetOf(libcurl.CurlWaitFd, "revents"))
    {
        @compileError("pollfd and CurlWaitFd layout mismatch");
    }
}

pub fn getConnection(self: *Network) ?*http.Connection {
    self.conn_mutex.lock();
    defer self.conn_mutex.unlock();

    const node = self.available.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}

pub fn releaseConnection(self: *Network, conn: *http.Connection) void {
    switch (conn.transport) {
        .websocket => {
            conn.deinit();
            self.ws_mutex.lock();
            defer self.ws_mutex.unlock();
            self.ws_pool.destroy(conn);
            self.ws_count -= 1;
        },
        else => {
            conn.reset(self.config, self.ca_blob, self.ip_filter) catch |err| {
                lp.assert(false, "couldn't reset curl easy", .{ .err = err });
            };
            self.conn_mutex.lock();
            defer self.conn_mutex.unlock();
            self.available.append(&conn.node);
        },
    }
}

pub fn newConnection(self: *Network) ?*http.Connection {
    const conn = blk: {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();

        if (self.ws_count >= self.ws_max) {
            return null;
        }

        const c = self.ws_pool.create() catch return null;
        self.ws_count += 1;
        break :blk c;
    };

    // don't do this under lock
    conn.* = http.Connection.init(self.ca_blob, self.config, self.ip_filter) catch {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();
        self.ws_pool.destroy(conn);
        self.ws_count -= 1;

        return null;
    };

    return conn;
}

// A Handle is a per-client view onto the shared multi owned by Network.
// Worker code goes through here for every interaction with libcurl /
// network state; the multi itself is driven by the network thread.
//
// Worker-side bookkeeping (in_use, counters) lives here. Network-side
// state (multi, submission queues) lives on Network. Cross-thread
// completion delivery happens via the wake pipe + completion queue:
// the network thread calls pushCompletion (via on_complete), the worker
// thread drains it via nextCompletion.
pub const Handle = struct {
    network: *Network,

    // Active conns (in network's multi or about to enter). Iterated
    // externally by abort, setTlsVerify, etc. — pub for direct access.
    in_use: std.DoublyLinkedList = .{},

    // Counters for in-flight conns by transport. Read externally
    // (ensureNoActiveConnection, abort assertion).
    http_active: usize = 0,
    ws_active: usize = 0,

    // Cross-thread completion delivery. The network thread pushes
    // completed conns via pushCompletion (write to pipe + append to
    // queue under mutex); the worker thread drains them via nextCompletion.
    _wake_pipe: [2]posix.fd_t = .{ -1, -1 },
    _completion_mutex: std.Thread.Mutex = .{},
    _completion_queue: std.DoublyLinkedList = .{},
    // Local buffer of conns moved out of _completion_queue under the
    // mutex; nextCompletion delivers them one at a time without
    // re-locking.
    _drained: std.DoublyLinkedList = .{},

    pub fn init(network: *Network) !Handle {
        const wake_pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        return .{
            .network = network,
            ._wake_pipe = wake_pipe,
        };
    }

    pub fn deinit(self: *Handle) void {
        for (&self._wake_pipe) |*fd| {
            if (fd.* >= 0) {
                posix.close(fd.*);
                fd.* = -1;
            }
        }
    }

    // Returns the read end of the wake pipe so the worker can include
    // it in its poll set. Becomes readable when pushCompletion runs.
    pub fn pollFd(self: *const Handle) posix.fd_t {
        return self._wake_pipe[0];
    }

    // Producer side (network thread). Stashes the err on the conn,
    // appends to the cross-thread queue and wakes the worker.
    fn pushCompletion(self: *Handle, conn: *http.Connection, err: ?anyerror) void {
        conn._completion_err = err;
        {
            self._completion_mutex.lock();
            defer self._completion_mutex.unlock();
            self._completion_queue.append(&conn.node);
        }
        _ = posix.write(self._wake_pipe[1], &.{1}) catch {};
    }

    // No-op: the network thread drives the multi. Kept for API
    // symmetry with the previous sync model.
    pub fn perform(self: *Handle) !c_int {
        _ = self;
        return 0;
    }

    // Poll the wake pipe alongside any caller-supplied fds.
    pub fn poll(self: *Handle, extra_fds: []posix.pollfd, timeout_ms: c_int) !void {
        // 1 wake pipe + extra_fds.
        var buf: [PSEUDO_POLLFDS + 8]posix.pollfd = undefined;
        const total = 1 + extra_fds.len;
        if (total > buf.len) return error.TooManyPollFds;

        buf[0] = .{ .fd = self._wake_pipe[0], .events = posix.POLL.IN, .revents = 0 };
        for (extra_fds, 0..) |fd, i| buf[1 + i] = fd;

        _ = posix.poll(buf[0..total], timeout_ms) catch |err| return err;

        // Copy revents back to caller.
        for (extra_fds, 0..) |*fd, i| fd.revents = buf[1 + i].revents;
    }

    pub const Completion = struct {
        conn: *http.Connection,
        err: ?anyerror,
    };

    // Pull the next completed conn (already removed from the multi by
    // the network thread). Drains the wake pipe and moves the queued
    // conns into a local buffer on the first call after a wake-up.
    pub fn nextCompletion(self: *Handle) !?Completion {
        if (self._drained.popFirst()) |node| return takeCompletion(node);

        // Drain pipe wake bytes.
        var buf: [64]u8 = undefined;
        while (true) {
            _ = posix.read(self._wake_pipe[0], &buf) catch break;
        }

        {
            self._completion_mutex.lock();
            defer self._completion_mutex.unlock();
            while (self._completion_queue.popFirst()) |n| self._drained.append(n);
        }

        if (self._drained.popFirst()) |node| return takeCompletion(node);
        return null;
    }

    fn takeCompletion(node: *std.DoublyLinkedList.Node) Completion {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        const err = conn._completion_err;
        conn._completion_err = null;
        return .{ .conn = conn, .err = err };
    }

    // connection pool delegates ----------------------------------------

    pub fn getConnection(self: *Handle) ?*http.Connection {
        return self.network.getConnection();
    }

    pub fn newConnection(self: *Handle) ?*http.Connection {
        return self.network.newConnection();
    }

    pub fn releaseConnection(self: *Handle, conn: *http.Connection) void {
        self.network.releaseConnection(conn);
    }

    // Hand off a configured conn for the network thread to add to the
    // multi.
    //
    // First-time: tracks in_use + counter, sets on_complete cb, queues.
    // Re-submit (conn already tracked, e.g. redirect): just queues — no
    // bookkeep change.
    //
    // On failure (only possible if conn.transport is invalid for our
    // bookkeeping), state is rolled back; caller releases the conn.
    pub fn submitRequest(self: *Handle, conn: *http.Connection) !void {
        if (!conn.in_use) {
            self.in_use.append(&conn._worker_node);
            conn.in_use = true;
            switch (conn.transport) {
                .http => self.http_active += 1,
                .websocket => self.ws_active += 1,
                else => unreachable,
            }
            conn.on_complete = httpCompletionCallback;
        }
        self.network.submitRequest(conn);
    }

    // Initiate cancellation of an active conn. Bookkeeping (in_use,
    // counters) stays in place until the canceled completion arrives
    // and finishConn runs.
    pub fn submitRemove(self: *Handle, conn: *http.Connection) void {
        self.network.submitRemove(conn);
    }

    // Terminal cleanup. Called from drainCompletions handlers after
    // a conn was delivered through nextCompletion (already detached
    // from the multi). Decrements counters, removes from in_use,
    // returns the conn to the pool.
    pub fn finishConn(self: *Handle, conn: *http.Connection) void {
        if (!conn.in_use) {
            // Already finished or never tracked (e.g. submit failure
            // path). Nothing to undo besides the pool release.
            self.network.releaseConnection(conn);
            return;
        }
        self.in_use.remove(&conn._worker_node);
        conn.in_use = false;
        switch (conn.transport) {
            .http => self.http_active -= 1,
            .websocket => self.ws_active -= 1,
            else => unreachable,
        }
        self.network.releaseConnection(conn);
    }

    // Routes a completed conn (from the network thread) back to its
    // owning Handle's wake pipe and completion queue.
    fn httpCompletionCallback(conn: *http.Connection, err: ?anyerror) void {
        const handle = switch (conn.transport) {
            .http => |t| &t.client.handle,
            .websocket => |ws| &ws._http_client.handle,
            .none => return,
        };
        handle.pushCompletion(conn, err);
    }

    pub const AbortOpts = struct {
        scope: enum { normal, full } = .normal,
    };

    // Abort all tracked conns. Each kill() initiates teardown via
    // submitRemove; the iteration below captures `next` before kill() in
    // case the call mutates the list.
    pub fn abort(self: *Handle) void {
        self._abort(null, .{ .scope = .full });
    }

    // Abort tracked conns belonging to frame_id. With .normal scope, http
    // transfers flagged protect_from_abort are spared; .full scope kills
    // them too. WebSockets ignore the scope flag.
    pub fn abortFrame(self: *Handle, frame_id: u32, opts: AbortOpts) void {
        self._abort(frame_id, opts);
    }

    fn _abort(self: *Handle, frame_id: ?u32, opts: AbortOpts) void {
        var n = self.in_use.first;
        while (n) |node| {
            n = node.next;
            const conn: *http.Connection = @fieldParentPtr("_worker_node", node);
            switch (conn.transport) {
                .http => |transfer| {
                    const params = transfer.req.params;
                    if (frame_id) |fid| {
                        if (params.frame_id == fid and (opts.scope == .full or !params.protect_from_abort)) {
                            transfer.kill();
                        }
                    } else {
                        transfer.kill();
                    }
                },
                .websocket => |ws| {
                    if (frame_id) |fid| {
                        if (ws._frame._frame_id == fid) ws.kill();
                    } else {
                        ws.kill();
                    }
                },
                .none => unreachable,
            }
        }

        if (frame_id == null and comptime builtin.mode == .Debug) {
            // After abort_all, any leftover http transfers should be
            // flagged aborted (in-callback transfers can't be deinit'd
            // synchronously). leftover count must match counters.
            var it = self.in_use.first;
            var leftover: usize = 0;
            while (it) |node| : (it = node.next) {
                const conn: *http.Connection = @fieldParentPtr("_worker_node", node);
                switch (conn.transport) {
                    .http => |transfer| std.debug.assert(transfer.aborted),
                    .websocket => {},
                    .none => {},
                }
                leftover += 1;
            }
            std.debug.assert(self.http_active + self.ws_active == leftover);
        }
    }

    // per-conn ops on active conns -------------------------------------
    //
    // submitOp: the network thread will apply the op when it sees the
    // conn in pending_ops. Op is dropped if the conn isn't in flight.

    pub fn submitTlsVerify(self: *Handle, conn: *http.Connection, verify: bool, use_proxy: bool) void {
        self.network.submitOp(conn, .{ .tls_verify = .{ .verify = verify, .use_proxy = use_proxy } });
    }

    pub fn submitUnpause(self: *Handle, conn: *http.Connection) void {
        self.network.submitOp(conn, .unpause);
    }
};

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
            remain = remain[64..];
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

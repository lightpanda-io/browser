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

const App = @import("../App.zig");
const Config = @import("../Config.zig");

const CDP = @import("../cdp/CDP.zig");
const libcurl = @import("../sys/libcurl.zig");

const http = @import("http.zig");
const IpFilter = @import("IpFilter.zig");
const RobotStore = @import("Robots.zig").RobotStore;
const WebBotAuth = @import("WebBotAuth.zig");

const Cache = @import("cache/Cache.zig");
const FsCache = @import("cache/FsCache.zig");

const log = lp.log;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const Network = @This();

const Listener = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    onAccept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
};

// Read side of a CDP WebSocket, registered with the Network thread so
// bytes are read off the socket from here and dispatched into the CDP
// layer via direct method calls on `cdp`. Network never sends on the
// socket — the worker is the sole writer. After registerCdp returns,
// the worker must not call posix.read on this socket directly.
// unregisterCdp is synchronous: it blocks until Network confirms the
// link has been dropped from its poll set and won't touch it again.
pub const CdpLink = struct {
    cdp: *CDP,
    state: State,
    socket: posix.socket_t,
    // The worker's HttpClient.Handles (by value — it's one pointer
    // wide). Network calls handles.wakeup() to unblock the worker
    // from curl_multi_poll whenever it pushes to the worker's inbox.
    handles: http.Handles,
    node: DoublyLinkedList.Node = .{},

    pub const State = enum {
        live,
        // Worker called unregisterCdp; Network will drop the link on
        // its next loop iteration and signal cdp_unregister.
        unregistering,
        // Network has dropped the link from its poll set. The worker
        // can safely free anything the link's callbacks closed over.
        removed,
    };
};

// Number of fixed pollfds entries (wakeup pipe + listener).
const PSEUDO_POLLFDS = 2;

const MAX_TICK_CALLBACKS = 16;

allocator: Allocator,

app: *App,
cache: ?Cache,
config: *const Config,
ca_blob: ?http.Blob,
robot_store: RobotStore,
web_bot_auth: ?WebBotAuth,

connections: []http.Connection,
available: DoublyLinkedList = .{},
conn_mutex: std.Thread.Mutex = .{},

ws_pool: std.heap.MemoryPool(http.Connection),
ws_count: usize = 0,
ws_max: u8,
ws_mutex: std.Thread.Mutex = .{},

pollfds: []posix.pollfd,
listener: ?Listener = null,
accept: std.atomic.Value(bool) = .init(true),

// Wakeup pipe: workers write to [1], main thread polls [0]
wakeup_pipe: [2]posix.fd_t = .{ -1, -1 },

shutdown: std.atomic.Value(bool) = .init(false),

// Multi is a heavy structure that can consume up to 2MB of RAM.
// Currently, Network is used sparingly, and we only create it on demand.
// When Network becomes truly shared, it should become a regular field.
multi: ?*libcurl.CurlM = null,
submission_mutex: std.Thread.Mutex = .{},
submission_queue: DoublyLinkedList = .{},

callbacks: [MAX_TICK_CALLBACKS]TickCallback = undefined,
callbacks_len: usize = 0,
callbacks_mutex: std.Thread.Mutex = .{},

// Registered CDP read endpoints. Producer-side (the worker doing
// register/unregister) and consumer-side (this thread's run loop) are
// serialized by cdp_mutex. cdp_unregister signals when a link
// transitions to .removed so unregisterCdp can return.
cdp_links: DoublyLinkedList = .{},
cdp_mutex: std.Thread.Mutex = .{},
cdp_unregister: std.Thread.Condition = .{},
// Per-iteration snapshot of CdpLinks whose sockets are in pollfds.
// Sized at maxConnections at init time so we never allocate inside
// run(). Parallel to pollfds[cdp_start..cdp_start + cdp_poll_count].
// Persists across iterations; only rebuilt when `cdp_dirty` is set.
cdp_poll_snapshot: []?*CdpLink,
cdp_poll_count: usize = 0,

// Set whenever the cdp_links list changes (register / unregister /
// natural drop). prepareCdpPollFds rebuilds the snapshot only when
// this is true; idle iterations skip the rebuild. Network run() ticks
// hundreds of times per second, and the link set is stable between
// connection lifecycle events, so the steady-state cost of the CDP
// poll prep is one mutex acquire + one bool read.
cdp_dirty: bool = false,

// Location in pollfds where cdp sockets start
cdp_start: usize,

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

    // IMPORTANT: This is a bit messy, and it exists specifically because
    // self.multi is optional. self.multi is optional so that, when telemetry is
    // disabled, we don't need the overhead of a multi. If self.multi wasn't
    // optional, then we wouldn't need to use posix.poll, we could use
    // curl_multi_poll. This is to do in a follow up.

    // The structure is: 0 is wakeup, 1 is listener, rest for curl fds:
    //   [0]                                          wakeup pipe
    //   [1]                                          listener
    //   [PSEUDO_POLLFDS .. + httpMaxConcurrent]      curl multi fds
    //   [.. + maxConnections]                        CDP socket fds
    const max_cdp = config.maxConnections();
    const pollfds = try allocator.alloc(posix.pollfd, PSEUDO_POLLFDS + config.httpMaxConcurrent() + max_cdp);
    errdefer allocator.free(pollfds);

    const cdp_poll_snapshot = try allocator.alloc(?*CdpLink, max_cdp);
    errdefer allocator.free(cdp_poll_snapshot);
    @memset(cdp_poll_snapshot, null);

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

    var available: DoublyLinkedList = .{};
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
        .cdp_poll_snapshot = cdp_poll_snapshot,
        .cdp_start = PSEUDO_POLLFDS + config.httpMaxConcurrent(),

        .available = available,
        .connections = connections,

        .app = app,

        .cache = cache,
        .robot_store = RobotStore.init(allocator),
        .web_bot_auth = web_bot_auth,

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
    self.allocator.free(self.cdp_poll_snapshot);

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

// Hand a CDP WebSocket's read side over to the main network thread. The caller
// owns the link and must keep it alive until unregisterCdp is called.
// The caller must not read from the socket.
pub fn registerCdp(self: *Network, link: *CdpLink) void {
    self.cdp_mutex.lock();
    self.cdp_links.append(&link.node);
    self.cdp_dirty = true;
    self.cdp_mutex.unlock();
    self.wakeupPoll();
}

// Synchronous teardown. Blocks the caller until this thread has
// dropped the link from its poll set and won't invoke any of the
// link's callbacks. Safe to call after Network has already dropped
// the link unsolicited (state == .removed) — returns immediately in
// that case.
pub fn unregisterCdp(self: *Network, link: *CdpLink) void {
    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();
    if (link.state == .live) {
        link.state = .unregistering;
        self.cdp_dirty = true;
        self.wakeupPoll();
    }

    while (link.state != .removed) {
        // condition variable, waiting for a signal
        self.cdp_unregister.wait(&self.cdp_mutex);
    }
}

// Drop a link from the poll set. Caller must hold cdp_mutex.
//   - on_disconnect is fired iff `notify` is true. Set notify=false
//     when the consumer already knows the link is dead (e.g. close
//     frame just went through on_bytes; the .close message in the
//     inbox is enough to wake the worker).
//   - The worker is woken via curl_multi_wakeup either way.
fn dropCdp(self: *Network, link: *CdpLink, err: ?anyerror, notify: bool) void {
    self.cdp_links.remove(&link.node);
    link.state = .removed;
    self.cdp_dirty = true;
    if (notify) {
        link.cdp.terminateFromNetwork();

        // notify=true means the worker hasn't been told yet — push the
        // disconnect into the inbox and break it out of curl_multi_poll.
        // notify=false paths have already woken the worker (close frame
        // case) or are about to be unblocked via cdp_unregister.broadcast
        // (unregister case); no extra wakeup needed.
        link.cdp.onLinkDisconnect(err);
        link.handles.wakeup() catch |e| {
            lp.log.warn(.cdp, "CDP link wakeup", .{ .err = e });
        };
    }
}

// Build the CDP portion of pollfds and snapshot the matching *CdpLink
// pointers so we can correlate revents after poll() returns. Called
// before poll, under cdp_mutex.
fn prepareCdpPollFds(self: *Network) void {
    const cdp_start = self.cdp_start;

    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    // Idle fast-path: link set unchanged since last rebuild, so the
    // snapshot + pollfds entries from the previous iteration are still
    // correct. Kernel will overwrite `revents` in the next poll() call.
    if (!self.cdp_dirty) {
        return;
    }
    self.cdp_dirty = false;

    @memset(self.pollfds[cdp_start..], .{ .fd = -1, .events = 0, .revents = 0 });

    var i: usize = 0;
    var it = self.cdp_links.first;
    while (it) |node| : (it = node.next) {
        lp.assert(i < self.cdp_poll_snapshot.len, "CDP poll snapshot overflow", .{ .i = i, .len = self.cdp_poll_snapshot.len });
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state != .live) {
            // Will be handled in processCdpEvents; don't poll its fd.
            continue;
        }

        self.pollfds[cdp_start + i] = .{
            .fd = link.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        self.cdp_poll_snapshot[i] = link;
        i += 1;
    }
    self.cdp_poll_count = i;
}

// Per-iteration CDP handling: process pending unregistrations, then
// process revents on each polled link. Called after poll().
fn processCdpEvents(self: *Network) void {
    var any_removed = false;
    const cdp_start = self.cdp_start;

    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    // First pass: pending unregister requests.
    var it = self.cdp_links.first;
    while (it) |node| {
        const next = node.next;
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state == .unregistering) {
            self.dropCdp(link, null, false);
            any_removed = true;
        }
        it = next;
    }

    // Second pass: revents on the snapshot. Skip links the first pass
    // (or a prior natural drop) has already removed.
    for (self.cdp_poll_snapshot[0..self.cdp_poll_count], 0..) |link_opt, i| {
        const link = link_opt orelse continue;
        if (link.state != .live) {
            continue;
        }
        const pfd = self.pollfds[cdp_start + i];
        if (pfd.revents == 0) {
            continue;
        }

        const fatal_events: i16 = comptime @intCast(posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
        if (pfd.revents & fatal_events != 0) {
            self.dropCdp(link, null, true);
            any_removed = true;
            continue;
        }

        if (pfd.revents & posix.POLL.IN == 0) {
            continue;
        }

        var buf: [16 * 1024]u8 = undefined;
        const n = posix.read(link.socket, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                lp.log.warn(.cdp, "CDP read", .{ .err = err });
                self.dropCdp(link, err, true);
                any_removed = true;
                continue;
            },
        };

        if (n == 0) {
            // peer EOF
            self.dropCdp(link, null, true);
            any_removed = true;
            continue;
        }

        const keep = link.cdp.onData(buf[0..n]) catch |err| {
            // Fatal frame/feed error. Whatever messages on_bytes
            // managed to push are still in the inbox; the failing
            // frame was NOT pushed, and the worker has no way to
            // know it should exit. Drop with notify=true so
            // on_disconnect surfaces a .disconnect into the inbox.
            // dropCdp wakes the worker.
            lp.log.info(.cdp, "CDP onData", .{ .err = err });
            self.dropCdp(link, err, true);
            any_removed = true;
            continue;
        };

        // on_bytes succeeded — wake the worker so it observes anything
        // new in the inbox (data / ping / close).
        link.handles.wakeup() catch |err| {
            lp.log.warn(.cdp, "CDP link wakeup", .{ .err = err });
        };

        if (!keep) {
            // Close frame: the handler already pushed .close. Worker's
            // drainInbox will call on_disconnect itself after replying,
            // so we drop without re-notifying.
            self.dropCdp(link, null, false);
            any_removed = true;
        }
    }

    if (any_removed) {
        self.cdp_unregister.broadcast();
    }
}

// On shutdown, force-disconnect every still-live CDP link. Each link's
// worker thread blocks in curl_multi_poll and is woken ONLY by this
// (Network) thread via dropCdp -> handles.wakeup(). If the run loop
// exits with links still live, those workers never wake and
// Server.deinit() spins on active_threads forever (issue #2510).
// Mirrors the peer-EOF path in processCdpEvents: dropCdp(notify=true)
// pushes a .disconnect into the worker's inbox and wakes it, so
// cdp.tick() returns false and the worker exits.
fn shutdownCdpLinks(self: *Network) void {
    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    var it = self.cdp_links.first;
    while (it) |node| {
        it = node.next;
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state == .live) {
            self.dropCdp(link, null, true);
        }
    }

    self.cdp_unregister.broadcast();
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

            self.preparePollFds(multi);
        }

        self.prepareCdpPollFds();

        // for ontick to work, you need to wake up periodically
        const timeout = blk: {
            const min_timeout = 250; // 250ms
            if (self.multi == null) {
                break :blk min_timeout;
            }

            // curl_multi_timeout reports -1 when curl has no timeout
            // preference (idle) and 0 when it wants to be serviced
            // immediately. Treat both as "no curl-imposed deadline" and
            // fall back to min_timeout — otherwise @min(min_timeout, -1)
            // would be -1, i.e. poll() blocks forever, starving onTick
            // (telemetry's periodic flush) and removing the safety net
            // that bounds any missed wakeup to min_timeout.
            const curl_timeout = self.getCurlTimeout();
            if (curl_timeout <= 0) {
                break :blk min_timeout;
            }

            break :blk @min(min_timeout, curl_timeout);
        };

        _ = posix.poll(self.pollfds, timeout) catch |err| {
            lp.log.err(.app, "poll", .{ .err = err });
            continue;
        };

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

        self.processCdpEvents();

        self.fireTicks();

        if (self.shutdown.load(.acquire)) {
            // Drain any live CDP links so their workers can exit (issue #2510).
            // Idempotent — no-op once drained, safe to call every iteration
            self.shutdownCdpLinks();

            if (running_handles == 0) {
                // Check if fireTicks submitted new requests (e.g. telemetry
                // flush). If so, continue the loop to drain and send them
                // before exiting.
                self.submission_mutex.lock();
                const has_pending = self.submission_queue.first != null;
                self.submission_mutex.unlock();

                if (!has_pending) {
                    break;
                }
            }
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

pub fn submitRequest(self: *Network, conn: *http.Connection) void {
    self.submission_mutex.lock();
    self.submission_queue.append(&conn.node);
    self.submission_mutex.unlock();
    self.wakeupPoll();
}

fn wakeupPoll(self: *Network) void {
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
}

fn drainQueue(self: *Network) void {
    self.submission_mutex.lock();
    defer self.submission_mutex.unlock();

    if (self.submission_queue.first == null) return;

    const multi = self.multi orelse blk: {
        const m = libcurl.curl_multi_init() orelse {
            lp.assert(false, "curl multi init failed", .{});
            unreachable;
        };
        self.multi = m;
        break :blk m;
    };

    while (self.submission_queue.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        conn.setPrivate(conn) catch |err| {
            lp.log.err(.app, "curl set private", .{ .err = err });
            self.releaseConnection(conn);
            continue;
        };
        libcurl.curl_multi_add_handle(multi, conn._easy) catch |err| {
            lp.log.err(.app, "curl multi add", .{ .err = err });
            self.releaseConnection(conn);
        };
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

        listener.onAccept(listener.ctx, socket);
    }
}

fn preparePollFds(self: *Network, multi: *libcurl.CurlM) void {
    // Only the curl slice — NOT through to the end of pollfds. The CDP
    // socket fds live in [cdp_start..] and are owned by
    // prepareCdpPollFds, which only rebuilds them when cdp_dirty is set
    // (a steady-state optimization). Slicing to the end here would
    // @memset those fds to -1 every iteration once a multi exists (which
    // happens as soon as telemetry sends its first request), silently
    // dropping every live CDP socket from the poll set — Network then
    // never reads another CDP message (#2508) nor observes peer
    // EOF/shutdown (#2507).
    const curl_fds = self.pollfds[PSEUDO_POLLFDS..self.cdp_start];
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
        switch (msg.data) {
            .done => |maybe_err| {
                if (maybe_err) |err| {
                    lp.log.warn(.app, "curl transfer error", .{ .err = err });
                }
            },
            else => continue,
        }

        const easy: *libcurl.Curl = msg.easy_handle;
        var ptr: *anyopaque = undefined;
        libcurl.curl_easy_getinfo(easy, .private, &ptr) catch
            lp.assert(false, "curl getinfo private", .{});
        const conn: *http.Connection = @ptrCast(@alignCast(ptr));

        libcurl.curl_multi_remove_handle(multi, easy) catch {};
        self.releaseConnection(conn);
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

const testing = @import("../testing.zig");

test "Network: preparePollFds leaves the CDP fd region untouched" {
    // Regression for #2507 / #2508. Once a multi exists (telemetry creates
    // one in optimized builds), preparePollFds runs every loop iteration.
    // It rebuilds only the curl slice [PSEUDO_POLLFDS..cdp_start]; the CDP
    // region [cdp_start..] is owned by prepareCdpPollFds, which keeps its
    // entries across iterations and only rebuilds when cdp_dirty is set.
    // A slice that ran to the end of pollfds @memset those CDP sockets to
    // -1, silently dropping every live CDP connection from the poll set —
    // so Network stopped reading CDP messages (#2508) and never observed
    // peer EOF/shutdown (#2507). curl global is initialized by the test
    // harness (App.init -> Network.init).
    const multi = libcurl.curl_multi_init() orelse return error.FailedToInitMulti;
    defer libcurl.curl_multi_cleanup(multi) catch {};

    const curl_slots = 4;
    const cdp_slots = 3;
    var pollfds: [PSEUDO_POLLFDS + curl_slots + cdp_slots]posix.pollfd = undefined;
    @memset(&pollfds, .{ .fd = -1, .events = 0, .revents = 0 });

    // preparePollFds only reads self.pollfds and self.cdp_start.
    var nw: Network = undefined;
    nw.pollfds = &pollfds;
    nw.cdp_start = PSEUDO_POLLFDS + curl_slots;

    // Two live CDP sockets parked in the CDP region, mimicking the steady
    // state between cdp_dirty rebuilds.
    pollfds[nw.cdp_start] = .{ .fd = 4242, .events = posix.POLL.IN, .revents = 0 };
    pollfds[nw.cdp_start + 1] = .{ .fd = 4243, .events = posix.POLL.IN, .revents = 0 };

    nw.preparePollFds(multi);

    try testing.expectEqual(@as(posix.fd_t, 4242), pollfds[nw.cdp_start].fd);
    try testing.expectEqual(@as(posix.fd_t, 4243), pollfds[nw.cdp_start + 1].fd);
}

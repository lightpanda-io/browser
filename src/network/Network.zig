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
const crypto = @import("../sys/libcrypto.zig");

const http = @import("http.zig");
const IpFilter = @import("IpFilter.zig");
const RobotStore = @import("Robots.zig").RobotStore;
const WebBotAuth = @import("WebBotAuth.zig");
const CurlDebugAllocator = @import("CurlDebugAllocator.zig");

const Cache = @import("cache/Cache.zig");
const FsCache = @import("cache/FsCache.zig");

const log = lp.log;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const IS_DEBUG = builtin.mode == .Debug;

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

allocator: Allocator,

app: *App,
cache: ?Cache,
config: *const Config,
/// Holds certificate bundle.
x509_store: *crypto.X509_STORE,
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

fn globalInit(allocator: Allocator) void {
    // Only route curl's own allocations through our allocator in Debug, so the
    // leak detector sees them. In Release it'd just wrap c_allocator (curl's
    // default malloc anyway) at the cost of a per-allocation header.
    const curl_allocator = comptime if (IS_DEBUG) CurlDebugAllocator.interface() else null;
    if (comptime IS_DEBUG) {
        CurlDebugAllocator.init(allocator);
    }

    libcurl.curl_global_init(.{ .ssl = true }, curl_allocator) catch |err| {
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

    // pollfds layout:
    //   [0]                                  wakeup pipe
    //   [1]                                  listener
    //   [PSEUDO_POLLFDS .. + max_cdp]        CDP socket fds
    const max_cdp = config.maxConnections();
    const pollfds = try allocator.alloc(posix.pollfd, PSEUDO_POLLFDS + max_cdp);
    errdefer allocator.free(pollfds);

    const cdp_poll_snapshot = try allocator.alloc(?*CdpLink, max_cdp);
    errdefer allocator.free(cdp_poll_snapshot);
    @memset(cdp_poll_snapshot, null);

    @memset(pollfds, .{ .fd = -1, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    const x509_store = blk: {
        if (config.tlsVerifyHost()) {
            break :blk try createX509Store(allocator);
        }
        break :blk crypto.X509_STORE_new() orelse {
            return error.FailedToCreateX509Store;
        };
    };
    errdefer crypto.X509_STORE_free(x509_store);

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
        connections[i] = try http.Connection.init(x509_store, config, ip_filter);
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
        .x509_store = x509_store,

        .pollfds = pollfds,
        .wakeup_pipe = pipe,
        .cdp_poll_snapshot = cdp_poll_snapshot,
        .cdp_start = PSEUDO_POLLFDS,

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
    for (&self.wakeup_pipe) |*fd| {
        if (fd.* >= 0) {
            posix.close(fd.*);
            fd.* = -1;
        }
    }

    self.allocator.free(self.pollfds);
    self.allocator.free(self.cdp_poll_snapshot);

    crypto.X509_STORE_free(self.x509_store);

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

    const poll_fd = &self.pollfds[0];
    const listen_fd = &self.pollfds[1];

    // Receiving a shutdown command does not terminate existing connections: we
    // stop accepting new ones but leave in-flight requests to external code to
    // terminate. This loop only services the listener and the CDP read sockets;
    // page fetches run on per-worker HttpClient multis and telemetry on its own
    // thread, so nothing here drives libcurl.
    while (true) {
        if (self.listener != null and !self.accept.load(.acquire)) {
            posix.close(self.listener.?.socket);
            self.listener = null;
            self.pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
        }

        self.prepareCdpPollFds();

        // wait until we get a CDP message or a signal on the wakeup pipe
        _ = posix.poll(self.pollfds, -1) catch |err| {
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

        self.processCdpEvents();

        if (self.shutdown.load(.acquire)) {
            // Drain any live CDP links so their workers can exit (issue #2510),
            // then stop. Page fetches and telemetry don't run on this loop, so
            // there is nothing else to flush here.
            self.shutdownCdpLinks();
            break;
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

fn wakeupPoll(self: *Network) void {
    _ = posix.write(self.wakeup_pipe[1], &.{1}) catch {};
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
            conn.reset(self.config, self.x509_store, self.ip_filter) catch |err| {
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
    conn.* = http.Connection.init(self.x509_store, self.config, self.ip_filter) catch {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();
        self.ws_pool.destroy(conn);
        self.ws_count -= 1;

        return null;
    };

    return conn;
}

const CreateX509StoreError = std.crypto.Certificate.Bundle.RescanError || error{FailedToCreateX509Store};

// TODO: on BSD / Linux, we could just read the PEM file directly.
// This whole rescan + decode is really just needed for MacOS. On Linux
// bundle.rescan does find the .pem file(s) which could be in a few different
// places, so it's still useful, just not efficient.
//
/// NEVER give full ownership of store to SSL_CTX, always rely on ref counting.
fn createX509Store(allocator: Allocator) CreateX509StoreError!*crypto.X509_STORE {
    const store = crypto.X509_STORE_new() orelse return error.FailedToCreateX509Store;
    errdefer crypto.X509_STORE_free(store);

    var bundle: std.crypto.Certificate.Bundle = .{};
    try bundle.rescan(allocator);
    defer bundle.deinit(allocator);

    const bytes = bundle.bytes.items;
    if (bytes.len == 0) {
        log.warn(.app, "No system certificates", .{});
        return store;
    }
    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        // d2i_X509 reads the cert's own DER length header to find its end and
        // advances `ptr` past it, so we just hand it the rest of the buffer.
        var ptr: [*]const u8 = bytes.ptr + index.*;
        const x509 = crypto.d2i_X509(null, &ptr, @intCast(bytes.len - index.*)) orelse {
            log.warn(.app, "Skipping unparseable system cert", .{});
            continue;
        };
        defer crypto.X509_free(x509); // add_cert takes its own ref; drop ours.
        // TODO: Handle error.
        const result = crypto.X509_STORE_add_cert(store, x509);
        if (result != 1) {
            log.warn(.app, "Failed to add X509 cert to store", .{});
        }
    }

    return store;
}

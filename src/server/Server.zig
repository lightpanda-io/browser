// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
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
const sys_net = @import("../sys/net.zig");

const CDP = @import("cdp/CDP.zig");
const http = @import("../network/http.zig");

const BiDi = @import("bidi/BiDi.zig");
const Handshake = @import("Handshake.zig");
const Driver = @import("Driver.zig");

const log = lp.log;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const Server = @This();

// Read side of a client (CDP / BiDi) WebSocket, registered with the
// server's run loop so bytes are read off the socket there and dispatched
// into the protocol layer via direct method calls on `driver`. The loop
// never sends on the socket — the worker is the sole writer. After
// registerLink returns, the worker must not call posix.read on this socket
// directly. unregisterLink is synchronous: it blocks until the loop
// confirms the link has been dropped from its poll set and won't touch it
// again.
pub const Link = struct {
    driver: Driver,
    state: State,
    socket: posix.socket_t,
    // The worker's HttpClient.Handles (by value — it's one pointer wide).
    // The loop calls handles.wakeup() to unblock the worker from
    // curl_multi_poll whenever it pushes to the worker's inbox.
    handles: http.Handles,
    node: DoublyLinkedList.Node = .{},

    pub const State = enum {
        live,
        // Worker called unregisterLink; the loop will drop the link on
        // its next iteration and signal link_removed.
        unregistering,
        // The loop has dropped the link from its poll set. The worker
        // can safely free anything the link's callbacks closed over.
        removed,
    };
};

// Number of fixed pollfds entries (wakeup pipe + listener).
const PSEUDO_POLLFDS = 2;

app: *App,
max_connections: usize,
protocols: Handshake.Protocols,
bidi_session_url: []const u8,
json_version_response: []const u8,

driver_mutex: std.Io.Mutex = .init,
drivers: std.ArrayList(Driver) = .empty,

// list of sockets that haven't yet (and might never) be updated to a driver
// (needed for a clean shutdown).
handshakes: std.ArrayList(posix.socket_t) = .empty,

// Number of active conns, used to enforce the cdp-max-connections limit.
active_conns: std.atomic.Value(u32) = .init(0),
// Number of existing threads, used to deinit correctly.
// It can be higher than active_conns b/c we free conn slots early.
active_threads: std.atomic.Value(u32) = .init(0),

cdp_pool: std.heap.MemoryPool(CDP),

listener: posix.socket_t,

// pollfds layout:
//   [0]                                  wakeup pipe
//   [1]                                  listener
//   [PSEUDO_POLLFDS .. + max_connections] link sockets
pollfds: []posix.pollfd,

// Wakeup pipe: other threads write to [1], the run loop polls [0]
wakeup_pipe: [2]posix.fd_t,

shutting_down: std.atomic.Value(bool) = .init(false),

// Registered client read endpoints. Producer-side (the worker doing
// register/unregister) and consumer-side (the run loop) are serialized
// by link_mutex. link_removed signals when a link transitions to
// .removed so unregisterLink can return.
links: DoublyLinkedList = .{},
link_mutex: std.Io.Mutex = .init,
link_removed: std.Io.Condition = .init,
// Per-iteration snapshot of Links whose sockets are in pollfds. Sized at
// max_connections at init time so we never allocate inside run().
// Parallel to pollfds[PSEUDO_POLLFDS..][0..poll_count]. Persists across
// iterations; only rebuilt when `links_dirty` is set.
poll_snapshot: []?*Link,
poll_count: usize = 0,

// Set whenever the links list changes (register / unregister / natural
// drop). preparePollFds rebuilds the snapshot only when this is true;
// idle iterations skip the rebuild. run() ticks hundreds of times per
// second, and the link set is stable between connection lifecycle
// events, so the steady-state cost of the poll prep is one mutex
// acquire + one bool read.
links_dirty: bool = false,

pub fn init(app: *App, address: sys_net.IpAddress) !*Server {
    const allocator = app.allocator;
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);

    const pipe = try sys_net.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    errdefer for (pipe) |fd| {
        _ = std.c.close(fd);
    };

    const max_connections = app.config.maxConnections();
    const pollfds = try allocator.alloc(posix.pollfd, PSEUDO_POLLFDS + max_connections);
    errdefer allocator.free(pollfds);
    @memset(pollfds, .{ .fd = -1, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    const poll_snapshot = try allocator.alloc(?*Link, max_connections);
    errdefer allocator.free(poll_snapshot);
    @memset(poll_snapshot, null);

    // Bind first so /json/version can advertise the OS-assigned port (--port 0).
    var bound_address = address;
    const listener = try bindListener(app.config, &bound_address);
    errdefer _ = std.c.close(listener);
    pollfds[1] = .{ .fd = listener, .events = posix.POLL.IN, .revents = 0 };
    log.note(.note, "server running", .{ .address = bound_address });

    const port = bound_address.getPort();
    const json_version_response = try buildJSONVersionResponse(app, port);
    errdefer allocator.free(json_version_response);

    const bidi_session_url = try std.fmt.allocPrint(allocator, "ws://{s}:{d}/session/", .{ app.config.advertiseHost(), port });
    errdefer allocator.free(bidi_session_url);

    var protocols: Handshake.Protocols = .{};
    for (app.config.protocols()) |p| switch (p) {
        .cdp => protocols.cdp = true,
        .webdriver => protocols.webdriver = true,
    };

    self.* = .{
        .app = app,
        .cdp_pool = .empty,
        .json_version_response = json_version_response,
        .bidi_session_url = bidi_session_url,
        .max_connections = max_connections,
        .listener = listener,
        .pollfds = pollfds,
        .wakeup_pipe = pipe,
        .poll_snapshot = poll_snapshot,
        .protocols = protocols,
    };
    return self;
}

fn bindListener(config: *const Config, address: *sys_net.IpAddress) !posix.socket_t {
    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try sys_net.socket(sys_net.family(address), flags, posix.IPPROTO.TCP);
    errdefer _ = std.c.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    const sa = sys_net.sockaddrFromAddress(address);
    try sys_net.bind(listener, sa.ptr(), sa.len);
    try sys_net.listen(listener, config.maxPendingConnections());

    // When the caller requests port 0, the OS assigns an ephemeral port; read
    // the actual bound address back so callers (e.g. logging) see the real port.
    var bound: posix.sockaddr.storage = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try sys_net.getsockname(listener, @ptrCast(&bound), &bound_len);
    address.* = sys_net.addressFromSockaddr(@ptrCast(&bound));

    return listener;
}

// Stop accepting, make run() return, and terminate every live worker.
// Idempotent: the signal handler calls it, and so does deinit.
pub fn shutdown(self: *Server) void {
    self.shutting_down.store(true, .release);
    self.wakeup();

    self.driver_mutex.lockUncancelable(lp.io);
    defer self.driver_mutex.unlock(lp.io);

    for (self.drivers.items) |*driver| {
        driver.shutdown();
    }
    for (self.handshakes.items) |socket| {
        sys_net.shutdown(socket, .recv) catch {};
    }
}

pub fn deinit(self: *Server) void {
    self.shutdown();

    while (self.active_threads.load(.monotonic) > 0) {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    const allocator = self.app.allocator;
    self.drivers.deinit(allocator);
    self.handshakes.deinit(allocator);
    self.cdp_pool.deinit(allocator);
    allocator.free(self.json_version_response);
    allocator.free(self.bidi_session_url);
    allocator.free(self.pollfds);
    allocator.free(self.poll_snapshot);
    for (self.wakeup_pipe) |fd| {
        _ = std.c.close(fd);
    }
    if (self.listener >= 0) {
        // run() never ran (or never returned through its exit path).
        _ = std.c.close(self.listener);
    }
    allocator.destroy(self);
}

// Blocks the calling thread servicing the listener and the registered client
// read sockets until shutdown(). Page fetches run on per-worker HttpClient
// multis and telemetry on its own thread, so nothing here drives libcurl.
pub fn run(self: *Server) void {
    var drain_buf: [64]u8 = undefined;

    const wakeup_fd = &self.pollfds[0];
    const listen_fd = &self.pollfds[1];

    while (true) {
        self.preparePollFds();

        // wait until we get a client message or a signal on the wakeup pipe
        _ = posix.poll(self.pollfds, -1) catch |err| {
            log.err(.app, "poll", .{ .err = err });
            continue;
        };

        // check wakeup pipe
        if (wakeup_fd.revents != 0) {
            wakeup_fd.revents = 0;
            while (true)
                _ = posix.read(self.wakeup_pipe[0], &drain_buf) catch break;
        }

        // accept new connections
        if (listen_fd.revents != 0) {
            listen_fd.revents = 0;
            self.acceptConnections();
        }

        self.processLinks();

        if (self.shutting_down.load(.acquire)) {
            // Drain any live links so their workers can exit (issue #2510),
            // then stop. Existing connections are torn down by shutdown();
            // there is nothing else to flush here.
            self.shutdownLinks();
            break;
        }
    }

    if (self.listener >= 0) {
        sys_net.shutdown(self.listener, .both) catch |err| blk: {
            if (err == error.SocketNotConnected and builtin.os.tag != .linux) {
                // This error is normal/expected on BSD/MacOS. We probably
                // shouldn't bother calling shutdown at all, but I guess this
                // is safer.
                break :blk;
            }
            log.warn(.app, "listener shutdown", .{ .err = err });
        };
        _ = std.c.close(self.listener);
        self.listener = -1;
    }
}

fn wakeup(self: *Server) void {
    _ = sys_net.write(self.wakeup_pipe[1], &.{1}) catch {};
}

fn acceptConnections(self: *Server) void {
    if (self.shutting_down.load(.acquire)) {
        return;
    }
    if (self.listener < 0) {
        return;
    }

    while (true) {
        const socket = sys_net.accept(self.listener, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                error.SocketNotListening => {
                    self.pollfds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
                    _ = std.c.close(self.listener);
                    self.listener = -1;
                    return;
                },
                error.ConnectionAborted => {
                    log.warn(.app, "accept connection aborted", .{});
                    continue;
                },
                else => {
                    log.err(.app, "accept error", .{ .err = err });
                    continue;
                },
            }
        };

        configureSocket(socket) catch {
            _ = std.c.close(socket);
            continue;
        };

        self.spawnWorker(socket) catch |err| {
            log.err(.app, "CDP spawn", .{ .err = err });
            _ = std.c.close(socket);
        };
    }
}

// Hand a client WebSocket's read side over to the run loop. The caller owns
// the link and must keep it alive until unregisterLink is called. The
// caller must not read from the socket.
pub fn registerLink(self: *Server, link: *Link) void {
    self.link_mutex.lockUncancelable(lp.io);
    self.links.append(&link.node);
    self.links_dirty = true;
    self.link_mutex.unlock(lp.io);
    self.wakeup();
}

// Synchronous teardown. Blocks the caller until the run loop has dropped
// the link from its poll set and won't invoke any of the link's
// callbacks. Safe to call after the loop has already dropped the link
// unsolicited (state == .removed) — returns immediately in that case.
pub fn unregisterLink(self: *Server, link: *Link) void {
    self.link_mutex.lockUncancelable(lp.io);
    defer self.link_mutex.unlock(lp.io);
    if (link.state == .live) {
        link.state = .unregistering;
        self.links_dirty = true;
        self.wakeup();
    }

    while (link.state != .removed) {
        // condition variable, waiting for a signal
        self.link_removed.waitUncancelable(lp.io, &self.link_mutex);
    }
}

const DropLinkOpts = struct {
    // on_disconnect is fired iff `notify` is true. false when the worker already
    // knows the link is dead.
    notify: bool,

    // Set when we know the peer is dead. Can help unblock a blocked worker's send()
    shutdown_socket: bool = false,
};

// Drop a link from the poll set. Caller must hold link_mutex.
fn dropLink(self: *Server, link: *Link, err: ?anyerror, opts: DropLinkOpts) void {
    self.links.remove(&link.node);
    link.state = .removed;
    self.links_dirty = true;

    if (opts.shutdown_socket) {
        sys_net.shutdown(link.socket, .both) catch {};
    }

    if (opts.notify) {
        // notify=true means the worker hasn't been told yet — push the
        // disconnect into the inbox and break it out of curl_multi_poll.
        // notify=false paths have already woken the worker (close frame
        // case) or are about to be unblocked via link_removed.broadcast
        // (unregister case); no extra wakeup needed.
        link.driver.onLinkDisconnect(err);
        link.handles.wakeup() catch |e| {
            log.warn(.app, "client link wakeup", .{ .err = e });
        };
    }
}

// Build the link portion of pollfds and snapshot the matching *Link
// pointers so we can correlate revents after poll() returns. Called
// before poll, under link_mutex.
fn preparePollFds(self: *Server) void {
    self.link_mutex.lockUncancelable(lp.io);
    defer self.link_mutex.unlock(lp.io);

    // Idle fast-path: link set unchanged since last rebuild, so the
    // snapshot + pollfds entries from the previous iteration are still
    // correct. Kernel will overwrite `revents` in the next poll() call.
    if (!self.links_dirty) {
        return;
    }
    self.links_dirty = false;

    const link_pollfds = self.pollfds[PSEUDO_POLLFDS..];
    @memset(link_pollfds, .{ .fd = -1, .events = 0, .revents = 0 });

    var i: usize = 0;
    var it = self.links.first;
    while (it) |node| : (it = node.next) {
        lp.assert(i < self.poll_snapshot.len, "poll snapshot overflow", .{ .i = i, .len = self.poll_snapshot.len });
        const link: *Link = @fieldParentPtr("node", node);
        if (link.state != .live) {
            // Will be handled in processLinks; don't poll its fd.
            continue;
        }

        link_pollfds[i] = .{
            .fd = link.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        self.poll_snapshot[i] = link;
        i += 1;
    }
    self.poll_count = i;
}

// Per-iteration link handling: process pending unregistrations, then
// process revents on each polled link. Called after poll().
fn processLinks(self: *Server) void {
    var any_removed = false;

    self.link_mutex.lockUncancelable(lp.io);
    defer self.link_mutex.unlock(lp.io);

    // First pass: pending unregister requests.
    var it = self.links.first;
    while (it) |node| {
        const next = node.next;
        const link: *Link = @fieldParentPtr("node", node);
        if (link.state == .unregistering) {
            self.dropLink(link, null, .{ .notify = false });
            any_removed = true;
        }
        it = next;
    }

    // Second pass: revents on the snapshot. Skip links the first pass
    // (or a prior natural drop) has already removed.
    const link_pollfds = self.pollfds[PSEUDO_POLLFDS..];
    for (self.poll_snapshot[0..self.poll_count], 0..) |link_opt, i| {
        const link = link_opt orelse continue;
        if (link.state != .live) {
            continue;
        }
        const pfd = link_pollfds[i];
        if (pfd.revents == 0) {
            continue;
        }

        const fatal_events: i16 = comptime @intCast(posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
        if (pfd.revents & fatal_events != 0) {
            self.dropLink(link, null, .{ .notify = true, .shutdown_socket = true });
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
                log.warn(.app, "client read", .{ .err = err });
                self.dropLink(link, err, .{ .notify = true, .shutdown_socket = true });
                any_removed = true;
                continue;
            },
        };

        if (n == 0) {
            // peer EOF
            self.dropLink(link, null, .{ .notify = true, .shutdown_socket = true });
            any_removed = true;
            continue;
        }

        const keep = link.driver.onData(buf[0..n]) catch |err| {
            // Fatal frame/feed error. Whatever messages on_bytes
            // managed to push are still in the inbox; the failing
            // frame was NOT pushed, and the worker has no way to
            // know it should exit. Drop with notify=true so
            // on_disconnect surfaces a .disconnect into the inbox.
            // dropLink wakes the worker.
            log.info(.app, "client onData", .{ .err = err });
            self.dropLink(link, err, .{ .notify = true });
            any_removed = true;
            continue;
        };

        // on_bytes succeeded — wake the worker so it observes anything
        // new in the inbox (data / ping / close).
        link.handles.wakeup() catch |err| {
            log.warn(.app, "client link wakeup", .{ .err = err });
        };

        if (!keep) {
            // Close frame: the handler already pushed .close. Worker's
            // drainInbox will call on_disconnect itself after replying,
            // so we drop without re-notifying.
            self.dropLink(link, null, .{ .notify = false });
            any_removed = true;
        }
    }

    if (any_removed) {
        self.link_removed.broadcast(lp.io);
    }
}

// On shutdown, force-disconnect every still-live link. Each link's
// worker thread blocks in curl_multi_poll and is woken ONLY by this
// thread via dropLink -> handles.wakeup(). If the run loop exits with
// links still live, those workers never wake and deinit() spins on
// active_threads forever (issue #2510). Mirrors the peer-EOF path in
// processLinks: dropLink(notify=true) pushes a .disconnect into the
// worker's inbox and wakes it, so cdp.tick() returns false and the
// worker exits.
fn shutdownLinks(self: *Server) void {
    self.link_mutex.lockUncancelable(lp.io);
    defer self.link_mutex.unlock(lp.io);

    var it = self.links.first;
    while (it) |node| {
        it = node.next;
        const link: *Link = @fieldParentPtr("node", node);
        if (link.state == .live) {
            self.dropLink(link, null, .{ .notify = true });
        }
    }

    self.link_removed.broadcast(lp.io);
}

// Liveness is enforced at the TCP layer via keepalive probes sent by the
// kernel. This is transparent to CDP clients — unlike a WebSocket ping, which
// go-rod panics on and chromedp logs as "malformed". Tunables in Config.zig.
fn configureSocket(socket: posix.socket_t) !void {
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
        log.warn(.app, "SO_KEEPALIVE", .{ .err = err });
        return err;
    };

    const idle_opt = switch (builtin.os.tag) {
        .macos, .ios => posix.TCP.KEEPALIVE,
        else => posix.TCP.KEEPIDLE,
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, idle_opt, &std.mem.toBytes(Config.CDP_KEEPALIVE_IDLE_S)) catch |err| {
        log.warn(.app, "TCP_KEEPIDLE", .{ .err = err });
        return err;
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(Config.CDP_KEEPALIVE_INTVL_S)) catch |err| {
        log.warn(.app, "TCP_KEEPINTVL", .{ .err = err });
        return err;
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(Config.CDP_KEEPALIVE_CNT)) catch |err| {
        log.warn(.app, "TCP_KEEPCNT", .{ .err = err });
        return err;
    };

    if (builtin.os.tag == .linux) {
        posix.setsockopt(socket, posix.IPPROTO.TCP, std.os.linux.TCP.USER_TIMEOUT, &std.mem.toBytes(Config.CDP_TCP_USER_TIMEOUT_MS)) catch |err| {
            log.warn(.app, "TCP_USER_TIMEOUT", .{ .err = err });
            return err;
        };
    }
}

fn spawnWorker(self: *Server, socket: posix.socket_t) !void {
    if (self.shutting_down.load(.acquire)) {
        return error.ShuttingDown;
    }

    // Atomically increment active_conns only if below max_connections.
    // Uses CAS loop to avoid race between checking the limit and incrementing.
    //
    // cmpxchgWeak may fail for two reasons:
    // 1. Another thread changed the value (increment or decrement)
    // 2. Spurious failure on some architectures (e.g. ARM)
    //
    // We use Weak instead of Strong because we need a retry loop anyway:
    // if CAS fails because a conn slot was freed (counter decreased), we should
    // retry rather than return an error - there may now be room for a new connection.
    //
    // On failure, cmpxchgWeak returns the actual value, which we reuse to avoid
    // an extra load on the next iteration.
    var current = self.active_conns.load(.monotonic);
    while (current < self.max_connections) {
        current = self.active_conns.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse break;
    } else {
        lp.metrics.serve_connection_limit.incr();
        return error.MaxConnectionsReached;
    }
    errdefer _ = self.active_conns.fetchSub(1, .monotonic);

    _ = self.active_threads.fetchAdd(1, .monotonic);
    errdefer _ = self.active_threads.fetchSub(1, .monotonic);

    const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, socket });
    thread.detach();
}

fn handleConnection(self: *Server, socket: posix.socket_t) void {
    var active_conns_early_release = false;
    defer {
        if (!active_conns_early_release) {
            _ = self.active_conns.fetchSub(1, .monotonic);
        }
    }
    defer _ = self.active_threads.fetchSub(1, .monotonic);
    defer _ = std.c.close(socket);

    const route = self.handshake(socket) orelse return;
    switch (route) {
        .cdp => self.serveCDP(socket, &active_conns_early_release),
        .bidi => |session_id| self.serveBiDi(socket, session_id, &active_conns_early_release),
    }
}

fn handshake(self: *Server, socket: posix.socket_t) ?Handshake.Route {
    {
        self.driver_mutex.lockUncancelable(lp.io);
        defer self.driver_mutex.unlock(lp.io);
        self.handshakes.append(self.app.allocator, socket) catch return null;
    }
    defer {
        self.driver_mutex.lockUncancelable(lp.io);
        defer self.driver_mutex.unlock(lp.io);
        for (self.handshakes.items, 0..) |s, i| {
            if (s == socket) {
                _ = self.handshakes.swapRemove(i);
                break;
            }
        }
    }
    return Handshake.run(self.app, socket, &.{
        .protocols = self.protocols,
        .json_version_response = self.json_version_response,
        .bidi_session_url = self.bidi_session_url,
    });
}

// The socket is an upgraded websocket speaking CDP.
fn serveCDP(self: *Server, socket: posix.socket_t, active_conns_early_release: *bool) void {
    const cdp = blk: {
        const allocator = self.app.allocator;
        self.driver_mutex.lockUncancelable(lp.io);
        defer self.driver_mutex.unlock(lp.io);
        break :blk self.cdp_pool.create(allocator) catch @panic("OOM");
    };
    defer {
        self.driver_mutex.lockUncancelable(lp.io);
        defer self.driver_mutex.unlock(lp.io);
        self.cdp_pool.destroy(cdp);
    }

    cdp.init(self.app, socket) catch |err| {
        log.err(.app, "CDP init", .{ .err = err });
        return;
    };
    defer cdp.deinit();

    lp.metrics.serve_connections.incr(.cdp);
    lp.metrics.serve_active_connections.incr(.cdp);
    defer lp.metrics.serve_active_connections.decr(.cdp);

    self.serve(.init(.{ .cdp = cdp }), active_conns_early_release);
}

// The socket is an upgraded websocket speaking WebDriver BiDi. session_id is
// set when the client came through a classic POST /session, which already
// created the session it's about to use.
fn serveBiDi(self: *Server, socket: posix.socket_t, session_id: ?[36]u8, active_conns_early_release: *bool) void {
    const allocator = self.app.allocator;

    // heap-allocated: BiDi embeds a Browser
    const bidi = allocator.create(BiDi) catch @panic("OOM");
    defer allocator.destroy(bidi);

    bidi.init(self.app, socket, session_id) catch |err| {
        log.err(.app, "BiDi init", .{ .err = err });
        return;
    };
    defer bidi.deinit();

    lp.metrics.serve_connections.incr(.bidi);
    lp.metrics.serve_active_connections.incr(.bidi);
    defer lp.metrics.serve_active_connections.decr(.bidi);

    self.serve(.init(.{ .bidi = bidi }), active_conns_early_release);
}

// Everything a live connection needs regardless of which protocol it
// speaks: tracking (so shutdown can reach it), handing the read side to
// the run loop, and running the worker loop.
fn serve(self: *Server, driver: Driver, active_conns_early_release: *bool) void {
    const conn = driver.conn;

    if (log.enabled(.app, .info)) {
        const client_address = getClientAddress(conn.socket) catch null;
        log.info(.app, "client connected", .{ .ip = client_address });
    }

    self.track(driver);
    defer self.untrack(driver);

    {
        // Transition from .starting state to .live
        // Lock needed even though the main thread hasn't seen this yet because
        // shutdown could access this from the sighandler thread.
        self.driver_mutex.lockUncancelable(lp.io);
        defer self.driver_mutex.unlock(lp.io);
        conn.state = .live;
    }

    // Hand the read side of the socket over to the run loop.
    // From here until the matching unregisterLink, the worker must NOT
    // read from the socket directly — bytes arrive via the inbox.
    // unregisterLink is synchronous, so by the time it returns the loop
    // is guaranteed to be done with this link.
    //
    // driver_link_active gates HttpClient.perform's block in
    // curl_multi_poll: with it false (tests, pre-handshake), perform
    // skips the poll when there's no in-flight curl work — sleeping
    // would just eat the timeout waiting for a wakeup that won't
    // come. We set it true *after* registerLink so the loop is already
    // accepting wakeups by the time the worker might poll, and clear
    // it *after* unregisterLink returns (the loop is guaranteed done
    // with us by then).
    self.registerLink(driver.link);
    driver.browser.http_client.driver_link_active = true;
    defer {
        self.unregisterLink(driver.link);
        driver.browser.http_client.driver_link_active = false;
    }

    // Check shutdown after markLive so that a concurrent shutdown either
    // sees us as .live and terminates us, or we observe the stop signal
    // here. Otherwise we could miss it and block deinit() indefinitely.
    if (self.shutting_down.load(.acquire)) {
        return;
    }

    driver.run();

    // Try to release the connection as soon as possible: the browser/V8
    // teardown in our callers' defers can take milliseconds, and a client
    // that disconnects and immediately reconnects shouldn't be rejected
    // for a slot we're merely unwinding.
    active_conns_early_release.* = true;
    _ = self.active_conns.fetchSub(1, .monotonic);
}

fn track(self: *Server, driver: Driver) void {
    self.driver_mutex.lockUncancelable(lp.io);
    defer self.driver_mutex.unlock(lp.io);
    self.drivers.append(self.app.allocator, driver) catch {};
}

fn untrack(self: *Server, driver: Driver) void {
    self.driver_mutex.lockUncancelable(lp.io);
    defer self.driver_mutex.unlock(lp.io);

    for (self.drivers.items, 0..) |*d, i| {
        if (d.conn == driver.conn) {
            _ = self.drivers.swapRemove(i);
            break;
        }
    }
}

fn getClientAddress(socket: posix.socket_t) !sys_net.IpAddress {
    var storage: posix.sockaddr.storage = undefined;
    var socklen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getpeername(socket, @ptrCast(&storage), &socklen);
    return sys_net.addressFromSockaddr(@ptrCast(&storage));
}

// The pointed-to driver is owned by its worker thread
fn buildJSONVersionResponse(app: *const App, port: u16) ![]const u8 {
    const host = app.config.advertiseHost();
    if (app.config.bindIsWildcard()) {
        // Serve is bound to INADDR_ANY but no --advertise-host was given;
        // advertiseHost() falls back to 127.0.0.1 so clients can still
        // connect locally. Surface the trade-off so users running
        // outside the same host know they have to opt in.
        log.note(.cdp, "advertising loopback for wildcard bind", .{
            .message = "--host is a wildcard (0.0.0.0 / ::) without --advertise-host; clients on other hosts will need --advertise-host to reach the CDP endpoint",
        });
    }
    const body_format =
        "{{" ++
        "\"Browser\": \"Lightpanda/1.0\", " ++
        "\"Protocol-Version\": \"1.3\", " ++
        "\"User-Agent\": \"Lightpanda/1.0\", " ++
        "\"Lightpanda-Version\": \"" ++ lp.build_config.version ++ "\", " ++
        "\"webSocketDebuggerUrl\": \"ws://{s}:{d}/\"" ++
        "}}";
    const body_len = std.fmt.count(body_format, .{ host, port });

    // We send a Connection: Close (and actually close the connection)
    // because chromedp (Go driver) sends a request to /json/version and then
    // does an upgrade request, on a different connection. Since we only allow
    // 1 connection at a time, the upgrade connection doesn't proceed until we
    // timeout the /json/version. So, instead of waiting for that, we just
    // always close HTTP requests.
    const response_format =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        body_format;
    return try std.fmt.allocPrint(app.allocator, response_format, .{ body_len, host, port });
}

const testing = @import("../testing.zig");
test "server: buildJSONVersionResponse" {
    const res = try buildJSONVersionResponse(testing.test_app, testing.test_app.config.port());
    defer testing.test_app.allocator.free(res);

    // The response includes the build version, so check structure rather than exact bytes.
    try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, res, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, res, "Connection: Close") != null);

    // Verify all required JSON fields are present in the body
    try testing.expect(std.mem.indexOf(u8, res, "\"Browser\": \"Lightpanda/") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"Protocol-Version\": \"1.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"User-Agent\": \"Lightpanda/") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"Lightpanda-Version\": \"" ++ lp.build_config.version ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9222/\"") != null);
}

test "Client: http invalid request" {
    testing.silenceLog(&.{.cdp});

    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /over/9000 HTTP/1.1\r\n" ++ "Header: " ++ ("a" ** 4100) ++ "\r\n\r\n");
    try testing.expectEqual("HTTP/1.1 413 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 17\r\n\r\n" ++
        "Request too large", res);
}

test "Client: http invalid handshake" {
    try assertHTTPError(
        400,
        "Invalid request",
        "\r\n\r\n",
    );

    try assertHTTPError(
        404,
        "Not found",
        "GET /over/9000 HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        404,
        "Not found",
        "POST / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Invalid HTTP protocol",
        "GET / HTTP/1.0\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n",
    );
}

test "Client: http handshake origin" {
    testing.silenceLog(&.{.cdp});

    const with_origin =
        "GET / HTTP/1.1\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "sec-websocket-version:13\r\n" ++
        "sec-websocket-key: this is my key\r\n" ++
        "Origin: {s}\r\n\r\n";

    for ([_][]const u8{
        "https://evil.com",
        // Being served from loopback yourself doesn't make you trusted.
        "http://127.0.0.1:8080",
        "http://localhost:8080",
        // Sandboxed iframes and data: URLs.
        "null",
    }) |origin| {
        var c = try createTestClient();
        defer c.deinit();

        var buf: [256]u8 = undefined;
        const res = try c.httpRequest(try std.fmt.bufPrint(&buf, with_origin, .{origin}));
        try testing.expectEqual("HTTP/1.1 403 \r\n" ++
            "Connection: Close\r\n" ++
            "Content-Length: 18\r\n\r\n" ++
            "Origin not allowed", res);
    }

    // The first one is enough; we never get far enough to see the second.
    try assertHTTPError(
        403,
        "Origin not allowed",
        "GET / HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "sec-websocket-version:13\r\n" ++
            "sec-websocket-key: this is my key\r\n" ++
            "Origin: https://evil.com\r\n" ++
            "Origin: https://evil.com\r\n\r\n",
    );
}

test "Client: http handshake host" {
    testing.silenceLog(&.{.cdp});

    // Any name in Host means something resolved to us that shouldn't
    // have (rebinding); only an IP literal gets through.
    const with_host =
        "GET / HTTP/1.1\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "sec-websocket-version:13\r\n" ++
        "sec-websocket-key: this is my key\r\n" ++
        "Host: {s}\r\n\r\n";

    for ([_][]const u8{
        "rebind.evil.com:9583",
        // Only the exact `localhost:<port>` form is allowed.
        "localhost",
        "LOCALHOST:9583",
        "localhost.evil.com:9583",
    }) |host| {
        var buf: [256]u8 = undefined;
        try assertHTTPError(
            403,
            "Host not allowed",
            try std.fmt.bufPrint(&buf, with_host, .{host}),
        );
    }

    // `localhost:<port>` is hardwired to loopback by browsers, no DNS
    // lookup involved, so it gets through like an IP literal.
    {
        var c = try createTestClient();
        defer c.deinit();
        var buf: [256]u8 = undefined;
        const res = try c.httpRequest(try std.fmt.bufPrint(&buf, with_host, .{"localhost:9583"}));
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 101 Switching Protocols\r\n"));
    }
}

test "Client: http valid handshake" {
    var c = try createTestClient();
    defer c.deinit();

    // No Origin (i.e. not a browser) and a Host we're reachable at: what
    // every CDP driver sends.
    const request =
        "GET /   HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:9583\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "sec-websocket-version:13\r\n" ++
        "sec-websocket-key: this is my key\r\n" ++
        "Custom:  Header-Value\r\n\r\n";

    const res = try c.httpRequest(request);
    try testing.expectEqual("HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: upgrade\r\n" ++
        "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n", res);
}

test "Client: read invalid websocket message" {
    // 131 = 128 (fin) | 3  where 3 isn't a valid type
    try assertWebSocketError(
        1002,
        &.{ 131, 128, 'm', 'a', 's', 'k' },
    );

    for ([_]u8{ 16, 32, 64 }) |rsv| {
        // none of the reserve flags should be set
        try assertWebSocketError(
            1002,
            &.{ rsv, 128, 'm', 'a', 's', 'k' },
        );

        // as a bitmask
        try assertWebSocketError(
            1002,
            &.{ rsv + 4, 128, 'm', 'a', 's', 'k' },
        );
    }

    // client->server messages must be masked
    try assertWebSocketError(
        1002,
        &.{ 129, 1, 'a' },
    );

    // control types (ping/ping/close) can't be > 125 bytes
    for ([_]u8{ 136, 137, 138 }) |op| {
        try assertWebSocketError(
            1002,
            &.{ op, 254, 1, 1 },
        );
    }

    {
        testing.expectLog(&.{.cdp});
        // length of message is 0, 0, 0, 0, 0, 16, 0, 1 i.e: 1024 * 1024 + 1
        try assertWebSocketError(1009, &.{ 129, 255, 0, 0, 0, 0, 0, 16, 0, 1, 'm', 'a', 's', 'k' });
    }

    // continuation type message must come after a normal message
    // even when not a fin frame
    try assertWebSocketError(
        1002,
        &.{ 0, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // continuation type message must come after a normal message
    // even as a fin frame
    try assertWebSocketError(
        1002,
        &.{ 128, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // text (non-fin) - text (non-fin)
    try assertWebSocketError(
        1002,
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 1, 128, 'k', 's', 'a', 'm' },
    );

    // text (non-fin) - text (fin) should always been continuation after non-fin
    try assertWebSocketError(
        1002,
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 129, 128, 'k', 's', 'a', 'm' },
    );

    // close must be fin
    try assertWebSocketError(
        1002,
        &.{
            8, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // ping must be fin
    try assertWebSocketError(
        1002,
        &.{
            9, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // pong must be fin
    try assertWebSocketError(
        1002,
        &.{
            10, 129, 'm', 'a', 's', 'k', 'd',
        },
    );
}

test "Client: ping reply" {
    try assertWebSocketMessage(
        // fin | pong, len
        &.{ 138, 0 },

        // fin | ping, masked | len, 4-byte mask
        &.{ 137, 128, 0, 0, 0, 0 },
    );

    try assertWebSocketMessage(
        // fin | pong, len, payload
        &.{ 138, 5, 100, 96, 97, 109, 104 },

        // fin | ping, masked | len, 4-byte mask, 5 byte payload
        &.{ 137, 133, 0, 5, 7, 10, 100, 101, 102, 103, 104 },
    );
}

test "Client: close message" {
    try assertWebSocketMessage(
        // fin | close, len, close code (normal)
        &.{ 136, 2, 3, 232 },

        // fin | close, masked | len, 4-byte mask
        &.{ 136, 128, 0, 0, 0, 0 },
    );
}

test "server: bidi session lifecycle" {
    var c = try createTestClient();
    defer c.deinit();
    try c.handshake("/session");

    try c.bidiCommand("{\"id\":1,\"method\":\"session.status\"}");
    try assertBidiMessage(&c, .{ .type = "success", .id = 1, .result = .{ .ready = true, .message = "" } });

    // capture the sessionId from session.new by hand — it's random
    try c.bidiCommand("{\"id\":2,\"method\":\"session.new\",\"params\":{\"capabilities\":{}}}");
    {
        const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
        defer if (msg.cleanup_fragment) c.reader.cleanup();

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg.data, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        try testing.expectEqual("success", obj.get("type").?.string);
        try testing.expectEqual(2, obj.get("id").?.integer);

        const result = obj.get("result").?.object;
        try testing.expectEqual(36, result.get("sessionId").?.string.len);

        const capabilities = result.get("capabilities").?.object;
        try testing.expectEqual("Lightpanda", capabilities.get("browserName").?.string);
        try testing.expectEqual(lp.build_config.version, capabilities.get("browserVersion").?.string);
        try testing.expectEqual(false, capabilities.get("acceptInsecureCerts").?.bool);
    }

    try c.bidiCommand("{\"id\":3,\"method\":\"session.status\"}");
    try assertBidiMessage(&c, .{ .type = "success", .id = 3, .result = .{ .ready = false, .message = "session already started" } });

    try c.bidiCommand("{\"id\":4,\"method\":\"session.new\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 4, .@"error" = "session not created", .message = "session already exists" });

    try c.bidiCommand("{\"id\":5,\"method\":\"session.subscribe\",\"params\":{\"events\":[\"log.entryAdded\"]}}");
    {
        // the subscription id is random
        const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
        defer if (msg.cleanup_fragment) c.reader.cleanup();

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg.data, .{});
        defer parsed.deinit();
        try testing.expectEqual("success", parsed.value.object.get("type").?.string);
        try testing.expectEqual(36, parsed.value.object.get("result").?.object.get("subscription").?.string.len);
    }

    try c.bidiCommand("{\"id\":6,\"method\":\"session.unsubscribe\",\"params\":{\"events\":[\"log.entryAdded\"]}}");
    // an empty result must serialize as {}, not [] — struct {}{} on the
    // expected side asserts the object-ness
    try assertBidiMessage(&c, .{ .type = "success", .id = 6, .result = struct {}{} });

    try c.bidiCommand("{\"id\":7,\"method\":\"session.end\"}");
    try assertBidiMessage(&c, .{ .type = "success", .id = 7, .result = struct {}{} });

    // ending the session closes the connection
    {
        const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
        defer if (msg.cleanup_fragment) c.reader.cleanup();
        try testing.expectEqual(.close, msg.type);
    }
}

test "server: bidi errors" {
    var c = try createTestClient();
    defer c.deinit();
    try c.handshake("/session");

    try c.bidiCommand("this is not json");
    try assertBidiMessage(&c, .{ .type = "error", .id = null, .@"error" = "invalid argument", .message = "invalid JSON message" });

    try c.bidiCommand("{\"method\":\"session.status\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = null, .@"error" = "invalid argument", .message = "missing command id" });

    try c.bidiCommand("{\"id\":1}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 1, .@"error" = "invalid argument", .message = "missing command method" });

    try c.bidiCommand("{\"id\":2,\"method\":\"browsingContext.getTree\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 2, .@"error" = "invalid session id", .message = "no active session" });

    // session-scoped commands before session.new
    try c.bidiCommand("{\"id\":3,\"method\":\"session.subscribe\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 3, .@"error" = "invalid session id", .message = "no active session" });

    try c.bidiCommand("{\"id\":4,\"method\":\"session.end\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 4, .@"error" = "invalid session id", .message = "no active session" });

    // an unknown command is reported as such even before session.new; only
    // known commands in known modules reach the session gate
    try c.bidiCommand("{\"id\":5,\"method\":\"session.over9000\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 5, .@"error" = "unknown command", .message = "session.over9000" });

    try c.bidiCommand("{\"id\":6,\"method\":\"storage.getCookies\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 6, .@"error" = "unknown command", .message = "storage.getCookies" });

    try c.bidiCommand("{\"id\":7,\"method\":\"nodothere\"}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 7, .@"error" = "unknown command", .message = "nodothere" });
}

test "server: bidi browsingContext" {
    testing.silenceLog(&.{.not_implemented});

    var c = try createTestClient();
    defer c.deinit();
    try c.handshake("/session");

    try c.bidiCommand("{\"id\":1,\"method\":\"session.new\",\"params\":{\"capabilities\":{}}}");
    try discardBidiMessage(&c); // response shape covered by the lifecycle test

    var context_id: [36]u8 = undefined;
    try c.bidiCommand("{\"id\":2,\"method\":\"browsingContext.create\",\"params\":{\"type\":\"tab\"}}");
    {
        const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
        defer if (msg.cleanup_fragment) c.reader.cleanup();

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg.data, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual("success", obj.get("type").?.string);
        const context = obj.get("result").?.object.get("context").?.string;
        try testing.expectEqual(36, context.len);
        @memcpy(&context_id, context);
    }

    try c.bidiCommand("{\"id\":3,\"method\":\"browsingContext.getTree\"}");
    try assertBidiMessage(&c, .{ .type = "success", .id = 3, .result = .{ .contexts = .{.{
        .context = &context_id,
        .url = "about:blank",
        .userContext = "default",
        .originalOpener = null,
        .children = .{},
    }} } });

    try c.bidiCommand("{\"id\":4,\"method\":\"session.subscribe\",\"params\":{\"events\":[\"browsingContext.domContentLoaded\",\"browsingContext.load\"]}}");
    try discardBidiMessage(&c);

    const url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom2.html";
    var buf: [256]u8 = undefined;
    try c.bidiCommand(try std.fmt.bufPrint(
        &buf,
        "{{\"id\":5,\"method\":\"browsingContext.navigate\",\"params\":{{\"context\":\"{s}\",\"url\":\"" ++ url ++ "\",\"wait\":\"complete\"}}}}",
        .{&context_id},
    ));
    try assertBidiEvent(&c, "browsingContext.domContentLoaded", &context_id, url);
    try assertBidiEvent(&c, "browsingContext.load", &context_id, url);
    {
        const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
        defer if (msg.cleanup_fragment) c.reader.cleanup();

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg.data, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual("success", obj.get("type").?.string);
        try testing.expectEqual(5, obj.get("id").?.integer);
        const result = obj.get("result").?.object;
        try testing.expectEqual(url, result.get("url").?.string);
        try testing.expectEqual(36, result.get("navigation").?.string.len);
    }

    try c.bidiCommand("{\"id\":6,\"method\":\"browsingContext.navigate\",\"params\":{\"context\":\"00000000-0000-0000-0000-000000000000\",\"url\":\"about:blank\"}}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 6, .@"error" = "no such frame", .message = "unknown context" });

    try c.bidiCommand("{\"id\":7,\"method\":\"browsingContext.create\",\"params\":{\"type\":\"tab\"}}");
    try assertBidiMessage(&c, .{ .type = "error", .id = 7, .@"error" = "unsupported operation" });

    try c.bidiCommand(try std.fmt.bufPrint(
        &buf,
        "{{\"id\":8,\"method\":\"browsingContext.close\",\"params\":{{\"context\":\"{s}\"}}}}",
        .{&context_id},
    ));
    try assertBidiMessage(&c, .{ .type = "success", .id = 8, .result = struct {}{} });

    try c.bidiCommand("{\"id\":9,\"method\":\"browsingContext.getTree\"}");
    try assertBidiMessage(&c, .{ .type = "success", .id = 9, .result = .{ .contexts = .{} } });
}

fn discardBidiMessage(c: *TestClient) !void {
    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    if (msg.cleanup_fragment) {
        c.reader.cleanup();
    }
}

fn assertBidiEvent(c: *TestClient, method: []const u8, context: []const u8, url: []const u8) !void {
    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg.data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual("event", obj.get("type").?.string);
    try testing.expectEqual(method, obj.get("method").?.string);

    const p = obj.get("params").?.object;
    try testing.expectEqual(context, p.get("context").?.string);
    try testing.expectEqual(url, p.get("url").?.string);
    try testing.expectEqual(36, p.get("navigation").?.string.len);
}

fn assertBidiMessage(c: *TestClient, expected: anytype) !void {
    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    try testing.expectEqual(.text, msg.type);
    try testing.expectJson(expected, msg.data);
}

test "server: 404" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /unknown HTTP/1.1\r\n\r\n");
    try testing.expectEqual("HTTP/1.1 404 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 9\r\n\r\n" ++
        "Not found", res);
}

test "server: classic session bootstrap" {
    // What Selenium does before it speaks BiDi: a classic POST /session
    // that hands back the websocket URL, then a DELETE on quit.
    const session_id = blk: {
        var c = try createTestClient();
        defer c.deinit();

        const body = "{\"capabilities\":{\"firstMatch\":[{}],\"alwaysMatch\":{\"browserName\":\"firefox\",\"webSocketUrl\":true}}}";
        const res = try c.httpRequest(std.fmt.comptimePrint("POST /session HTTP/1.1\r\n" ++
            "Content-Type: application/json;charset=UTF-8\r\n" ++
            "Content-Length: {d}\r\n\r\n" ++
            "{s}", .{ body.len, body }));
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, res, "\r\nConnection: Close\r\n") != null);

        const json = res[std.mem.indexOf(u8, res, "\r\n\r\n").? + 4 ..];
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();

        const value = parsed.value.object.get("value").?.object;
        const id = value.get("sessionId").?.string;
        try testing.expectEqual(36, id.len);

        const capabilities = value.get("capabilities").?.object;
        try testing.expectEqual("Lightpanda", capabilities.get("browserName").?.string);
        try testing.expectEqual(false, capabilities.get("acceptInsecureCerts").?.bool);
        const ws_url = capabilities.get("webSocketUrl").?.string;
        try testing.expectEqual("ws://127.0.0.1:9583/session/", ws_url[0 .. ws_url.len - 36]);
        try testing.expectEqual(id, ws_url[ws_url.len - 36 ..]);

        break :blk id[0..36].*;
    };

    {
        // The session already exists on the advertised URL: no session.new
        // needed (or possible), everything else works as usual.
        var c = try createTestClient();
        defer c.deinit();
        var path_buf: [64]u8 = undefined;
        try c.handshake(try std.fmt.bufPrint(&path_buf, "/session/{s}", .{&session_id}));

        try c.bidiCommand("{\"id\":1,\"method\":\"session.status\"}");
        try assertBidiMessage(&c, .{ .type = "success", .id = 1, .result = .{ .ready = false, .message = "session already started" } });

        try c.bidiCommand("{\"id\":2,\"method\":\"session.new\",\"params\":{\"capabilities\":{}}}");
        try assertBidiMessage(&c, .{ .type = "error", .id = 2, .@"error" = "session not created", .message = "session already exists" });

        try c.bidiCommand("{\"id\":3,\"method\":\"browsingContext.getTree\"}");
        try assertBidiMessage(&c, .{ .type = "success", .id = 3, .result = .{ .contexts = .{} } });
    }

    {
        var c = try createTestClient();
        defer c.deinit();
        var request_buf: [128]u8 = undefined;
        const res = try c.httpRequest(try std.fmt.bufPrint(&request_buf, "DELETE /session/{s} HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .{&session_id}));
        try testing.expectEqual("HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 14\r\n" ++
            "Connection: Close\r\n" ++
            "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
            "{\"value\":null}", res);
    }
}

test "server: classic session bootstrap errors" {
    {
        // the body can arrive after the headers
        var c = try createTestClient();
        defer c.deinit();
        const body = "{\"capabilities\":{\"alwaysMatch\":{\"browserName\":\"firefox\"}}}";
        try sys_net.writeAll(c.socket, std.fmt.comptimePrint("POST /session HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{body.len}));
        lp.io.sleep(.fromMilliseconds(20), .awake) catch {};
        const res = try c.httpRequest(body);
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 500 Internal Server Error\r\n"));
        try testing.expect(std.mem.endsWith(u8, res, "{\"value\":{\"error\":\"session not created\",\"message\":\"only WebDriver BiDi sessions are supported; request the webSocketUrl capability\",\"stacktrace\":\"\"}}"));
    }

    {
        var c = try createTestClient();
        defer c.deinit();
        const res = try c.httpRequest("POST /session HTTP/1.1\r\nContent-Length: 8\r\n\r\nnot json");
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 400 Bad Request\r\n"));
        try testing.expect(std.mem.endsWith(u8, res, "{\"value\":{\"error\":\"invalid argument\",\"message\":\"invalid JSON body\",\"stacktrace\":\"\"}}"));
    }

    try assertHTTPError(404, "Not found", "POST /session/abc HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    try assertHTTPError(404, "Not found", "DELETE /session HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    // a websocket upgrade on /session/<id> needs a real session id
    try assertHTTPError(404, "Not found", "GET /session/abc HTTP/1.1\r\n\r\n");
}

test "server: protocol gate" {
    // The test server serves both; --protocol picks which a real server does.
    const protocols = &testing.test_cdp_server.?.protocols;
    defer protocols.* = .{ .cdp = true, .webdriver = true };

    protocols.* = .{ .cdp = true };
    try assertHTTPError(404, "Not found", "GET /status HTTP/1.1\r\n\r\n");
    try assertHTTPError(404, "Not found", "POST /session HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
    try assertHTTPError(404, "Not found", "DELETE /session/x HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    try assertHTTPError(404, "Not found", "GET /session HTTP/1.1\r\n" ++
        "Connection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: k\r\n\r\n");
    {
        var c = try createTestClient();
        defer c.deinit();
        const res = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    }

    protocols.* = .{ .webdriver = true };
    try assertHTTPError(404, "Not found", "GET /json/version HTTP/1.1\r\n\r\n");
    try assertHTTPError(404, "Not found", "GET /json/list HTTP/1.1\r\n\r\n");
    try assertHTTPError(404, "Not found", "GET / HTTP/1.1\r\n" ++
        "Connection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: k\r\n\r\n");
    {
        var c = try createTestClient();
        defer c.deinit();
        const res = try c.httpRequest("GET /status HTTP/1.1\r\n\r\n");
        try testing.expectEqual("HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 37\r\n" ++
            "Connection: Close\r\n" ++
            "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
            "{\"value\":{\"ready\":true,\"message\":\"\"}}", res);
    }
    {
        // /metrics is protocol-neutral
        var c = try createTestClient();
        defer c.deinit();
        const res = try c.httpRequestAlloc("GET /metrics HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    }
}

test "server: get /json/version" {
    {
        // twice on the same connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res1, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, res1, "\"Browser\": \"Lightpanda/") != null);
        try testing.expect(std.mem.indexOf(u8, res1, "\"Protocol-Version\": \"1.3\"") != null);
        try testing.expect(std.mem.indexOf(u8, res1, "\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9583/\"") != null);
    }

    {
        // again on a new connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res1, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, res1, "\"Browser\": \"Lightpanda/") != null);
    }
}

test "server: get /json/protocol" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequestAlloc("GET /json/protocol HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, res, "Content-Type: application/json") != null);

    const body_start = std.mem.indexOf(u8, res, "\r\n\r\n").? + 4;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res[body_start..], .{});
    defer parsed.deinit();

    const domains = parsed.value.object.get("domains").?.array;
    try testing.expectEqual(21, domains.items.len);

    var found_dom = false;
    var found_lp = false;
    for (domains.items) |domain| {
        const name = domain.object.get("domain").?.string;
        if (std.mem.eql(u8, name, "DOM")) found_dom = true;
        if (std.mem.eql(u8, name, "LP")) found_lp = true;
    }
    try testing.expect(found_dom);
    try testing.expect(found_lp);
}

test "server: get /metrics" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /metrics HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, res, "Content-Type: text/plain; version=0.0.4") != null);
    try testing.expect(std.mem.indexOf(u8, res, "build_info{version=") != null);
    try testing.expect(std.mem.indexOf(u8, res, "# TYPE serve_connections_total counter") != null);
}

fn assertHTTPError(
    comptime expected_status: u16,
    comptime expected_body: []const u8,
    input: []const u8,
) !void {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest(input);
    const expected_response = std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ expected_status, expected_body.len, expected_body },
    );

    try testing.expectEqual(expected_response, res);
}

fn assertWebSocketError(close_code: u16, input: []const u8) !void {
    var c = try createTestClient();
    defer c.deinit();

    try c.handshake("/");
    try sys_net.writeAll(c.socket, input);

    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    try testing.expectEqual(.close, msg.type);
    try testing.expectEqual(2, msg.data.len);
    try testing.expectEqual(close_code, std.mem.readInt(u16, msg.data[0..2], .big));
}

fn assertWebSocketMessage(expected: []const u8, input: []const u8) !void {
    var c = try createTestClient();
    defer c.deinit();

    try c.handshake("/");
    try sys_net.writeAll(c.socket, input);

    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    const actual = c.reader.buf[0 .. msg.data.len + 2];
    try testing.expectEqualSlices(u8, expected, actual);
}

const MockCDP = struct {
    messages: std.ArrayList([]const u8) = .empty,

    allocator: Allocator = testing.allocator,

    fn init(_: Allocator, client: anytype) MockCDP {
        _ = client;
        return .{};
    }

    fn deinit(self: *MockCDP) void {
        const allocator = self.allocator;
        for (self.messages.items) |msg| {
            allocator.free(msg);
        }
        self.messages.deinit(allocator);
    }

    fn handleMessage(self: *MockCDP, message: []const u8) bool {
        const owned = self.allocator.dupe(u8, message) catch unreachable;
        self.messages.append(self.allocator, owned) catch unreachable;
        return true;
    }
};

fn createTestClient() !TestClient {
    const address: sys_net.IpAddress = .{ .ip4 = .loopback(9583) };
    const socket = try sys_net.connect(&address);

    const timeout = std.mem.toBytes(posix.timeval{
        .sec = 10,
        .usec = 0,
    });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    return .{
        .socket = socket,
        .reader = .{
            .max_message_size = 1024,
            .allocator = testing.allocator,
            .buf = try testing.allocator.alloc(u8, 1024 * 16),
        },
    };
}

const TestClient = struct {
    socket: posix.socket_t,
    buf: [8192]u8 = undefined,
    reader: WS.Reader(false),

    const WS = @import("../network/WS.zig");

    fn deinit(self: *TestClient) void {
        _ = std.c.close(self.socket);
        self.reader.deinit();
    }

    fn httpRequest(self: *TestClient, req: []const u8) ![]const u8 {
        try sys_net.writeAll(self.socket, req);

        var pos: usize = 0;
        var total_length: ?usize = null;
        while (true) {
            const n = try posix.read(self.socket, self.buf[pos..]);
            if (n == 0) {
                return if (pos == self.buf.len) error.MessageTooLarge else error.NoMoreData;
            }
            pos += n;
            const response = self.buf[0..pos];
            if (total_length == null) {
                const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse continue;
                const header = response[0 .. header_end + 4];

                const cl = blk: {
                    const cl_header = "Content-Length: ";
                    const start = (std.mem.indexOf(u8, header, cl_header) orelse {
                        break :blk 0;
                    }) + cl_header.len;

                    const end = std.mem.indexOfScalarPos(u8, header, start, '\r') orelse {
                        return error.InvalidContentLength;
                    };

                    break :blk std.fmt.parseInt(usize, header[start..end], 10) catch {
                        return error.InvalidContentLength;
                    };
                };

                total_length = cl + header.len;
            }

            if (total_length) |tl| {
                if (pos == tl) {
                    return response;
                }
                if (pos > tl) {
                    return error.DataExceedsContentLength;
                }
            }
        }
    }

    // Reads until the server closes the connection, for responses larger
    // than buf (e.g. /json/protocol).
    fn httpRequestAlloc(self: *TestClient, req: []const u8) ![]const u8 {
        try sys_net.writeAll(self.socket, req);

        var response: std.ArrayList(u8) = .empty;
        while (true) {
            const n = try posix.read(self.socket, &self.buf);
            if (n == 0) {
                return response.items;
            }
            try response.appendSlice(testing.arena_allocator, self.buf[0..n]);
        }
    }

    fn handshake(self: *TestClient, path: []const u8) !void {
        var request_buf: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf, "GET {s}   HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "sec-websocket-version:13\r\n" ++
            "sec-websocket-key: this is my key\r\n" ++
            "Custom:  Header-Value\r\n\r\n", .{path});

        const res = try self.httpRequest(request);
        try testing.expectEqual("HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: upgrade\r\n" ++
            "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n", res);
    }

    // client->server frames must be masked; a zero mask leaves the payload
    // bytes unchanged.
    fn bidiCommand(self: *TestClient, payload: []const u8) !void {
        var frame: [1024]u8 = undefined;
        frame[0] = 129; // fin | text
        var header_len: usize = 2;
        if (payload.len <= 125) {
            frame[1] = 128 | @as(u8, @intCast(payload.len));
        } else {
            frame[1] = 128 | 126;
            std.mem.writeInt(u16, frame[2..4], @intCast(payload.len), .big);
            header_len = 4;
        }
        @memset(frame[header_len..][0..4], 0);
        @memcpy(frame[header_len + 4 ..][0..payload.len], payload);
        try sys_net.writeAll(self.socket, frame[0 .. header_len + 4 + payload.len]);
    }

    fn readWebsocketMessage(self: *TestClient) !?WS.Message {
        while (true) {
            // two frames can arrive in one read; drain buffered ones first
            if (try self.reader.next()) |msg| {
                return msg;
            }
            const n = try posix.read(self.socket, self.reader.readBuf());
            if (n == 0) {
                return error.Closed;
            }
            self.reader.len += n;
        }
    }
};

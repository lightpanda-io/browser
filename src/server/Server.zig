// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const BiDi = @import("bidi/BiDi.zig");

const WS = @import("WS.zig");
const http = @import("http.zig");
const Driver = @import("Driver.zig");
const Inbox = @import("../Inbox.zig");

const log = lp.log;
const posix = std.posix;
const Connection = http.Connection;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

// Which protocol-specific routes we serve
const Protocols = struct {
    cdp: bool = false,
    webdriver: bool = false,
};

const Server = @This();

// fds the process needs beyond client connections and the HTTP client's
const FD_HEADROOM = 128;

// How much one readable websocket may pull in per loop iteration; sized so a
// large driver message (Playwright sends ~400KB) takes a couple of turns
// rather than dozens, without starving the other connections.
const WS_READ_BUDGET = 256 * 1024;

// A websocket connection, this loop's side of Link.zig (the worker's side)
const WebSocket = struct {
    socket: posix.socket_t,
    address: sys_net.IpAddress,
    // threads `websockets` while live, the pool's free list otherwise
    node: DoublyLinkedList.Node,
    protocol: Driver.Protocol,
    // The worker's mailbox, which is how the main loop communicates with the worker.
    inbox: Inbox = .{},
    // null until the worker attaches
    driver: ?Driver = null,
    // whether or not socket is in the poll set. Makes sure we don't double-remove
    monitored: bool = false,

    const Pool = struct {
        slab: []WebSocket,
        free: DoublyLinkedList,
        live: usize, // acquired and not yet released

        fn init(allocator: Allocator, capacity: usize) !Pool {
            const slab = try allocator.alloc(WebSocket, capacity);
            var free: DoublyLinkedList = .{};
            for (slab) |*ws| {
                ws.node = .{};
                free.append(&ws.node);
            }
            return .{ .slab = slab, .free = free, .live = 0 };
        }

        fn deinit(self: *Pool, allocator: Allocator) void {
            allocator.free(self.slab);
        }

        fn acquire(self: *Pool) !*WebSocket {
            const node = self.free.popFirst() orelse return error.NoWebSocketSlot;
            self.live += 1;
            return @fieldParentPtr("node", node);
        }

        pub fn isFull(self: *const Pool) bool {
            return self.live == self.slab.len;
        }

        fn release(self: *Pool, ws: *WebSocket) void {
            self.live -= 1;
            ws.node = .{};
            self.free.append(&ws.node);
        }
    };
};

// Worker -> loop request, see worker_queue.
const WorkerRequest = struct {
    ws: *WebSocket,
    op: union(enum) {
        attach: Driver,
        release: *std.Io.Event,
    },
};

app: *App,
io_engine: IOEngine,
listener: posix.socket_t,

listener_paused: bool,

// # of client connections we can have alive. Not --cdp-max-connections which
// limits drivers (which cost a lot of memory). We need a higher limit to support
// keepalive and hits to /json/version,  /metrics, etc.
max_connections: usize,

// the protocols (cdp/bidi) we support
protocols: Protocols,

// Live connections still in the HTTP phase, ordered by deadline
http_connections: DoublyLinkedList,
http_connection_pool: Connection.Pool,

// Websocket connections, attached or not
websockets: DoublyLinkedList,
websocket_pool: WebSocket.Pool,

// Worker communicates with the main loop through this queue, protected by the
// mutex.
worker_mutex: std.Io.Mutex,
worker_queue: std.ArrayList(WorkerRequest),
// the queue is a double-buffer so that we don't have to hold worker_mutex while
// draining it, just need to swap the two.
worker_drain: std.ArrayList(WorkerRequest),

// A shutdown has been signaled AND the loop has started to process it
shutdown_begun: bool,

// Will block on this until all workers are shutdown
workers: lp.WaitGroup,

// Dynamic responses (/metrics, ...) are built here. If they can't be written
// immediately, it will be copied to the Connection's pending
scratch: std.Io.Writer.Allocating,

json_version_response: []const u8,
// ws://host:port/session/ — what POST /session advertises, the id goes on the end
bidi_session_url: []const u8,

pub fn init(app: *App, address: sys_net.IpAddress) !*Server {
    const config = app.config;
    const allocator = app.allocator;

    const io_engine = try IOEngine.init();
    errdefer io_engine.deinit();

    var scratch = try std.Io.Writer.Allocating.initCapacity(allocator, 8192);
    errdefer scratch.deinit();

    var json_version_response: []const u8 = "";
    var bidi_session_url: []const u8 = "";

    const max_connections = fdBudget(config);

    const listener = blk: {
        const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
        const l = try sys_net.socket(sys_net.family(&address), flags, posix.IPPROTO.TCP);
        errdefer sys_net.close(l);

        try posix.setsockopt(l, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.TCP, "NODELAY")) {
            try posix.setsockopt(l, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
        }

        const sa = sys_net.sockaddrFromAddress(&address);
        try sys_net.bind(l, sa.ptr(), sa.len);
        {
            // look this up incase --port 0 was used
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try sys_net.getsockname(l, @ptrCast(&bound), &bound_len);
            const bound_address = sys_net.addressFromSockaddr(@ptrCast(&bound));

            json_version_response = try http.buildJSONVersionResponse(app, bound_address.getPort());
            errdefer allocator.free(json_version_response);

            bidi_session_url = try std.fmt.allocPrint(allocator, "ws://{s}:{d}/session/", .{ config.advertiseHost(), bound_address.getPort() });
            errdefer allocator.free(bidi_session_url);

            try sys_net.listen(l, config.maxPendingConnections());
            log.note(.note, "server running", .{
                .address = bound_address,
                .max_connections = max_connections,
                .max_browser_connections = config.maxConnections(),
            });
        }

        break :blk l;
    };
    errdefer sys_net.close(listener);

    var http_connection_pool = try Connection.Pool.init(app);
    errdefer http_connection_pool.deinit();

    var protocols: Protocols = .{};
    for (config.protocols()) |p| switch (p) {
        .cdp => protocols.cdp = true,
        .webdriver => protocols.webdriver = true,
    };

    const request_capacity = 2 * config.maxConnections();
    var worker_queue: std.ArrayList(WorkerRequest) = try .initCapacity(allocator, request_capacity);
    errdefer worker_queue.deinit(allocator);

    var worker_drain: std.ArrayList(WorkerRequest) = try .initCapacity(allocator, request_capacity);
    errdefer worker_drain.deinit(allocator);

    var websocket_pool = try WebSocket.Pool.init(allocator, config.maxConnections());
    errdefer websocket_pool.deinit(allocator);

    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);

    self.* = .{
        .app = app,
        .io_engine = io_engine,
        .listener = listener,
        .listener_paused = false,
        .scratch = scratch,
        .protocols = protocols,
        .http_connections = .{},
        .http_connection_pool = http_connection_pool,
        .json_version_response = json_version_response,
        .bidi_session_url = bidi_session_url,
        .max_connections = max_connections,
        .websockets = .{},
        .websocket_pool = websocket_pool,
        .worker_mutex = .init,
        .worker_queue = worker_queue,
        .worker_drain = worker_drain,
        .shutdown_begun = false,
        .workers = .{},
    };
    return self;
}

pub fn deinit(self: *Server) void {
    const allocator = self.app.allocator;

    self.workers.wait();
    lp.assert(self.websockets.first == null, "Server.deinit websockets", .{});
    while (self.http_connections.first) |node| {
        http.disconnect(self, @fieldParentPtr("node", node));
    }

    self.scratch.deinit();
    self.websocket_pool.deinit(allocator);
    self.worker_queue.deinit(allocator);
    self.worker_drain.deinit(allocator);
    self.http_connection_pool.deinit();
    allocator.free(self.json_version_response);
    allocator.free(self.bidi_session_url);
    sys_net.close(self.listener);
    self.io_engine.deinit();
    allocator.destroy(self);
}

// Any thread (signal handler, mcp).
pub fn shutdown(self: *Server) void {
    self.io_engine.stop();
}

// blocks the caller
pub fn run(self: *Server) void {
    self.io_engine.monitorListener(self.listener) catch |err| {
        log.fatal(.serve, "io listen", .{ .err = err });
        return;
    };

    while (self.runOnce()) {}
}

fn runOnce(self: *Server) bool {
    const deadline = blk: {
        // self.http_connections is ordered by deadline
        const node = self.http_connections.first orelse break :blk null;
        const conn: *Connection = @fieldParentPtr("node", node);
        break :blk conn.deadline -| lp.datetime.milliTimestamp(.boot);
    };

    var events = self.io_engine.wait(deadline);
    const now = lp.datetime.milliTimestamp(.boot);

    var pending_accept = false;
    var pending_signal = false;
    var pending_shutdown = false;
    while (events.next()) |event| {
        switch (event) {
            .accept => pending_accept = true,
            .read_write => |rw| switch (rw.target) {
                .http => |conn| http.processEvent(self, conn, rw, now),
                .ws => |ws| self.processWebSocketEvent(ws, rw),
            },
            .signal => pending_signal = true,
            .shutdown => pending_shutdown = true,
        }
    }

    // signal first: a worker that released frees a slot the accept can use.
    if (pending_signal) {
        self.drainWorkerQueue();
    }
    if (pending_accept) {
        self.accept(now) catch |err| log.err(.serve, "accept", .{ .err = err });
    }
    // shutdown last: it's terminal, and draining the queue first keeps it from
    // walking a websocket whose worker has already gone.
    if (pending_shutdown) {
        self.beginShutdown();
    }

    // evict http connections that have passed their deadline
    while (self.http_connections.first) |node| {
        const conn: *Connection = @fieldParentPtr("node", node);
        if (conn.deadline > now) {
            // self.http_connections is ordered by deadline, so as soon as we find one
            // that hasn't reach its deadline, none of the ones after can.
            break;
        }
        lp.metrics.serve_http_evictions.incr();
        http.disconnect(self, conn);
    }

    if (self.shutdown_begun and self.websocket_pool.live == 0) {
        return false;
    }
    return true;
}

fn accept(self: *Server, now: u64) !void {
    if (self.liveConnections() >= self.max_connections) {
        return self.saturated();
    }

    while (true) {
        var address: posix.sockaddr.storage = undefined;
        var address_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const socket = sys_net.accept(self.listener, @ptrCast(&address), &address_len, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                error.ConnectionAborted => {
                    log.warn(.serve, "accept connection aborted", .{});
                    continue;
                },
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                    log.warn(.serve, "accept fd limit", .{ .err = err });
                    return self.saturated();
                },
                else => {
                    log.err(.serve, "accept error", .{ .err = err });
                    continue;
                },
            }
        };
        errdefer sys_net.close(socket);
        configureSocket(socket);

        const peer = sys_net.addressFromSockaddr(@ptrCast(&address));
        if (comptime lp.IS_DEBUG) {
            log.debug(.serve, "client connected", .{ .address = peer });
        }

        const conn = try self.http_connection_pool.acquire();
        errdefer self.http_connection_pool.release(conn);
        conn.socket = socket;
        conn.address = peer;

        try self.io_engine.monitorHTTP(conn);
        conn.deadline = now + http.IDLE_TIMEOUT_MS;
        self.http_connections.append(&conn.node);

        if (self.liveConnections() == self.max_connections) {
            return;
        }
    }
}

// A peer that goes away without a FIN (a killed VM, a NAT timeout) leaves an
// upgraded connection holding a worker, a browser and a --cdp-max-connections
// slot; nothing above the socket notices. Keepalive is what ends it, and
// Driver.tick's wait cadence is built on that. Best effort: a socket we can't
// configure is still a usable socket.
fn configureSocket(socket: posix.socket_t) void {
    setSocketOption(socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, @as(c_int, 1), "SO_KEEPALIVE");

    const idle_opt = switch (builtin.os.tag) {
        .macos, .ios => posix.TCP.KEEPALIVE,
        else => posix.TCP.KEEPIDLE,
    };
    setSocketOption(socket, posix.IPPROTO.TCP, idle_opt, Config.CDP_KEEPALIVE_IDLE_S, "TCP_KEEPIDLE");
    setSocketOption(socket, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, Config.CDP_KEEPALIVE_INTVL_S, "TCP_KEEPINTVL");
    setSocketOption(socket, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, Config.CDP_KEEPALIVE_CNT, "TCP_KEEPCNT");

    if (comptime builtin.os.tag == .linux) {
        setSocketOption(socket, posix.IPPROTO.TCP, std.os.linux.TCP.USER_TIMEOUT, Config.CDP_TCP_USER_TIMEOUT_MS, "TCP_USER_TIMEOUT");
    }
}

fn setSocketOption(socket: posix.socket_t, level: i32, option: u32, value: anytype, comptime name: []const u8) void {
    posix.setsockopt(socket, level, option, &std.mem.toBytes(value)) catch |err| {
        log.warn(.serve, "setsockopt", .{ .err = err, .option = name });
    };
}

fn liveConnections(self: *const Server) usize {
    return self.http_connection_pool.live + self.websocket_pool.live;
}

// We want to accept a connection, but have reached the connection limit. See
// If there is any we can disconnect.
fn saturated(self: *Server) !void {
    lp.metrics.serve_connection_limit.incr();
    var node = self.http_connections.first;
    while (node) |n| : (node = n.next) {
        const conn: *Connection = @fieldParentPtr("node", n);
        if (conn.isIdle()) {
            // we found an idle connection, bye.
            http.disconnect(self, conn);
            return;
        }
    }

    // there isn't an available slot, we need to pause the listener (so that
    // new connections sit in the OS backlog)
    if (self.listener_paused) {
        // ...we already did that
        return;
    }
    try self.io_engine.pauseListener(self.listener);
    self.listener_paused = true;
}

fn processWebSocketEvent(self: *Server, ws: *WebSocket, rw: IOEvent.ReadWrite) void {
    if (ws.monitored == false) {
        // only attachWorker puts a websocket in the poll set, and only once
        // the driver is set; an unmonitored slot has no business here.
        return;
    }

    const driver = ws.driver orelse {
        // the socket is only monitered after an attach, which sets the driver
        lp.assert(false, "Server.processWebSocketEvent driver", .{});
        unreachable;
    };

    if (rw.readable) {
        const keep = driver.onReadable(WS_READ_BUDGET) catch |err| switch (err) {
            error.Closed => return self.dropWebSocket(ws, null, true), // peer EOF
            // read error or fatal framing error: the worker doesn't know, so notify
            else => return self.dropWebSocket(ws, err, true),
        };
        if (keep == false) {
            // Close frame consumed: the framer already pushed .close, the
            // worker will reply and disconnect itself.
            return self.dropWebSocket(ws, null, false);
        }
    } else if (rw.hangup) {
        return self.dropWebSocket(ws, null, true);
    }
}

pub fn slotFreed(self: *Server) void {
    if (self.listener_paused and !self.shutdown_begun) {
        // the listener was paused (since we had no free slots)
        // unpause it (we now have a free slot).
        self.io_engine.monitorListener(self.listener) catch |err| {
            // the next recycle retries
            log.err(.serve, "resume listener", .{ .err = err });
            return;
        };
        self.listener_paused = false;
    }
}

// The 101 has been written: take the fd off the http Connection (the http
// side recycles it) into a websocket slot/
pub fn upgradeConnection(self: *Server, conn: *Connection, protocol: Driver.Protocol, session_id: ?[36]u8) void {
    // it'll get added back once the Worker is started and able to process messages
    self.io_engine.remove(conn.socket);
    self.http_connections.remove(&conn.node);

    const ws = self.websocket_pool.acquire() catch |err| {
        if (comptime lp.IS_DEBUG) {
            // should not be reachable. In the HTTP upgrade processing, we
            // checked isFull()
            unreachable;
        }

        // but, let's be safe..
        log.err(.serve, "websocket slot", .{ .err = err });
        sys_net.close(conn.socket);
        return;
    };

    ws.* = .{
        .node = .{},
        .socket = conn.socket,
        .address = conn.address,
        .protocol = protocol,
    };
    self.websockets.append(&ws.node);

    lp.metrics.serve_connections.incr(protocol);
    lp.metrics.serve_active_connections.incr(protocol);

    self.workers.start();
    const thread = std.Thread.spawn(.{}, Worker.start, .{ self, ws, session_id }) catch |err| {
        // cleanup what we just did prior to spawning.
        log.err(.serve, "worker spawn", .{ .err = err });
        self.workers.finish();
        sys_net.close(ws.socket);
        self.releaseWebSocket(ws);
        return;
    };
    thread.detach();
}

fn drainWorkerQueue(self: *Server) void {
    self.worker_mutex.lockUncancelable(lp.io);
    std.mem.swap(std.ArrayList(WorkerRequest), &self.worker_queue, &self.worker_drain);
    self.worker_mutex.unlock(lp.io);

    for (self.worker_drain.items) |request| {
        switch (request.op) {
            .attach => |driver| self.attachWorker(request.ws, driver),
            .release => |notify| self.releaseWorker(request.ws, notify),
        }
    }
    self.worker_drain.clearRetainingCapacity();
}

// The Worker is spawned, the Driver is setup. It has signaled us that it's
// ready to receive messages and given us the driver to associate to the
// connection.
fn attachWorker(self: *Server, ws: *WebSocket, driver: Driver) void {
    if (comptime lp.IS_DEBUG) {
        // a worker attaches exactly once
        lp.assert(ws.driver == null, "Server.attachWorker attached", .{});
    }
    ws.driver = driver;
    if (self.shutdown_begun) {
        driver.shutdown();
    }
    self.io_engine.monitorWebSocket(ws) catch |err| {
        log.err(.serve, "ws monitor", .{ .err = err });
        // never monitored, so this only tells the worker
        return self.dropWebSocket(ws, err, true);
    };
    ws.monitored = true;
}

fn releaseWorker(self: *Server, ws: *WebSocket, notify: *std.Io.Event) void {
    if (ws.monitored) {
        ws.monitored = false;
        self.io_engine.remove(ws.socket);
    }
    self.releaseWebSocket(ws);
    // The worker is free to deinit its driver and close the fd from here.
    notify.set(lp.io);
}

// Frees the slot once the loop is done with the fd. The fd itself is closed
// by whoever owns the end of its life: the worker after its driver's deinit,
// or upgradeConnection when there never was a worker.
fn releaseWebSocket(self: *Server, ws: *WebSocket) void {
    self.websockets.remove(&ws.node);
    ws.driver = null;
    ws.inbox.deinit();
    lp.metrics.serve_active_connections.decr(ws.protocol);
    self.websocket_pool.release(ws);
    self.slotFreed();
}

// unlike close above, this stops the polling on the socket and, optionally,
// informs the Worker that it should shut down. Ultimately, when it does shutdown
// releaseWebSocket above will be called.
fn dropWebSocket(self: *Server, ws: *WebSocket, err: ?anyerror, notify: bool) void {
    if (ws.monitored) {
        // only turned on in attachWorker, so it'll never be turned on again
        ws.monitored = false;
        self.io_engine.remove(ws.socket);
    }

    if (notify) {
        // Some closes the drivers knows about, some it doesn't. But the driver
        // is always the final authority on cleanup, so we always inform it of
        // the close.
        if (ws.driver) |driver| {
            driver.onLinkDisconnect(err);
        }
    }
}

fn beginShutdown(self: *Server) void {
    if (self.shutdown_begun) {
        return;
    }
    self.shutdown_begun = true;

    if (!self.listener_paused) {
        self.io_engine.pauseListener(self.listener) catch {};
        self.listener_paused = true;
    }
    while (self.http_connections.first) |node| {
        http.disconnect(self, @fieldParentPtr("node", node));
    }

    var node = self.websockets.first;
    while (node) |n| : (node = n.next) {
        const ws: *WebSocket = @fieldParentPtr("node", n);
        // not attached yet: attachWorker terminates it on arrival
        if (ws.driver) |driver| {
            driver.shutdown();
        }
    }
}

fn fdBudget(config: *const Config) usize {
    const reserve: usize = @as(usize, config.httpMaxConcurrent()) + config.wsMaxConcurrent() + FD_HEADROOM;
    const soft: u64 = blk: {
        const limit = posix.getrlimit(.NOFILE) catch |err| {
            log.warn(.serve, "getrlimit", .{ .err = err });
            break :blk 1024;
        };
        break :blk limit.cur;
    };
    // put some limit incase of a unlimited or very large rlimit
    const ceiling = (64 * 1024 * 1024) / @max(@as(u64, config.cdpMaxHTTPMessageSize()), 1);
    const budget = @min(soft, ceiling) -| reserve;
    return @intCast(@max(budget, 8));
}

fn signal(self: *Server) void {
    self.io_engine.signal();
}

// Stateless, but helps to group things that run on the Worker thread
const Worker = struct {
    fn start(server: *Server, ws: *WebSocket, session_id: ?[36]u8) void {
        defer server.workers.finish();
        Worker._start(server, ws, session_id) catch |err| {
            log.err(.serve, "worker init", .{ .err = err });
            Worker.releaseConnection(server, ws);
        };
    }

    fn _start(server: *Server, ws: *WebSocket, session_id: ?[36]u8) !void {
        const allocator = server.app.allocator;
        // The socket outlives the slot: the driver's deinit below still
        // writes to it (inspector detach notifications), so it closes last,
        // after the loop has released us. `ws` itself must not be touched
        // after releaseConnection returns.
        const socket = ws.socket;
        defer sys_net.close(socket);
        switch (ws.protocol) {
            .cdp => {
                const cdp = try allocator.create(CDP);
                defer allocator.destroy(cdp);
                try cdp.init(server.app, ws.socket, &ws.inbox);
                defer cdp.deinit();
                Worker.run(server, ws, .init(.{ .cdp = cdp }, &ws.inbox));
            },
            .bidi => {
                const bidi = try allocator.create(BiDi);
                defer allocator.destroy(bidi);
                try bidi.init(server.app, ws.socket, &ws.inbox, session_id);
                defer bidi.deinit();
                Worker.run(server, ws, .init(.{ .bidi = bidi }, &ws.inbox));
            },
        }
    }

    fn run(server: *Server, ws: *WebSocket, driver: Driver) void {
        Worker.notifyLoopOfChange(server, .{ .ws = ws, .op = .{ .attach = driver } });
        driver.run();
        // Release first: until the loop has let go of this websocket it can
        // still drop the link, and onLinkDisconnect requests a terminate.
        Worker.releaseConnection(server, ws);

        // CDP/BiDi close the session before Browser.deinit, so disarm now.
        driver.browser.prepareForTeardown();
    }

    // Worker -> loop: synchronous release. Blocks until the loop has dropped the
    // fd and won't call feed() again, so the caller can safely deinit the driver
    // (which frees the reader).
    fn releaseConnection(server: *Server, ws: *WebSocket) void {
        var notify: std.Io.Event = .unset;
        Worker.notifyLoopOfChange(server, .{ .ws = ws, .op = .{ .release = &notify } });
        notify.waitUncancelable(lp.io);
    }

    fn notifyLoopOfChange(server: *Server, request: WorkerRequest) void {
        server.worker_mutex.lockUncancelable(lp.io);
        server.worker_queue.appendAssumeCapacity(request);
        server.worker_mutex.unlock(lp.io);
        server.io_engine.signal();
    }
};

const IOEngine = switch (builtin.os.tag) {
    .linux => EPoll,
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
    else => unreachable,
};

// Abstraction over an EPoll or KQueue event
pub const IOEvent = union(enum) {
    accept: void,
    signal: void,
    shutdown: void,
    read_write: ReadWrite,

    pub const ReadWrite = struct {
        target: union(enum) {
            ws: *WebSocket,
            http: *Connection,
        },
        hangup: bool,
        readable: bool,
        writable: bool,
    };
};

const EPoll = struct {
    fd: posix.socket_t,
    close_fd: posix.socket_t, // to signal shutdown
    signal_fd: posix.socket_t, // to signal external
    event_list: [128]EpollEvent,

    const linux = std.os.linux;
    const EpollEvent = linux.epoll_event;

    fn init() !EPoll {
        const fd = try sys_net.epoll_create1(0);
        errdefer sys_net.close(fd);

        const close_fd = try sys_net.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer sys_net.close(close_fd);

        const signal_fd = try sys_net.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer sys_net.close(signal_fd);

        // Both eventfds are edge-triggered and never read: every write is its
        // own edge, and one delivery services everything that arrived.
        {
            var event = linux.epoll_event{
                .data = .{ .ptr = 1 },
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
            };
            try sys_net.epoll_ctl(fd, linux.EPOLL.CTL_ADD, close_fd, &event);
        }

        {
            var event = linux.epoll_event{
                .data = .{ .ptr = 2 },
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
            };
            try sys_net.epoll_ctl(fd, linux.EPOLL.CTL_ADD, signal_fd, &event);
        }

        return .{
            .fd = fd,
            .close_fd = close_fd,
            .signal_fd = signal_fd,
            .event_list = undefined,
        };
    }

    fn deinit(self: *const EPoll) void {
        sys_net.close(self.close_fd);
        sys_net.close(self.signal_fd);
        sys_net.close(self.fd);
    }

    fn stop(self: *const EPoll) void {
        const increment: u64 = 1;
        _ = sys_net.write(self.close_fd, std.mem.asBytes(&increment)) catch |err| {
            log.fatal(.serve, "network close", .{ .err = err, .type = "epoll" });
        };
    }

    fn signal(self: *const EPoll) void {
        const increment: u64 = 1;
        _ = sys_net.write(self.signal_fd, std.mem.asBytes(&increment)) catch |err| {
            log.err(.serve, "network signal", .{ .err = err, .type = "epoll" });
        };
    }

    fn monitorListener(self: *const EPoll, fd: posix.fd_t) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.EXCLUSIVE, .data = .{ .ptr = 0 } };
        return sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn pauseListener(self: *const EPoll, fd: posix.fd_t) !void {
        return sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, null);
    }

    const READ_EVENTS = linux.EPOLL.IN | linux.EPOLL.RDHUP;

    // No RDHUP while writing: it's level-triggered, so a half-closed peer
    // would wake us continuously while the send buffer is full. A gone peer
    // surfaces as a write error instead.
    const WRITE_EVENTS = linux.EPOLL.OUT;

    // Poll data carries the owner: an http Connection as-is, an WebSocket with
    // the low bit set (both are word-aligned, so the bit is free).
    const WS_TAG: usize = 1;

    fn monitorHTTP(self: *const EPoll, conn: *Connection) !void {
        var event = linux.epoll_event{
            .data = .{ .ptr = @intFromPtr(conn) },
            .events = READ_EVENTS,
        };
        return sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, conn.socket, &event);
    }

    fn monitorWebSocket(self: *const EPoll, ws: *WebSocket) !void {
        var event = linux.epoll_event{
            .data = .{ .ptr = @intFromPtr(ws) | WS_TAG },
            .events = READ_EVENTS,
        };
        return sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, ws.socket, &event);
    }

    pub fn waitWritable(self: *const EPoll, conn: *Connection) !void {
        return self.modify(conn, WRITE_EVENTS);
    }

    pub fn waitReadable(self: *const EPoll, conn: *Connection) !void {
        return self.modify(conn, READ_EVENTS);
    }

    fn modify(self: *const EPoll, conn: *Connection, events: u32) !void {
        var event = linux.epoll_event{
            .data = .{ .ptr = @intFromPtr(conn) },
            .events = events,
        };
        return sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, conn.socket, &event);
    }

    pub fn remove(self: *const EPoll, socket: posix.socket_t) void {
        sys_net.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, socket, null) catch {};
    }

    // null blocks until an event arrives
    fn wait(self: *EPoll, timeout_ms: ?u64) Iterator {
        const event_list = &self.event_list;
        const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(i32))) else -1;

        const event_count = sys_net.epoll_wait(self.fd, event_list, timeout);
        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []EpollEvent,

        fn next(self: *Iterator) ?IOEvent {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;

            const event = &events[index];
            switch (event.data.ptr) {
                0 => return .{ .accept = {} },
                1 => return .{ .shutdown = {} },
                2 => return .{ .signal = {} },
                else => |nptr| {
                    const flags = event.events;
                    return .{ .read_write = .{
                        .target = if (nptr & WS_TAG == 0)
                            .{ .http = @ptrFromInt(nptr) }
                        else
                            .{ .ws = @ptrFromInt(nptr & ~WS_TAG) },
                        .readable = flags & linux.EPOLL.IN != 0,
                        .writable = flags & linux.EPOLL.OUT != 0,
                        .hangup = flags & (linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0,
                    } };
                },
            }
        }
    };
};

const KQueue = struct {
    fd: i32,
    event_list: [128]Kevent,

    const EV = std.c.EV;
    const NOTE = std.c.NOTE;
    const EVFILT = std.c.EVFILT;
    const Kevent = std.c.Kevent;

    // Poll data carries the owner: an http Connection as-is, an WebSocket with
    // the low bit set (both are word-aligned, so the bit is free).
    const WS_TAG: usize = 1;

    // The listener carries 0. The two wake channels are EVFILT_USER events,
    // whose ident only has to be unique amongst user events, so it doubles as
    // the udata sentinel.
    const LISTENER: usize = 0;
    const SHUTDOWN: usize = 1;
    const SIGNAL: usize = 2;

    fn init() !KQueue {
        const fd = try sys_net.kqueue();
        errdefer sys_net.close(fd);

        var self = KQueue{ .fd = fd, .event_list = undefined };

        // Both wake channels are edge-triggered and never drained: every
        // NOTE_TRIGGER is its own edge, EV_CLEAR resets the event as it is
        // delivered, and one delivery services everything that arrived.
        try self.change(&.{
            userEvent(SHUTDOWN, EV.ADD | EV.CLEAR, 0),
            userEvent(SIGNAL, EV.ADD | EV.CLEAR, 0),
        });

        return self;
    }

    fn deinit(self: *const KQueue) void {
        sys_net.close(self.fd);
    }

    fn stop(self: *const KQueue) void {
        self.change(&.{userEvent(SHUTDOWN, 0, NOTE.TRIGGER)}) catch |err| {
            log.fatal(.serve, "network close", .{ .err = err, .type = "kqueue" });
        };
    }

    fn signal(self: *const KQueue) void {
        self.change(&.{userEvent(SIGNAL, 0, NOTE.TRIGGER)}) catch |err| {
            log.err(.serve, "network signal", .{ .err = err, .type = "kqueue" });
        };
    }

    fn monitorListener(self: *const KQueue, fd: posix.fd_t) !void {
        return self.monitor(fd, EVFILT.READ, LISTENER);
    }

    fn pauseListener(self: *const KQueue, fd: posix.fd_t) !void {
        return self.change(&.{socketEvent(fd, EVFILT.READ, EV.DELETE, 0)});
    }

    fn monitorHTTP(self: *const KQueue, conn: *Connection) !void {
        return self.monitor(conn.socket, EVFILT.READ, @intFromPtr(conn));
    }

    fn monitorWebSocket(self: *const KQueue, ws: *WebSocket) !void {
        return self.monitor(ws.socket, EVFILT.READ, @intFromPtr(ws) | WS_TAG);
    }

    // A socket only ever has one of the two filters registered, so flipping is
    // a delete plus an add. The callers only ever flip a connection that is
    // registered for the filter being dropped, so the delete can't fail and
    // abort the rest of the list.
    pub fn waitWritable(self: *const KQueue, conn: *Connection) !void {
        return self.flip(conn, EVFILT.READ, EVFILT.WRITE);
    }

    pub fn waitReadable(self: *const KQueue, conn: *Connection) !void {
        return self.flip(conn, EVFILT.WRITE, EVFILT.READ);
    }

    fn flip(self: *const KQueue, conn: *Connection, from: i16, to: i16) !void {
        return self.change(&.{
            socketEvent(conn.socket, from, EV.DELETE, 0),
            socketEvent(conn.socket, to, EV.ADD | EV.ENABLE, @intFromPtr(conn)),
        });
    }

    pub fn remove(self: *const KQueue, socket: posix.socket_t) void {
        // We don't track which of the two a socket is registered for, and it
        // might not be registered at all.
        self.unmonitor(socket, EVFILT.READ);
        self.unmonitor(socket, EVFILT.WRITE);
    }

    // No EV_CLEAR, no EV_DISPATCH: socket filters stay level-triggered, the
    // loop relies on an unread remainder waking us again.
    fn monitor(self: *const KQueue, socket: posix.socket_t, filter: i16, udata: usize) !void {
        return self.change(&.{socketEvent(socket, filter, EV.ADD | EV.ENABLE, udata)});
    }

    fn unmonitor(self: *const KQueue, socket: posix.socket_t, filter: i16) void {
        self.change(&.{socketEvent(socket, filter, EV.DELETE, 0)}) catch {};
    }

    // Registrations go through their own kevent call rather than riding along
    // with the next wait: an empty event list makes kqueue report a bad change
    // through errno, so the callers above can keep an honest error union.
    fn change(self: *const KQueue, changes: []const Kevent) !void {
        var none: [0]Kevent = .{};
        _ = try sys_net.kevent(self.fd, changes, &none, null);
    }

    fn userEvent(ident: usize, flags: u16, fflags: u32) Kevent {
        return .{
            .ident = ident,
            .filter = EVFILT.USER,
            .flags = flags,
            .fflags = fflags,
            .data = 0,
            .udata = ident,
        };
    }

    fn socketEvent(socket: posix.socket_t, filter: i16, flags: u16, udata: usize) Kevent {
        return .{
            .ident = @intCast(socket),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
    }

    // null blocks until an event arrives
    fn wait(self: *KQueue, timeout_ms: ?u64) Iterator {
        const event_list = &self.event_list;

        var ts: std.c.timespec = undefined;
        const timeout: ?*const std.c.timespec = if (timeout_ms) |ms| blk: {
            ts = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
            break :blk &ts;
        } else null;

        // With no changes to apply, only programmer errors are possible.
        const event_count = sys_net.kevent(self.fd, &.{}, event_list, timeout) catch unreachable;
        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []Kevent,

        fn next(self: *Iterator) ?IOEvent {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;

            const event = &events[index];
            switch (event.udata) {
                LISTENER => return .{ .accept = {} },
                SHUTDOWN => return .{ .shutdown = {} },
                SIGNAL => return .{ .signal = {} },
                else => |nptr| {
                    return .{
                        .read_write = .{
                            .target = if (nptr & WS_TAG == 0)
                                .{ .http = @ptrFromInt(nptr) }
                            else
                                .{ .ws = @ptrFromInt(nptr & ~WS_TAG) },
                            .readable = event.filter == EVFILT.READ,
                            .writable = event.filter == EVFILT.WRITE,
                            // EV_EOF on a read filter can still come with buffered
                            // bytes; readers deal with the two together.
                            .hangup = event.flags & (EV.EOF | EV.ERROR) != 0,
                        },
                    };
                },
            }
        }
    };
};

const testing = @import("../testing.zig");
test "server: buildJSONVersionResponse" {
    const res = try http.buildJSONVersionResponse(testing.test_app, testing.test_app.config.port());
    defer testing.test_app.allocator.free(res);

    // The response includes the build version, so check structure rather than exact bytes.
    try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, res, "Content-Type: application/json") != null);
    // HTTP connections are kept alive now
    try testing.expect(std.mem.indexOf(u8, res, "Connection: Close") == null);

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

    // A known path with the wrong method is a 405 now (it used to 404).
    try assertHTTPError(
        405,
        "Method not allowed",
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
    testing.expectLog(&.{ .serve, .serve, .serve, .serve, .serve });

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
    testing.expectLog(&.{ .serve, .serve, .serve, .serve });

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

// --cdp-max-connections caps websockets only. Drivers (chromedp, for one) hit
// /json/version on a keepalive connection and then upgrade on a fresh one;
// with a single shared pool, X drivers needed 2X slots and the Xth upgrade
// was refused.
test "Client: idle http connections don't consume websocket slots" {
    const cap: usize = testing.test_app.config.maxConnections();
    const idle = try testing.allocator.alloc(TestClient, cap + 4);
    defer testing.allocator.free(idle);

    var opened: usize = 0;
    defer for (idle[0..opened]) |*c| c.deinit();
    for (idle) |*c| {
        c.* = try createTestClient();
        opened += 1;
        const res = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    }

    // more idle http connections than the websocket cap, and the upgrade
    // still goes through
    var ws = try createTestClient();
    defer ws.deinit();
    try ws.handshake("/");
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
    // the path exists (POST), the method doesn't
    try assertHTTPError(405, "Method not allowed", "DELETE /session HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
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
            "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
            "{\"value\":{\"ready\":true,\"message\":\"\"}}", res);
    }
    {
        // /metrics is protocol-neutral
        var c = try createTestClient();
        defer c.deinit();
        const res = try c.httpRequestAlloc("GET /metrics HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(res);
        try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
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

// A frame larger than WS_READ_BUDGET takes the loop more than one turn to
// assemble; the body isn't JSON, so the worker answers with a protocol error
// once it has the whole thing.
test "Client: websocket message larger than the read budget" {
    const payload_len = WS_READ_BUDGET + WS_READ_BUDGET / 2;
    const frame = try testing.allocator.alloc(u8, 14 + payload_len);
    defer testing.allocator.free(frame);

    frame[0] = 129; // fin | text
    frame[1] = 255; // masked | 127: 8-byte length follows
    std.mem.writeInt(u64, frame[2..10], payload_len, .big);
    @memset(frame[10..14], 0); // mask
    @memset(frame[14..], 'x');

    try assertWebSocketError(1002, frame);
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

test "server: 404" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /unknown HTTP/1.1\r\n\r\n");
    try testing.expectEqual("HTTP/1.1 404 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 9\r\n\r\n" ++
        "Not found", res);
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
    defer testing.allocator.free(res);

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
    try testing.expect(std.mem.indexOf(u8, res, "# TYPE serve_http_requests_total counter") != null);
    try testing.expect(std.mem.indexOf(u8, res, "# TYPE serve_connections_total counter") != null);
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
    const code = std.mem.readInt(u16, msg.data[0..2], .big);
    try testing.expectEqual(close_code, code);
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
    buf: [8192 * 2]u8 = undefined,
    reader: WS.ReaderNoMask,

    fn deinit(self: *TestClient) void {
        sys_net.close(self.socket);
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
                total_length = try responseLength(response) orelse continue;
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
        defer response.deinit(testing.allocator);
        var total_length: ?usize = null;
        while (true) {
            const n = try posix.read(self.socket, &self.buf);
            if (n == 0) {
                return error.NoMoreData;
            }
            try response.appendSlice(testing.allocator, self.buf[0..n]);
            if (total_length == null) {
                total_length = try responseLength(response.items) orelse continue;
            }
            if (response.items.len >= total_length.?) {
                return response.toOwnedSlice(testing.allocator);
            }
        }
    }

    // Header + Content-Length once the header block is complete, else null.
    // The server keeps HTTP/1.1 connections open, so EOF never marks the end
    // of a response.
    fn responseLength(response: []const u8) !?usize {
        const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
        const header = response[0 .. header_end + 4];

        const cl_header = "Content-Length: ";
        const start = (std.mem.indexOf(u8, header, cl_header) orelse return header.len) + cl_header.len;
        const end = std.mem.indexOfScalarPos(u8, header, start, '\r') orelse {
            return error.InvalidContentLength;
        };
        const cl = std.fmt.parseInt(usize, header[start..end], 10) catch {
            return error.InvalidContentLength;
        };
        return cl + header.len;
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

// A server of our own, bound to an ephemeral port and never run(): these
// tests drive its handlers by hand to reproduce what one event batch does.
// The real test server (port 9583) is shared and can't be torn down.
const LoopTest = struct {
    server: *Server,
    address: sys_net.IpAddress,

    fn init() !LoopTest {
        const server = try Server.init(testing.test_app, .{ .ip4 = .loopback(0) });
        errdefer server.deinit();
        server.protocols = .{ .cdp = true, .webdriver = true };
        // run() does this; runOnce() on its own would never see an accept
        try server.io_engine.monitorListener(server.listener);

        var bound: posix.sockaddr.storage = undefined;
        var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        try sys_net.getsockname(server.listener, @ptrCast(&bound), &bound_len);

        return .{ .server = server, .address = sys_net.addressFromSockaddr(@ptrCast(&bound)) };
    }

    fn deinit(self: *LoopTest) void {
        self.server.deinit();
    }

    fn expectResponse(self: *const LoopTest, client: posix.socket_t, prefix: []const u8) !void {
        _ = self;
        var buf: [512]u8 = undefined;
        const n = try posix.read(client, &buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], prefix));
    }

    // Connects a client and runs the accept the loop would have run,
    // returning the client's end and the Connection the loop now owns.
    fn accept(self: *LoopTest) !struct { posix.socket_t, *Connection } {
        const client = try sys_net.connect(&self.address);
        errdefer sys_net.close(client);
        // never block the suite on a response that isn't coming
        const timeout = std.mem.toBytes(posix.timeval{ .sec = 5, .usec = 0 });
        try posix.setsockopt(client, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);

        const before = self.server.http_connections.last;
        try pollReadable(self.server.listener);
        try self.server.accept(lp.datetime.milliTimestamp(.boot));

        const node = self.server.http_connections.last orelse return error.NotAccepted;
        if (node == before) {
            return error.NotAccepted;
        }
        return .{ client, @fieldParentPtr("node", node) };
    }

    // macOS delivers loopback traffic asynchronously: right after connect()
    // or write() returns, the peer's accept queue or read buffer can still be
    // empty. Linux processes it inline, so these tests never waited there.
    fn pollReadable(fd: posix.socket_t) !void {
        var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&pfd, 1000) == 0) {
            return error.Timeout;
        }
    }
};

// epoll and kqueue both report in the order things became ready, so making the
// deferred event ready first and the socket readable second puts the batch in
// the order that used to be fatal: the recycle before the event that names it.
test "server: a shutdown in the same batch as a readable connection" {
    var lt = try LoopTest.init();
    defer lt.deinit();

    const client, const conn = try lt.accept();
    defer sys_net.close(client);

    // shutdown first...
    lt.server.shutdown();
    // ...then the request, so it lands behind it in the batch
    try sys_net.writeAll(client, "GET /json/version HTTP/1.1\r\n\r\n");
    try LoopTest.pollReadable(conn.socket);

    // beginShutdown drops every http connection, so running it where it
    // arrived left the rest of the batch pointing at a recycled (or freed)
    // Connection. The request has to be answered first.
    try testing.expectEqual(false, lt.server.runOnce());
    try lt.expectResponse(client, "HTTP/1.1 200 OK\r\n");
    try testing.expect(lt.server.shutdown_begun);
}

test "server: an accept at the connection limit in the same batch as a readable connection" {
    var lt = try LoopTest.init();
    defer lt.deinit();

    const client, const conn = try lt.accept();
    defer sys_net.close(client);

    // one connection, and no room for another: the next accept has to make
    // room by disconnecting an idle connection
    lt.server.max_connections = 1;
    try testing.expectEqual(1, lt.server.liveConnections());

    // the accept first...
    const second = try sys_net.connect(&lt.address);
    defer sys_net.close(second);
    // the listener has to be in the batch too, or runOnce() sees the request
    // alone and saturated() -- the thing under test -- never runs
    try LoopTest.pollReadable(lt.server.listener);
    // ...then the request, so it lands behind it in the batch
    try sys_net.writeAll(client, "GET /json/version HTTP/1.1\r\n\r\n");
    try LoopTest.pollReadable(conn.socket);

    // saturated() picks the idle connection to drop, which is the one the
    // batch is still holding a pointer to. Its request comes first.
    _ = lt.server.runOnce();
    try lt.expectResponse(client, "HTTP/1.1 200 OK\r\n");
}

// Why the ordering matters rather than a flag on the connection: past the
// pool's retain count a release doesn't recycle, it destroys, so a stale
// pointer isn't merely pointing at the wrong client -- it's dangling.
test "server: releasing past the pool's retain destroys the connection" {
    var lt = try LoopTest.init();
    defer lt.deinit();

    const pool = &lt.server.http_connection_pool;
    const retain = pool.retain;

    const clients = try testing.allocator.alloc(posix.socket_t, retain + 1);
    defer testing.allocator.free(clients);
    var doomed: *Connection = undefined;
    for (clients, 0..) |*client, i| {
        client.*, const conn = try lt.accept();
        if (i == clients.len - 1) {
            doomed = conn;
        }
    }
    defer for (clients) |client| sys_net.close(client);
    try testing.expectEqual(retain + 1, pool.live);
    try testing.expectEqual(0, pool.free_count);

    while (lt.server.http_connections.first) |node| {
        http.disconnect(lt.server, @fieldParentPtr("node", node));
    }

    // retain + 1 released but only retain came back, and `doomed` is not among
    // them: it was destroyed, not pooled.
    try testing.expectEqual(0, pool.live);
    try testing.expectEqual(retain, pool.free_count);
    var node = pool.free.first;
    while (node) |n| : (node = n.next) {
        try testing.expect(@as(*Connection, @fieldParentPtr("node", n)) != doomed);
    }
}

test "server: the connection budget is bounded by buffer memory" {
    const opts = &testing.test_config.mode.serve;
    const original = opts.cdp_max_http_message_size;
    defer opts.cdp_max_http_message_size = original;

    // whatever NOFILE happens to be, we never sign up for more read buffers
    // than fdBudget's ceiling pays for (kept in step with it by hand)
    const ceiling = 64 * 1024 * 1024;
    for ([_]u14{ 1024, 4096, 16383 }) |size| {
        opts.cdp_max_http_message_size = size;
        const budget = fdBudget(testing.test_app.config);
        try testing.expect(budget * size <= ceiling);
        try testing.expect(budget >= 8);
    }
}

test "server: accepted sockets get TCP keepalive" {
    var lt = try LoopTest.init();
    defer lt.deinit();

    const client, const conn = try lt.accept();
    defer sys_net.close(client);

    // Driver.tick leans on this for liveness: without it a peer that goes
    // away without a FIN holds a worker and a connection slot forever.
    var value: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    try testing.expectEqual(0, std.c.getsockopt(conn.socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &value, &len));
    // BSD reports the option bit (8), Linux reports 1
    try testing.expect(value != 0);

    http.disconnect(lt.server, conn);
}

test "server: the http read buffer is sized by --cdp-max-http-message-size" {
    // the pool is built in Server.init, so this has to move first
    const opts = &testing.test_config.mode.serve;
    const original = opts.cdp_max_http_message_size;
    defer opts.cdp_max_http_message_size = original;
    opts.cdp_max_http_message_size = 8192;

    var lt = try LoopTest.init();
    defer lt.deinit();

    const client, const conn = try lt.accept();
    defer sys_net.close(client);

    try testing.expectEqual(8192, conn.buffer.buf.len);

    http.disconnect(lt.server, conn);
}

test "server: http connections stay ordered by deadline" {
    var lt = try LoopTest.init();
    defer lt.deinit();

    // A connects and completes a request, so it gets the served deadline...
    const client_a, const conn_a = try lt.accept();
    defer sys_net.close(client_a);
    try sys_net.writeAll(client_a, "GET /json/version HTTP/1.1\r\n\r\n");
    try LoopTest.pollReadable(conn_a.socket);
    const readable: IOEvent.ReadWrite = .{ .target = .{ .http = conn_a }, .readable = true, .writable = false, .hangup = false };
    http.processEvent(lt.server, conn_a, readable, lp.datetime.milliTimestamp(.boot));

    // ...and B connects after it, so it sits behind A in the list.
    const client_b, const conn_b = try lt.accept();
    defer sys_net.close(client_b);

    // run() reads the wait timeout off the head and the eviction sweep stops
    // at the first unexpired entry, so a later node may never hold an earlier
    // deadline.
    var node = lt.server.http_connections.first;
    var previous: u64 = 0;
    while (node) |n| : (node = n.next) {
        const conn: *Connection = @fieldParentPtr("node", n);
        try testing.expect(conn.deadline >= previous);
        previous = conn.deadline;
    }

    http.disconnect(lt.server, conn_a);
    http.disconnect(lt.server, conn_b);
}

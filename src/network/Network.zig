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

listener: ?Listener = null,
accept: std.atomic.Value(bool) = .init(true),

// CDP sockets the network thread polls on behalf of workers. Each
// worker registers its accepted socket via submitCdpRegister; the
// network thread applies the mutation in drainInbox and polls it
// alongside the listener + curl's fds. Network-thread-private —
// no lock needed because all mutations come through the inbox.
//
// `extra_fds` mirrors cdp_regs (parallel arrays). extra_fds[0] is
// the listener slot when bound; cdp_regs covers entries from
// extra_fds[cdp_start..].
cdp_regs: std.ArrayList(CdpReg) = .empty,
extra_fds: std.ArrayList(libcurl.CurlWaitFd) = .empty,

shutdown: std.atomic.Value(bool) = .init(false),

multi: *libcurl.CurlM,

// Cross-thread inbox: workers submit work (add/remove/op) via the
// submit* methods; the network thread drains in `drainInbox` and
// dispatches on Message kind. Modeled after an OTP-style GenServer
// inbox: all worker → network communication funnels through here.
//
// InboxItem entries are allocated from `inbox_pool` under the
// mutex; the drain frees them back to the pool in a single batch.
inbox: std.DoublyLinkedList = .{},
inbox_mutex: std.Thread.Mutex = .{},
inbox_pool: std.heap.MemoryPool(InboxItem),

callbacks: [MAX_TICK_CALLBACKS]TickCallback = undefined,
callbacks_len: usize = 0,
callbacks_mutex: std.Thread.Mutex = .{},

/// Optional IP filter for blocking requests to private/internal networks (--block-private-networks).
ip_filter: ?*IpFilter = null,

const TickCallback = struct {
    ctx: *anyopaque,
    fun: *const fn (*anyopaque) void,
};

// One message kind per worker → network operation. The dispatch is in
// `drainInbox`. `_in_multi` gates the conn-targeting ops so a stale
// .unpause / .tls_verify aimed at a conn whose completion is already
// in the pipeline becomes a no-op.
pub const Message = union(enum) {
    add: *http.Connection,
    remove: *http.Connection,
    unpause: *http.Connection,
    tls_verify: struct {
        conn: *http.Connection,
        verify: bool,
        use_proxy: bool,
    },
    cdp_register: struct {
        fd: posix.fd_t,
        handler: CdpHandler,
    },
    cdp_unregister: posix.fd_t,
};

const InboxItem = struct {
    msg: Message,
    node: std.DoublyLinkedList.Node = .{},
};

// Handler invoked by the network thread when a CDP socket has data
// or hits EOF. Both callbacks fire on the network thread; both
// should be quick (push to the owner's inbox, don't do parsing here).
pub const CdpHandler = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, data: []const u8) void,
    on_disconnect: *const fn (ctx: *anyopaque) void,
};

const CdpReg = struct {
    fd: posix.fd_t,
    handler: CdpHandler,
    // Set when we see EOF / read error / unregister request. The fd
    // is removed from extra_fds when this flips so we stop polling
    // it; the reg itself stays until on_disconnect is delivered and
    // the worker confirms its inbox is drained (which it does
    // implicitly by completing its deinit wait).
    eof: bool = false,
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

    const multi = libcurl.curl_multi_init() orelse return error.FailedToInitializeMulti;
    errdefer libcurl.curl_multi_cleanup(multi) catch {};

    try libcurl.curl_multi_setopt(multi, .max_host_connections, config.httpMaxHostOpen());

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,

        .available = available,
        .connections = connections,

        .app = app,

        .robot_store = RobotStore.init(allocator),
        .web_bot_auth = web_bot_auth,
        .cache = cache,

        .ws_pool = .init(allocator),
        .ws_max = config.wsMaxConcurrent(),

        .ip_filter = ip_filter,

        .multi = multi,
        .inbox_pool = .init(allocator),
    };
}

pub fn deinit(self: *Network) void {
    libcurl.curl_multi_cleanup(self.multi) catch {};
    self.inbox_pool.deinit();
    self.cdp_regs.deinit(self.allocator);
    self.extra_fds.deinit(self.allocator);

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
}

pub fn unbind(self: *Network) void {
    self.accept.store(false, .release);
    self.wakeupPoll();
}

// Async: enqueue a CDP-socket registration. The network thread
// applies it in drainInbox. Handler callbacks fire on the network
// thread once polling picks up activity on the fd.
pub fn submitCdpRegister(self: *Network, fd: posix.fd_t, handler: CdpHandler) !void {
    return self.submit(.{ .cdp_register = .{ .fd = fd, .handler = handler } });
}

// Async: enqueue a CDP-socket unregistration. The network thread
// flips the reg's `eof`, stops polling, and fires `on_disconnect` —
// the worker uses that as the ack that no more handler calls will
// happen for this fd (safe to free ctx after draining its inbox).
pub fn submitCdpUnregister(self: *Network, fd: posix.fd_t) !void {
    return self.submit(.{ .cdp_unregister = fd });
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
    var running_handles: c_int = 0;

    // Per-iteration scratch for CDP socket reads. Sized to match the
    // ws reader's initial capacity so one read fits one push.
    var cdp_buf: [16 * 1024]u8 = undefined;

    // Listener (if bound) lives at extra_fds[0] for the duration.
    // CDP entries occupy extra_fds[cdpOffset()..] in lock-step with
    // cdp_regs: cdp_regs[i] ↔ extra_fds[i + cdpOffset()]. All
    // mutations happen on the network thread (here or in drainInbox)
    // so no locking is needed; the invariant holds across each
    // iteration boundary.
    if (self.listener) |listener| {
        self.extra_fds.append(self.allocator, .{
            .fd = listener.socket,
            .events = .{ .pollin = true },
            .revents = .{},
        }) catch @panic("OOM");
    }

    // Please note that receiving a shutdown command does not terminate all connections.
    // When gracefully shutting down a server, we at least want to send the remaining
    // telemetry, but we stop accepting new connections. It is the responsibility
    // of external code to terminate its requests upon shutdown.
    while (true) {
        if (self.listener != null and !self.accept.load(.acquire)) {
            posix.close(self.listener.?.socket);
            self.listener = null;
            // Shift CDP entries down by 1 to keep the parallel
            // invariant (cdp_regs[i] ↔ extra_fds[i + cdpOffset()]).
            // O(N) but happens at most once per Network lifetime.
            _ = self.extra_fds.orderedRemove(0);
        }

        self.drainInbox();

        // Kickstart newly added handles (DNS/connect) so that curl
        // registers its sockets before we poll.
        libcurl.curl_multi_perform(self.multi, &running_handles) catch |err| {
            lp.log.err(.app, "curl perform", .{ .err = err });
        };
        self.processCompletions();

        // TODO: the 250ms cap is here only so `fireTicks` runs often
        // enough for telemetry's periodic flush. Telemetry should
        // schedule its own wakeup (via curl_multi_wakeup) when it has
        // work, after which we can let curl pick the timeout freely.
        const timeout = blk: {
            const curl_timeout = self.getCurlTimeout();
            if (curl_timeout == 0) break :blk 0;

            const min_timeout = 250;
            break :blk @min(min_timeout, curl_timeout);
        };

        // curl_multi_poll handles curl's own sockets plus everything
        // in extra_fds (listener + CDP sockets). Cross-thread wakeup
        // comes via curl_multi_wakeup (no pipe needed).
        libcurl.curl_multi_poll(self.multi, self.extra_fds.items, timeout, null) catch |err| {
            lp.log.err(.app, "curl poll", .{ .err = err });
            continue;
        };

        // Listener: always extra_fds[0] when bound.
        if (self.listener != null and self.extra_fds.items[0].revents.pollin) {
            self.acceptConnections();
        }

        // CDP: parallel-array dispatch, no fd lookups. Eof entries
        // are skipped (their extra_fds.events is zeroed so they
        // can't have pollin set, but the explicit check documents
        // the invariant). Iteration order is stable because eof
        // doesn't remove from either list — only unregister does.
        const offset = self.cdpOffset();
        for (self.cdp_regs.items, 0..) |*reg, i| {
            if (reg.eof) continue;
            const fd_state = self.extra_fds.items[i + offset];
            if (!fd_state.revents.pollin) continue;
            self.dispatchCdpRead(reg, i + offset, &cdp_buf);
        }

        libcurl.curl_multi_perform(self.multi, &running_handles) catch |err| {
            lp.log.err(.app, "curl perform", .{ .err = err });
        };
        self.processCompletions();

        self.fireTicks();

        if (self.shutdown.load(.acquire) and running_handles == 0) {
            // Check if fireTicks submitted new requests (e.g. telemetry flush).
            // If so, continue the loop to drain and send them before exiting.
            self.inbox_mutex.lock();
            const has_pending = self.inbox.first != null;
            self.inbox_mutex.unlock();
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

// ── Inbox: worker → network thread submission ──────────────────────────────

pub fn submitAdd(self: *Network, conn: *http.Connection) !void {
    return self.submit(.{ .add = conn });
}

pub fn submitRemove(self: *Network, conn: *http.Connection) !void {
    return self.submit(.{ .remove = conn });
}

pub fn submitUnpause(self: *Network, conn: *http.Connection) !void {
    return self.submit(.{ .unpause = conn });
}

pub fn submitTlsVerify(self: *Network, conn: *http.Connection, verify: bool, use_proxy: bool) !void {
    return self.submit(.{ .tls_verify = .{ .conn = conn, .verify = verify, .use_proxy = use_proxy } });
}

fn submit(self: *Network, msg: Message) !void {
    {
        self.inbox_mutex.lock();
        defer self.inbox_mutex.unlock();
        const item = try self.inbox_pool.create();
        item.* = .{ .msg = msg };
        self.inbox.append(&item.node);
    }
    self.wakeupPoll();
}

// Called by callers driving submissions outside of `run` (tests, and
// the late-shutdown path that needs to flush any canceled completions
// after the network thread has stopped).
pub fn drainPendingForShutdown(self: *Network) void {
    self.drainInbox();
    self.processCompletions();
}

fn wakeupPoll(self: *Network) void {
    libcurl.curl_multi_wakeup(self.multi) catch |err| {
        lp.log.warn(.app, "curl multi wakeup", .{ .err = err });
    };
}

// Splice the inbox into a local list under the lock, then walk it
// twice: once to process (handleAdd / handleRemove fire on_complete
// which crosses into the worker's completion queue; ops touch
// libcurl), then once to free items back to the pool in a single
// locked batch.
fn drainInbox(self: *Network) void {
    var local: std.DoublyLinkedList = .{};
    {
        self.inbox_mutex.lock();
        defer self.inbox_mutex.unlock();
        while (self.inbox.popFirst()) |n| local.append(n);
    }
    if (local.first == null) return;

    var it = local.first;
    while (it) |node| : (it = node.next) {
        const item: *InboxItem = @fieldParentPtr("node", node);
        switch (item.msg) {
            .add => |conn| self.handleAdd(conn),
            .remove => |conn| self.handleRemove(conn),
            .unpause => |conn| {
                if (!conn._in_multi) continue;
                conn.pause(.{ .cont = true }) catch |err| {
                    lp.log.warn(.app, "curl pause", .{ .err = err });
                };
            },
            .tls_verify => |t| {
                if (!t.conn._in_multi) continue;
                t.conn.setTlsVerify(t.verify, t.use_proxy) catch |err| {
                    lp.log.warn(.app, "curl setTlsVerify", .{ .err = err });
                };
            },
            .cdp_register => |r| self.handleCdpRegister(r.fd, r.handler),
            .cdp_unregister => |fd| self.handleCdpUnregister(fd),
        }
    }

    self.inbox_mutex.lock();
    defer self.inbox_mutex.unlock();
    while (local.popFirst()) |node| {
        const item: *InboxItem = @fieldParentPtr("node", node);
        self.inbox_pool.destroy(item);
    }
}

// Add a conn to the multi. On failure, fire on_complete with the
// error (or release directly if no callback is set). `_in_multi`
// stays false on failure so subsequent ops are dropped.
fn handleAdd(self: *Network, conn: *http.Connection) void {
    conn.setPrivate(conn) catch |err| {
        lp.log.err(.app, "curl set private", .{ .err = err });
        self.fireOnComplete(conn, err);
        return;
    };
    libcurl.curl_multi_add_handle(self.multi, conn._easy) catch |err| {
        lp.log.err(.app, "curl multi add", .{ .err = err });
        self.fireOnComplete(conn, err);
        return;
    };
    conn._in_multi = true;
}

// Remove a conn from the multi (cancel path). Always fires
// on_complete with Canceled — even if the conn never made it into
// the multi (e.g. .remove came in before .add ran), the contract
// stands: the owner gets exactly one terminal on_complete.
fn handleRemove(self: *Network, conn: *http.Connection) void {
    if (conn._in_multi) {
        libcurl.curl_multi_remove_handle(self.multi, conn._easy) catch |err| {
            lp.assert(false, "curl multi remove (was in_multi)", .{ .err = err });
        };
        conn._in_multi = false;
    }
    self.fireOnComplete(conn, error.Canceled);
}

fn fireOnComplete(self: *Network, conn: *http.Connection, err: ?anyerror) void {
    if (conn.on_complete) |cb| {
        cb(conn, err);
    } else {
        self.releaseConnection(conn);
    }
}

// Append a CDP registration. Both lists grow together so
// extra_fds[cdp_start + i] always matches cdp_regs[i] for non-eof
// entries — see the run loop's dispatch indexing.
fn handleCdpRegister(self: *Network, fd: posix.fd_t, handler: CdpHandler) void {
    self.cdp_regs.append(self.allocator, .{ .fd = fd, .handler = handler }) catch |err| {
        lp.log.err(.app, "cdp register OOM", .{ .err = err });
        handler.on_disconnect(handler.ctx);
        return;
    };
    self.extra_fds.append(self.allocator, .{
        .fd = fd,
        .events = .{ .pollin = true },
        .revents = .{},
    }) catch |err| {
        lp.log.err(.app, "cdp register OOM extra_fds", .{ .err = err });
        _ = self.cdp_regs.pop();
        handler.on_disconnect(handler.ctx);
        return;
    };
}

// Find the registration by fd, drop it from both parallel arrays.
// Fires on_disconnect as the "unregister processed" ack the worker
// is waiting for — unless we already fired it on EOF.
//
// swapRemove on both lists at the same logical index preserves the
// parallel invariant: cdp_regs[i] ↔ extra_fds[i + offset]. Both
// lists move their last entry to position i.
fn handleCdpUnregister(self: *Network, fd: posix.fd_t) void {
    const offset = self.cdpOffset();
    for (self.cdp_regs.items, 0..) |*reg, i| {
        if (reg.fd != fd) continue;
        const already_eof = reg.eof;
        const handler = reg.handler;
        _ = self.cdp_regs.swapRemove(i);
        _ = self.extra_fds.swapRemove(i + offset);
        if (!already_eof) handler.on_disconnect(handler.ctx);
        return;
    }
}

inline fn cdpOffset(self: *Network) usize {
    return if (self.listener != null) 1 else 0;
}

// Read from a readable CDP socket and dispatch to its handler.
// On EOF / error, marks the reg eof'd and fires on_disconnect;
// the reg+extra_fds slot stay parallel until the worker's
// unregister fully removes them.
fn dispatchCdpRead(self: *Network, reg: *CdpReg, fd_idx: usize, buf: []u8) void {
    const n = posix.read(reg.fd, buf) catch |err| {
        lp.log.warn(.app, "cdp read", .{ .err = err });
        self.markCdpEof(reg, fd_idx);
        return;
    };
    if (n == 0) {
        self.markCdpEof(reg, fd_idx);
        return;
    }
    reg.handler.on_data(reg.handler.ctx, buf[0..n]);
}

// EOF / error path. Reg stays in cdp_regs (and its extra_fds slot)
// to preserve the parallel invariant; zeroing events stops poll
// from waking us on this fd. Worker's unregister will fully remove.
fn markCdpEof(self: *Network, reg: *CdpReg, fd_idx: usize) void {
    reg.eof = true;
    self.extra_fds.items[fd_idx].events = .{};
    reg.handler.on_disconnect(reg.handler.ctx);
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

fn getCurlTimeout(self: *Network) i32 {
    var timeout_ms: c_long = -1;
    libcurl.curl_multi_timeout(self.multi, &timeout_ms) catch return -1;
    return @intCast(@min(timeout_ms, std.math.maxInt(i32)));
}

fn processCompletions(self: *Network) void {
    var msgs_in_queue: c_int = 0;
    while (libcurl.curl_multi_info_read(self.multi, &msgs_in_queue)) |msg| {
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

        libcurl.curl_multi_remove_handle(self.multi, easy) catch |err| {
            lp.assert(false, "curl multi remove (post-completion)", .{ .err = err });
        };
        conn._in_multi = false;
        self.fireOnComplete(conn, maybe_err);
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

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const ArenaPool = @import("../ArenaPool.zig");
const Notification = @import("../Notification.zig");
const timestamp = @import("../datetime.zig").timestamp;

const URL = @import("URL.zig");
const WebSocket = @import("webapi/net/WebSocket.zig");
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;

const http = @import("../network/http.zig");
const Robots = @import("../network/Robots.zig");
const Network = @import("../network/Network.zig");

const log = lp.log;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const IS_DEBUG = builtin.mode == .Debug;

pub const Method = http.Method;
pub const Headers = http.Headers;
pub const ResponseHead = http.ResponseHead;
pub const HeaderIterator = http.HeaderIterator;
const CachedResponse = @import("../network/cache/Cache.zig").CachedResponse;

pub const CacheLayer = @import("../network/layer/CacheLayer.zig");
pub const RobotsLayer = @import("../network/layer/RobotsLayer.zig");
pub const WebBotAuthLayer = @import("../network/layer/WebBotAuthLayer.zig");
pub const InterceptionLayer = @import("../network/layer/InterceptionLayer.zig");

// This is loosely tied to a browser Frame. Loading all the <scripts>, doing
// XHR requests, and loading imports all happens through here. Sine the app
// currently supports 1 browser and 1 frame at-a-time, we only have 1 Client and
// re-use it from frame to frame. This allows us better re-use of the various
// buffers/caches (including keepalive connections) that libcurl has.
//
// The app has other secondary http needs, like telemetry. While we want to
// share some things (namely the ca blob, and maybe some configuration
// (TODO: ??? should proxy settings be global ???)), we're able to call
// client.abortList() to abort the transfers being made by a frame, without
// impacting those other http requests.
pub const Client = @This();

// Conns active in the multi (or about to enter). Iterated by abort /
// setTlsVerify. A conn enters here when the worker calls `submitConn`
// and exits when `finishConn` runs (after the terminal completion has
// been drained from the inbox).
in_use: std.DoublyLinkedList = .{},
http_active: usize = 0,
ws_active: usize = 0,

// Use to generate the next request ID
next_request_id: u32 = 0,

// Every currently-alive Transfer indexed by its id. Maintained so cross-
// component code (CDP intercept state, future scheduling/debugging) can
// look up a transfer by id without holding a *Transfer that might dangle.
// Inserted in Client.request, removed in Transfer.deinit. The pointer is
// only valid for the lifetime of the entry.
transfers: std.AutoHashMapUnmanaged(u32, *Transfer) = .empty,

// Transfers waiting for a free Connection from the Network pool. Drained
// in tick().
queue: std.DoublyLinkedList = .{},

// Per-worker inbox. The network thread pushes events here (HTTP
// completions, WS frame events, CDP socket bytes); the worker drains
// via `inbox.next(timeout_ms)` from its outer loop.
inbox: Inbox,

// The main app allocator
allocator: Allocator,

network: *Network,

arena_pool: *ArenaPool,

// The current proxy. CDP can change it, changeProxy(null) restores
// from config.
http_proxy: ?[:0]const u8 = null,

// track if the client use a proxy for connections.
// We can't use http_proxy because we want also to track proxy configured via
// CDP.
use_proxy: bool,

// Current TLS verification state, applied per-connection in makeRequest.
tls_verify: bool = true,

obey_robots: bool,

// User agent override set via CDP Emulation.setUserAgentOverride.
// When set, takes precedence over the config's http_headers values.
// Both fields are allocated from self.allocator when set, null otherwise.
user_agent_override: ?[:0]const u8 = null,
user_agent_header_override: ?[:0]const u8 = null,

cdp_client: ?CDPClient = null,

max_response_size: usize,

cache_layer: CacheLayer,
robots_layer: RobotsLayer,
web_bot_auth_layer: WebBotAuthLayer,
interception_layer: InterceptionLayer,
entry_layer: Layer,

pub const Layer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (*anyopaque, *Transfer) anyerror!void,
    };

    pub fn request(self: Layer, transfer: *Transfer) !void {
        return self.vtable.request(self.ptr, transfer);
    }
};

fn layerWith(self: anytype, next: Layer) Layer {
    self.next = next;
    return self.layer();
}

// libcurl can monitor arbitrary sockets, this lets us use libcurl to poll
// both HTTP data as well as messages from an CDP connection.
// Furthermore, we have some tension between blocking scripts and request
// interception. For non-blocking scripts, because nothing blocks, we can
// just queue the scripts until we receive a response to the interception
// notification. But for blocking scripts (which block the parser), it's hard
// to return control back to the CDP loop. So the `read` function pointer is
// used by the Client to have the CDP client read more data from the socket,
// specifically when we're waiting for a request interception response to
// a blocking script.
pub const CDPClient = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    // Fired from the worker thread when CDP bytes arrive in the
    // inbox (the network thread did the read; we just hand the
    // bytes back to CDP for ws framing + command dispatch).
    on_data: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    // Fired from the worker thread when the CDP socket has been
    // closed / EOF'd / errored on the network thread side. After
    // this fires, no more on_data will arrive for this connection.
    on_disconnect: *const fn (ctx: *anyopaque) void,

    blocking_read_start: *const fn (*anyopaque) bool,
    blocking_read: *const fn (*anyopaque) bool,
    blocking_read_end: *const fn (*anyopaque) bool,
};

pub fn init(self: *Client, allocator: Allocator, network: *Network, cdp_client: ?CDPClient) !void {
    const http_proxy = network.config.httpProxy();

    self.* = Client{
        .network = network,
        .allocator = allocator,
        .cdp_client = cdp_client,
        .inbox = .init(allocator),

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .obey_robots = network.config.obeyRobots(),
        .max_response_size = network.config.httpMaxResponseSize() orelse std.math.maxInt(u32),

        .cache_layer = .{},
        .robots_layer = .{ .allocator = allocator, .network = network },
        .web_bot_auth_layer = .{},
        .interception_layer = .{},
        .entry_layer = undefined,
        .arena_pool = &network.app.arena_pool,
    };

    var next = self.layer();

    if (network.config.obeyRobots()) {
        next = layerWith(&self.robots_layer, next);
    }

    if (network.config.httpCacheDir() != null) {
        next = layerWith(&self.cache_layer, next);
    }

    if (network.config.mode == .serve) {
        next = layerWith(&self.interception_layer, next);
    }

    if (network.config.webBotAuth() != null) {
        next = layerWith(&self.web_bot_auth_layer, next);
    }

    self.entry_layer = next;
}

pub fn deinit(self: *Client) void {
    self.abort();

    // abort() submitted a remove for every in-flight conn. The network
    // thread will deliver exactly one canceled completion per conn,
    // each one decrementing in_use via finishConn. We wait for those
    // acks before freeing anything libcurl callbacks could still reach.
    //
    // If the network thread has stopped (app shutdown), it won't ack
    // us; drive its queues ourselves first.
    var watchdog = std.time.Timer.start() catch unreachable;
    while (self.in_use.first != null) {
        if (self.network.shutdown.load(.acquire)) {
            self.network.drainPendingForShutdown();
        }
        _ = self.processInbox(5_000) catch {};
        if (watchdog.read() > 30 * std.time.ns_per_s) {
            lp.assert(false, "HttpClient.deinit: stuck draining cancellations", .{
                .http_active = self.http_active,
                .ws_active = self.ws_active,
            });
        }
    }

    self.inbox.deinit();
    self.clearUserAgentOverride();
    self.robots_layer.deinit(self.allocator);
    self.transfers.deinit(self.allocator);
}

// Look up a live transfer by its id. Returns null if the transfer has been
// destroyed. Use this — rather than holding *Transfer across yields — for
// any code path that's interleaved with the request lifecycle (CDP
// continueRequest/fulfill/abort, async cleanups).
pub fn findTransfer(self: *Client, id: u32) ?*Transfer {
    return self.transfers.get(id);
}

pub fn layer(self: *Client) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = _request },
    };
}

// Set a user agent override. Both the raw UA string and the pre-formatted
// "User-Agent: <ua>" header string are allocated from self.allocator.
pub fn setUserAgentOverride(self: *Client, ua: []const u8) !void {
    self.clearUserAgentOverride();
    const override = try self.allocator.dupeZ(u8, ua);
    errdefer self.allocator.free(override);
    const header = try std.fmt.allocPrintSentinel(self.allocator, "User-Agent: {s}", .{ua}, 0);
    self.user_agent_override = override;
    self.user_agent_header_override = header;
}

// Clear any user agent override, restoring the default from config.
pub fn clearUserAgentOverride(self: *Client) void {
    if (self.user_agent_override) |ua| {
        self.allocator.free(ua);
        self.user_agent_override = null;
    }
    if (self.user_agent_header_override) |uah| {
        self.allocator.free(uah);
        self.user_agent_header_override = null;
    }
}

// Enable TLS verification on all connections.
pub fn setTlsVerify(self: *Client, verify: bool) !void {
    // Remove inflight connections check on enable TLS b/c chromiumoxide calls
    // the command during navigate and Curl seems to accept it...

    var it = self.in_use.first;
    while (it) |node| : (it = node.next) {
        const conn: *http.Connection = @fieldParentPtr("_worker_node", node);
        self.network.submitTlsVerify(conn, verify, self.use_proxy);
    }

    self.tls_verify = verify;
}

// Restrictive since it'll only work if there are no inflight requests. In some
// cases, the libcurl documentation is clear that changing settings while a
// connection is inflight is undefined. It doesn't say anything about CURLOPT_PROXY,
// but better to be safe than sorry.
// For now, this restriction is ok, since it's only called by CDP on
// createBrowserContext, at which point, if we do have an active connection,
// that's probably a bug (a previous abort failed?). But if we need to call this
// at any point in time, it could be worth digging into libcurl to see if this
// can be changed at any point in the easy's lifecycle.
pub fn changeProxy(self: *Client, proxy: ?[:0]const u8) !void {
    try self.ensureNoActiveConnection();
    self.http_proxy = proxy orelse self.network.config.httpProxy();
    self.use_proxy = self.http_proxy != null;
}

pub fn newHeaders(self: *const Client) !http.Headers {
    const ua_header = self.user_agent_header_override orelse self.network.config.http_headers.user_agent_header;
    return http.Headers.init(ua_header);
}

pub fn getUserAgent(self: *const Client) [:0]const u8 {
    return self.user_agent_override orelse self.network.config.http_headers.user_agent;
}

pub fn abort(self: *Client) void {
    // Snapshot before killing: kill() -> deinit removes entries from
    // self.transfers, which would invalidate a live iterator.
    var snapshot = std.ArrayList(*Transfer).initCapacity(self.allocator, self.transfers.count()) catch @panic("OOM");
    defer snapshot.deinit(self.allocator);
    var it = self.transfers.valueIterator();
    while (it.next()) |t| {
        snapshot.appendAssumeCapacity(t.*);
    }

    for (snapshot.items) |t| {
        t.kill();
    }

    // After the kill loop:
    //   - self.queue is empty (queued transfers had no conn and
    //     deinit'd synchronously).
    //   - self.transfers and self.in_use may still hold entries for
    //     in-flight transfers waiting on their canceled completion.
    //     deinit's wait loop drains those.
    if (comptime IS_DEBUG) {
        std.debug.assert(self.queue.first == null);
    }
}

// Kill every transfer + websocket owned by `owner`. Used when the owner
// (Frame / WorkerGlobalScope) is being torn down. After this returns,
// every WebSocket is fully gone; HTTP transfers that were mid-perform may
// still be on `owner.transfers` (Transfer.kill defers their deinit), but
// they've been unlinked from the owner list via kill()'s deferred branch
// so the owner is free to die.
pub fn abortOwner(self: *Client, owner: *Owner) void {
    self.abortRequests(owner);
    var n = owner.websockets.first;
    while (n) |node| {
        n = node.next;
        const ws: *@import("webapi/net/WebSocket.zig") = @fieldParentPtr("_owner_node", node);
        ws.kill();
    }
    if (comptime IS_DEBUG) {
        std.debug.assert(owner.websockets.first == null);
    }
}

// HTTP-only variant. WebSockets survive (they're cross-document by
// design). Used by the navigation path that aborts in-flight resource
// loads for a frame but lets its WebSockets keep running.
pub fn abortRequests(_: *Client, owner: *Owner) void {
    var n = owner.transfers.first;
    while (n) |node| {
        n = node.next;
        const t: *Transfer = @fieldParentPtr("owner_node", node);
        t.kill();
    }
    // owner.transfers may still have entries: Transfer.kill defers
    // (flags `aborted` + noops callbacks) when called mid-perform and
    // only fully deinits later via processOneMessage. The deferred-branch
    // unlinks the node and clears Transfer.owner, so by the time the
    // owner itself is freed, no orphan transfer points at it.
}

pub fn tick(self: *Client, timeout_ms: u32) !PerformStatus {
    try self.drainQueue();
    const status = try self.perform(@intCast(timeout_ms));
    // perform/processMessages just released a batch of connections back to
    // the pool. Drain again so queued transfers can use them this tick
    // instead of waiting for the next runner iteration.
    try self.drainQueue();
    return status;
}

fn drainQueue(self: *Client) !void {
    while (self.queue.popFirst()) |queue_node| {
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);
        const conn = self.network.getConn() orelse {
            self.queue.prepend(queue_node);
            return;
        };
        // Cleared only after we've successfully obtained a connection;
        // if we put the node back, _queued stays true.
        transfer._queued = false;
        try self.makeRequest(conn, transfer);
    }
}

// last layer
pub fn _request(_: *anyopaque, transfer: *Transfer) !void {
    return transfer.client.process(transfer);
}

// Ownership contract: from the moment this function is entered, the
// HttpClient owns `req` — specifically `req.headers` (a curl_slist).
// On success, transfer.deinit eventually frees it. On any failure path
// inside this function, we free it before returning the error. Callers
// must NOT pair `request()` with their own `errdefer headers.deinit()`
// — that's a double-free.
pub fn request(self: *Client, req: Request, owner: ?*Owner) !void {
    const arena = self.arena_pool.acquire(.small, "Request.arena") catch |err| {
        req.headers.deinit();
        return err;
    };

    const transfer = arena.create(Transfer) catch |err| {
        req.headers.deinit();
        self.arena_pool.release(arena);
        return err;
    };

    transfer.* = .{
        .req = req,
        .client = self,
        .arena = arena,
        .id = self.incrReqId(),
        .start_time = timestamp(.monotonic),
        // owner is set AFTER we've actually appended to the owner list,
        // so transfer.deinit's `if (self.owner)` branch only fires when
        // we're truly linked. Otherwise we'd try to remove a node from
        // a list it was never in.
        .owner = null,
        .owner_node = .{},
    };

    // From here, transfer owns req+arena. Any subsequent failure flows
    // through transfer.deinit (or transfer.abort), which handles headers
    // via req.deinit. Do NOT free headers directly past this point.

    // Register for id-based lookup. putNoClobber would fail if request_id
    // collides (i.e. we've wrapped through 2^32 requests and the old
    // transfer is still alive — practically never).
    self.transfers.putNoClobber(self.allocator, transfer.id, transfer) catch |err| {
        transfer.deinit();
        return err;
    };

    if (owner) |o| {
        o.addTransfer(transfer);
        transfer.owner = o;
    }

    // From this point forward, the transfer owns `req` and `arena`. If the
    // layer chain fails before any layer commits the transfer to an external
    // owner (queue / multi handle / pending interception), we clean up here
    // via transfer.abort which fires error_callback and deinits.
    self.entry_layer.request(transfer) catch |err| {
        if (!transfer.loop_owned) {
            transfer.abort(err);
        }
        return err;
    };
}

const SyncContext = struct {
    allocator: Allocator,
    completion: union(enum) {
        in_progress: void,
        done: void,
        err: anyerror,
        shutdown: void,
    } = .in_progress,

    status: u16 = 0,
    body: std.ArrayList(u8),

    fn headerCallback(response: Response) anyerror!bool {
        const self: *SyncContext = @ptrCast(@alignCast(response.ctx));
        lp.assert(response.status() != null, "HttpClient.SyncRequest.headerCallback", .{ .value = response.status() });
        self.status = response.status().?;
        if (response.contentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.allocator, cl);
        }
        return true;
    }

    fn dataCallback(response: Response, data: []const u8) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(response.ctx));
        try self.body.appendSlice(self.allocator, data);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .done;
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .{ .err = err };
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .shutdown;
    }
};

pub fn syncRequest(self: *Client, allocator: Allocator, req: Request) !SyncResponse {
    var sync_ctx = SyncContext{ .allocator = allocator, .body = .empty };
    errdefer sync_ctx.body.deinit(allocator);

    var r = req;
    r.ctx = &sync_ctx;
    r.header_callback = SyncContext.headerCallback;
    r.data_callback = SyncContext.dataCallback;
    r.done_callback = SyncContext.doneCallback;
    r.error_callback = SyncContext.errorCallback;
    r.shutdown_callback = SyncContext.shutdownCallback;
    try self.request(r, null);

    while (sync_ctx.completion == .in_progress) {
        const status = try self.tick(200);
        log.debug(.http, "sync request tick", .{ .status = status });
        switch (status) {
            .cdp_socket => {
                const cdp = self.cdp_client.?;
                _ = cdp.blocking_read(cdp.ctx);
            },
            .normal => continue,
        }
    }

    switch (sync_ctx.completion) {
        .in_progress => @panic("Impossible to be in progress here."),
        .done, .shutdown => return .{
            .status = sync_ctx.status,
            .body = sync_ctx.body,
        },
        .err => |e| return e,
    }
}

// Above, request will not process if there's an interception request. In such
// cases, the interceptor is expected to call resume to continue the transfer
// or transfer.abort() to abort it.
fn process(self: *Client, transfer: *Transfer) !void {
    // submitConn → Network.submitAdd is always safe to call. The network
    // thread serializes mailbox processing, so there's no re-entrancy
    // risk that used to require the `performing` check.
    if (self.network.getConn()) |conn| {
        return self.makeRequest(conn, transfer);
    }
    self.queue.append(&transfer._node);
    transfer._queued = true;
    transfer.loop_owned = true;
}

pub fn nextReqId(self: *Client) u32 {
    return self.next_request_id +% 1;
}

pub fn incrReqId(self: *Client) u32 {
    const id = self.next_request_id +% 1;
    self.next_request_id = id;
    return id;
}

// Same restriction as changeProxy. Should be ok since this is only called on
// BrowserContext deinit.
pub fn restoreOriginalProxy(self: *Client) !void {
    try self.ensureNoActiveConnection();

    self.http_proxy = self.network.config.httpProxy();
    self.use_proxy = self.http_proxy != null;
}

fn makeRequest(self: *Client, conn: *http.Connection, transfer: *Transfer) anyerror!void {
    {
        // Reset per-response state for retries (auth challenge, queue).
        const auth = transfer._auth_challenge;
        transfer.reset();
        transfer._auth_challenge = auth;

        transfer._conn = conn;
        errdefer {
            transfer._conn = null;
            self.network.releaseConn(conn);
        }

        try transfer.configureConn(conn);
    }

    // submitConn tracks the conn in our in_use list and sends an .add
    // message to the network thread's inbox. From here, the transfer's
    // terminal cleanup happens when the canceled/done completion is
    // delivered back to our inbox.
    self.submitConn(conn);
    transfer.loop_owned = true;

    if (transfer.req.start_callback) |cb| {
        cb(Response.fromTransfer(transfer)) catch |err| {
            transfer.abort(err);
            return err;
        };
    }
}

// Kept for caller-API stability; `.cdp_socket` is no longer returned
// (CDP socket I/O migrated to the network thread — bytes arrive via
// the inbox and are dispatched inline to `cdp_client.on_data`).
pub const PerformStatus = enum {
    cdp_socket,
    normal,
};

fn perform(self: *Client, timeout_ms: c_int) anyerror!PerformStatus {
    // Drain anything already pending (non-blocking).
    _ = try self.processInbox(0);

    // Block waiting for an event. With CDP I/O on the network
    // thread, there's a single source of events (the inbox) — block
    // there if there's anything we're waiting on.
    if (self.in_use.first != null or self.cdp_client != null) {
        _ = try self.processInbox(@intCast(timeout_ms));
    }

    _ = try self.processInbox(0);
    return .normal;
}

// Used by deinit to drain canceled completions until in_use empties.
// Returns true if at least one message was processed.
fn processInbox(self: *Client, timeout_ms: u32) !bool {
    var processed = false;
    while (true) {
        const wait_ms: u32 = if (processed) 0 else timeout_ms;
        const msg = self.inbox.next(wait_ms) orelse break;
        processed = true;
        switch (msg) {
            .http_completion => |c| self.handleHttpCompletion(c.conn, c.err),
            .cdp_data => |bytes| {
                defer self.allocator.free(bytes);
                if (self.cdp_client) |cdp| {
                    cdp.on_data(cdp.ctx, bytes) catch |err| {
                        log.err(.http, "cdp on_data", .{ .err = err });
                    };
                }
            },
            .cdp_disconnect => {
                if (self.cdp_client) |cdp| cdp.on_disconnect(cdp.ctx);
            },
            .ws_open => |ws| ws.handleOpen() catch |err| {
                log.err(.websocket, "ws_open dispatch", .{ .err = err });
            },
            .ws_message => |m| {
                defer self.allocator.free(m.data);
                m.ws.handleMessage(m.data, m.frame_type) catch |err| {
                    log.err(.websocket, "ws_message dispatch", .{ .err = err });
                };
            },
        }
    }
    return processed;
}

fn handleHttpCompletion(self: *Client, conn: *http.Connection, err: ?anyerror) void {
    switch (conn.transport) {
        .http => |transfer| {
            const done = self.processOneMessage(conn, err, transfer) catch |perr| blk: {
                log.err(.http, "process_messages", .{ .err = perr, .req = transfer });
                transfer.requestFailed(perr, true);
                break :blk true;
            };
            if (done) transfer.deinit();
        },
        .websocket => |ws| {
            // ws_active gets decremented through the call to disconnected.
            if (err) |e| switch (e) {
                error.GotNothing, error.Canceled => ws.disconnected(null),
                else => ws.disconnected(e),
            } else ws.disconnected(null);
        },
        .none => {
            // The owner disowned this conn before the terminal
            // completion landed (WebSocket.cleanup's abort path clears
            // transport after submitRemoveAndWait). Release the conn
            // now — the owner's already torn down its state.
            self.finishConn(conn);
        },
    }
}

fn processOneMessage(self: *Client, conn: *http.Connection, err: ?anyerror, transfer: *Transfer) !bool {
    if (err == null or err.? == error.RecvError) {
        transfer.detectAuthChallenge(conn);
    }

    // In case of auth challenge
    // TODO give a way to configure the number of auth retries.
    if (transfer._auth_challenge != null and transfer._tries < 10) {
        var wait_for_interception = false;
        transfer.req.notification.dispatch(
            .http_request_auth_required,
            &.{ .transfer = transfer, .wait_for_interception = &wait_for_interception },
        );
        if (wait_for_interception) {
            self.interception_layer.intercepted += 1;
            if (comptime IS_DEBUG) {
                log.debug(.http, "wait for auth interception", .{ .intercepted = self.interception_layer.intercepted });
            }

            // Whether or not this is a blocking request, we're not going
            // to process it now. We can end the transfer, which will
            // release the easy handle back into the pool. The transfer
            // is still valid/alive (just has no handle).
            transfer.releaseConn();
            return false;
        }
    }

    // Redirect: reuse the same conn (preserve TCP state). The conn was
    // already removed from the multi by Network.processCompletions before
    // firing on_complete — we just reconfigure and submitAdd it back.
    // No _detached_conn dance needed: at this point the conn is fully
    // out of libcurl's view.
    if (err == null) {
        const status = try conn.getResponseCode();
        if (status >= 300 and status <= 399) {
            try transfer.handleRedirect();
            transfer.reset();
            try transfer.configureConn(conn);
            self.network.submitAdd(conn);
            return false;
        }
    }

    // Transfer is done (success or error). Caller owns deinit.
    // Return true = done (caller will deinit), false = continues (redirect/auth).

    // When the server closes the TLS connection without a close_notify alert,
    // BoringSSL reports RecvError. If we already received valid HTTP headers,
    // this is a normal end-of-body (the connection closure signals the end
    // of the response per HTTP/1.1 when there is no Content-Length).
    const is_conn_close_recv = blk: {
        const e = err orelse break :blk false;
        if (e != error.RecvError) break :blk false;
        const hdr = conn.getResponseHeader("connection", 0) orelse break :blk true;
        break :blk std.ascii.eqlIgnoreCase(hdr.value, "close");
    };

    // Block re-entrant abort from inside the user callback chain.
    transfer._performing = true;
    defer transfer._performing = false;

    if (err != null and !is_conn_close_recv) {
        transfer.requestFailed(transfer.res.callback_error orelse err.?, true);
        return true;
    }

    if (!transfer.res.header_done_called) {
        // In case of request w/o data, we need to call the header done
        // callback now.
        const proceed = try transfer.headerDoneCallback(conn);
        if (!proceed) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    const body = transfer.res.stream_buffer.items;
    if (body.len > 0) {
        try transfer.req.data_callback(Response.fromTransfer(transfer), body);
        if (transfer.isAborted()) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    // Release conn ASAP so it's available; some done_callbacks will
    // load more resources.
    transfer.releaseConn();

    try transfer.req.done_callback(transfer.req.ctx);

    return true;
}

// Track a conn as in-flight on this worker and send an .add message
// to the network thread. submitAdd is infallible (panics on OOM), so
// no rollback path is needed.
pub fn submitConn(self: *Client, conn: *http.Connection) void {
    self.in_use.append(&conn._worker_node);
    conn.in_use = true;
    conn.on_complete = httpCompletionCallback;
    switch (conn.transport) {
        .http => self.http_active += 1,
        .websocket => self.ws_active += 1,
        else => unreachable,
    }
    self.network.submitAdd(conn);
}

// Terminal cleanup. Called when a conn's final completion has been
// processed (the conn is provably out of the multi already): remove
// from in_use, decrement counter, return to pool.
pub fn finishConn(self: *Client, conn: *http.Connection) void {
    if (conn.in_use) self._untrack(conn);
    self.network.releaseConn(conn);
}

// Synchronous abort: the conn may still be in the multi, and the
// caller is about to free state that libcurl callbacks reference.
// Blocks until the network thread has removed the easy handle (no
// more callbacks will fire), then does the worker-side bookkeeping
// while transport still tells us which counter to decrement, then
// clears transport. The pool release is deferred to
// handleHttpCompletion's `.none` arm — any stale completion still in
// our inbox needs to land cleanly before the conn memory is recycled.
pub fn disownConn(self: *Client, conn: *http.Connection) void {
    self.network.submitRemoveAndWait(conn);
    self._untrack(conn);
    conn.transport = .none;
}

// in_use list removal + counter decrement. Caller decides whether to
// release the conn afterward (finishConn) or defer (disownConn).
fn _untrack(self: *Client, conn: *http.Connection) void {
    self.in_use.remove(&conn._worker_node);
    conn.in_use = false;
    switch (conn.transport) {
        .http => self.http_active -= 1,
        .websocket => self.ws_active -= 1,
        else => unreachable,
    }
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.http_active > 0 or self.ws_active > 0) {
        return error.InflightConnection;
    }
}

pub const Request = struct {
    pub const StartCallback = *const fn (response: Response) anyerror!void;
    pub const HeaderCallback = *const fn (response: Response) anyerror!bool;
    pub const DataCallback = *const fn (response: Response, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    pub const ResourceType = enum {
        document,
        xhr,
        script,
        fetch,

        // Allowed Values: Document, Stylesheet, Image, Media, Font, Script,
        // TextTrack, XHR, Fetch, Prefetch, EventSource, WebSocket, Manifest,
        // SignedExchange, Ping, CSPViolationReport, Preflight, FedCM, Other
        // https://chromedevtools.github.io/devtools-protocol/tot/Network/#type-ResourceType
        pub fn string(self: ResourceType) []const u8 {
            return switch (self) {
                .document => "Document",
                .xhr => "XHR",
                .script => "Script",
                .fetch => "Fetch",
            };
        }
    };

    frame_id: u32,
    loader_id: u32,
    method: Method,
    url: [:0]const u8,
    headers: http.Headers,
    body: ?[]const u8 = null,
    cookie_jar: ?*CookieJar,
    cookie_origin: [:0]const u8,
    resource_type: ResourceType,
    credentials: ?[:0]const u8 = null,
    notification: *Notification,
    timeout_ms: u32 = 0,
    skip_robots: bool = false,

    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?StartCallback = null,
    header_callback: HeaderCallback = Noop.headerCallback,
    data_callback: DataCallback = Noop.dataCallback,
    done_callback: DoneCallback = Noop.doneCallback,
    error_callback: ErrorCallback = Noop.errorCallback,
    shutdown_callback: ?ShutdownCallback = null,

    pub fn getCookieString(self: *Request, arena: Allocator) !?[:0]const u8 {
        const jar = self.cookie_jar orelse return null;
        var aw: std.Io.Writer.Allocating = .init(arena);
        try jar.forRequest(self.url, &aw.writer, .{
            .is_http = true,
            .origin_url = self.cookie_origin,
            .is_navigation = self.resource_type == .document,
        });
        const written = aw.written();
        if (written.len == 0) return null;
        try aw.writer.writeByte(0);
        return written.ptr[0..written.len :0];
    }

    pub fn deinit(self: *const Request) void {
        self.headers.deinit();
    }
};

pub const FulfilledResponse = struct {
    status: u16,
    url: [:0]const u8,
    headers: []const http.Header,
    body: ?[]const u8,

    pub fn contentType(self: *const FulfilledResponse) ?[]const u8 {
        for (self.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) return hdr.value;
        }
        return null;
    }
};

pub const Response = struct {
    ctx: *anyopaque,
    inner: union(enum) {
        transfer: *Transfer,
        cached: *const CachedResponse,
        fulfilled: *const FulfilledResponse,
    },

    pub fn fromTransfer(transfer: *Transfer) Response {
        return .{ .ctx = transfer.req.ctx, .inner = .{ .transfer = transfer } };
    }

    pub fn fromCached(ctx: *anyopaque, resp: *const CachedResponse) Response {
        return .{ .ctx = ctx, .inner = .{ .cached = resp } };
    }

    pub fn fromFulfilled(ctx: *anyopaque, fulfilled: *const FulfilledResponse) Response {
        return .{ .ctx = ctx, .inner = .{ .fulfilled = fulfilled } };
    }

    pub fn status(self: Response) ?u16 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.status else null,
            .cached => |c| c.metadata.status,
            .fulfilled => |f| f.status,
        };
    }

    pub fn contentType(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |*rh| rh.contentType() else null,
            .cached => |c| c.metadata.content_type,
            .fulfilled => |f| f.contentType(),
        };
    }

    pub fn contentLength(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| t.getContentLength(),
            .cached => |c| switch (c.data) {
                .buffer => |buf| @intCast(buf.len),
                .file => |f| @intCast(f.len),
            },
            .fulfilled => |f| if (f.body) |b| @intCast(b.len) else null,
        };
    }

    pub fn redirectCount(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.redirect_count else null,
            .cached, .fulfilled => 0,
        };
    }

    pub fn url(self: Response) [:0]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.req.url,
            .cached => |c| c.metadata.url,
            .fulfilled => |f| f.url,
        };
    }

    pub fn headerIterator(self: Response) HeaderIterator {
        return switch (self.inner) {
            .transfer => |t| t.responseHeaderIterator(),
            .cached => |c| HeaderIterator{ .list = .{ .list = c.metadata.headers } },
            .fulfilled => |f| HeaderIterator{ .list = .{ .list = f.headers } },
        };
    }

    pub fn abort(self: Response, err: anyerror) void {
        switch (self.inner) {
            .transfer => |t| t.abort(err),
            .cached, .fulfilled => {},
        }
    }

    pub fn format(self: Response, writer: *std.Io.Writer) !void {
        return switch (self.inner) {
            .transfer => |t| try t.format(writer),
            .cached => |c| try c.format(writer),
            .fulfilled => |f| try writer.print("fulfilled {s}", .{f.url}),
        };
    }
};

pub const SyncResponse = struct {
    status: u16,
    body: std.ArrayList(u8),

    pub fn deinit(self: *SyncResponse, allocator: Allocator) void {
        self.body.deinit(allocator);
    }
};

pub const Transfer = struct {
    id: u32 = 0,
    arena: Allocator,

    owner: ?*Owner,
    owner_node: std.DoublyLinkedList.Node = .{},

    // Latched true by the first commit point that hands the transfer off to
    // an external owner: client.queue.append, successful trackConn, or
    // InterceptionLayer pausing for a CDP response. Once set, Client.request's
    // errdefer skips cleanup — whoever now owns the transfer will deinit it.
    loop_owned: bool = false,

    // True iff `_node` is currently linked in `client.queue` (waiting for a
    // libcurl handle). Set in `Client.process` on enqueue, cleared in
    // `Client.tick` on popFirst, and used by `Transfer.deinit` to safely
    // unlink — `deinit` has no other way to detect queue membership, and
    // a transfer aborted while queued (e.g. via owner-list abort) would
    // otherwise leave a dangling `_node` in `client.queue` that the next
    // `tick` would dereference and hand to libcurl.
    _queued: bool = false,

    req: Request,
    res: Transfer.Response = .{},
    client: *Client,

    start_time: u64,
    // Atomic because the libcurl data/header callbacks (running on the
    // network thread) read it to bail out early when the worker has
    // aborted us.
    aborted: std.atomic.Value(bool) = .init(false),

    _notified_fail: bool = false,

    _conn: ?*http.Connection = null,

    _auth_challenge: ?http.AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,
    // True while this transfer is inside its processOneMessage callback
    // chain on the worker. Blocks re-entrant abort/kill from deiniting
    // out from under the chain.
    _performing: bool = false,
    _redirect_count: u8 = 0,

    // for when a Transfer is queued in the client.queue
    _node: std.DoublyLinkedList.Node = .{},

    pub fn isAborted(self: *const Transfer) bool {
        return self.aborted.load(.acquire);
    }

    fn setAborted(self: *Transfer) void {
        self.aborted.store(true, .release);
    }

    fn releaseConn(self: *Transfer) void {
        if (self._conn) |conn| {
            self.client.finishConn(conn);
            self._conn = null;
        }
    }

    pub fn deinit(self: *Transfer) void {
        if (self._conn) |conn| {
            self.client.finishConn(conn);
            self._conn = null;
        }

        // Unlink from client.queue if we were waiting for a handle.
        // Without this, deinit'ing a queued transfer (e.g. via owner-list
        // abort during navigation) leaves a dangling _node in the queue
        // that the next tick would pop and hand to libcurl → UAF.
        if (self._queued) {
            self.client.queue.remove(&self._node);
            self._queued = false;
        }

        // Drop the id→*Transfer index entry before freeing the memory.
        // Any concurrent CDP lookup by id will now see this transfer as gone.
        _ = self.client.transfers.remove(self.id);

        self.req.deinit();
        if (self.owner) |o| {
            o.removeTransfer(self);
        }
        // The Transfer itself lives on this arena, so this must be last —
        // `self` is invalid memory after release.
        const arena_pool = self.client.arena_pool;
        const arena = self.arena;
        arena_pool.release(arena);
    }

    // Cancel this transfer with `err`. Fires error_callback once (latched
    // via _notified_fail), then either deinits synchronously or, if we
    // have a libcurl handle, submits a remove to the network thread and
    // lets the canceled completion drive the deinit from processOneMessage.
    pub fn abort(self: *Transfer, err: anyerror) void {
        self.requestFailed(err, true);
        self.detachOrDeinit();
    }

    // Owner-driven teardown: fires shutdown_callback (not error_callback)
    // and otherwise behaves like abort.
    fn kill(self: *Transfer) void {
        if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }
        self.detachOrDeinit();
    }

    // Three cases:
    //   1. `_performing` — we're inside our own processOneMessage callback
    //      chain on this worker. It will call deinit when it returns;
    //      deiniting here would double-free. Detach (noop callbacks, flag
    //      aborted, unlink from owner) so anything the chain still does
    //      is a no-op, then return.
    //   2. We have a libcurl handle in the multi — submit a remove. The
    //      network thread will fire a canceled completion that lands in
    //      our inbox; processOneMessage will deinit then. Detach now so
    //      no user callbacks fire in the meantime.
    //   3. No handle and no in-flight callback (queued / parked / never
    //      submitted). Deinit synchronously.
    fn detachOrDeinit(self: *Transfer) void {
        if (self._performing) {
            self.detachInPerform();
            return;
        }
        if (self._conn) |conn| {
            self.detachInPerform();
            self.client.network.submitRemove(conn);
            return;
        }
        self.deinit();
    }

    // Detach state used by the two "leave the transfer alive while we
    // wait for libcurl to be done with it" paths:
    //   - flag `aborted` so the libcurl data/header callbacks (running
    //     on the network thread) bail out early,
    //   - noop every user callback so anything still firing is a no-op,
    //   - unlink from owner.transfers and clear `owner` so the owning
    //     Frame/WGS can be freed while this transfer is still draining.
    //     transfer.deinit (called later by processOneMessage) sees
    //     `owner == null` and skips the list-remove that would otherwise
    //     UAF against a freed list.
    fn detachInPerform(self: *Transfer) void {
        self.setAborted();
        self.req.start_callback = null;
        self.req.shutdown_callback = null;
        self.req.header_callback = Noop.headerCallback;
        self.req.data_callback = Noop.dataCallback;
        self.req.done_callback = Noop.doneCallback;
        self.req.error_callback = Noop.errorCallback;
        if (self.owner) |o| {
            o.removeTransfer(self);
            self.owner = null;
        }
    }

    // Internal failure-notification helper. Latches via _notified_fail so
    // multiple paths racing to report the same failure only fire one
    // notification. Goes through transfer.req — so layer wrappers
    // (InterceptContext, CacheContext) see the failure and can propagate
    // it up the chain.
    //
    // Not part of the external API: callers cancelling a transfer should
    // use transfer.abort(err) instead, which goes through this and also
    // handles the deinit / detach side. The internal HttpClient flow uses
    // this directly (from processOneMessage) because it's already paired
    // with the natural processMessages → transfer.deinit handoff.
    //
    // execute_callback=true → fires error_callback. false → fires
    // shutdown_callback (used by Frame shutdown / WGS teardown).
    fn requestFailed(self: *Transfer, err: anyerror, comptime execute_callback: bool) void {
        if (self._notified_fail) return;
        self._notified_fail = true;

        if (execute_callback) {
            self.req.error_callback(self.req.ctx, err);
        } else if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }
    }

    fn configureConn(self: *Transfer, conn: *http.Connection) anyerror!void {
        const client = self.client;
        const req = &self.req;

        // Set callbacks and per-client settings on the pooled connection.
        try conn.setWriteCallback(Transfer.dataCallback);
        try conn.setFollowLocation(false);
        try conn.setProxy(client.http_proxy);
        try conn.setTlsVerify(client.tls_verify, client.use_proxy);

        try conn.setURL(req.url);
        try conn.setMethod(req.method);
        if (req.body) |b| {
            try conn.setBody(b);
        } else {
            try conn.setGetMode();
        }

        var header_list = req.headers;
        try conn.secretHeaders(&header_list, &client.network.config.http_headers);
        try conn.setHeaders(&header_list);

        // Add cookies from cookie jar.
        if (try self.req.getCookieString(self.arena)) |cookies| {
            try conn.setCookies(@ptrCast(cookies.ptr));
        }

        conn.transport = .{ .http = self };

        // Per-request timeout override (e.g. XHR timeout)
        if (req.timeout_ms > 0) {
            try conn.setTimeout(req.timeout_ms);
        }

        // add credentials
        if (req.credentials) |creds| {
            if (self._auth_challenge != null and self._auth_challenge.?.source == .proxy) {
                try conn.setProxyCredentials(creds);
            } else {
                try conn.setCredentials(creds);
            }
        }
    }

    pub fn reset(self: *Transfer) void {
        // Note: do NOT reset _auth_challenge or _redirect_count here. They
        // span retries — _auth_challenge tells makeRequest whether to use
        // setProxyCredentials vs setCredentials; _redirect_count caps the
        // total hops. The rest of the response state is per-attempt.
        self._notified_fail = false;
        self._tries += 1;
        self.res.stream_buffer.clearRetainingCapacity();
        self.res = .{ .stream_buffer = self.res.stream_buffer };
    }

    fn buildResponseHeader(self: *Transfer, conn: *const http.Connection) !void {
        if (comptime IS_DEBUG) {
            std.debug.assert(self.res.header == null);
        }

        const url = try conn.getEffectiveUrl();

        const status: u16 = if (self._auth_challenge != null)
            407
        else
            try conn.getResponseCode();

        self.res.header = .{
            .url = url,
            .status = status,
            .redirect_count = self._redirect_count,
        };

        if (conn.getResponseHeader("content-type", 0)) |ct| {
            var hdr = &self.res.header.?;
            const value = ct.value;
            const len = @min(value.len, ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        const req = self.req;
        return writer.print("{s} {s}", .{ @tagName(req.method), req.url });
    }

    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        self.req.url = url;
    }

    fn handleRedirect(transfer: *Transfer) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;
        const arena = transfer.arena;

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        // retrieve cookies from the redirect's response.
        if (req.cookie_jar) |jar| {
            var i: usize = 0;
            while (conn.getResponseHeader("set-cookie", i)) |ct| : (i += 1) {
                try jar.populateFromResponse(transfer.req.url, ct.value);

                if (i >= ct.amount) {
                    break;
                }
            }
        }

        // resolve the redirect target.
        const location = conn.getResponseHeader("location", 0) orelse {
            return error.LocationNotFound;
        };

        const url: [:0]const u8 = blk: {
            if (location.value.len == 0) {
                // Might seem silly, but URL.resovle will return location.value as-is
                // if empty, and location.value is memory owned by libcurl.
                break :blk "";
            }

            const base_url = try conn.getEffectiveUrl();
            const resolved = try URL.resolve(arena, std.mem.span(base_url), location.value, .{});

            // RFC 7231 §7.1.2: if the Location value has no fragment, the redirect
            // inherits the fragment from the URI used to generate the request.
            // URL.resolve follows RFC 3986 §5.3, which drops the base fragment when
            // the relative ref has none, so we re-attach it here.
            if (URL.getHash(resolved).len == 0) {
                const original_hash = URL.getHash(transfer.req.url);
                if (original_hash.len != 0) {
                    break :blk try std.mem.joinZ(arena, "", &.{ resolved, original_hash });
                }
            }
            break :blk resolved;
        };

        try transfer.updateURL(url);
        // 301, 302, 303 → change to GET, drop body.
        // 307, 308 → keep method and body.
        const status = try conn.getResponseCode();
        if (status == 301 or status == 302 or status == 303) {
            req.method = .GET;
            req.body = null;
        }
    }

    fn detectAuthChallenge(transfer: *Transfer, conn: *const http.Connection) void {
        const status = conn.getResponseCode() catch return;
        const connect_status = conn.getConnectCode() catch return;

        if (status != 401 and status != 407 and connect_status != 401 and connect_status != 407) {
            transfer._auth_challenge = null;
            return;
        }

        if (conn.getResponseHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getConnectHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getResponseHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else if (conn.getConnectHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else {
            transfer._auth_challenge = .{ .status = status, .source = null, .scheme = null, .realm = null };
        }
    }

    pub fn updateCredentials(self: *Transfer, userpwd: [:0]const u8) void {
        self.req.credentials = userpwd;
    }

    pub fn replaceRequestHeaders(self: *Transfer, allocator: Allocator, headers: []const http.Header) !void {
        self.req.headers.deinit();

        var buf: std.ArrayList(u8) = .empty;
        var new_headers = try self.client.newHeaders();
        for (headers) |hdr| {
            // safe to re-use this buffer, because Headers.add because curl copies
            // the value we pass into curl_slist_append.
            defer buf.clearRetainingCapacity();
            try std.fmt.format(buf.writer(allocator), "{s}: {s}", .{ hdr.name, hdr.value });
            try buf.append(allocator, 0); // null terminated
            try new_headers.add(buf.items[0 .. buf.items.len - 1 :0]);
        }
        self.req.headers = new_headers;
    }

    // abortAuthChallenge is called when an auth challenge interception is
    // abort. We don't call self.releaseConn here b/c it has been done
    // before interception process.
    pub fn abortAuthChallenge(self: *Transfer) void {
        if (comptime IS_DEBUG) {
            log.debug(.http, "abort auth transfer", .{ .intercepted = self.client.interception_layer.intercepted });
        }

        self.client.interception_layer.intercepted -= 1;
        self.abort(error.AbortAuthChallenge);
        return;
    }

    // headerDoneCallback is called once the headers have been read.
    // It can be called either on dataCallback or once the request for those
    // w/o body.
    fn headerDoneCallback(transfer: *Transfer, conn: *const http.Connection) !bool {
        lp.assert(transfer.res.header_done_called == false, "Transfer.headerDoneCallback", .{});
        defer transfer.res.header_done_called = true;

        try transfer.buildResponseHeader(conn);

        if (transfer.req.cookie_jar) |jar| {
            var i: usize = 0;
            while (true) {
                const ct = conn.getResponseHeader("set-cookie", i);
                if (ct == null) break;
                jar.populateFromResponse(transfer.req.url, ct.?.value) catch |err| {
                    log.err(.http, "set cookie", .{ .err = err, .req = transfer });
                    return err;
                };
                i += 1;
                if (i >= ct.?.amount) break;
            }
        }

        if (transfer.getContentLength()) |cl| {
            if (cl > transfer.client.max_response_size) {
                return error.ResponseTooLarge;
            }
        }

        const proceed = transfer.req.header_callback(Client.Response.fromTransfer(transfer)) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        return proceed and !transfer.isAborted();
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) usize {
        // libcurl should only ever emit 1 chunk at a time
        if (comptime IS_DEBUG) {
            std.debug.assert(chunk_count == 1);
        }

        const conn: *http.Connection = @ptrCast(@alignCast(data));
        var transfer = conn.transport.http;
        const res = &transfer.res;

        if (!res.first_data_received) {
            res.first_data_received = true;

            // Skip body for responses that will be retried (redirects, auth challenges).
            const status = conn.getResponseCode() catch |err| {
                log.err(.http, "getResponseCode", .{ .err = err, .source = "body callback" });
                return http.writefunc_error;
            };
            if ((status >= 300 and status <= 399) or status == 401 or status == 407) {
                res.skip_body = true;
                return @intCast(chunk_len);
            }

            // Pre-size buffer from Content-Length.
            if (transfer.getContentLength()) |cl| {
                if (cl > transfer.client.max_response_size) {
                    res.callback_error = error.ResponseTooLarge;
                    return http.writefunc_error;
                }
                res.stream_buffer.ensureTotalCapacity(transfer.arena, cl) catch {};
            }
        }

        if (res.skip_body) return @intCast(chunk_len);

        res.bytes_received += chunk_len;
        if (res.bytes_received > transfer.client.max_response_size) {
            res.callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        const chunk = buffer[0..chunk_len];
        res.stream_buffer.appendSlice(transfer.arena, chunk) catch |err| {
            res.callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.isAborted()) {
            return http.writefunc_error;
        }

        return @intCast(chunk_len);
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        // We always have a real curl request here. We handle injection up in InterceptionLayer.
        lp.assert(self._conn != null, "Transfer.responseHeaderIterator", .{ .value = self._conn != null });
        const conn = self._conn.?;

        // If we have a connection, than this is a real curl request and we
        // iterate through the header that curl maintains.
        return .{ .curl = .{ .conn = conn } };
    }

    // This function should be called during the dataCallback. Calling it after
    // such as in the doneCallback is guaranteed to return null.
    pub fn getContentLength(self: *const Transfer) ?u32 {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(u32, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        if (self._conn) |conn| {
            // If we have a connection, than this is a normal request. We can get the
            // header value from the connection.
            const cl = conn.getResponseHeader("content-length", 0) orelse return null;
            return cl.value;
        }

        // If we have no handle, then maybe this is being called after the
        // doneCallback. OR, maybe this is a "fulfilled" request. Let's check
        // the injected headers (if we have any).

        const rh = self.res.header orelse return null;
        for (rh._injected_headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        return null;
    }

    // Response-state owned by this transfer's currently-in-flight response.
    // Reset on every retry (auth retry, redirect) via Transfer.reset — only
    // the cross-retry counters (_auth_challenge, _redirect_count) live on
    // Transfer itself. `Transfer.Response` is the on-Transfer storage; the
    // top-level `Client.Response` is the actual Response (which is a union, e.g.
    // for a cached response)
    const Response = struct {
        header: ?ResponseHead = null,

        // total bytes received in the response, including the response status
        // line, the headers, and the [encoded] body.
        bytes_received: usize = 0,

        // track if the header callbacks done have been called.
        header_done_called: bool = false,

        skip_body: bool = false,
        first_data_received: bool = false,

        // Buffered response body. Filled by dataCallback, consumed in processMessages.
        stream_buffer: std.ArrayList(u8) = .{},

        // Error captured in dataCallback to be reported in processMessages.
        callback_error: ?anyerror = null,
    };
};

pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.interception_layer.intercepted > 0, "HttpClient.continueTransfer", .{ .value = self.interception_layer.intercepted });
        log.debug(.http, "continue transfer", .{ .intercepted = self.interception_layer.intercepted });
    }

    self.interception_layer.intercepted -= 1;
    return self.process(transfer);
}

const Noop = struct {
    fn headerCallback(_: Response) !bool {
        return true;
    }
    fn dataCallback(_: Response, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

// An opaque-from-the-outside handle that Frame / WorkerGlobalScope embed
// to track the HTTP transfers + WebSockets they own.
pub const Owner = struct {
    transfers: std.DoublyLinkedList = .{},
    websockets: std.DoublyLinkedList = .{},

    pub fn addTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.append(&t.owner_node);
    }

    pub fn removeTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.remove(&t.owner_node);
    }

    pub fn addWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.append(&ws._owner_node);
    }

    pub fn removeWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.remove(&ws._owner_node);
    }
};

// ── Inbox ────────────────────────────────────────────────────────────────────
//
// Per-worker mailbox. The network thread pushes events here; the worker
// drains via `next()` from `Client.perform`. Same OTP-style queue
// pattern as `Network.inbox`, but the directions are reversed (network
// thread is the producer, worker is the consumer) and the wake
// primitive is a pipe (so the worker can poll it alongside other fds —
// the CDP socket today, removable once CDP I/O migrates fully).

pub const InMessage = union(enum) {
    http_completion: HttpCompletion,

    // CDP socket bytes read by the network thread. The slice is
    // heap-allocated from `Client.allocator`; the worker frees it
    // after dispatching to `cdp_client.on_data`.
    cdp_data: []u8,
    // CDP socket EOF / error / unregister ack from the network thread.
    cdp_disconnect,

    // WebSocket open handshake completed. The network thread observed
    // the upgrade headers and set `_ready_state = .open`; the worker
    // dispatches the JS open event.
    ws_open: *WebSocket,
    // WebSocket text/binary frame fully assembled. `data` is
    // heap-allocated from `Client.allocator` (copied off the libcurl
    // buffer); the worker frees it after dispatching the JS message
    // event.
    ws_message: WsMessage,
    // NOTE: there is no `ws_disconnect`/`ws_close` variant. The
    // close-handshake completion (whether the server initiates or we
    // do) flows through libcurl's natural termination — the WS conn
    // completes, fires the normal HTTP-style completion, and
    // handleHttpCompletion's `.websocket` arm dispatches via
    // `ws.disconnected` on the worker. Avoids duplicating the path.

    pub const HttpCompletion = struct {
        conn: *http.Connection,
        err: ?anyerror,
    };

    pub const WsMessage = struct {
        ws: *WebSocket,
        data: []u8,
        frame_type: http.WsFrameType,
    };
};

pub const Inbox = struct {
    // The allocator backing both the item pool and cdp_data byte
    // allocations. Stashed so deinit can free undrained cdp_data
    // slices before tearing down the pool itself.
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    queue: std.DoublyLinkedList = .{},
    pool: std.heap.MemoryPool(Item),
    wake_pipe: [2]posix.fd_t = .{ -1, -1 },

    const Item = struct {
        msg: InMessage,
        node: std.DoublyLinkedList.Node = .{},
    };

    pub fn init(allocator: Allocator) Inbox {
        const pipe = posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) catch |err| {
            lp.assert(false, "inbox pipe create", .{ .err = err });
            unreachable;
        };
        return .{
            .allocator = allocator,
            .pool = .init(allocator),
            .wake_pipe = pipe,
        };
    }

    pub fn deinit(self: *Inbox) void {
        for (&self.wake_pipe) |*fd| {
            if (fd.* >= 0) {
                posix.close(fd.*);
                fd.* = -1;
            }
        }
        // Free any undrained heap-allocated payloads (cdp_data /
        // ws_message bytes) before the pool (which owns the Item
        // structs) goes away.
        while (self.queue.popFirst()) |node| {
            const item: *Item = @fieldParentPtr("node", node);
            switch (item.msg) {
                .cdp_data => |bytes| self.allocator.free(bytes),
                .ws_message => |msg| self.allocator.free(msg.data),
                else => {},
            }
        }
        self.pool.deinit();
    }

    // Returns the read end of the wake pipe so the caller can include it
    // in a poll set (alongside the CDP socket for now).
    pub fn pollFd(self: *const Inbox) posix.fd_t {
        return self.wake_pipe[0];
    }

    // Called from any thread (typically the network thread). Allocates a
    // queue item from the pool, appends it, wakes the worker via the pipe.
    pub fn push(self: *Inbox, msg: InMessage) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const item = try self.pool.create();
            item.* = .{ .msg = msg };
            self.queue.append(&item.node);
        }
        _ = posix.write(self.wake_pipe[1], &.{1}) catch {};
    }

    // Worker side. Pop next message, blocking up to `timeout_ms` (0 =
    // non-blocking). Returns null on timeout.
    pub fn next(self: *Inbox, timeout_ms: u32) ?InMessage {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.queue.popFirst()) |node| return self.takeItem(node);
        }

        if (timeout_ms == 0) return null;

        var fds = [_]posix.pollfd{
            .{ .fd = self.wake_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, @intCast(timeout_ms)) catch return null;

        if (fds[0].revents != 0) {
            var drain: [64]u8 = undefined;
            while (true) {
                _ = posix.read(self.wake_pipe[0], &drain) catch break;
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.popFirst()) |node| return self.takeItem(node);
        return null;
    }

    fn takeItem(self: *Inbox, node: *std.DoublyLinkedList.Node) InMessage {
        const item: *Item = @fieldParentPtr("node", node);
        const msg = item.msg;
        self.pool.destroy(item);
        return msg;
    }
};

// Set as `conn.on_complete` in `submitConn` for HTTP and WebSocket
// conns. Fired by the network thread post-completion; routes the
// completion to the owning HttpClient's inbox by inspecting transport.
fn httpCompletionCallback(conn: *http.Connection, err: ?anyerror) void {
    const client = switch (conn.transport) {
        .http => |t| t.client,
        .websocket => |ws| ws._http_client,
        .none => return,
    };
    client.inbox.push(.{ .http_completion = .{ .conn = conn, .err = err } }) catch |e| {
        log.err(.http, "inbox push failed", .{ .err = e });
        // OOM during completion delivery. Release the conn directly so
        // the pool isn't permanently down a slot; the worker won't see
        // the completion but its deinit watchdog will catch the stuck
        // in_use entry.
        client.network.releaseConn(conn);
    };
}

// ── CDP socket handoff ──────────────────────────────────────────────────────
//
// The CDP socket is read by the network thread on this HttpClient's
// behalf. Bytes are heap-copied per read and pushed to our inbox;
// the worker dispatches them inline through `cdp_client.on_data`.
// `cdp_client` itself must be set in `init` before registering.

// Hand the worker's CDP socket to the network thread for reading.
pub fn registerCdpSocket(self: *Client, fd: posix.fd_t) void {
    self.network.submitCdpRegister(fd, .{
        .ctx = self,
        .on_data = cdpNetData,
        .on_disconnect = cdpNetDisconnect,
    });
}

// Tell the network thread to stop reading the CDP socket. After the
// network processes this, it fires `on_disconnect` once — the worker
// uses that as the ack that it's safe to free its ctx.
pub fn unregisterCdpSocket(self: *Client, fd: posix.fd_t) void {
    self.network.submitCdpUnregister(fd);
}

// Network-thread side of CDP read. Copy + push.
fn cdpNetData(ctx: *anyopaque, data: []const u8) void {
    const self: *Client = @ptrCast(@alignCast(ctx));
    const owned = self.allocator.dupe(u8, data) catch |err| {
        log.err(.http, "cdp_data alloc failed", .{ .err = err });
        return;
    };
    self.inbox.push(.{ .cdp_data = owned }) catch |err| {
        log.err(.http, "cdp_data push failed", .{ .err = err });
        self.allocator.free(owned);
    };
}

fn cdpNetDisconnect(ctx: *anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ctx));
    self.inbox.push(.cdp_disconnect) catch |err| {
        log.err(.http, "cdp_disconnect push failed", .{ .err = err });
    };
}

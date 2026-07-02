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
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;

const http = @import("../network/http.zig");
const Network = @import("../network/Network.zig");

const CDP = @import("../cdp/CDP.zig");
const Inbox = @import("../Inbox.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

pub const Method = http.Method;
pub const Header = http.Header;
pub const Headers = http.Headers;
pub const ResponseHead = http.ResponseHead;
pub const HeaderIterator = http.HeaderIterator;
const CachedResponse = @import("../network/cache/Cache.zig").CachedResponse;

pub const CacheLayer = @import("../network/layer/CacheLayer.zig");
pub const RobotsLayer = @import("../network/layer/RobotsLayer.zig");
pub const WebBotAuthLayer = @import("../network/layer/WebBotAuthLayer.zig");
pub const InterceptionLayer = @import("../network/layer/InterceptionLayer.zig");
pub const DeferringLayer = @import("../network/layer/DeferringLayer.zig");

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

// Count of active ws requests
ws_active: usize = 0,

// Count of active http requests
http_active: usize = 0,

// Our curl multi handle.
handles: http.Handles,

// Connections currently in this client's curl_multi.
in_use: std.DoublyLinkedList = .{},

// Connections that failed to be removed from curl_multi during perform.
dirty: std.DoublyLinkedList = .{},

// Whether we're currently inside a curl_multi_perform call.
performing: bool = false,

// Use to generate the next request ID
next_request_id: u32 = 0,

// Every currently-alive Transfer indexed by its id. Maintained so cross-
// component code (CDP intercept state, future scheduling/debugging) can
// look up a transfer by id without holding a *Transfer that might dangle.
// Inserted in Client.request, removed in Transfer.deinit. The pointer is
// only valid for the lifetime of the entry.
transfers: std.AutoHashMapUnmanaged(u32, *Transfer) = .empty,

// When handles has no more available easys, requests get queued.
queue: std.DoublyLinkedList = .{},

// A queue for things that MUST happen on the next tick.
next_tick_queue: std.DoublyLinkedList = .{},
next_tick_count: usize = 0,

// Queue is for Transfers that have no connection. ready_queue is for connections
// that were initiated when performing == true and thus need to wait until
// performing == false before being added. I'm hoping this is temporary and that
// we can unify the two queues. But HTTP is being changed a lot right now, and
// I'm trying to minimize the surface area.
ready_queue: std.DoublyLinkedList = .{},

// The main app allocator
allocator: Allocator,

network: *Network,

arena_pool: *ArenaPool,

// The current proxy. Callers can change it, changeProxy(null) restores
// from config. May point either at `http_proxy_owned` (a caller-supplied
// dupe) or at the config string (which we must not free).
http_proxy: ?[:0]const u8 = null,

// When a caller (e.g. CDP) supplies a proxy, we have to dupe it to take ownership
// which we'll be responsible for freeing.
http_proxy_owned: ?[:0]const u8 = null,

// track if the client use a proxy for connections.
// We can't use http_proxy because we want also to track proxy configured via
// CDP.
use_proxy: bool,

// Current TLS verification state, applied per-connection in makeRequest.
tls_verify: bool = true,

// User agent override set via CDP Emulation.setUserAgentOverride.
// When set, takes precedence over the config's http_headers values.
// Both fields are allocated from self.allocator when set, null otherwise.
user_agent_override: ?[:0]const u8 = null,
user_agent_header_override: ?[:0]const u8 = null,

// The CDP layer we dispatch inbox messages to. Set in CDP.init for
// `serve` mode; null in all other modes. Since this is set early, BEFORE the
// CDP socket is registered with the network thread, we also have the
// `cdp_link_active` boolean.
cdp: ?*CDP = null,

// True iff a producer (Server.handleConnection, after the worker
// handshake completes) has registered the CDP socket with the Network
// thread and Network will fire curl_multi_wakeup on our multi handle
// when it pushes to the inbox. perform uses this — NOT `cdp != null`
// — to decide whether to block in poll without any in-flight curl
// work. cdp is set in CDP.init, well before the link is wired; tests
// and the pre-handshake window have a cdp but no producer, so polling
// there would just eat the timeout waiting for a wakeup that's never
// coming.
cdp_link_active: bool = false,

// CDP messages parsed off the WS socket by the Network thread land
// here. perform drains the inbox at each safe point and dispatches
// via cdp.onMessage / onPing / onClose / onDisconnect. Always present
// even in non-CDP mode — the empty-queue drain is one mutex lock plus
// a linked-list head check, cheaper than nullability everywhere.
inbox: Inbox,

max_response_size: usize,

blocking_requests: std.AutoHashMapUnmanaged(u32, u32) = .empty,

cache_layer: CacheLayer,
robots_layer: RobotsLayer,
web_bot_auth_layer: WebBotAuthLayer,
interception_layer: InterceptionLayer,
deferring_layer: DeferringLayer,
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

pub const NextTickNode = struct {
    pub const Run =
        *const fn (*Transfer, ?*anyopaque) void;
    pub const Abort = *const fn (?*anyopaque) void;

    node: std.DoublyLinkedList.Node = .{},
    ctx: ?*anyopaque,
    run: Run,
    abort: ?Abort = null,
};

pub fn init(self: *Client, allocator: Allocator, network: *Network, cdp: ?*CDP) !void {
    var handles = try http.Handles.init(network.config);
    errdefer handles.deinit();

    const http_proxy = network.config.httpProxy();

    self.* = Client{
        .handles = handles,
        .network = network,
        .allocator = allocator,
        .cdp = cdp,
        .inbox = .{},

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .max_response_size = network.config.httpMaxResponseSize() orelse std.math.maxInt(u32),

        .cache_layer = .{},
        .robots_layer = .{ .allocator = allocator, .network = network },
        .web_bot_auth_layer = .{},
        .interception_layer = .{},
        .deferring_layer = .{ .allocator = allocator, .network = network },
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

    next = layerWith(&self.deferring_layer, next);

    self.entry_layer = next;
}

pub fn deinit(self: *Client) void {
    self.abort();

    if (comptime IS_DEBUG) {
        lp.assert(
            self.next_tick_count == 0,
            "next_tick_count must be 0",
            .{ .value = self.next_tick_count },
        );
    }

    self.handles.deinit();

    self.clearUserAgentOverride();
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
    }

    self.robots_layer.deinit(self.allocator);
    self.deferring_layer.deinit();
    self.blocking_requests.deinit(self.allocator);
    self.transfers.deinit(self.allocator);
    self.inbox.deinit(self.arena_pool);
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
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try conn.setTlsVerify(verify, self.use_proxy);
    }

    it = self.ready_queue.first;
    while (it) |node| : (it = node.next) {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try conn.setTlsVerify(verify, self.use_proxy);
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

    // Free any previously-duped proxy before we overwrite http_proxy.
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
        self.http_proxy_owned = null;
    }

    // Reset to the config default; if dupeZ below fails, http_proxy is
    // left pointing at this rather than at the freed dup.
    self.http_proxy = self.network.config.httpProxy();

    if (proxy) |p| {
        const owned = try self.allocator.dupeZ(u8, p);
        self.http_proxy_owned = owned;
        self.http_proxy = owned;
    }
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

    // After the kill loop, every internal list should drain itself via
    // each transfer's deinit:
    //   - self.transfers : transfers.remove(self.id)
    //   - self.queue     : unlinked if _queued is set
    //   - self.in_use / self.ready_queue : via removeConn
    //   - self.dirty     : drained at end of each perform; nothing left here
    // Any non-empty list means a transfer escaped cleanup — assert so we
    // catch the regression rather than silently leaking on next use.
    if (comptime IS_DEBUG) {
        std.debug.assert(self.transfers.size == 0);
        std.debug.assert(self.queue.first == null);
        std.debug.assert(self.in_use.first == null);
        std.debug.assert(self.ready_queue.first == null);
        std.debug.assert(self.dirty.first == null);
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

// What CDP messages drainInbox is allowed to dispatch this tick.
//   .all       — outer event loop (Runner.tick). Safe to dispatch
//                everything; the JS stack is empty.
//   .sync_wait — reachable from inside a JS callback (syncRequest,
//                waitForImport). The JS callstack above us holds
//                refs to page / session / V8 state; dispatching a
//                command that frees that state would UAF on unwind.
//                Cherry-pick only Fetch interception responses
const DrainMode = enum { all, sync_wait };

pub fn tick(self: *Client, timeout_ms: u32, mode: DrainMode) !void {
    if (self.inbox.terminated) {
        return error.ClientDisconnected;
    }

    try self.drainNextTickQueue();
    try self.drainQueue();
    try self.perform(@intCast(timeout_ms));
    // perform/processMessages just released a batch of connections back to
    // the pool. Drain again so queued transfers can use them this tick
    // instead of waiting for the next runner iteration.
    try self.drainQueue();
    // Dispatch CDP messages here, not inside perform: perform recurses
    // via processOneMessage's redirect path (perform → processMessages
    // → processOneMessage → perform), and dispatching CDP from that
    // nested call would fire CDP handlers mid-redirect, defeating the
    // "safe points only" guarantee.
    try self.drainInbox(mode);
}

pub fn runNextTick(
    self: *Client,
    transfer: *Transfer,
    ctx: ?*anyopaque,
    params: struct { run: NextTickNode.Run, abort: ?NextTickNode.Abort = null },
) !void {
    transfer._next_tick_node = .{ .ctx = ctx, .run = params.run, .abort = params.abort };

    self.next_tick_count += 1;
    self.next_tick_queue.append(&transfer._next_tick_node.?.node);
}

fn cancelNextTick(self: *Client, transfer: *Transfer) void {
    if (transfer._next_tick_node) |*ntn| {
        self.next_tick_queue.remove(&ntn.node);
        self.next_tick_count -= 1;

        if (ntn.abort) |abort_cb| {
            abort_cb(ntn.ctx);
        }
    }
}

fn drainNextTickQueue(self: *Client) !void {
    var remaining = self.next_tick_count;
    while (remaining > 0) : (remaining -= 1) {
        const node = self.next_tick_queue.popFirst() orelse break;
        defer self.next_tick_count -= 1;
        const n: *NextTickNode = @fieldParentPtr("node", node);

        const transfer: *Transfer = @fieldParentPtr(
            "_next_tick_node",
            @as(*?NextTickNode, @ptrCast(n)),
        );

        const ntn = n.*;
        transfer._next_tick_node = null;
        ntn.run(transfer, ntn.ctx);
    }
}

fn drainQueue(self: *Client) !void {
    while (self.queue.popFirst()) |queue_node| {
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);
        const conn = self.network.getConnection() orelse {
            self.queue.prepend(queue_node);
            return;
        };
        // Bridge state to .created so a failure inside makeRequest before
        // any commit cleans up via the abort below. makeRequest flips to
        // .inflight on a successful trackConn.
        transfer.state = .created;
        self.makeRequest(conn, transfer) catch |err| {
            if (transfer.state == .created) {
                transfer.abort(err);
            }
            return err;
        };
    }
}

// last layer
pub fn _request(_: *anyopaque, transfer: *Transfer) !void {
    return transfer.client.process(transfer);
}

// HttpClient takes ownership of req.headers; do not pair with
// `errdefer headers.deinit()`
pub fn request(self: *Client, req: Request, owner: ?*Owner) !void {
    _ = try self.requestT(req, owner);
}

// Like `request`, but returns the created `*Transfer`. The caller does not own
// the returned `*Transfer` and must thus use it with care. From the moment this
// function is entered, the HttpClient owns `req` — specifically `req.headers`
// On success, transfer.deinit eventually frees it. On any failure path inside
// this function, we free it before returning the error.
fn requestT(self: *Client, req: Request, owner: ?*Owner) !*Transfer {
    const arena = self.arena_pool.acquire(.small, "Request.arena") catch |err| {
        req.headers.deinit();
        return err;
    };

    const transfer = blk: {
        errdefer {
            req.headers.deinit();
            self.arena_pool.release(arena);
        }

        var owned = req;
        // Most of the time, the req data will outlive the transfer. But not
        // always. The most problematic case is with a QueuedNavigation which
        // is freed quite quickly and would definetly not survive a queued
        // request.
        //
        // These are all small, so duping them into the transfer's arena is
        // cheap and can solve some nasty UAF.
        owned.url = try arena.dupeZ(u8, req.url);
        owned.cookie_origin = try arena.dupeZ(u8, req.cookie_origin);
        if (req.credentials) |c| {
            owned.credentials = try arena.dupeZ(u8, c);
        }

        // The body can be larger, so callers can signal, via the
        // `body_outlives_request` flag that they guarantee that the body
        // will outlive the transfer (and thus doesn't need to be duped)
        if (req.body) |b| {
            if (req.body_outlives_request == false) {
                owned.body = try arena.dupe(u8, b);
            }
        }

        const t = try arena.create(Transfer);
        t.* = .{
            .req = owned,
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
        break :blk t;
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
    // via transfer.abort which fires error_callback and deinits. `.created`
    // means no commit happened — anything else is held by an owner that
    // will clean up.

    // Synthetic schemes never touch the network or the layer chain — they skip
    // robots/cache/interception and deliver on the next tick
    if (Synthetic.isSynthetic(req.url)) {
        // The 2nd transfer is the callback context. We don't actually use it,
        // we're just sticking transfer in there to have something.
        self.runNextTick(transfer, null, .{ .run = Synthetic.run }) catch |err| {
            if (transfer.state == .created) {
                transfer.abort(err);
            }
            return err;
        };
        return transfer;
    }

    self.entry_layer.request(transfer) catch |err| {
        if (transfer.state == .created) {
            transfer.abort(err);
        }
        return err;
    };

    return transfer;
}

// Non-network URL schemes whose response is synthesized in-process rather than
// fetched, think blob data URLs.
const Synthetic = struct {
    const data_url = @import("data_url.zig");

    fn isSynthetic(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:");
    }

    fn run(transfer: *Transfer, _: ?*anyopaque) void {
        // prevents a callback that triggers a navigation queue from killing
        // this transfer from under us.
        transfer.state = .completing;
        defer transfer.deinit();

        const fulfilled = build(transfer) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
            return;
        };
        deliver(&transfer.req, &fulfilled) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
        };
    }

    fn build(transfer: *Transfer) !FulfilledResponse {
        const arena = transfer.arena;
        const url = transfer.req.url;

        var body: []const u8 = "";
        var content_type: []const u8 = "";

        if (std.mem.startsWith(u8, url, "data:")) {
            const parsed = try data_url.parse(arena, url);
            content_type = parsed.content_type;
            body = parsed.body;
        } else {
            // blob: — resolved against the owning frame's registry.
            const owner = transfer.owner orelse return error.BlobNotFound;
            const blob_urls = owner.blob_urls orelse return error.BlobNotFound;
            const blob = blob_urls.get(url) orelse return error.BlobNotFound;
            content_type = blob._mime;
            body = blob._slice;
        }

        // A blob with no type yields no Content-Type header.
        const headers = if (content_type.len > 0) blk: {
            const h = try arena.alloc(http.Header, 1);
            h[0] = .{ .name = "content-type", .value = content_type };
            break :blk h;
        } else &[_]http.Header{};

        return .{
            .url = url,
            .body = body,
            .status = 200,
            .headers = headers,
        };
    }

    fn deliver(req: *Request, fulfilled: *const FulfilledResponse) !void {
        const response = Response.fromFulfilled(req.ctx, fulfilled);
        if (req.start_callback) |cb| {
            try cb(response);
        }

        const result = try req.header_callback(response);
        if (result == .abort) {
            return error.Abort;
        }

        if (fulfilled.body) |b| {
            if (b.len > 0) {
                try req.data_callback(response, b);
            }
        }
        try req.done_callback(req.ctx);
    }
};

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

    fn headerCallback(response: Response) anyerror!HeaderResult {
        const self: *SyncContext = @ptrCast(@alignCast(response.ctx));
        lp.assert(response.status() != null, "HttpClient.SyncRequest.headerCallback", .{ .value = response.status() });
        self.status = response.status().?;
        if (response.contentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.allocator, cl);
        }
        return .proceed;
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
    if (self.inbox.terminated) {
        // request() takes ownership of req.headers on every path; we return
        // before calling it, so free the curl_slist here to avoid leaking it.
        req.headers.deinit();
        return error.ClientDisconnected;
    }

    var sync_ctx = SyncContext{ .allocator = allocator, .body = .empty };
    errdefer sync_ctx.body.deinit(allocator);

    const expected_id = self.nextReqId();
    const frame_id = req.frame_id;
    try self.blocking_requests.putNoClobber(self.allocator, frame_id, expected_id);
    defer _ = self.blocking_requests.remove(frame_id);

    var r = req;
    r.ctx = &sync_ctx;
    r.header_callback = SyncContext.headerCallback;
    r.data_callback = SyncContext.dataCallback;
    r.done_callback = SyncContext.doneCallback;
    r.error_callback = SyncContext.errorCallback;
    r.shutdown_callback = SyncContext.shutdownCallback;
    const transfer = try self.requestT(r, null);

    while (sync_ctx.completion == .in_progress) {
        self.tick(200, .sync_wait) catch |err| {
            if (sync_ctx.completion == .in_progress) {
                // tick failed for a reason unrelated to our transfer (likely OOM or
                // client disconnect). transfer.req.ctx points at &sync_ctx on this
                // stack — abort to sever that reference before we return
                transfer.abort(err);
            }
            return err;
        };
        if (sync_ctx.completion == .in_progress and self.inbox.contains(isSyncWaitInterrupt)) {
            // A teardown/close command is queued but sync_wait can't dispatch
            // it mid-parse (it would free the Page/Frame this stack holds).
            // Abort the blocking fetch so the parser unwinds to the next safe
            // drain and the command runs there, instead of stalling for the
            // full per-request timeout per blocking script.
            transfer.abort(error.SyncWaitInterrupted);
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
    // libcurl doesn't allow recursive calls, if we're in a `perform()` operation
    // then we _have_ to queue this.
    if (self.performing == false) {
        if (self.network.getConnection()) |conn| {
            return self.makeRequest(conn, transfer);
        }
    }

    self.queue.append(&transfer._node);
    transfer.state = .queued;
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
    conn.debug_added = 0;
    conn.debug_removed = 0;
    conn.debug_remove_err = null;
    {
        // Reset per-response state for retries (auth challenge, queue).
        const auth = transfer._auth_challenge;
        transfer.reset();
        transfer._auth_challenge = auth;

        // conn is locally held during configure; we don't write it to
        // `transfer._conn` until trackConn commits it to the multi
        // handle. If configureConn fails, release the conn back to the
        // pool — `transfer.state` stays `.created`, and the caller
        // (Client.request's errdefer or drainQueue's catch) aborts
        // the transfer.
        errdefer self.releaseConn(conn);

        try transfer.configureConn(conn);
    }

    // As soon as trackConn succeeds, the multi handle owns the transfer's
    // lifecycle. perform/processMessages will eventually invoke completion
    // callbacks and call transfer.deinit.
    self.trackConn(conn) catch |err| {
        self.releaseConn(conn);
        return err;
    };
    transfer._conn = conn;
    transfer.state = .inflight;

    if (transfer.req.start_callback) |cb| {
        cb(Response.fromTransfer(transfer)) catch |err| {
            // We're now committed to the multi. transfer.abort fires the
            // error_callback and tears down (removeConn handles the
            // already-in-multi case via the dirty queue).
            transfer.abort(err);
            return err;
        };
    }

    // Start the request (and move along any other request). This used to call
    // self.perform(0) but that can also execute callbacks. Normally, that
    // wouldn't be so bad. But curl can synchronously fire callbacks for the
    // request we JUST added, which we do not want (it results in incorrect
    // execution).
    self.performing = true;
    defer self.performing = false;
    _ = try self.handles.perform();
}

fn perform(self: *Client, timeout_ms: c_int) anyerror!void {
    const running = blk: {
        self.performing = true;
        defer self.performing = false;

        break :blk try self.handles.perform();
    };

    // Process dirty connections — return them to Network pool.
    while (self.dirty.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        self.handles.remove(conn) catch |err| {
            lp.assert(false, "multi_remove_handle", .{
                .err = err,
                .in_use = conn.in_use,
                .added = conn.debug_added,
                .removed = conn.debug_removed,
                .remove_err = conn.debug_remove_err,
            });
        };
        conn.debug_removed = 2;
        self.releaseConn(conn);
    }

    while (self.ready_queue.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try self.trackConn(conn);
    }

    // We just processed completions; their done_callbacks may have
    // scheduled microtasks (JS continuations) or queued new transfers.
    // Return without polling so the caller (_tick) can run macrotasks
    // and re-evaluate. Otherwise we'd sleep on cdp_link_active for up
    // to timeout_ms while pending JS work sits idle.
    if (try self.processMessages()) {
        return;
    }

    // Poll for HTTP I/O. The Network thread will call curl_multi_wakeup
    // on our multi handle whenever it pushes to our inbox, so we drop
    // out of poll promptly even when we have no curl handles in flight
    // — but ONLY if a producer is actually wired up. `cdp_link_active`
    // is set by Server.handleConnection once network.registerCdp has
    // returned; in tests (which never register) and during the
    // pre-handshake window the flag stays false and we don't waste a
    // poll timeout waiting for a wakeup that won't arrive.
    if (running > 0 or self.cdp_link_active) {
        // when cdp_link_active == true, the network thread will unblock this
        // by calling wakup on our multi.
        try self.handles.poll(&.{}, timeout_ms);
    }

    _ = try self.processMessages();
}

// Drain any CDP messages the Network thread pushed into our inbox
// and dispatch them via the cdp_client callbacks. Returns
// error.ClientDisconnected if the inbox surfaced a disconnect message,
// so the worker loop can tear down the connection. Called from tick
// only — NOT from perform, because perform recurses through
// processOneMessage's redirect path.
fn drainInbox(self: *Client, mode: DrainMode) !void {
    const cdp = self.cdp orelse return;
    while (true) {
        const msg = switch (mode) {
            .all => self.inbox.pop(),
            .sync_wait => self.inbox.popIf(allowDuringSyncWait),
        } orelse return;

        defer msg.deinit(self.arena_pool);

        switch (msg.payload) {
            .cdp => |*c| cdp.onMessage(c) catch |err| {
                // A single malformed/failed dispatch shouldn't poison
                // the rest of the batch — log and continue.
                log.err(.cdp, "CDP dispatch", .{ .err = err });
            },
            .ping => |body| cdp.onPing(body),
            .close => {
                cdp.onClose();
                cdp.onDisconnect(null);
                self.inbox.terminated = true;
                return error.ClientDisconnected;
            },
            .disconnect => |err| {
                cdp.onDisconnect(err);
                self.inbox.terminated = true;
                return error.ClientDisconnected;
            },
        }
    }
}

// Predicate for Inbox.popIf during sync_wait drains. Always allows
// ping/close/disconnect (control frames must be observed). CDP data
// messages are filtered: only the four Fetch interception methods
// are safe to dispatch from inside a JS callback (they mutate
// transfer state via InterceptionLayer; they don't touch page /
// session / V8 state). The check is exact on the parsed `method`
// field — no substring matching against raw JSON.
//
// Every method listed here must be safe to dispatch with
// JS on the stack — meaning it must NO reach any other code
// path that frees Page/Session/Frame/Worker state the unwinding
// eval frame above us will dereference.
fn allowDuringSyncWait(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .ping, .close, .disconnect => true,
        .cdp => |c| isFetchInterceptionMethod(c.input.method),
    };
}

fn isFetchInterceptionMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Fetch.continueRequest") or
        std.mem.eql(u8, method, "Fetch.failRequest") or
        std.mem.eql(u8, method, "Fetch.fulfillRequest") or
        std.mem.eql(u8, method, "Fetch.continueWithAuth");
}

// True for inbox messages that mean "this page/connection is going away".
// syncRequest uses this to bail out of a blocking-script wait promptly
// rather than holding the worker for the per-request timeout while a
// teardown command sits undispatched behind the sync_wait allowlist.
fn isSyncWaitInterrupt(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .close, .disconnect => true,
        .ping => false,
        .cdp => |c| isTeardownMethod(c.input.method),
    };
}

fn isTeardownMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Target.closeTarget") or
        std.mem.eql(u8, method, "Target.disposeBrowserContext") or
        std.mem.eql(u8, method, "Page.close");
}

pub fn isRedirectStatus(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

fn processOneMessage(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
    // State at entry: .inflight = conn (multi just delivered a completion).

    // Workaround for libcurl Brotli trailing-byte rejection.
    //
    // Some CDNs (e.g. CloudFront serving Brave Search) emit a Brotli stream
    // whose compressed payload has 1+ trailing bytes after the logical end.
    // The Brotli decoder reports BROTLI_DECODER_RESULT_SUCCESS, but libcurl's
    // brotli_do_write() (content_encoding.c:439) treats any unconsumed input
    // bytes as CURLE_WRITE_ERROR. All decompressed body data has already been
    // delivered to our write callback successfully.
    //
    // Browsers accept such responses (the decompressed content is valid), so
    // we match that behavior: when CURLE_WRITE_ERROR arrives but our callback
    // never errored and bytes were received, treat it as success.
    const effective_err: ?anyerror = if (msg.err) |err| blk: {
        if (err == error.WriteError and transfer.res.callback_error == null and transfer.res.bytes_received > 0) {
            log.debug(.http, "WriteError downgraded", .{ .url = transfer.req.url, .bytes = transfer.res.bytes_received });
            break :blk null;
        }
        break :blk err;
    } else null;

    if (effective_err == null or effective_err.? == error.RecvError) {
        transfer.detectAuthChallenge(msg.conn);
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
            // is still valid/alive (just has no handle); park it for
            // continueWithAuth.
            self.removeConn(transfer._conn.?);
            transfer._conn = null;
            transfer.state = .{ .parked = .intercept_auth };
            return false;
        }
    }

    // Handle redirects: reuse the same connection to preserve TCP state.
    // A redirect status without a Location header is not a redirect, it's a
    // final response and falls through so its body is delivered.
    if (effective_err == null) {
        const status = try msg.conn.getResponseCode();
        if (isRedirectStatus(status)) {
            if (msg.conn.getResponseHeader("location", 0)) |location| {
                try transfer.handleRedirect(location.value);

                const conn = transfer._conn.?;

                try self.handles.remove(conn);
                conn.debug_removed = 3;
                // Conn temporarily out of multi during reconfigure.
                // _detached_conn lets processMessages release it if any of
                // the steps below throw. State stays .inflight; _conn stays set
                transfer._detached_conn = conn;

                transfer.reset();
                try transfer.configureConn(conn);
                try self.handles.add(conn);
                conn.debug_added = 2;
                transfer._detached_conn = null;

                _ = try self.perform(0);

                return false;
            }
        }
    }

    // Transfer is done (success or error). Caller (processMessages) owns deinit.
    // Return true = done (caller will deinit), false = continues (redirect/auth).

    // When the server closes the TLS onnection without a close_notify alert,
    // BoringSSL reports RecvError. If we already received valid HTTP headers,
    // this is a normal end-of-body (the connection closure signals the end
    // of the response per HTTP/1.1 when there is no Content-Length).
    // We must check this before endTransfer, which may reset the easy handle.
    const is_conn_close_recv = blk: {
        const err = effective_err orelse break :blk false;
        if (err != error.RecvError) break :blk false;
        const hdr = msg.conn.getResponseHeader("connection", 0) orelse break :blk true;
        break :blk std.ascii.eqlIgnoreCase(hdr.value, "close");
    };

    // Transition to .completing so re-entrant aborts from user callbacks
    // defer their teardown to processMessages. (_conn carries through
    // from .inflight; nothing to set here.)
    transfer.state = .completing;

    if (effective_err != null and !is_conn_close_recv) {
        transfer.requestFailed(transfer.res.callback_error orelse effective_err.?, true);
        return true;
    }

    if (!transfer.res.header_done_called) {
        // In case of request w/o data, we need to call the header done
        // callback now.
        const result = try transfer.headerDoneCallback(msg.conn);
        switch (result) {
            .proceed => {},
            .handled => return true,
            .abort => {
                transfer.requestFailed(error.Abort, true);
                return true;
            },
        }
    }

    const body = transfer.res.stream_buffer.items;

    // Replay buffered body through user's data_callback.
    if (body.len > 0) {
        try transfer.req.data_callback(Response.fromTransfer(transfer), body);

        if (transfer.state == .aborted) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    // release conn ASAP so that it's available; some done_callbacks
    // will load more resources. State stays .completing — the
    // processMessages caller still owns deinit.
    self.removeConn(msg.conn);
    transfer._conn = null;

    try transfer.req.done_callback(transfer.req.ctx);

    return true;
}

fn processMessages(self: *Client) !bool {
    var processed = false;
    while (try self.handles.readMessage()) |msg| {
        switch (msg.conn.transport) {
            .http => |transfer| {
                const done = self.processOneMessage(msg, transfer) catch |err| blk: {
                    log.err(.http, "process_messages", .{ .err = err, .req = transfer });
                    transfer.requestFailed(err, true);
                    if (transfer._detached_conn) |c| {
                        // Conn was removed from handles during redirect reconfiguration
                        // but not re-added. Release it directly to avoid double-remove.
                        self.in_use.remove(&c.node);
                        self.http_active -= 1;
                        self.releaseConn(c);
                        transfer._detached_conn = null;
                    }
                    break :blk true;
                };
                if (done) {
                    transfer.deinit();
                    processed = true;
                }
            },
            .websocket => |ws| {
                // ws_active will be decremented through the call to disconnected
                if (msg.err) |err| switch (err) {
                    error.GotNothing => ws.disconnected(null),
                    else => ws.disconnected(err),
                } else {
                    // Clean close - no error
                    ws.disconnected(null);
                }

                processed = true;
            },
            .none => unreachable,
        }
    }
    return processed;
}

pub fn trackConn(self: *Client, conn: *http.Connection) !void {
    if (self.performing) {
        conn.in_use = false;
        self.ready_queue.append(&conn.node);
        return;
    }

    self.in_use.append(&conn.node);
    conn.in_use = true;
    // Set private pointer so readMessage can find the Connection.
    // Must be done each time since curl_easy_reset clears it when
    // connections are returned to pool.
    conn.setPrivate(conn) catch |err| {
        self.in_use.remove(&conn.node);
        conn.in_use = false;
        self.releaseConn(conn);
        return err;
    };
    self.handles.add(conn) catch |err| {
        self.in_use.remove(&conn.node);
        conn.in_use = false;
        self.releaseConn(conn);
        return err;
    };
    conn.debug_added = 1;

    switch (conn.transport) {
        .http => self.http_active += 1,
        .websocket => self.ws_active += 1,
        else => unreachable,
    }
}

pub fn removeConn(self: *Client, conn: *http.Connection) void {
    if (conn.in_use == false) {
        self.ready_queue.remove(&conn.node);
        self.releaseConn(conn);
        return;
    }

    self.in_use.remove(&conn.node);
    conn.in_use = false;
    switch (conn.transport) {
        .http => self.http_active -= 1,
        .websocket => self.ws_active -= 1,
        else => unreachable,
    }
    if (self.handles.remove(conn)) {
        conn.debug_removed = 1;
        self.releaseConn(conn);
    } else |err| {
        // Can happen if we're in a perform() call, so we'll queue this
        // for cleanup later.
        conn.debug_remove_err = err;
        self.dirty.append(&conn.node);
    }
}

fn releaseConn(self: *Client, conn: *http.Connection) void {
    self.network.releaseConnection(conn);
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.http_active > 0 or self.ws_active > 0) {
        return error.InflightConnection;
    }
}

pub const HeaderResult = enum {
    /// Continue processing normally.
    proceed,
    /// Caller took ownership of the response; stop w/o error or abort.
    handled,
    /// Abort the Transfer,
    abort,
};

pub const Request = struct {
    pub const StartCallback = *const fn (response: Response) anyerror!void;
    pub const HeaderCallback = *const fn (response: Response) anyerror!HeaderResult;
    pub const DataCallback = *const fn (response: Response, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    pub const ResourceType = enum {
        document,
        xhr,
        script,
        fetch,
        stylesheet,

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
                .stylesheet => "Stylesheet",
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

    // Requests that are internal to the browser and skip various layers,
    // these do not need to be deferred and do not obey robots.txt.
    internal: bool = false,

    // When false, the caller does not guarantee that the body outlives the
    // transfer, and thus we'll need to dupe it.
    body_outlives_request: bool = false,

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
        if (aw.written().len == 0) {
            return null;
        }
        try aw.writer.writeByte(0);
        const written = aw.written();
        return written.ptr[0 .. written.len - 1 :0];
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

pub const StableResponse = struct {
    ctx: *anyopaque,
    status: u16,
    url: [:0]const u8,
    headers: []const http.Header,
    body: ?[]const u8,

    pub fn contentType(self: *const StableResponse) ?[]const u8 {
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
        stable: *const StableResponse,
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

    pub fn fromStable(stable: *const StableResponse) Response {
        return .{ .ctx = stable.ctx, .inner = .{ .stable = stable } };
    }

    pub fn status(self: Response) ?u16 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.status else null,
            .cached => |c| c.metadata.status,
            .fulfilled => |f| f.status,
            .stable => |s| s.status,
        };
    }

    pub fn contentType(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |*rh| rh.contentType() else null,
            .cached => |c| c.metadata.content_type,
            .fulfilled => |f| f.contentType(),
            .stable => |s| s.contentType(),
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
            .stable => |s| if (s.body) |b| @intCast(b.len) else null,
        };
    }

    pub fn redirectCount(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.redirect_count else null,
            .cached, .fulfilled, .stable => 0,
        };
    }

    pub fn url(self: Response) [:0]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.req.url,
            .cached => |c| c.metadata.url,
            .fulfilled => |f| f.url,
            .stable => |s| s.url,
        };
    }

    pub fn headerIterator(self: Response) HeaderIterator {
        return switch (self.inner) {
            .transfer => |t| t.responseHeaderIterator(),
            .cached => |c| HeaderIterator{ .list = .{ .list = c.metadata.headers } },
            .fulfilled => |f| HeaderIterator{ .list = .{ .list = f.headers } },
            .stable => |s| HeaderIterator{ .list = .{ .list = s.headers } },
        };
    }

    pub fn abort(self: Response, err: anyerror) void {
        switch (self.inner) {
            .transfer => |t| t.abort(err),
            .cached, .fulfilled, .stable => {},
        }
    }

    pub fn format(self: Response, writer: *std.Io.Writer) !void {
        return switch (self.inner) {
            .transfer => |t| try t.format(writer),
            .cached => |c| try c.format(writer),
            .fulfilled => |f| try writer.print("fulfilled {s}", .{f.url}),
            .stable => |s| writer.print("stable {s}", .{s.url}),
        };
    }

    pub fn toStable(self: Response, arena: std.mem.Allocator) !StableResponse {
        const new_url = try arena.dupeZ(u8, self.url());

        var headers: std.ArrayListUnmanaged(http.Header) = .{};
        var it = self.headerIterator();
        while (it.next()) |hdr| {
            try headers.append(arena, .{
                .name = try arena.dupe(u8, hdr.name),
                .value = try arena.dupe(u8, hdr.value),
            });
        }

        return .{
            .ctx = self.ctx,
            .status = self.status() orelse 0,
            .url = new_url,
            .headers = headers.items,
            .body = null,
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

    // The transfer's lifecycle position. Source of truth for
    // "is this committed?" and "can we deinit synchronously?".
    // The conn the transfer holds (if any) is tracked separately
    // in `_conn` — orthogonal to state. See `State` below.
    state: State = .created,

    // Conn the transfer currently holds. Set when makeRequest commits
    // the conn to the multi handle; cleared by the "release ASAP" step
    // inside processOneMessage, by the auth-parking path, and by deinit.
    // Lifetime is decoupled from `state` on purpose: a single transition
    // shouldn't have to thread the conn pointer, and aborts in mid-flight
    // can let `deinit` find the conn via this field instead of carrying
    // it on every state variant.
    _conn: ?*http.Connection = null,

    req: Request,
    res: Transfer.Response = .{},
    client: *Client,

    start_time: u64,

    _notified_fail: bool = false,

    // Set when conn is temporarily detached from transfer during redirect
    // reconfiguration. Used by processMessages to release the orphaned conn
    // if reconfiguration fails. Transient inside the redirect path only.
    _detached_conn: ?*http.Connection = null,

    _auth_challenge: ?http.AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,
    _redirect_count: u8 = 0,

    // for when a Transfer is queued in the client.queue
    _node: std.DoublyLinkedList.Node = .{},

    // for when a Transfer is queued for the next tick.
    _next_tick_node: ?NextTickNode = null,

    // Debug canary: set on the first deinit, so that if a second deinit on the
    // same instance is called, we have a double free. The memory _could_ be
    // re-used, since the lack of a failure doesn't proove there's no UAF.
    _deinited: bool = false,

    pub const State = union(enum) {
        // Pre-commit. Only valid inside the request flow (Client.request
        // or a re-entry like continueTransfer / unpark) before any commit
        // point hands the transfer to an external owner. Client.request's
        // errdefer uses `.created` to decide whether to abort.
        created,

        // On client.queue, waiting for a libcurl handle. `_node` is
        // linked into client.queue.
        queued,

        // Conn (in `_conn`) is in the multi handle; libcurl owns the
        // lifecycle. processOneMessage will eventually fire callbacks
        // for us.
        inflight,

        // processOneMessage is running user callbacks. The conn may
        // still be in `_conn` (header/data phase) or have been cleared
        // by the "release ASAP" step before done_callback fires.
        completing,

        // External owner is holding the transfer paused. The owner is
        // responsible for resuming or terminating it.
        parked: ParkedBy,

        // detachInPerform ran; user callbacks are noop'd, owner link is
        // cleared, processOneMessage / processMessages will deinit on
        // exit. `_conn` (if any) is what `deinit` will release once
        // libcurl is done with it.
        aborted,
    };

    pub const ParkedBy = enum {
        // CDP Fetch interception, request phase.
        intercept_request,

        // CDP auth challenge — processOneMessage stashed the transfer
        // waiting for continueWithAuth.
        intercept_auth,

        // RobotsLayer holds the transfer pending a robots.txt fetch.
        robots,
    };

    // Layer-facing: park the transfer for an external owner. The caller
    // must be holding the transfer in the request flow (state == .created).
    pub fn park(self: *Transfer, by: ParkedBy) void {
        lp.assert(self.state == .created, "Transfer.park", .{ .state = self.state });
        self.state = .{ .parked = by };
    }

    // Layer-facing: take the transfer out of .parked and return it to
    // the request flow (.created). This assumes pre-inflight handling (i.e. the
    // transfer was in .created before being parked). This is true today, but
    // could become false if Request Interception ever supports the "response"
    // requestStage (although, to support this, I think the safety of transfers
    // post-perform would need to be improved),
    pub fn unpark(self: *Transfer) void {
        lp.assert(self.state == .parked, "Transfer.unpark", .{ .state = self.state });
        self.leaveIntercept();
        self.state = .created;
    }

    // Decrement the interception counter iff this transfer is currently
    // parked for CDP interception.
    fn leaveIntercept(self: *Transfer) void {
        if (self.state != .parked) {
            return;
        }
        switch (self.state.parked) {
            .robots => {},
            .intercept_request, .intercept_auth => {
                const intercept_layer = &self.client.interception_layer;
                lp.assert(intercept_layer.intercepted > 0, "Transfer.leaveIntercept", .{ .value = intercept_layer.intercepted });
                intercept_layer.intercepted -= 1;
            },
        }
    }

    pub fn deinit(self: *Transfer) void {
        if (comptime IS_DEBUG) {
            lp.assert(self._deinited == false, "Transfer.deinit", .{ .id = self.id });
            self._deinited = true;
        }
        self.leaveIntercept();
        if (self._conn) |c| {
            self.client.removeConn(c);
            self._conn = null;
        }

        // Unlink from client.queue if we were waiting for a handle.
        // Without this, deinit'ing a queued transfer (e.g. via owner-list
        // abort during navigation) leaves a dangling _node in the queue
        // that the next tick would pop and hand to libcurl → UAF.
        if (self.state == .queued) {
            self.client.queue.remove(&self._node);
        }

        // Drop the id→*Transfer index entry before freeing the memory.
        // Any concurrent CDP lookup by id will now see this transfer as gone.
        _ = self.client.transfers.remove(self.id);

        self.client.cancelNextTick(self);

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
    // via _notified_fail), then either deinits synchronously or, if we're
    // mid-perform with a libcurl handle still in the multi, detaches and
    // lets the natural processOneMessage flow deinit later.
    //
    // This is the ONE entry point external callers should use to cancel
    // a transfer. Don't reach for kill() or requestFailed() directly —
    // they're internal helpers.
    pub fn abort(self: *Transfer, err: anyerror) void {
        self.requestFailed(err, true);
        self.detachOrDeinit();
    }

    // Abort a transfer that an external owner (CDP interception) is holding in a
    // .parked state. Unlike abort(), this is re-entrancy safe so that if
    // requestFailed causes a teardown/navigate, this won't be killed again
    // Mirrors InterceptionLayer.fulfillRequest. unpark asserts the transfer is
    // actually parked.
    pub fn abortParked(self: *Transfer, err: anyerror) void {
        self.unpark();
        self.state = .completing;
        defer self.deinit();
        self.requestFailed(err, true);
    }

    // Owner-driven teardown: fires shutdown_callback (not error_callback)
    // and otherwise behaves like abort. Called by Client.abortOwner /
    // abortRequests when a Frame / WGS is being torn down.
    fn kill(self: *Transfer) void {
        if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }
        self.detachOrDeinit();
    }

    // Decide whether to tear down now or defer until processOneMessage
    // eventually drains the in-flight curl handle.
    //
    // Two states force deferral:
    //   * `.completing` — processOneMessage is currently processing
    //     this transfer. It will call `transfer.deinit` itself after the
    //     chain returns; deiniting here would double-free. This covers
    //     both the with-conn and post-release-ASAP windows.
    //   * `.inflight` while `client.performing` — libcurl could still
    //     fire callbacks for us. Releasing the arena now would UAF
    //     from inside curl.
    //
    // Otherwise (created / queued / parked / fully drained), there is
    // nothing left referencing this transfer and we can safely deinit
    // inline.
    fn detachOrDeinit(self: *Transfer) void {
        const must_defer = switch (self.state) {
            .completing => true,
            .inflight => self.client.performing,
            else => false,
        };
        if (must_defer) {
            self.detachInPerform();
        } else {
            self.deinit();
        }
    }

    // Deferred-cleanup path when we can't synchronously deinit.
    //
    // We:
    //   - transition state to `.aborted` so processOneMessage's
    //     normal-completion paths short-circuit when they next see
    //     this transfer,
    //   - noop every user callback so libcurl naturally draining the
    //     in-flight response can't re-enter user code,
    //   - unlink from owner.transfers and clear `owner` so the owning
    //     Frame/WGS can be freed while this transfer is still draining.
    //     transfer.deinit (called later by processOneMessage) sees
    //     `owner == null` and skips the list-remove that would otherwise
    //     UAF against a freed list.
    fn detachInPerform(self: *Transfer) void {
        // `_conn` (if any) rides through .aborted untouched; deinit
        // releases it once libcurl is done.
        self.state = .aborted;
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

    // `url` must have transfer-arena lifetime: it's stored as-is, not duped.
    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        self.req.url = url;
    }

    fn handleRedirect(transfer: *Transfer, location: []const u8) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;

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

        // base_url and location are owned by curl; applyRedirectTarget resolves a
        // fresh arena-owned copy that gets stored in transfer.req.url.
        const base_url = try conn.getEffectiveUrl();
        const status = try conn.getResponseCode();
        try transfer.applyRedirectTarget(std.mem.span(base_url), location, status);
    }

    // Called above (in handleRedirect) and by a CDP fulfill request which redirects
    pub fn applyRedirectTarget(transfer: *Transfer, base: [:0]const u8, location: []const u8, status: u16) !void {
        const req = &transfer.req;
        const arena = transfer.arena;

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        // resolve the redirect target.
        const url: [:0]const u8 = blk: {
            if (location.len == 0) {
                // Might seem silly, but URL.resovle will return location as-is
                // if empty, and location may be memory owned by libcurl.
                break :blk "";
            }

            const resolved = try URL.resolve(arena, base, location, .{});

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

        // The transfer is still .parked(.intercept_auth)
        self.abortParked(error.AbortAuthChallenge);
    }

    // headerDoneCallback is called once the headers have been read.
    // It can be called either on dataCallback or once the request for those
    // w/o body.
    fn headerDoneCallback(transfer: *Transfer, conn: *const http.Connection) !HeaderResult {
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

        const result = transfer.req.header_callback(Client.Response.fromTransfer(transfer)) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        if (result == .proceed and transfer.state == .aborted) return .abort;
        return result;
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
            // Only skip the body when the response will actually be retried
            // as a redirect (a redirect status with a Location header). Any
            // other 3xx is a final response whose body must be kept.
            if (isRedirectStatus(status) and conn.getResponseHeader("location", 0) != null) {
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

        if (transfer.state == .aborted) {
            return http.writefunc_error;
        }

        return @intCast(chunk_len);
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        // We always have a real curl request here. We handle injection up in InterceptionLayer.
        const c = self._conn;
        lp.assert(c != null, "Transfer.responseHeaderIterator", .{ .value = c != null });
        // If we have a connection, than this is a real curl request and we
        // iterate through the header that curl maintains.
        return .{ .curl = .{ .conn = c.? } };
    }

    // This function should be called during the dataCallback. Calling it after
    // such as in the doneCallback is guaranteed to return null.
    pub fn getContentLength(self: *const Transfer) ?u32 {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(u32, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        if (self._conn) |c| {
            // If we have a connection, than this is a normal request. We can get the
            // header value from the connection.
            const cl = c.getResponseHeader("content-length", 0) orelse return null;
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
        log.debug(.http, "continue transfer", .{ .intercepted = self.interception_layer.intercepted });
    }

    transfer.unpark();
    self.process(transfer) catch |err| {
        if (transfer.state == .created) {
            transfer.abort(err);
        }
        return err;
    };
}

const Noop = struct {
    fn headerCallback(_: Response) !HeaderResult {
        return .proceed;
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

    // The owning Frame's / WorkerGlobalScope's blob: registry,
    blob_urls: ?*const std.StringHashMapUnmanaged(*Blob) = null,

    const WebSocket = @import("webapi/net/WebSocket.zig");
    const Blob = @import("webapi/Blob.zig");

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

const testing = @import("../testing.zig");

test "HttpClient: isFetchInterceptionMethod matches the four Fetch methods" {
    try testing.expect(isFetchInterceptionMethod("Fetch.continueRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.failRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.fulfillRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.continueWithAuth"));
}

test "HttpClient: isFetchInterceptionMethod rejects unrelated methods" {
    try testing.expect(!isFetchInterceptionMethod(""));
    try testing.expect(!isFetchInterceptionMethod("Fetch.enable"));
    try testing.expect(!isFetchInterceptionMethod("Fetch.disable"));
    try testing.expect(!isFetchInterceptionMethod("Page.navigate"));
    try testing.expect(!isFetchInterceptionMethod("Runtime.evaluate"));
    // strict-equality check: a prefix of a valid name must not match
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueReq"));
    // trailing space, etc.
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueRequest "));
}

test "HttpClient: allowDuringSyncWait allows ping/close/disconnect" {
    var ping_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .ping = "" },
    };
    try testing.expect(allowDuringSyncWait(&ping_msg));

    var close_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .close,
    };
    try testing.expect(allowDuringSyncWait(&close_msg));

    var disconnect_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .disconnect = null },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_msg));

    var disconnect_err_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .disconnect = error.PeerClosed },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_err_msg));
}

test "HttpClient: allowDuringSyncWait allows only Fetch interception CDP methods" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Fetch.continueRequest",
        "Fetch.failRequest",
        "Fetch.fulfillRequest",
        "Fetch.continueWithAuth",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(allowDuringSyncWait(&msg));
    }
}

test "HttpClient: allowDuringSyncWait denies non-Fetch CDP methods" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.enable",
        "Fetch.disable",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!allowDuringSyncWait(&msg));
    }
}

test "HttpClient: isSyncWaitInterrupt matches teardown methods, close and disconnect" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Target.closeTarget",
        "Target.disposeBrowserContext",
        "Page.close",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(isSyncWaitInterrupt(&msg));
    }

    var close_msg = Inbox.Message{ .arena = testing.allocator, .payload = .close };
    try testing.expect(isSyncWaitInterrupt(&close_msg));

    var disconnect_msg = Inbox.Message{ .arena = testing.allocator, .payload = .{ .disconnect = null } };
    try testing.expect(isSyncWaitInterrupt(&disconnect_msg));
}

test "HttpClient: isSyncWaitInterrupt ignores ping and non-teardown CDP methods" {
    var ping_msg = Inbox.Message{ .arena = testing.allocator, .payload = .{ .ping = "" } };
    try testing.expect(!isSyncWaitInterrupt(&ping_msg));

    var raw_buf: [16]u8 = undefined;
    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.continueRequest",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!isSyncWaitInterrupt(&msg));
    }
}

test "HttpClient: fulfillRequest survives a done_callback that tears down the owner" {
    // Regression: Fetch.fulfillRequest runs the consumer's done_callback while
    // the transfer is still parked for interception. A done_callback that runs
    // JS which navigates / closes the page re-entrantly kills the transfer
    // (abortOwner -> kill -> deinit). Previously the transfer was still
    // `.parked` at that point, so the re-entrant teardown freed it
    // synchronously and fulfillRequest's trailing deinit was a double-free +
    // `intercepted` underflow (surfacing later as a Transfer.leaveIntercept
    // assert at session teardown). fulfillRequest now moves the transfer to
    // `.completing` first, so the teardown defers and there is exactly one free.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        done_called: bool = false,

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
            // Mimics a navigation / page-close kicked off from inside the
            // fulfilled response's done_callback, which kills this transfer.
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    // Mirror InterceptionLayer.request committing the transfer to CDP.
    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    try client.interception_layer.fulfillRequest(transfer, 200, &.{}, "hello");

    try testing.expect(ctx.done_called);
    // The transfer was freed exactly once: counter back to 0, dropped from the
    // id index and the owner list. A double-free would have underflowed
    // `intercepted` (or tripped the leaveIntercept assert).
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: fulfillRequest follows a 3xx redirect" {
    // Regression for #2828: a CDP Fetch.fulfillRequest with a 3xx status + a
    // Location header must be followed like a real network redirect (re-issued
    // down the chain to the resolved target), not delivered as a final response.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Only network.config is read (httpMaxRedirects, which ignores its config),
    // so a pointer to an otherwise-undefined Network is safe here.
    var net: Network = undefined;

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.network = &net;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    // Capturing stub for interception_layer.next: records the re-issued request
    // and returns without committing (transfer stays .created; we clean up).
    const Captor = struct {
        captured: bool = false,
        url: []const u8 = "",
        method: Method = undefined,

        fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.captured = true;
            self.url = transfer.req.url;
            self.method = transfer.req.method;
        }
    };
    var captor = Captor{};
    client.interception_layer.next = .{
        .ptr = &captor,
        .vtable = &.{ .request = Captor.request },
    };

    // 302 with a relative Location: rewrite to GET, drop body, resolve target.
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .frame_id = 0,
                .loader_id = 0,
                .method = .POST,
                .url = "http://example.com/start",
                .body = "payload",
                .headers = .{ .headers = null },
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .ctx = undefined,
            },
            .client = &client,
            .id = 1,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.interception_layer.intercepted += 1;

        try client.interception_layer.fulfillRequest(transfer, 302, &.{
            .{ .name = "Location", .value = "/end" },
        }, null);

        try testing.expect(captor.captured);
        try testing.expectEqual("http://example.com/end", captor.url);
        try testing.expectEqual(.GET, captor.method);
        try testing.expectEqual(null, transfer.req.body);
        // Unparked exactly once; transfer is still alive (re-issued, not deinited).
        try testing.expectEqual(0, client.interception_layer.intercepted);
        try testing.expectEqual(1, client.transfers.count());
        transfer.deinit();
    }

    // 307 with an absolute Location: keep method and body.
    captor = .{};
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .frame_id = 0,
                .loader_id = 0,
                .method = .POST,
                .url = "http://example.com/start",
                .body = "payload",
                .headers = .{ .headers = null },
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .ctx = undefined,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.interception_layer.intercepted += 1;

        try client.interception_layer.fulfillRequest(transfer, 307, &.{
            .{ .name = "location", .value = "http://example.com/other" },
        }, null);

        try testing.expect(captor.captured);
        try testing.expectEqual("http://example.com/other", captor.url);
        try testing.expectEqual(.POST, captor.method);
        try testing.expectEqual("payload", transfer.req.body.?);
        try testing.expectEqual(0, client.interception_layer.intercepted);
        transfer.deinit();
    }
}

test "HttpClient: fulfillRequest delivers a 3xx without a Location as the response" {
    // A redirect status with no Location header is not a redirect: the body is
    // delivered as the final response (matching the real-network path).
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    const Ctx = struct {
        done_called: bool = false,
        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
        }
    };
    var ctx = Ctx{};

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    try client.interception_layer.fulfillRequest(transfer, 302, &.{}, "body");

    // Delivered (done_callback ran) and freed exactly once.
    try testing.expect(ctx.done_called);
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: abortParked survives an error_callback that tears down the owner" {
    // Same re-entrancy hazard as fulfillRequest, but on the abort path
    // (failRequest / continueWithAuth-cancel / session teardown). abortParked
    // fires the failure callback while .completing, so a re-entrant owner
    // teardown defers to the single deinit instead of double-freeing.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        err_called: bool = false,

        fn errorCallback(ctx: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.err_called = true;
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .error_callback = Ctx.errorCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    transfer.abortParked(error.Abort);

    try testing.expect(ctx.err_called);
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

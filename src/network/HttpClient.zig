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

const Inbox = @import("../Inbox.zig");
const ArenaPool = @import("../ArenaPool.zig");
const Notification = @import("../Notification.zig");
const timestamp = @import("../datetime.zig").timestamp;

const CDP = @import("../cdp/CDP.zig");
const Watchdog = @import("../Watchdog.zig");
const URL = @import("../browser/URL.zig");
const WebSocket = @import("../browser/webapi/net/WebSocket.zig");
const CookieJar = @import("../browser/webapi/storage/Cookie.zig").Jar;

const http = @import("http.zig");
const Network = @import("Network.zig");
const Cache = @import("cache/Cache.zig");
const RobotsGate = @import("RobotsGate.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

pub const Method = http.Method;
pub const Header = http.Header;
pub const Headers = http.Headers;
pub const HeaderIterator = http.HeaderIterator;

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

// Watchdog instrumentation for this client's worker thread. Wraps the poll
// in perform (and the background-task wait in Runner) so the watchdog can
// tell "parked, waiting for work" from "stuck between waits". Registered
// with App.watchdog by Browser.init.
heartbeat: Watchdog.Heartbeat = .{},

// Use to generate the next request ID
next_request_id: u32 = 0,

// Every currently-alive Transfer indexed by its id. Maintained so cross-
// component code (CDP intercept state, future scheduling/debugging) can
// look up a transfer by id without holding a *Transfer that might dangle.
// Inserted in Client.request, removed in Transfer.deinit. The pointer is
// only valid for the lifetime of the entry.
transfers: std.AutoHashMapUnmanaged(u32, *Transfer) = .empty,

// Connections currently in this client's curl_multi.
in_use: std.DoublyLinkedList = .{},

// Queue for request that are waiting an available connection (aka, easy)
pending_queue: std.DoublyLinkedList = .{},

// Queue for completed transfers that haven't had their callbacks executed yet
dispatch_queue: std.DoublyLinkedList = .{},

// WebSockets with buffered incoming events awaiting delivery. Separate from
// dispatch_queue because the entries aren't Transfers and the gating rule is
// simpler: WS events only deliver at tick(.all).
ws_dispatch_queue: std.DoublyLinkedList = .{},
ws_dispatch_count: usize = 0,

// Completed transfers held back by a frame's blocking request. dispatch()
// parks them here on first sight so the gate is evaluated once per transfer
// per blocking window, not once per tick; releaseBlocking splices them
// back. Blocking requests are common (every bare <script src> is one), so
// this keeps dispatch O(new work) during page load.
gated_queue: std.DoublyLinkedList = .{},

// Undelivered transfers across dispatch_queue + gated_queue.
dispatch_count: usize = 0,

// Transfers retired by Transfer.deinit. This is a safety measure incase
// something tries to use the transfer after it's freed.
graveyard: std.DoublyLinkedList = .{},

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

// While a frame has a blocking (synchronous) request in flight, dispatch
// holds back every other transfer for that frame so their callbacks can't
// run JS while the parser is on the stack. frame_id -> blocking transfer id.
blocking_requests: std.AutoHashMapUnmanaged(u32, u32) = .empty,

// Count of transfers parked for CDP interception (request or auth phase).
// They're off every other activity counter while parked; the network-idle
// heuristics add this in.
intercepted: usize = 0,

// null or referencing network.cache
cache: ?*Cache,

// Cached config decisions, resolved once at init.
serve_mode: bool,
obey_robots: bool,

robots: RobotsGate,

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
        .cache = if (network.cache) |*c| c else null,

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .max_response_size = network.config.httpMaxResponseSize() orelse 1 * 1024 * 1024 * 1024, // 1 GiB

        .serve_mode = network.config.mode == .serve,
        .obey_robots = network.config.obeyRobots(),
        .robots = .{ .allocator = allocator, .network = network },
        .arena_pool = &network.app.arena_pool,
    };
}

pub fn deinit(self: *Client) void {
    self.abort();
    self.processGraveyard();

    if (comptime IS_DEBUG) {
        lp.assert(
            self.dispatch_count == 0,
            "dispatch_count must be 0",
            .{ .value = self.dispatch_count },
        );
        lp.assert(
            self.ws_dispatch_count == 0,
            "ws_dispatch_count must be 0",
            .{ .value = self.ws_dispatch_count },
        );
    }

    self.handles.deinit();

    self.clearUserAgentOverride();
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
    }

    self.robots.deinit();
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

pub fn incrReqId(self: *Client) u32 {
    const id = self.next_request_id +% 1;
    self.next_request_id = id;
    return id;
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

    self.tls_verify = verify;
}

pub fn disableCache(self: *Client, disable: bool) void {
    if (disable) {
        self.cache = null;
    } else {
        self.cache = if (self.network.cache) |*c| c else null;
    }
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
    //   - self.pending_queue     : unlinked if _queued is set
    //   - self.in_use    : via removeConn
    // Any non-empty list means a transfer escaped cleanup — assert so we
    // catch the regression rather than silently leaking on next use.
    // ws_dispatch_queue drains through owner teardown (abortOwner -> kill),
    // which precedes Client.deinit.
    if (comptime IS_DEBUG) {
        std.debug.assert(self.transfers.size == 0);
        std.debug.assert(self.pending_queue.first == null);
        std.debug.assert(self.dispatch_queue.first == null);
        std.debug.assert(self.gated_queue.first == null);
        std.debug.assert(self.in_use.first == null);
        std.debug.assert(self.ws_dispatch_queue.first == null);
        // - self.robots.pending : each robots fetch's shutdown_callback
        //   drops its entry; parked waiters unlink in their own deinit.
        std.debug.assert(self.robots.pending.count() == 0);
    }
}

// Release the arenas of retired transfers. Must only run at a safe point, e.g.
// tick(.all)
fn processGraveyard(self: *Client) void {
    while (self.graveyard.popFirst()) |node| {
        const transfer: *Transfer = @fieldParentPtr("_node", node);
        const arena = transfer.arena;
        self.arena_pool.release(arena);
    }
}

// Kill every transfer + websocket owned by `owner`. Used when the owner
// (Frame / WorkerGlobalScope) is being torn down. After this returns,
// every WebSocket is fully gone; a transfer whose callbacks are being
// delivered right now may still be on `owner.transfers` (Transfer.kill
// defers its deinit), but it's been unlinked from the owner list via
// kill()'s deferred branch so the owner is free to die.
pub fn abortOwner(self: *Client, owner: *Owner) void {
    self.abortRequests(owner);
    var n = owner.websockets.first;
    while (n) |node| {
        n = node.next;
        const ws: *WebSocket = @fieldParentPtr("_owner_node", node);
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
    // (flags `aborted` + noops callbacks) when called from inside a
    // deliver() and only fully deinits when its loop exits. The deferred
    // branch unlinks the node and clears Transfer.owner, so by the time
    // the owner itself is freed, no orphan transfer points at it.
}

// Point-in-time snapshot of the client's outstanding work
pub const Activity = struct {
    // in-flight + buffered-awaiting-dispatch + parked-for-CDP-interception
    http: usize,

    // WebSockets with undelivered events. Unlike ws_conns which only captures
    // a connected websocket, this actually indicates that there's some activity
    // on i
    ws_events: usize,

    // Live WebSocket connections.
    ws_conns: usize,

    // transfers waiting on a free connection
    pending: bool,

    pub fn total(self: Activity) usize {
        return self.http + self.ws_events;
    }

    pub fn idle(self: Activity) bool {
        return self.total() == 0 and !self.pending;
    }
};

pub fn activity(self: *const Client) Activity {
    return .{
        .http = self.http_active + self.dispatch_count + self.intercepted,
        .ws_events = self.ws_dispatch_count,
        .ws_conns = self.ws_active,
        .pending = self.pending_queue.first != null,
    };
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

// One-shot convenience: create and submit in a single call. HttpClient takes
// ownership of req.headers; do not pair with `errdefer headers.deinit()`.
// Callers that have no headers of their own can leave req.headers at its
// (empty) default — the client fills in its baseline headers (user agent,
// etc.).
pub fn request(self: *Client, req: Request, owner: ?*Owner) anyerror!void {
    const transfer = try self.newRequest(req, owner);
    return transfer.submit();
}

// Create a request without submitting it. The caller owns the returned
// transfer until transfer.submit().  On error, header is freed. On success,
// headers is owned by the transfer.
pub fn newRequest(self: *Client, req: Request, owner: ?*Owner) anyerror!*Transfer {
    const arena = self.arena_pool.acquire(.small, "Request.arena") catch |err| {
        req.headers.deinit();
        return err;
    };

    const transfer = blk: {
        var owned = req;
        errdefer {
            owned.headers.deinit();
            self.arena_pool.release(arena);
        }

        if (owned.headers.headers == null) {
            owned.headers = try self.newHeaders();
        }

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

            // Browsers never send Expect: 100-continue; libcurl generates it
            // for HTTP/1.1 requests whose body exceeds 1MB
            // (EXPECT_100_THRESHOLD), which stalls the request ~1s against
            // servers/proxies that never answer the interim response. An
            // empty value ("Expect:") suppresses the generated header. Only
            // requests with a body can trigger it, and over HTTP/2 curl never
            // generates it, so the entry is inert there. Added here (not
            // configureConn) so redirect/auth retries don't append duplicates.
            try owned.headers.add("Expect:");
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

    // From here the transfer owns `req` and `arena`
    self.transfers.putNoClobber(self.allocator, transfer.id, transfer) catch |err| {
        transfer.deinit();
        return err;
    };

    if (owner) |o| {
        o.addTransfer(transfer);
        transfer.owner = o;
    }

    return transfer;
}

pub fn tick(self: *Client, timeout_ms: u32) !void {
    self.processGraveyard();
    return self._tick(timeout_ms, .all);
}

pub fn tickSync(self: *Client, timeout_ms: u32) !void {
    return self._tick(timeout_ms, .sync_wait);
}

pub fn _tick(self: *Client, timeout_ms: u32, mode: DrainMode) !void {
    if (self.inbox.terminated) {
        return error.ClientDisconnected;
    }

    const dispatched = self.dispatchCompleted(mode);

    try self.startPending();

    const running = try self.handles.perform();

    const processed = try self.processMessages();
    if (dispatched == false and processed == false and self.dispatch_queue.first == null and self.ws_dispatch_queue.first == null) {
        // Nothing was dispatched, no messages were processed and nothing is
        // waiting for dispatch. We need to wait for I/O.
        if (running > 0 or self.cdp_link_active) {
            {
                self.heartbeat.enterWait();
                defer self.heartbeat.exitWait();
                // The network layer will wake this up if there's acticity.
                try self.handles.poll(&.{}, @intCast(timeout_ms));
            }
            // poll only waits, so we do the perform -> process dance again
            _ = try self.handles.perform();
            _ = try self.processMessages();
        }
    } else {
        // If we DID dispatch or process messages, we don't wan to wait / poll.
        // We want to proceses completions and return to the caller ASAP so that
        // it can check progress, e.g. maybe the message we processed cause
        // "load" to fire, and that's what it was waiting for.
    }

    try self.startPending();

    _ = self.dispatchCompleted(mode);

    // dispatch CDP commands
    try self.drainInbox(mode);
}

// Deliver completed response. This is the ONLY place user callbacks run,
// so a callback is free to start new requests, abort transfers, or tear down
// its frame. The client is never inside libcurl here.
//
// This should be as simple as: iterate the `dispatch_queue` and dispatch each
// transfer...EXCEPT...a frame can have a blocking request. So, as we iterate
// we find out if a transfer is gated behind a blocking request and move it
// from the `dispatch_queue` to the `gated_queue`. That way, every call to
// `dispatchCompleted` doesn't keep checking the same gated transfers over and
// over.
fn dispatchCompleted(self: *Client, mode: DrainMode) bool {
    if (mode == .all) {
        if (comptime IS_DEBUG) {
            // .all never inside a syncRequest, so nothing can be gating requests.
            std.debug.assert(self.blocking_requests.count() == 0);
        }
    }

    // blocking_requests.count() is always true on tick(.all) but can also
    // happen mid .sync_wait. This is important to do. During blocking, we gated
    // every request. When the blocking requested completed, it only unblocked
    // it's frames request.
    if (self.blocking_requests.count() == 0) {
        var node = self.gated_queue.last;
        while (node) |n| {
            node = n.prev;
            const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
            if (mode == .sync_wait and self.isGated(transfer)) {
                // still gated: a document is never delivered on a sync pump
                continue;
            }
            transfer._gated = false;
            self.gated_queue.remove(n);
            self.dispatch_queue.prepend(n);
        }
    }

    var dispatched = false;

    // pop is safest as it allows anything to manipulate the queue as necessary
    // (e.g. a frame could be aborted)s
    while (self.dispatch_queue.popFirst()) |n| {
        const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
        if (mode == .sync_wait and self.isGated(transfer)) {
            transfer._gated = true;
            self.gated_queue.append(n);
            continue;
        }
        self.dispatch_count -= 1;
        transfer._dispatch_queued = false;
        transfer.deliver();
        dispatched = true;
    }

    if (mode == .all) {
        while (self.ws_dispatch_queue.popFirst()) |n| {
            const ws: *WebSocket = @fieldParentPtr("_dispatch_node", n);
            self.ws_dispatch_count -= 1;
            ws._dispatch_queued = false;
            ws.deliverEvents();
            dispatched = true;
        }
    }

    return dispatched;
}

// wsEnqueue and wsDequeue are the only places ws_dispatch_queue is mutated.
pub fn wsEnqueue(self: *Client, node: *std.DoublyLinkedList.Node) void {
    self.ws_dispatch_queue.append(node);
    self.ws_dispatch_count += 1;
}

pub fn wsDequeue(self: *Client, node: *std.DoublyLinkedList.Node) void {
    self.ws_dispatch_queue.remove(node);
    self.ws_dispatch_count -= 1;
}

// Is this transfer gated behind a blocking request
fn isGated(self: *const Client, transfer: *const Transfer) bool {
    if (transfer.req.internal) {
        // internal transfers are never blocked (e.g. robots.txt)
        return false;
    }
    if (transfer.req.resource_type == .document) {
        // isGated is only ever called during a syncRequest, so if we're here,
        // we know we're trying to load a blocking request. We don't want to
        // deliver a document here, even on a different frame, because that
        // will start the parser, which can trigger more sync blocks. That
        // sounds fine, but we're on the stack of the sync request, and this
        // can easily end up overflowing v8's stack if we have a lot of nested
        // or even sibling blocking scripts to fetch.
        return true;
    }
    if (self.blocking_requests.count() == 0) {
        // O(1) quick check.
        return false;
    }
    // The gate is global, not per-frame: delivering another frame's
    // JS-running callback (script eval, XHR onload) here still executes on
    // the blocking request's stack and can nest parse -> syncRequest ->
    // parse until v8's stack overflows — same hazard as the .document case
    // above. Only the blocking transfer itself gets through.
    const blocking_id = self.blocking_requests.get(transfer.req.frame_id) orelse return true;
    return transfer.id != blocking_id;
}

fn startPending(self: *Client) !void {
    while (self.pending_queue.popFirst()) |queue_node| {
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);
        const conn = self.network.getConnection() orelse {
            self.pending_queue.prepend(queue_node);
            return;
        };
        // Bridge state to .created so a failure inside makeRequest before
        // any commit cleans up via the failAsync below. makeRequest flips to
        // .inflight on a successful trackConn.
        transfer.state = .created;
        self.makeRequest(conn, transfer) catch |err| {
            if (transfer.state == .created) {
                // Fail through the dispatcher: this can run from a
                // tick(.sync_wait), and error_callback JS must not fire
                // on a blocking request's stack.
                transfer.failAsync(err);
            }
            return err;
        };
    }
}

const SubmitFrom = enum { start, after_intercept, network };

// Process a transfer, passing it through our pipeline. A transfer an move off
// the pipeline(e.g. while parked waiting for a robots.txt check) and then
// pushed back onto it, which is what `from` helps us achieve.
fn pipeline(self: *Client, transfer: *Transfer, from: SubmitFrom) !void {
    sw: switch (from) {
        .start => {
            if (self.network.web_bot_auth) |wba| {
                const authority = URL.getHost(transfer.req.url);
                try wba.signRequest(transfer.arena, &transfer.req.headers, authority);
            }

            if (self.serve_mode) {
                transfer._notify_cdp = true;
                transfer.req.notification.dispatch(.http_request_start, &.{ .transfer = transfer });

                var wait_for_interception = false;
                transfer.req.notification.dispatch(.http_request_intercept, &.{
                    .transfer = transfer,
                    .wait_for_interception = &wait_for_interception,
                });
                if (wait_for_interception) {
                    // The CDP listener stashed the transfer id and will
                    // resolve it via continueIntercepted / fulfillIntercepted
                    // / abortParked.
                    self.intercepted += 1;
                    transfer.park(.intercept_request);
                    if (comptime IS_DEBUG) {
                        log.debug(.http, "wait for interception", .{ .intercepted = self.intercepted });
                    }
                    return;
                }
            }
            continue :sw SubmitFrom.after_intercept;
        },
        .after_intercept => {
            if (try self.cacheLookup(transfer)) {
                // response came from the cache, we're done
                return;
            }
            if (self.obey_robots and !transfer.req.internal) {
                switch (try self.robots.check(transfer)) {
                    .allowed => {
                        lp.metrics.robots_access.incr(.allow);
                    },
                    .blocked => {
                        lp.metrics.robots_access.incr(.deny);
                        return transfer.failAsync(error.RobotsBlocked);
                    },
                    .pending => return,
                }
            }
            continue :sw SubmitFrom.network;
        },
        .network => try self.processTransfer(transfer),
    }
}

// RobotsGate resumption. The robots gate is the last step before the
// network, so an allowed transfer goes straight there.
pub fn resumeAfterRobots(self: *Client, transfer: *Transfer) !void {
    return self.pipeline(transfer, .network);
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
            return hdr.value;
        }
    }
    return null;
}

// Returns true if the request was served from the cache (response buffered
// for dispatch). On a miss the transfer is tagged so completion can store
// the response; on an expired-with-validators entry the request becomes a
// conditional revalidation.
fn cacheLookup(self: *Client, transfer: *Transfer) !bool {
    const cache = self.cache orelse return false;

    const req = &transfer.req;
    if (req.method != .GET or req.streaming or req.skip_cache) {
        return false;
    }

    // Redirects rewrite req.url; the entry must be stored/renewed under the
    // URL this lookup ran against, not the final hop. req.url is arena-owned,
    // so the captured slice outlives any redirect rewrite.
    transfer._cache_key = req.url;

    const arena = transfer.arena;
    var iter = req.headers.iterator();
    const req_headers = try iter.collect(arena);

    const cached = cache.get(arena, .{
        .url = req.url,
        .timestamp = std.time.timestamp(),
        .request_headers = req_headers.items,
    }) orelse {
        lp.metrics.http_cache.incr(.miss);
        transfer._cache_intent = .store;
        return false;
    };

    if (cached.expired == false) {
        lp.metrics.http_cache.incr(.hit);
        try transfer.bufferCached(cached);
        return true;
    }

    if (cached.metadata.hasValidators() == false) {
        // Expired and no validators
        lp.metrics.http_cache.incr(.miss);
        cached.data.deinit();
        cache.evict(req.url);
        transfer._cache_intent = .store;
        return false;
    }

    // expired but with validators
    log.debug(.cache, "revalidate with etag", .{
        .url = req.url,
        .etag = cached.metadata.etag,
        .last_modified = cached.metadata.last_modified,
    });
    if (cached.metadata.etag) |etag| {
        try req.headers.add(try std.fmt.allocPrintSentinel(arena, "If-None-Match: {s}", .{etag}, 0));
    }
    if (cached.metadata.last_modified) |lm| {
        try req.headers.add(try std.fmt.allocPrintSentinel(arena, "If-Modified-Since: {s}", .{lm}, 0));
    }
    transfer._cache_intent = .{ .revalidate = cached };
    return false;
}

// 304 on a revalidation: renew the stored entry from the fresh headers and
// serve the stale copy. Returns true if the stale entry became the response.
fn cacheRevalidated(self: *Client, transfer: *Transfer) !bool {
    if (transfer._cache_intent != .revalidate) {
        return false;
    }
    const rh = transfer.res.header orelse return false;
    if (rh.status != 304) {
        return false;
    }
    // could have been disabled in-between
    const cache = self.cache orelse return false;

    const stale = transfer._cache_intent.revalidate;
    transfer._cache_intent = .none;

    cache.renew(transfer.arena, .{
        .url = transfer._cache_key,
        .timestamp = std.time.timestamp(),
        .headers = transfer.res.headers,
    }) catch |err| {
        log.warn(.cache, "renew failed", .{ .err = err });
    };

    lp.metrics.http_cache.incr(.revalidated);
    try transfer.bufferCached(stale);
    return true;
}

// Store a cacheable response at completion, from the materialized response
// headers and the buffered body. Failures are logged, never fatal — the
// consumer gets its response either way.
fn cacheStore(self: *Client, transfer: *Transfer) void {
    switch (transfer._cache_intent) {
        .none => return,
        .store => {},
        .revalidate => |stale| {
            // Not a 304: the stored entry is out of date. Drop it and store
            // the fresh response below.
            stale.data.deinit();
        },
    }
    // Cleared with the release above: deinit must not release the stale
    // entry a second time on any early return below.
    transfer._cache_intent = .none;

    // could have been disabled while waiting of the response
    const cache = self.cache orelse return;

    const arena = transfer.arena;
    const rh = &(transfer.res.header orelse return);
    const headers = transfer.res.headers;

    const vary = findHeader(headers, "vary");
    const maybe_cm = Cache.tryCache(
        arena,
        std.time.timestamp(),
        transfer._cache_key,
        rh.status,
        rh.contentType(),
        findHeader(headers, "cache-control"),
        vary,
        findHeader(headers, "age"),
        findHeader(headers, "etag"),
        findHeader(headers, "last-modified"),
        findHeader(headers, "set-cookie") != null,
        findHeader(headers, "authorization") != null,
    ) catch |err| {
        log.warn(.http, "cache eligibility", .{ .err = err });
        return;
    };
    var metadata = maybe_cm orelse return;

    var vary_headers: std.ArrayList(http.Header) = .empty;
    if (vary) |vary_str| {
        var req_it = transfer.req.headers.iterator();
        while (req_it.next()) |hdr| {
            var vary_iter = std.mem.splitScalar(u8, vary_str, ',');
            while (vary_iter.next()) |part| {
                const name = std.mem.trim(u8, part, &std.ascii.whitespace);
                if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                    const owned: http.Header = .{
                        .name = arena.dupe(u8, hdr.name) catch return,
                        .value = arena.dupe(u8, hdr.value) catch return,
                    };
                    vary_headers.append(arena, owned) catch return;
                }
            }
        }
    }

    metadata.headers = headers;
    metadata.vary_headers = vary_headers.items;

    if (comptime IS_DEBUG) {
        log.debug(.browser, "http cache", .{ .key = transfer._cache_key, .metadata = metadata });
    }
    cache.put(metadata, transfer.res.buffer.items) catch |err| {
        log.warn(.http, "cache put failed", .{ .err = err });
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

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *SyncContext = @ptrCast(@alignCast(transfer.req.ctx));
        lp.assert(transfer.responseStatus() != null, "HttpClient.SyncRequest.headerCallback", .{ .value = transfer.responseStatus() });
        self.status = transfer.responseStatus().?;
        if (transfer.getContentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.allocator, cl);
        }
        return .proceed;
    }

    fn dataCallback(transfer: *Transfer, data: []const u8) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(transfer.req.ctx));
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
        req.deinit();
        return error.ClientDisconnected;
    }

    var sync_ctx = SyncContext{ .allocator = allocator, .body = .empty };
    errdefer sync_ctx.body.deinit(allocator);

    var r = req;
    r.sync = true;
    r.ctx = &sync_ctx;
    r.header_callback = SyncContext.headerCallback;
    r.data_callback = SyncContext.dataCallback;
    r.done_callback = SyncContext.doneCallback;
    r.error_callback = SyncContext.errorCallback;
    r.shutdown_callback = SyncContext.shutdownCallback;
    const transfer = try self.newRequest(r, null);

    const frame_id = req.frame_id;
    self.blocking_requests.putNoClobber(self.allocator, frame_id, transfer.id) catch |err| {
        transfer.deinit();
        return err;
    };
    defer self.releaseBlocking(frame_id);

    try transfer.submit();

    while (sync_ctx.completion == .in_progress) {
        self.tickSync(200) catch |err| {
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

fn processTransfer(self: *Client, transfer: *Transfer) !void {
    if (self.network.getConnection()) |conn| {
        return self.makeRequest(conn, transfer);
    }

    self.pending_queue.append(&transfer._node);
    transfer.state = .queued;
}

// A blocking request is complete. Any completed transfer that was placed in the
// gated_queue because of it can now be placed back in the dispatch queue.
fn releaseBlocking(self: *Client, frame_id: u32) void {
    _ = self.blocking_requests.remove(frame_id);
    // items were added to the gate in order, so walking backwards restores that
    // order. (Order might not matter, but preserving it costs nothing)

    // No callback is executed here. Nothing mutates our queues, so iterating
    // it this way is safe.
    var node = self.gated_queue.last;
    while (node) |n| {
        node = n.prev;
        const transfer: *Transfer = @fieldParentPtr("_queue_node", n);
        if (transfer.req.frame_id != frame_id) {
            continue;
        }
        transfer._gated = false;
        self.gated_queue.remove(n);
        self.dispatch_queue.prepend(n);
    }
}

fn makeRequest(self: *Client, conn: *http.Connection, transfer: *Transfer) anyerror!void {
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

    // Start the request (and move along any other request).
    _ = try self.handles.perform();
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
// transfer state via the interception gate; they don't touch page /
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

fn processMessages(self: *Client) !bool {
    var processed = false;
    while (try self.handles.readMessage()) |msg| {
        switch (msg.conn.transport) {
            .http => |transfer| {
                // On success, processOneMessage owns the transfer's fate: it
                // either buffered it for dispatch, parked it, or deinit'd it.
                // Only the throw path cleans up here.
                const done = self.processOneMessage(msg, transfer) catch |err| blk: {
                    log.err(.http, "process_messages", .{ .err = err, .req = transfer });
                    if (transfer._detached_conn) |c| {
                        // Conn was removed from handles during redirect reconfiguration
                        // but not re-added. Release it directly to avoid double-remove.
                        // _conn still aliases it during that window.
                        self.in_use.remove(&c.node);
                        self.http_active -= 1;
                        self.releaseConn(c);
                        if (transfer._conn == c) {
                            transfer._conn = null;
                        }
                        transfer._detached_conn = null;
                    }
                    if (transfer._conn) |c| {
                        self.removeConn(c);
                        transfer._conn = null;
                    }
                    // Fail through the dispatcher — error_callback must not
                    // run user code from the pump; it would bypass the
                    // blocking gate (see dispatchCompleted).
                    transfer.failAsync(err);
                    break :blk true;
                };
                if (done) {
                    processed = true;
                }
            },
            .websocket => |ws| {
                // Releases the conn now (decrementing ws_active); the JS
                // close/error events are buffered for dispatchCompleted.
                if (msg.err) |err| switch (err) {
                    error.GotNothing => ws.transportClosed(null),
                    else => ws.transportClosed(err),
                } else {
                    // Clean close - no error
                    ws.transportClosed(null);
                }

                processed = true;
            },
            .none => unreachable,
        }
    }
    return processed;
}

fn processOneMessage(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
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

    if (transfer.state == .aborted) {
        // A streaming transfer's callback aborted it mid-deliver and a
        // nested pump saw the completion; there is nothing to deliver and
        // nobody else owns the transfer anymore.
        self.removeConn(msg.conn);
        transfer._conn = null;
        transfer.deinit();
        return true;
    }

    // A streaming response that has emitted events is committed: its header
    // (and data) already reached the consumer, so it can't be transparently
    // retried as an auth challenge — don't even offer it to CDP, parking it
    // would strand the already-queued events.
    if (!transfer.res.stream.started and (effective_err == null or effective_err.? == error.RecvError)) {
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
            self.intercepted += 1;
            if (comptime IS_DEBUG) {
                log.debug(.http, "wait for auth interception", .{ .intercepted = self.intercepted });
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
            if (msg.conn.getResponseHeader("location", 0)) |location| switch (transfer.req.redirect) {
                .follow => {
                    try transfer.handleRedirect(location.value);
                    if (!transfer.req.internal) lp.metrics.http_redirects.incr();

                    const conn = transfer._conn.?;

                    try self.handles.remove(conn);
                    // Conn temporarily out of multi during reconfigure.
                    // _detached_conn lets processMessages release it if any of
                    // the steps below throw. State stays .inflight; _conn stays set
                    transfer._detached_conn = conn;

                    transfer.reset();
                    try transfer.configureConn(conn);
                    try self.handles.add(conn);
                    transfer._detached_conn = null;

                    // Get the redirect on the wire now. Any completion messages
                    // this produces are picked up by the processMessages loop
                    // we were called from — no recursion into the pump.
                    _ = try self.handles.perform();

                    return false;
                },
                // error_callback surfaces this as a TypeError.
                .@"error" => {
                    self.removeConn(msg.conn);
                    transfer._conn = null;
                    transfer.failAsync(error.RedirectNotAllowed);
                    return true;
                },
                // Don't follow; fall through to deliver the 3xx as the final
                // response, which the fetch layer turns into an opaque redirect.
                .manual => {},
            };
        }
    }

    // Transfer is done (success or error). Materialize the response into the
    // transfer's arena, release the conn, and buffer the events — user
    // callbacks run later, from dispatch(), never from here.

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

    if (effective_err != null and !is_conn_close_recv) {
        self.removeConn(msg.conn);
        transfer._conn = null;
        transfer.failAsync(transfer.res.callback_error orelse effective_err.?);
        return true;
    }

    try transfer.materializeResponse(msg.conn);

    // Latency is only meaningful for responses that hit the network (cache
    // and synthetic responses never reach processOneMessage).
    if (!transfer.req.internal) {
        if (msg.conn.getTotalTimeMicros()) |micros| {
            lp.metrics.http_duration_ms.observe(@intCast(@max(0, @divTrunc(micros, 1000))));
        } else |_| {}
    }

    // Release the conn before any of this response's callbacks can run —
    // they'll want it for the next resource.
    self.removeConn(msg.conn);
    transfer._conn = null;

    if (try self.cacheRevalidated(transfer)) {
        return true;
    }
    self.cacheStore(transfer);

    transfer._cdp_content_length = transfer.getContentLength() orelse 0;
    try transfer.bufferEvents(transfer.res.buffer.items);
    return true;
}

// Commit a configured conn to the multi handle. On error the conn is left
// with the caller (makeRequest's catch and WebSocket.init's errdefer
// release it).
pub fn trackConn(self: *Client, conn: *http.Connection) !void {
    // Set private pointer so readMessage can find the Connection.
    // Must be done each time since curl_easy_reset clears it when
    // connections are returned to pool.
    try conn.setPrivate(conn);
    try self.handles.add(conn);

    self.in_use.append(&conn.node);
    switch (conn.transport) {
        .http => self.http_active += 1,
        .websocket => self.ws_active += 1,
        else => unreachable,
    }
}

pub fn removeConn(self: *Client, conn: *http.Connection) void {
    self.in_use.remove(&conn.node);
    switch (conn.transport) {
        .http => self.http_active -= 1,
        .websocket => self.ws_active -= 1,
        else => unreachable,
    }
    // User code never runs inside perform anymore, so this can't be a
    // mid-perform removal; a failure here is a usage bug.
    self.handles.remove(conn) catch |err| {
        lp.assert(false, "multi_remove_handle", .{ .err = err });
    };
    self.releaseConn(conn);
}

fn releaseConn(self: *Client, conn: *http.Connection) void {
    self.network.releaseConnection(conn);
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.http_active > 0 or self.ws_active > 0) {
        return error.InflightConnection;
    }
}

pub const Request = struct {
    pub const StartCallback = *const fn (transfer: *Transfer) anyerror!void;
    pub const HeaderCallback = *const fn (transfer: *Transfer) anyerror!Transfer.HeaderResult;
    pub const DataCallback = *const fn (transfer: *Transfer, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    pub const ResourceType = enum {
        document,
        xhr,
        script,
        fetch,
        stylesheet,
        eventsource,

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
                .eventsource => "EventSource",
            };
        }
    };

    // Fetch request redirect mode. `.follow` keeps navigations, XHR and
    // internal requests transparently following redirects.
    pub const RedirectMode = enum { follow, manual, @"error" };

    frame_id: u32,
    loader_id: u32,
    method: Method,
    url: [:0]const u8,
    // Empty by default; the client fills in its baseline headers (user
    // agent, sec-ch-ua, accept-language) when none are supplied.
    headers: http.Headers = .{ .headers = null },
    body: ?[]const u8 = null,
    cookie_jar: ?*CookieJar,
    cookie_origin: [:0]const u8,
    resource_type: ResourceType,
    redirect: RedirectMode = .follow,
    credentials: ?[:0]const u8 = null,
    notification: *Notification,
    timeout_ms: u32 = 0,
    skip_cache: bool = false,

    // Requests that are internal to the browser and skip various layers,
    // these do not need to be deferred and do not obey robots.txt.
    internal: bool = false,

    // Set by syncRequest; only used to label the http_requests metric.
    sync: bool = false,

    // Deliver the response body progressively: data_callback can fire multiple
    // times. Currently, streaming request always bypass the cache as they are only
    // used for EventSource.
    streaming: bool = false,

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

    // Fired exactly once if the transfer is torn down by its owner (frame /
    // worker teardown, a superseding navigation) before completing. It must
    // drop any stored *Transfer and must not run JS. Deliberately has no
    // default: anyone holding a *Transfer forgets this at their peril, so
    // every caller decides — pass `HttpClient.noopShutdown` to opt out,
    // knowingly.
    shutdown_callback: ShutdownCallback,

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

pub const SyncResponse = struct {
    status: u16,
    body: std.ArrayList(u8),

    pub fn deinit(self: *SyncResponse, allocator: Allocator) void {
        self.body.deinit(allocator);
    }
};

// CDP Fetch.continueWithAuth: resume a transfer parked on an auth
// challenge. The auth retry goes straight back to the network — it already
// passed the request-side pipeline on its first attempt.
pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (comptime IS_DEBUG) {
        log.debug(.http, "continue transfer", .{ .intercepted = self.intercepted });
    }

    transfer.unpark();
    self.processTransfer(transfer) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

// CDP Fetch.continueRequest: resume a transfer parked at the interception
// gate, re-entering the pipeline at the step after interception. The CDP
// command may have mutated req (url / method / headers / body) first.
pub fn continueIntercepted(self: *Client, transfer: *Transfer) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "Client.continueIntercepted", .{ .value = self.intercepted });
    }

    transfer.unpark();
    self.pipeline(transfer, .after_intercept) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

// CDP Fetch.fulfillRequest: resolve a parked transfer with an interceptor-
// supplied response. A redirect status with a Location header is followed
// like a real network redirect; anything else is buffered for dispatch —
// the consumer's callbacks never run from the CDP command itself.
pub fn fulfillIntercepted(
    self: *Client,
    transfer: *Transfer,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "Client.fulfillIntercepted", .{ .value = self.intercepted });
    }

    transfer.unpark();

    const followed = blk: {
        if (isRedirectStatus(status) == false) {
            break :blk false;
        }
        const location = findHeader(headers, "location") orelse break :blk false;
        try self.fulfillRedirect(transfer, status, headers, location);
        break :blk true;
    };

    if (followed) {
        return;
    }

    transfer.bufferFulfilled(status, headers, body) catch |err| {
        transfer.abortPipelineError(err);
        return err;
    };
}

fn fulfillRedirect(
    self: *Client,
    transfer: *Transfer,
    status: u16,
    headers: []const http.Header,
    location: []const u8,
) !void {
    errdefer |err| transfer.abortPipelineError(err);

    // retrieve cookies from the fulfilled response's headers.
    if (transfer.req.cookie_jar) |jar| {
        for (headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                try jar.populateFromResponse(transfer.req.url, hdr.value);
            }
        }
    }

    try transfer.applyRedirectTarget(transfer.req.url, location, status);
    try self.pipeline(transfer, .after_intercept);
}

// The explicit opt-out for Request.shutdown_callback, for callers that hold
// no reference to the transfer (or whose cleanup runs through other paths).
pub fn noopShutdown(_: *anyopaque) void {}

const Noop = struct {
    fn headerCallback(_: *Transfer) !Transfer.HeaderResult {
        return .proceed;
    }
    fn dataCallback(_: *Transfer, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

// Debug-only stubs installed on retirement. Unlike detachInDelivery's Noop
// set (which curl legitimately drains through), nothing may ever invoke a
// callback on a retired transfer.
const Poison = struct {
    fn headerCallback(_: *Transfer) anyerror!Transfer.HeaderResult {
        @panic("callback on retired transfer");
    }
    fn dataCallback(_: *Transfer, _: []const u8) anyerror!void {
        @panic("callback on retired transfer");
    }
    fn doneCallback(_: *anyopaque) anyerror!void {
        @panic("callback on retired transfer");
    }
    fn errorCallback(_: *anyopaque, _: anyerror) void {
        @panic("callback on retired transfer");
    }
    fn shutdownCallback(_: *anyopaque) void {
        @panic("callback on retired transfer");
    }
};

// An opaque-from-the-outside handle that Frame / WorkerGlobalScope embed
// to track the HTTP transfers + WebSockets they own.
pub const Owner = struct {
    transfers: std.DoublyLinkedList = .{},
    websockets: std.DoublyLinkedList = .{},

    // The owning Frame's / WorkerGlobalScope's blob: registry,
    blob_urls: ?*const std.StringHashMapUnmanaged(*Blob) = null,

    const Blob = @import("../browser/webapi/Blob.zig");

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
    res: Response = .{},
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

    // Linked into client.pending_queue while .queued; reused to link the
    // retired transfer into client.graveyard (deinit unlinks it from the
    // pending queue first, so the node is always free by then).
    _node: std.DoublyLinkedList.Node = .{},

    // Buffered response ordered events awaiting dispatch.
    _events: std.ArrayList(Event) = .{},

    // controls if _queue_node is in client.dispatch_queue (false) or
    // client.gated_queue (true)
    _gated: bool = false,

    // True while _queue_node is linked into dispatch_queue/gated_queue.
    // A streaming transfer can be queued while still .inflight (in the multi)
    _dispatch_queued: bool = false,

    _queue_node: std.DoublyLinkedList.Node = .{},

    // Mirror this transfer's lifecycle as CDP Network.* events (serve mode).
    _notify_cdp: bool = false,

    // Response came from the http cache; drives the served-from-cache
    // notification at delivery.
    _from_cache: bool = false,

    // What the cache wants from this transfer's response.
    _cache_intent: CacheIntent = .none,

    // Cache key captured at lookup time (req.url before any redirect
    // rewrote it). Only meaningful while _cache_intent != .none.
    _cache_key: [:0]const u8 = "",

    // Content length reported on the CDP loadingFinished event.
    _cdp_content_length: usize = 0,

    // Set by the first deinit. A retired transfer is unlinked from
    // everything and sits on client.graveyard
    _retired: bool = false,

    pub const State = union(enum) {
        // Pre-commit. Only valid inside the request flow (Client.request
        // or a re-entry like continueTransfer / unpark) before any commit
        // point hands the transfer to an external owner. Client.request's
        // errdefer uses `.created` to decide whether to abort.
        created,

        // On client.queue, waiting for a libcurl handle. `_node` is
        // linked into client.queue.
        queued,

        // Response events are buffered on `_events`, waiting for dispatch
        // to deliver them. `_queue_node` is linked into
        // client.dispatch_queue. No conn is held.
        buffered,

        // Conn (in `_conn`) is in the multi handle; libcurl owns the
        // lifecycle. processOneMessage will eventually fire callbacks
        // for us.
        inflight,

        // deliver() is running user callbacks (abort() also latches this
        // to defer re-entrant teardown). For a buffered transfer no conn
        // is held; a streaming transfer's conn is still in the multi and
        // the state returns to .inflight after the batch.
        delivering,

        // External owner is holding the transfer paused. The owner is
        // responsible for resuming or terminating it.
        parked: ParkedBy,

        // detachInDelivery ran; user callbacks are noop'd, owner link is
        // cleared, deliver() will deinit when its loop exits. `_conn`
        // (if any) is what `deinit` will release.
        aborted,
    };

    pub const ParkedBy = enum {
        // CDP Fetch interception, request phase.
        intercept_request,

        // CDP auth challenge — processOneMessage stashed the transfer
        // waiting for continueWithAuth.
        intercept_auth,

        // RobotsGate holds the transfer pending a robots.txt fetch.
        robots,
    };

    pub const HeaderResult = enum {
        /// Continue processing normally.
        proceed,
        /// Abort the Transfer,
        abort,
    };

    // Gate-facing: park the transfer for an external owner. The caller
    // must be holding the transfer in the request flow (state == .created).
    pub fn park(self: *Transfer, by: ParkedBy) void {
        lp.assert(self.state == .created, "Transfer.park", .{ .state = self.state });
        self.state = .{ .parked = by };
    }

    // Gate-facing: take the transfer out of .parked and return it to
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
                lp.assert(self.client.intercepted > 0, "Transfer.leaveIntercept", .{ .value = self.client.intercepted });
                self.client.intercepted -= 1;
            },
        }
    }

    // Submit a transfer created with Client.newRequest, entering the
    // request pipeline. Consumes the caller's ownership unconditionally:
    // on failure the transfer is already cleaned up (error_callback fired,
    // memory freed) — do not deinit it, and do not touch it after this.
    pub fn submit(self: *Transfer) anyerror!void {
        if (!self.req.internal) {
            lp.metrics.http_requests.incr(if (self.req.sync) .sync else .async);
        }
        // Synthetic schemes never touch the network — no robots, cache, or
        // interception. The response is materialized here and delivered by
        // the dispatcher like any other transfer.
        if (Synthetic.isSynthetic(self.req.url)) {
            Synthetic.buffer(self) catch |err| {
                // Buffer the failure too (blob-not-found is a normal
                // JS-visible TypeError). Delivered like any other error (e.g
                // asynchronously in deliver).
                self.failAsync(err);
            };
            return;
        }

        self.client.pipeline(self, .start) catch |err| {
            self.abortPipelineError(err);
            return err;
        };
    }

    pub fn deinit(self: *Transfer) void {
        if (self._retired) {
            // transfer.deinit should be called once. But _retired and the graveyard
            // are a safety net born out of UAFs.
            if (comptime IS_DEBUG) {
                lp.assert(false, "Transfer.deinit on retired transfer", .{ .id = self.id });
            }
            return;
        }
        self._retired = true;
        self.leaveIntercept();
        if (self._conn) |c| {
            self.client.removeConn(c);
            self._conn = null;
        }

        // Unlink from client.pending_queue if we were waiting for a handle.
        if (self.state == .queued) {
            self.client.pending_queue.remove(&self._node);
        }

        // Same for the dispatch queue: a queued transfer (buffered, or
        // streaming with a pending batch) killed out-of-band (owner
        // teardown, abort) must not be delivered.
        if (self._dispatch_queued) {
            if (self._gated) {
                self.client.gated_queue.remove(&self._queue_node);
            } else {
                self.client.dispatch_queue.remove(&self._queue_node);
            }
            self.client.dispatch_count -= 1;
            self._dispatch_queued = false;
        }

        // And for the robots gate: RobotsGate.pending holds a raw *Transfer
        // while we're parked.
        if (self.state == .parked and self.state.parked == .robots) {
            self.client.robots.remove(self);
        }

        // A pending revalidation entry owns cache resources (possibly an
        // open file). It's resolved at completion; if we die first, release.
        switch (self._cache_intent) {
            .revalidate => |stale| stale.data.deinit(),
            .none, .store => {},
        }

        // Drop the id→*Transfer index entry before freeing the memory.
        // Any concurrent CDP lookup by id will now see this transfer as gone.
        _ = self.client.transfers.remove(self.id);

        self.req.deinit();
        if (self.owner) |o| {
            o.removeTransfer(self);
        }

        if (comptime IS_DEBUG) {
            // Any callback on a corpse is a bug — fail loudly instead of
            // silently running user code from a retired transfer.
            self.req.start_callback = null;
            self.req.header_callback = Poison.headerCallback;
            self.req.data_callback = Poison.dataCallback;
            self.req.done_callback = Poison.doneCallback;
            self.req.error_callback = Poison.errorCallback;
            self.req.shutdown_callback = Poison.shutdownCallback;
        }

        // Why not free the memory here? It _should_ be safe, but the flow is
        // complicated, and history tells us we'll get UAF. The above effectively
        // rendered the transfer dead,but it's memory alive, just incase
        // something uses it. We'll clean it up when it's likely to be safer.
        self.client.graveyard.append(&self._node);
    }

    // Cancel this transfer with `err`. Fires error_callback once (latched
    // via _notified_fail), then either deinits synchronously or, if
    // deliver() is running our callbacks, detaches and lets deliver()
    // deinit when its loop exits.
    //
    // This is the ONE entry point external callers should use to cancel
    // a transfer. Don't reach for kill() or requestFailed() directly —
    // they're internal helpers.
    pub fn abort(self: *Transfer, err: anyerror) void {
        // error_callback can run JS that tears this transfer down again
        // (e.g. an XHR abort handler navigates -> abortRequests -> kill).
        // Hold the state at .delivering so the re-entrant teardown defers,
        // then do the single real teardown against the original state.
        const state = self.state;
        self.state = .delivering;
        self.requestFailed(err);
        self.state = state;
        self.detachOrDeinit();
    }

    // A pipeline entry point failed. The pipeline still owns the transfer in
    // two states: .created and .inflight. In all other states, the owner
    // delivers the failure.
    pub fn abortPipelineError(self: *Transfer, err: anyerror) void {
        switch (self.state) {
            .created, .inflight => self.abort(err),
            else => {},
        }
    }

    // Abort a transfer that an external owner (CDP interception) is holding
    // in a .parked state.
    pub fn abortParked(self: *Transfer, err: anyerror) void {
        self.unpark();
        self.failAsync(err);
    }

    // Owner-driven teardown: fires shutdown_callback (not error_callback)
    // and otherwise behaves like abort. Called by Client.abortOwner /
    // abortRequests when a Frame / WGS is being torn down. Any buffered,
    // undelivered events are dropped — the consumer is going away with us.
    fn kill(self: *Transfer) void {
        if (self._notify_cdp and !self._notified_fail) {
            self._notified_fail = true;
            self.req.notification.dispatch(.http_request_fail, &.{
                .transfer = self,
                .err = error.Shutdown,
            });
        }
        self.req.shutdown_callback(self.req.ctx);
        self.detachOrDeinit();
    }

    // Decide whether to tear down now or defer.
    //
    // Only `.delivering` forces deferral — deliver() is running this
    // transfer's callbacks and will call `transfer.deinit` itself after
    // its loop exits; deiniting here would double-free.
    //
    // Otherwise (created / queued / inflight / parked / fully drained),
    // nothing else references this transfer and we can safely deinit
    // inline. User code never runs inside libcurl, so an abort can't
    // arrive mid-perform: removing an .inflight conn from the multi here
    // is always legal.
    fn detachOrDeinit(self: *Transfer) void {
        if (self.state == .delivering) {
            self.detachInDelivery();
        } else {
            self.deinit();
        }
    }

    // Deferred-cleanup path when deliver() owns the transfer.
    //
    // We:
    //   - transition state to `.aborted` so deliver()'s loop stops before
    //     the next event (and, for a streaming transfer whose conn is
    //     still in the multi, so a nested pump's completion path
    //     short-circuits),
    //   - noop every user callback so a nested pump draining the still-
    //     inflight response can't re-enter user code,
    //   - unlink from owner.transfers and clear `owner` so the owning
    //     Frame/WGS can be freed while this transfer is still draining.
    //     transfer.deinit (called by deliver() on exit) sees
    //     `owner == null` and skips the list-remove that would otherwise
    //     UAF against a freed list.
    fn detachInDelivery(self: *Transfer) void {
        // `_conn` (if any) rides through .aborted untouched; deinit
        // releases it once libcurl is done.
        self.state = .aborted;
        self.req.start_callback = null;
        self.req.shutdown_callback = noopShutdown;
        self.req.header_callback = Noop.headerCallback;
        self.req.data_callback = Noop.dataCallback;
        self.req.done_callback = Noop.doneCallback;
        self.req.error_callback = Noop.errorCallback;
        if (self.owner) |o| {
            o.removeTransfer(self);
            self.owner = null;
        }
    }

    // Some type of failure, either internal or external, either explicit or
    // implicit. transfer.abort() is the external and explicit path. There are
    // various internal callers, but the most common is a callback error.
    fn requestFailed(self: *Transfer, err: anyerror) void {
        if (self._notified_fail) {
            return;
        }
        self._notified_fail = true;

        if (!self.req.internal) {
            lp.metrics.http_error.incr(http.errorReason(err));
        }

        if (self._notify_cdp) {
            self.req.notification.dispatch(.http_request_fail, &.{
                .transfer = self,
                .err = err,
            });
        }

        self.req.error_callback(self.req.ctx, err);
    }

    // A consumer callback failed mid-delivery: latch the failure, notify,
    // free. Only called from deliver().
    fn failDelivery(self: *Transfer, err: anyerror) void {
        log.err(.http, "delivery callback", .{ .err = err, .req = self });
        self.requestFailed(err);
        self.deinit();
    }

    // Fail the transfer asynchronously: the error is buffered and
    // error_callback fires from the dispatcher, never from the caller's
    // stack.
    pub fn failAsync(self: *Transfer, err: anyerror) void {
        self._events.append(self.arena, .{ .err = err }) catch {
            // Can't buffer (OOM): failing inline beats losing the error.
            return self.abort(err);
        };
        self.scheduleDispatch();
    }

    // Commit the transfer's buffered events for delivery. From here on the
    // dispatcher owns the transfer's fate; deinit unlinks it if it dies
    // out-of-band first.
    fn scheduleDispatch(self: *Transfer) void {
        if (self.state == .delivering) {
            return;
        }
        if (comptime IS_DEBUG) {
            lp.assert(
                self.state == .created or self.state == .inflight,
                "Transfer.scheduleDispatch",
                .{ .state = self.state },
            );
        }
        self.state = .buffered;
        self.enqueueDispatch();
    }

    fn enqueueDispatch(self: *Transfer) void {
        if (self._dispatch_queued) {
            return;
        }
        self._dispatch_queued = true;
        self.client.dispatch_queue.append(&self._queue_node);
        self.client.dispatch_count += 1;
    }

    // Buffer the standard success event sequence. `body` is either owned by
    // transfer.arena OR, through some other mechanism, outlives the transfer.
    fn bufferEvents(self: *Transfer, body: []const u8) !void {
        // Single delivery point for every successful response — network,
        // cache, and synthetic, on both the sync and async paths. Redirect
        // hops never reach here (they loop back in processOneMessage), so
        // http_status reflects the final response only. Internal requests
        // (robots.txt) are tracked by the robots_* metrics instead.
        if (self.res.stream.started) {
            try self._events.append(self.arena, .done);
            self.scheduleDispatch();
            return;
        }

        if (!self.req.internal) {
            const status = if (self.res.header) |h| h.status else 0;
            lp.metrics.http_status.incr(http.statusCategory(status));
            lp.metrics.http_response_size_bytes.observe(body.len);
        }

        try self._events.ensureUnusedCapacity(self.arena, 4);
        self._events.appendAssumeCapacity(.start);
        self._events.appendAssumeCapacity(.header);
        if (body.len > 0) {
            self._events.appendAssumeCapacity(.{ .data = body });
        }
        self._events.appendAssumeCapacity(.done);
        self.scheduleDispatch();
    }

    fn setResponseHead(self: *Transfer, status: u16, content_type: ?[]const u8) void {
        self.res.header = .{
            .url = self.req.url.ptr,
            .status = status,
            .redirect_count = self._redirect_count,
        };
        if (content_type) |ct| {
            var hdr = &self.res.header.?;
            const len = @min(ct.len, http.ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], ct[0..len]);
        }
    }

    // Serve a cache entry as this transfer's response. Takes ownership of
    // `cached` (file-backed bodies are read into the arena and closed).
    fn bufferCached(self: *Transfer, cached: Cache.CachedResponse) !void {
        const arena = self.arena;

        const body: []const u8 = switch (cached.data) {
            .buffer => |b| b,
            .file => |f| blk: {
                defer f.file.close();
                const buf = try arena.alloc(u8, f.len);
                const n = try f.file.preadAll(buf, f.offset);
                break :blk buf[0..n];
            },
        };

        self.setResponseHead(cached.metadata.status, cached.metadata.content_type);
        self.res.headers = cached.metadata.headers;
        self._from_cache = true;
        self._cdp_content_length = body.len;
        try self.bufferEvents(body);
    }

    // Materialize an interceptor-supplied response (CDP fulfillRequest).
    // `headers` and `body` are caller-owned; copy everything that must
    // survive until dispatch.
    fn bufferFulfilled(self: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
        const arena = self.arena;

        const owned = try arena.alloc(http.Header, headers.len);
        var content_type: ?[]const u8 = null;
        for (headers, 0..) |hdr, i| {
            owned[i] = .{
                .name = try arena.dupe(u8, hdr.name),
                .value = try arena.dupe(u8, hdr.value),
            };
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                content_type = owned[i].value;
            }
        }

        const owned_body: []const u8 = if (body) |b| try arena.dupe(u8, b) else "";

        self.setResponseHead(status, content_type);
        self.res.headers = owned;
        self._cdp_content_length = owned_body.len;
        try self.bufferEvents(owned_body);
    }

    // Copy everything the response needs out of the conn and into the
    // transfer arena. After this, delivery never touches libcurl state —
    // the conn can be released and reused before the consumer sees a byte.
    fn materializeResponse(self: *Transfer, conn: *http.Connection) !void {
        if (self.res.stream.started) {
            // Streaming: already materialized at the first delivered chunk.
            return;
        }
        const arena = self.arena;

        if (self.res.header == null) {
            try self.buildResponseHeader(conn);
        }
        // buildResponseHeader stores a curl-owned url pointer; re-anchor it
        // in the arena so it survives the conn release.
        self.res.header.?.url = (try arena.dupeZ(u8, std.mem.span(self.res.header.?.url))).ptr;

        var it = HeaderIterator{ .curl = .{ .conn = conn } };
        const headers = try it.collect(arena);
        self.res.headers = headers.items;

        if (self.req.cookie_jar) |jar| {
            for (self.res.headers) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                    jar.populateFromResponse(self.req.url, hdr.value) catch |err| {
                        log.err(.http, "set cookie", .{ .err = err, .req = self });
                        return err;
                    };
                }
            }
        }

        if (self.getContentLength()) |cl| {
            if (cl > self.client.max_response_size) {
                return error.ResponseTooLarge;
            }
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
        } else if (req.streaming) {
            try conn.setTimeout(0);
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
        self.res.buffer.clearRetainingCapacity();
        self.res = .{
            .buffer = self.res.buffer,
            .stream = .{ .spare = self.res.stream.spare },
        };
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
            const len = @min(value.len, http.ResponseHead.MAX_CONTENT_TYPE_LEN);
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
            log.debug(.http, "abort auth transfer", .{ .intercepted = self.client.intercepted });
        }

        // The transfer is still .parked(.intercept_auth)
        self.abortParked(error.AbortAuthChallenge);
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
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
                res.buffer.ensureTotalCapacity(transfer.arena, cl) catch {};
            }
        }

        if (res.skip_body) {
            return @intCast(chunk_len);
        }

        res.bytes_received += chunk_len;

        const chunk = buffer[0..chunk_len];

        if (transfer.req.streaming) {
            if (transfer.state == .aborted) {
                return http.writefunc_error;
            }
            // A stream's total is unbounded by design; cap the undelivered
            // batch instead — that's what actually occupies memory.
            if (res.buffer.items.len + chunk_len > transfer.client.max_response_size) {
                res.callback_error = error.ResponseTooLarge;
                return http.writefunc_error;
            }
            transfer.streamChunk(conn, chunk) catch |err| {
                res.callback_error = err;
                return http.writefunc_error;
            };
            return @intCast(chunk_len);
        }

        if (res.bytes_received > transfer.client.max_response_size) {
            res.callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        res.buffer.appendSlice(transfer.arena, chunk) catch |err| {
            res.callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.state == .aborted) {
            return http.writefunc_error;
        }

        return @intCast(chunk_len);
    }

    fn streamChunk(self: *Transfer, conn: *http.Connection, chunk: []const u8) !void {
        const res = &self.res;
        if (res.stream.started == false) {
            // we haven't delivered the start/header events yet
            try self.materializeResponse(conn);
            try self._events.ensureUnusedCapacity(self.arena, 3);
            self._events.appendAssumeCapacity(.start);
            self._events.appendAssumeCapacity(.header);
            res.stream.started = true;
        }
        // append the data to whatever data we already have (but haven't delivered)
        try res.buffer.appendSlice(self.arena, chunk);
        if (res.stream.data_queued == false) {
            res.stream.data_queued = true;
            try self._events.append(self.arena, .stream_data);
        }

        switch (self.state) {
            .inflight => self.enqueueDispatch(),
            // deliver() is mid-batch on this transfer; its loop consumes
            // events appended behind its cursor.
            .delivering => {},
            else => if (comptime IS_DEBUG) {
                lp.assert(false, "Transfer.scheduleStreamDispatch", .{ .state = self.state });
            },
        }
    }

    // Response-view accessors. Callbacks receive the *Transfer once the
    // response is materialized, so these are always safe from a callback;
    // header/status are null before that point.
    pub fn responseStatus(self: *const Transfer) ?u16 {
        const rh = self.res.header orelse return null;
        return rh.status;
    }

    pub fn contentType(self: *Transfer) ?[]const u8 {
        if (self.res.header) |*rh| {
            return rh.contentType();
        }
        return null;
    }

    pub fn redirectCount(self: *const Transfer) ?u32 {
        const rh = self.res.header orelse return null;
        return rh.redirect_count;
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        if (self.res.headers.len > 0 or self._conn == null) {
            return .{ .list = .{ .list = self.res.headers } };
        }
        // Mid-stream (pump time): headers aren't materialized yet, read
        // them off the live conn.
        return .{ .curl = .{ .conn = self._conn.? } };
    }

    pub fn getContentLength(self: *const Transfer) ?usize {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(usize, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        // Materialized headers (dispatch time, any source).
        for (self.res.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        // Mid-stream (curl's write callback): read from the live conn.
        if (self._conn) |c| {
            const cl = c.getResponseHeader("content-length", 0) orelse return null;
            return cl.value;
        }

        return null;
    }

    // Only ever called from tick, delivers buffered events to their consumer.
    // A buffered (completed) transfer gets exactly one deliver() and dies at
    // the end of it. A streaming transfer gets one deliver() per dispatched
    // batch and stays inflight between batches, until a terminal event
    // (done / err) or an abort.
    fn deliver(transfer: *Transfer) void {
        // A streaming batch is delivered while the conn is still inflight;
        // that state is restored after the batch unless it turned terminal.
        const was_inflight = transfer.state == .inflight;

        // Important. If a callback tries to kill the transfer (e.g. abort()),
        // this will cause the teardown to be deferred so that it doesn't get
        // freed from under us.
        transfer.state = .delivering;

        const req = &transfer.req;
        if (transfer._from_cache) {
            req.notification.dispatch(
                .http_request_served_from_cache,
                &.{ .transfer = transfer },
            );
        }

        // Index loop, re-reading len and items on every iteration: a
        // streaming transfer's callback can re-enter the pump (syncRequest)
        // and append more events — possibly the terminal one — to the batch
        // being delivered.
        var terminal = !was_inflight;
        var i: usize = 0;
        while (i < transfer._events.items.len) : (i += 1) {
            if (transfer.state == .aborted) {
                // the state can become aborted as events are processed, check
                // it on every iteration.
                break;
            }
            const event = transfer._events.items[i];
            switch (event) {
                .start => {
                    if (req.start_callback) |cb| {
                        cb(transfer) catch |err| {
                            return transfer.failDelivery(err);
                        };
                    }
                },
                .header => {
                    if (transfer._notify_cdp) {
                        req.notification.dispatch(.http_response_header_done, &.{
                            .transfer = transfer,
                        });
                    }
                    const result = req.header_callback(transfer) catch |err| {
                        return transfer.failDelivery(err);
                    };
                    if (result == .abort) {
                        return transfer.failDelivery(error.Abort);
                    }
                },
                .data => |chunk| {
                    if (transfer._notify_cdp) {
                        req.notification.dispatch(.http_response_data, &.{
                            .data = chunk,
                            .transfer = transfer,
                        });
                    }
                    req.data_callback(transfer, chunk) catch |err| {
                        return transfer.failDelivery(err);
                    };
                },
                .stream_data => {
                    // Move the batch into stream.spare and deliver it from
                    // there: chunks received during the callback (re-entrant
                    // pump) append to the swapped-in buffer and queue a new
                    // .stream_data that this loop picks up, while the batch
                    // the consumer is reading stays untouched. The batch is
                    // only valid during the callback — it's cleared right
                    // after, ready to be swapped back in.
                    const res = &transfer.res;
                    res.stream.data_queued = false;
                    std.mem.swap(std.ArrayList(u8), &res.buffer, &res.stream.spare);
                    const chunk = res.stream.spare.items;
                    if (transfer._notify_cdp) {
                        req.notification.dispatch(.http_response_data, &.{
                            .data = chunk,
                            .transfer = transfer,
                        });
                    }
                    req.data_callback(transfer, chunk) catch |err| {
                        return transfer.failDelivery(err);
                    };
                    res.stream.spare.clearRetainingCapacity();
                },
                .done => {
                    terminal = true;
                    if (transfer._notify_cdp) {
                        req.notification.dispatch(.http_request_done, &.{
                            .transfer = transfer,
                            .content_length = transfer._cdp_content_length,
                        });
                    }
                    req.done_callback(req.ctx) catch |err| {
                        return transfer.failDelivery(err);
                    };
                },
                .err => |err| {
                    terminal = true;
                    transfer.requestFailed(err);
                    break;
                },
            }
        }

        if (transfer.state == .aborted or terminal) {
            transfer.deinit();
            return;
        }

        // Mid-stream batch fully delivered; the conn is still receiving.
        transfer._events.clearRetainingCapacity();
        transfer.state = .inflight;
    }
};

// Response-state owned by this transfer's currently-in-flight response.
// Reset on every retry (auth retry, redirect) via Transfer.reset — only
// the cross-retry counters (_auth_challenge, _redirect_count) live on
// Transfer itself. Consumers read it through the accessors above
// (status / contentType / responseHeaderIterator / getContentLength).
const Response = struct {
    header: ?http.ResponseHead = null,

    // Full response headers, materialized into the transfer arena at
    // completion (or set directly by cache / synthetic / fulfill).
    headers: []const http.Header = &.{},

    // total bytes received in the response, including the response status
    // line, the headers, and the [encoded] body.
    bytes_received: usize = 0,

    skip_body: bool = false,
    first_data_received: bool = false,

    // Response body. Filled by dataCallback, consumed in processMessages.
    // See Stream.spare to see how this works in streaming mode
    buffer: std.ArrayList(u8) = .{},

    // Error captured in dataCallback to be reported in processMessages.
    callback_error: ?anyerror = null,

    // State for streaming. Unused in non-streaming
    stream: Stream = .{},

    const Stream = struct {
        // Whether we've queued the start/header events or not
        started: bool = false,

        // We only queue one .stream_data event at a time, it drains whatever
        // has accumulated since the last deliver
        data_queued: bool = false,

        // Along with the main Response.buffer, acts as a double buffer allowing
        // us to accumulate new data while in a delivery callback.
        spare: std.ArrayList(u8) = .{},
    };
};

// A single buffered response event. The payload of `data` has transfer-arena
// lifetime. `done`, and `err` are terminal — nothing follows them.
const Event = union(enum) {
    start,
    header,
    data: []const u8,
    stream_data, // the payload is carried in res.stream.data_queued
    done,
    err: anyerror,
};

// What the http cache wants from a transfer's response.
const CacheIntent = union(enum) {
    none,

    // Inspect the response at completion and store it if cacheable.
    store,

    // Conditional request in flight; on a 304 the stale entry is renewed
    // and served. Owns the entry (possibly an open file) until resolved.
    revalidate: Cache.CachedResponse,
};

// Non-network URL schemes whose response is synthesized in-process rather than
// fetched, think blob data URLs.
const Synthetic = struct {
    const data_url = @import("../browser/data_url.zig");

    fn isSynthetic(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:");
    }

    // Materialize the synthetic response onto the transfer and buffer it for
    // dispatch — delivered exactly like any other response.
    fn buffer(transfer: *Transfer) !void {
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
            // blob can be removed by the time we run, dupe it.
            content_type = try arena.dupe(u8, blob._mime);
            body = try arena.dupe(u8, blob._slice);
        }

        const has_content_type = content_type.len > 0;
        transfer.setResponseHead(200, if (has_content_type) content_type else null);
        if (content_type.len > 0) {
            const h = try arena.alloc(http.Header, 1);
            h[0] = .{ .name = "content-type", .value = content_type };
            transfer.res.headers = h;
        }
        transfer._cdp_content_length = body.len;
        try transfer.bufferEvents(body);
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

fn initTestClient(client: *Client, pool: *ArenaPool) void {
    client.* = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = pool;
    client.transfers = .empty;
    client.blocking_requests = .empty;
    client.pending_queue = .{};
    client.dispatch_queue = .{};
    client.gated_queue = .{};
    client.ws_dispatch_queue = .{};
    client.ws_dispatch_count = 0;
    client.graveyard = .{};
    client.dispatch_count = 0;
    client.intercepted = 0;
    client.cache = null;
    client.serve_mode = false;
    client.obey_robots = false;
    client.robots = .{ .allocator = testing.allocator, .network = undefined };
}

test "HttpClient: fulfillIntercepted survives a done_callback that tears down the owner" {
    // Regression: the fulfilled response's done_callback runs JS which
    // navigates / closes the page, re-entrantly killing the transfer
    // (abortOwner -> kill). deliver() holds the transfer in `.delivering`,
    // so the teardown defers and there is exactly one free.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
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
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .shutdown_callback = noopShutdown,
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

    // Mirror the interception gate committing the transfer to CDP.
    transfer.park(.intercept_request);
    client.intercepted += 1;

    try client.fulfillIntercepted(transfer, 200, &.{}, "hello");
    // The response is buffered, not delivered from the CDP command.
    try testing.expectEqual(false, ctx.done_called);
    try testing.expectEqual(1, client.dispatch_count);

    _ = client.dispatchCompleted(.all);

    try testing.expect(ctx.done_called);
    // The transfer was freed exactly once: counter back to 0, dropped from the
    // id index and the owner list. A double-free would have underflowed
    // `intercepted` (or tripped the leaveIntercept assert).
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.dispatch_count);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: aborting a robots-parked transfer unlinks it from the gate" {
    // Regression: RobotsGate.pending kept a raw *Transfer with nothing
    // removing it when a parked transfer was aborted out-of-band
    // (xhr.abort(), owner teardown). The robots.txt resolution would then
    // unpark freed memory.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);
    defer client.robots.deinit();

    const robots_url = "http://example.com/robots.txt";

    var waiting: std.ArrayList(*Transfer) = .empty;
    for (0..2) |i| {
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
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .shutdown_callback = noopShutdown,
            },
            .client = &client,
            .id = @intCast(i + 1),
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
        try waiting.append(testing.allocator, transfer);
        transfer.park(.robots);
    }
    try client.robots.pending.putNoClobber(testing.allocator, robots_url, waiting);

    const t1 = client.robots.pending.get(robots_url).?.items[0];
    const t2 = client.robots.pending.get(robots_url).?.items[1];

    t1.abort(error.Abort);
    try testing.expectEqual(1, client.robots.pending.get(robots_url).?.items.len);
    try testing.expect(client.robots.pending.get(robots_url).?.items[0] == t2);
    try testing.expectEqual(1, client.transfers.count());

    t2.abort(error.Abort);
    try testing.expectEqual(0, client.robots.pending.get(robots_url).?.items.len);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: fulfillIntercepted follows a 3xx redirect" {
    // Regression for #2828: a CDP Fetch.fulfillRequest with a 3xx status + a
    // Location header must be followed like a real network redirect (re-issued
    // through the pipeline to the resolved target), not delivered as a final
    // response.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Only network.config (httpMaxRedirects, which ignores its config),
    // network.cache and the (empty) connection pool are read on this path.
    var net: Network = undefined;
    net.cache = null;
    // An empty pool makes processTransfer queue the re-issued request
    // instead of putting it on the wire — the queue IS the capture.
    net.available = .{};
    net.conn_mutex = .{};

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    client.network = &net;
    defer client.transfers.deinit(testing.allocator);

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
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .shutdown_callback = noopShutdown,
                .ctx = undefined,
            },
            .client = &client,
            .id = 1,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.intercepted += 1;

        try client.fulfillIntercepted(transfer, 302, &.{
            .{ .name = "Location", .value = "/end" },
        }, null);

        // Re-issued (queued for the network), not delivered.
        try testing.expectEqual(true, transfer.state == .queued);
        try testing.expectEqual("http://example.com/end", transfer.req.url);
        try testing.expectEqual(.GET, transfer.req.method);
        try testing.expectEqual(null, transfer.req.body);
        // Unparked exactly once; transfer is still alive.
        try testing.expectEqual(0, client.intercepted);
        try testing.expectEqual(1, client.transfers.count());
        transfer.deinit();
    }

    // 307 with an absolute Location: keep method and body.
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
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .shutdown_callback = noopShutdown,
                .ctx = undefined,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.intercepted += 1;

        try client.fulfillIntercepted(transfer, 307, &.{
            .{ .name = "location", .value = "http://example.com/other" },
        }, null);

        try testing.expectEqual(true, transfer.state == .queued);
        try testing.expectEqual("http://example.com/other", transfer.req.url);
        try testing.expectEqual(.POST, transfer.req.method);
        try testing.expectEqual("payload", transfer.req.body.?);
        try testing.expectEqual(0, client.intercepted);
        transfer.deinit();
    }
}

test "HttpClient: fulfillIntercepted delivers a 3xx without a Location as the response" {
    // A redirect status with no Location header is not a redirect: the body is
    // delivered as the final response (matching the real-network path).
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
    defer client.transfers.deinit(testing.allocator);

    const Ctx = struct {
        done_called: bool = false,
        status: ?u16 = null,

        fn headerCallback(transfer: *Transfer) !Transfer.HeaderResult {
            const self: *@This() = @ptrCast(@alignCast(transfer.req.ctx));
            self.status = transfer.responseStatus();
            return .proceed;
        }

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
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .shutdown_callback = noopShutdown,
            .ctx = &ctx,
            .header_callback = Ctx.headerCallback,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

    transfer.park(.intercept_request);
    client.intercepted += 1;

    try client.fulfillIntercepted(transfer, 302, &.{}, "body");
    _ = client.dispatchCompleted(.all);

    // Delivered (done_callback ran) and freed exactly once.
    try testing.expect(ctx.done_called);
    try testing.expectEqual(302, ctx.status.?);
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: abortParked survives an error_callback that tears down the owner" {
    // Same re-entrancy hazard as fulfillRequest, but on the abort path
    // (failRequest / continueWithAuth-cancel / session teardown). abortParked
    // buffers the failure; deliver() fires it while .delivering, so a
    // re-entrant owner teardown defers to the single deinit instead of
    // double-freeing.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
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
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .shutdown_callback = noopShutdown,
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
    client.intercepted += 1;

    transfer.abortParked(error.Abort);

    // The failure is buffered, not delivered from the CDP command itself —
    // error_callback JS must not run on a blocking request's stack.
    try testing.expectEqual(false, ctx.err_called);
    try testing.expectEqual(0, client.intercepted);
    try testing.expectEqual(1, client.dispatch_count);

    _ = client.dispatchCompleted(.all);

    try testing.expect(ctx.err_called);
    try testing.expectEqual(0, client.dispatch_count);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: abort survives an error_callback that tears down the owner" {
    // Regression: abort() fired error_callback before detachOrDeinit, so JS
    // in that callback that killed the transfer again (navigation ->
    // abortRequests -> kill) freed it inline and abort() then ran
    // detachOrDeinit on freed memory. abort holds .delivering across
    // requestFailed so the re-entrant kill defers to the single teardown.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    initTestClient(&client, &pool);
    // Runs before pool.deinit (LIFO): retired arenas must go back first.
    defer client.processGraveyard();
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

    // .created — abort before the transfer was committed anywhere.
    {
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
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .xhr,
                .notification = undefined,
                .shutdown_callback = noopShutdown,
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

        transfer.abort(error.Abort);

        try testing.expect(ctx.err_called);
        try testing.expectEqual(0, client.transfers.count());
        try testing.expectEqual(null, owner.transfers.first);
    }

    // .buffered — abort while queued for dispatch; the queue must end up
    // empty and the transfer freed exactly once.
    {
        ctx.err_called = false;
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
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .xhr,
                .notification = undefined,
                .shutdown_callback = noopShutdown,
                .ctx = &ctx,
                .error_callback = Ctx.errorCallback,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
        owner.addTransfer(transfer);
        transfer.owner = &owner;

        transfer.state = .buffered;
        transfer._dispatch_queued = true;
        client.dispatch_queue.append(&transfer._queue_node);
        client.dispatch_count += 1;

        transfer.abort(error.Abort);

        try testing.expect(ctx.err_called);
        try testing.expectEqual(0, client.dispatch_count);
        try testing.expectEqual(null, client.dispatch_queue.first);
        try testing.expectEqual(0, client.transfers.count());
        try testing.expectEqual(null, owner.transfers.first);
    }
}

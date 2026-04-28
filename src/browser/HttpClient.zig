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

const URL = @import("URL.zig");
const Notification = @import("../Notification.zig");
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;

const http = @import("../network/http.zig");
const Network = @import("../network/Network.zig");
const Robots = @import("../network/Robots.zig");
const timestamp = @import("../datetime.zig").timestamp;

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

// This is loosely tied to a browser Page. Loading all the <scripts>, doing
// XHR requests, and loading imports all happens through here. Sine the app
// currently supports 1 browser and 1 frame at-a-time, we only have 1 Client and
// re-use it from frame to frame. This allows us better re-use of the various
// buffers/caches (including keepalive connections) that libcurl has.
//
// The app has other secondary http needs, like telemetry. While we want to
// share some things (namely the ca blob, and maybe some configuration
// (TODO: ??? should proxy settings be global ???)), we're able to do call
// client.abort() to abort the transfers being made by a frame, without impacting
// those other http requests.
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

// When handles has no more available easys, requests get queued.
queue: std.DoublyLinkedList = .{},

// Queue is for Transfers that have no connection. ready_queue is for connections
// that were initiated when performing == true and thus need to wait until
// performing == false before being added. I'm hoping this is temporary and that
// we can unify the two queues. But HTTP is being changed a lot right now, and
// I'm trying to minimize the surface area.
ready_queue: std.DoublyLinkedList = .{},

// The main app allocator
allocator: Allocator,

network: *Network,

// Once we have a handle/easy to process a request with, we create a Transfer
// which contains the Request as well as any state we need to process the
// request. These will come and go with each request.
transfer_pool: std.heap.MemoryPool(Transfer),

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
        request: *const fn (*anyopaque, *Client, Request) anyerror!void,
    };

    pub fn request(self: Layer, client: *Client, req: Request) !void {
        return self.vtable.request(self.ptr, client, req);
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
    blocking_read_start: *const fn (*anyopaque) bool,
    blocking_read: *const fn (*anyopaque) bool,
    blocking_read_end: *const fn (*anyopaque) bool,
};

pub fn init(allocator: Allocator, network: *Network) !*Client {
    var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
    errdefer transfer_pool.deinit();

    const client = try allocator.create(Client);
    errdefer allocator.destroy(client);

    var handles = try http.Handles.init(network.config);
    errdefer handles.deinit();

    const http_proxy = network.config.httpProxy();

    client.* = .{
        .handles = handles,
        .network = network,
        .allocator = allocator,
        .transfer_pool = transfer_pool,

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .obey_robots = network.config.obeyRobots(),
        .max_response_size = network.config.httpMaxResponseSize() orelse std.math.maxInt(u32),

        .cache_layer = .{},
        .robots_layer = .{ .allocator = allocator },
        .web_bot_auth_layer = .{},
        .interception_layer = .{},
        .entry_layer = undefined,
    };

    var next = client.layer();

    if (network.config.obeyRobots()) {
        next = layerWith(&client.robots_layer, next);
    }

    if (network.config.httpCacheDir() != null) {
        next = layerWith(&client.cache_layer, next);
    }

    next = layerWith(&client.interception_layer, next);

    if (network.config.webBotAuth() != null) {
        next = layerWith(&client.web_bot_auth_layer, next);
    }

    client.entry_layer = next;

    return client;
}

pub fn deinit(self: *Client) void {
    self.abort();
    self.handles.deinit();

    self.transfer_pool.deinit();
    self.clearUserAgentOverride();

    self.robots_layer.deinit(self.allocator);

    self.allocator.destroy(self);
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
    self._abort(true, 0);
}

pub fn abortFrame(self: *Client, frame_id: u32) void {
    self._abort(false, frame_id);
}

// Written this way so that both abort and abortFrame can share the same code
// but abort can avoid the frame_id check at comptime.
fn _abort(self: *Client, comptime abort_all: bool, frame_id: u32) void {
    abortConnections(self.in_use, abort_all, frame_id);
    abortConnections(self.ready_queue, abort_all, frame_id);

    {
        var q = &self.queue;
        var n = q.first;
        while (n) |node| {
            n = node.next;
            const transfer: *Transfer = @fieldParentPtr("_node", node);
            if (comptime abort_all) {
                transfer.kill();
            } else if (transfer.req.params.frame_id == frame_id) {
                q.remove(node);
                transfer.kill();
            }
        }
    }

    if (comptime abort_all) {
        self.queue = .{};
        self.ready_queue = .{};
    }

    if (comptime IS_DEBUG and abort_all) {
        // Even after an abort_all, we could still have transfers, but, at the
        // very least, they should all be flagged as aborted.
        var it = self.in_use.first;
        var leftover: usize = 0;
        while (it) |node| : (it = node.next) {
            const conn: *http.Connection = @fieldParentPtr("node", node);
            switch (conn.transport) {
                .http => |transfer| std.debug.assert(transfer.aborted),
                .websocket => {},
                .none => {},
            }
            leftover += 1;
        }
        std.debug.assert(self.http_active == leftover);
    }
}

fn abortConnections(list: std.DoublyLinkedList, comptime abort_all: bool, frame_id: u32) void {
    var n = list.first;
    while (n) |node| {
        n = node.next;
        const conn: *http.Connection = @fieldParentPtr("node", node);
        switch (conn.transport) {
            .http => |transfer| {
                if ((comptime abort_all) or transfer.req.params.frame_id == frame_id) {
                    transfer.kill();
                }
            },
            .websocket => |ws| {
                if ((comptime abort_all) or ws._frame._frame_id == frame_id) {
                    ws.kill();
                }
            },
            .none => unreachable,
        }
    }
}

pub fn tick(self: *Client, timeout_ms: u32) !PerformStatus {
    while (self.queue.popFirst()) |queue_node| {
        const conn = self.network.getConnection() orelse {
            self.queue.prepend(queue_node);
            break;
        };

        try self.makeRequest(conn, @fieldParentPtr("_node", queue_node));
    }

    return self.perform(@intCast(timeout_ms));
}

pub fn _request(ptr: *anyopaque, _: *Client, req: Request) !void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    const transfer = try self.makeTransfer(req);
    return self.process(transfer);
}

pub fn request(self: *Client, req: Request) !void {
    // Assign Request Id.
    var our_req = req;
    our_req.params.request_id = self.incrReqId();

    const arena = try self.network.app.arena_pool.acquire(.small, "Request.arena");
    our_req.params.arena = arena;

    return self.entry_layer.request(self, our_req) catch |err| {
        our_req.error_callback(our_req.ctx, err);
        self.deinitRequest(our_req);
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

pub fn syncRequest(self: *Client, allocator: Allocator, params: RequestParams) !SyncResponse {
    var sync_ctx = SyncContext{ .allocator = allocator, .body = .empty };
    errdefer sync_ctx.body.deinit(allocator);

    try self.request(.{
        .params = params,
        .ctx = &sync_ctx,
        .header_callback = SyncContext.headerCallback,
        .data_callback = SyncContext.dataCallback,
        .done_callback = SyncContext.doneCallback,
        .error_callback = SyncContext.errorCallback,
        .shutdown_callback = SyncContext.shutdownCallback,
    });

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
    // libcurl doesn't allow recursive calls, if we're in a `perform()` operation
    // then we _have_ to queue this.
    if (self.performing == false) {
        if (self.network.getConnection()) |conn| {
            return self.makeRequest(conn, transfer);
        }
    }

    self.queue.append(&transfer._node);
}

pub fn nextReqId(self: *Client) u32 {
    return self.next_request_id +% 1;
}

pub fn incrReqId(self: *Client) u32 {
    const id = self.next_request_id +% 1;
    self.next_request_id = id;
    return id;
}

fn makeTransfer(self: *Client, req: Request) !*Transfer {
    const transfer = try self.transfer_pool.create();
    errdefer self.transfer_pool.destroy(transfer);

    transfer.* = .{
        .start_time = timestamp(.monotonic),
        .id = req.params.request_id,
        .url = req.params.url,
        .req = req,
        .client = self,
    };
    return transfer;
}

fn requestFailed(transfer: *Transfer, err: anyerror, comptime execute_callback: bool) void {
    if (transfer._notified_fail) {
        // we can force a failed request within a callback, which will eventually
        // result in this being called again in the more general loop. We do this
        // because we can raise a more specific error inside a callback in some cases
        return;
    }

    transfer._notified_fail = true;

    if (execute_callback) {
        transfer.req.error_callback(transfer.req.ctx, err);
    } else if (transfer.req.shutdown_callback) |cb| {
        cb(transfer.req.ctx);
    }
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
            transfer.deinit();
            self.releaseConn(conn);
        }

        try transfer.configureConn(conn);
    }

    // As soon as this is called, our "perform" loop is responsible for
    // cleaning things up. That's why the above code is in a block. If anything
    // fails BEFORE `curl_multi_add_handle` succeeds, the we still need to do
    // cleanup. But if things fail after `curl_multi_add_handle`, we expect
    // perform to pickup the failure and cleanup.
    self.trackConn(conn) catch |err| {
        transfer._conn = null;
        transfer.deinit();
        return err;
    };

    if (transfer.req.start_callback) |cb| {
        cb(Response.fromTransfer(transfer)) catch |err| {
            transfer.deinit();
            return err;
        };
    }
    _ = try self.perform(0);
}

pub const PerformStatus = enum {
    cdp_socket,
    normal,
};

fn perform(self: *Client, timeout_ms: c_int) anyerror!PerformStatus {
    const running = blk: {
        self.performing = true;
        defer self.performing = false;

        break :blk try self.handles.perform();
    };

    // Process dirty connections — return them to Network pool.
    while (self.dirty.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        self.handles.remove(conn) catch |err| {
            log.fatal(.http, "multi remove handle", .{ .err = err, .src = "perform" });
            @panic("multi_remove_handle");
        };
        self.releaseConn(conn);
    }

    while (self.ready_queue.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try self.trackConn(conn);
    }

    // We're potentially going to block for a while until we get data. Process
    // whatever messages we have waiting ahead of time.
    if (try self.processMessages()) {
        return .normal;
    }

    var status = PerformStatus.normal;
    if (self.cdp_client) |cdp_client| {
        var wait_fds = [_]http.WaitFd{.{
            .fd = cdp_client.socket,
            .events = .{ .pollin = true },
            .revents = .{},
        }};
        try self.handles.poll(&wait_fds, timeout_ms);
        if (wait_fds[0].revents.pollin or wait_fds[0].revents.pollpri or wait_fds[0].revents.pollout) {
            status = .cdp_socket;
        }
    } else if (running > 0) {
        try self.handles.poll(&.{}, timeout_ms);
    }

    _ = try self.processMessages();
    return status;
}

fn processOneMessage(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
    if (msg.err == null or msg.err.? == error.RecvError) {
        transfer.detectAuthChallenge(msg.conn);
    }

    // In case of auth challenge
    // TODO give a way to configure the number of auth retries.
    if (transfer._auth_challenge != null and transfer._tries < 10) {
        var wait_for_interception = false;
        transfer.req.params.notification.dispatch(
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

    // Handle redirects: reuse the same connection to preserve TCP state.
    if (msg.err == null) {
        const status = try msg.conn.getResponseCode();
        if (status >= 300 and status <= 399) {
            try transfer.handleRedirect();

            const conn = transfer._conn.?;

            try self.handles.remove(conn);
            transfer._conn = null;
            transfer._detached_conn = conn; // signal orphan for processMessages cleanup

            transfer.reset();
            try transfer.configureConn(conn);
            try self.handles.add(conn);
            transfer._detached_conn = null;
            transfer._conn = conn; // reattach after successful re-add

            _ = try self.perform(0);

            return false;
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
        const err = msg.err orelse break :blk false;
        if (err != error.RecvError) break :blk false;
        const hdr = msg.conn.getResponseHeader("connection", 0) orelse break :blk true;
        break :blk std.ascii.eqlIgnoreCase(hdr.value, "close");
    };

    // make sure the transfer can't be immediately aborted from a callback
    // since we still need it here.
    transfer._performing = true;
    defer transfer._performing = false;

    if (msg.err != null and !is_conn_close_recv) {
        transfer.requestFailed(transfer._callback_error orelse msg.err.?, true);
        return true;
    }

    if (!transfer._header_done_called) {
        // In case of request w/o data, we need to call the header done
        // callback now.
        const proceed = try transfer.headerDoneCallback(msg.conn);
        if (!proceed) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    const body = transfer._stream_buffer.items;

    // Replay buffered body through user's data_callback.
    if (transfer._stream_buffer.items.len > 0) {
        try transfer.req.data_callback(Response.fromTransfer(transfer), body);

        if (transfer.aborted) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    // release conn ASAP so that it's available; some done_callbacks
    // will load more resources.
    transfer.releaseConn();

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
        self.releaseConn(conn);
    } else |_| {
        // Can happen if we're in a perform() call, so we'll queue this
        // for cleanup later.
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

pub const RequestParams = struct {
    /// This is unsafe to access until you pass it to `Client.request()` where it gets assigned.
    arena: Allocator = undefined,
    /// This is unsafe to access until you pass it to `Client.request()` where it gets assigned.
    request_id: u32 = undefined,

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

    const ResourceType = enum {
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

    pub fn deinit(self: *const RequestParams) void {
        self.headers.deinit();
    }
};

pub const Request = struct {
    pub const StartCallback = *const fn (response: Response) anyerror!void;
    pub const HeaderCallback = *const fn (response: Response) anyerror!bool;
    pub const DataCallback = *const fn (response: Response, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    params: RequestParams,
    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?StartCallback = null,
    header_callback: HeaderCallback,
    data_callback: DataCallback,
    done_callback: DoneCallback,
    error_callback: ErrorCallback,
    shutdown_callback: ?ShutdownCallback = null,

    pub fn getCookieString(self: *Request) !?[:0]const u8 {
        const jar = self.params.cookie_jar orelse return null;
        var aw: std.Io.Writer.Allocating = .init(self.params.arena);
        try jar.forRequest(self.params.url, &aw.writer, .{
            .is_http = true,
            .origin_url = self.params.cookie_origin,
            .is_navigation = self.params.resource_type == .document,
        });
        const written = aw.written();
        if (written.len == 0) return null;
        try aw.writer.writeByte(0);
        return written.ptr[0..written.len :0];
    }

    pub fn deinit(self: *const Request) void {
        self.params.deinit();
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
            .transfer => |t| if (t.response_header) |rh| rh.status else null,
            .cached => |c| c.metadata.status,
            .fulfilled => |f| f.status,
        };
    }

    pub fn contentType(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| if (t.response_header) |*rh| rh.contentType() else null,
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
            .transfer => |t| if (t.response_header) |rh| rh.redirect_count else null,
            .cached, .fulfilled => 0,
        };
    }

    pub fn url(self: Response) [:0]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.url,
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
    req: Request,
    url: [:0]const u8,
    client: *Client,
    // total bytes received in the response, including the response status line,
    // the headers, and the [encoded] body.
    bytes_received: usize = 0,

    start_time: u64,
    aborted: bool = false,

    // We'll store the response header here
    response_header: ?ResponseHead = null,

    // track if the header callbacks done have been called.
    _header_done_called: bool = false,

    _notified_fail: bool = false,

    _conn: ?*http.Connection = null,
    // Set when conn is temporarily detached from transfer during redirect
    // reconfiguration. Used by processMessages to release the orphaned conn
    // if reconfiguration fails.
    _detached_conn: ?*http.Connection = null,

    _auth_challenge: ?http.AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,
    _performing: bool = false,
    _redirect_count: u8 = 0,
    _skip_body: bool = false,
    _first_data_received: bool = false,

    // Buffered response body. Filled by dataCallback, consumed in processMessages.
    _stream_buffer: std.ArrayList(u8) = .{},

    // Error captured in dataCallback to be reported in processMessages.
    _callback_error: ?anyerror = null,

    // for when a Transfer is queued in the client.queue
    _node: std.DoublyLinkedList.Node = .{},

    fn releaseConn(self: *Transfer) void {
        if (self._conn) |conn| {
            self.client.removeConn(conn);
            self._conn = null;
        }
    }

    fn deinit(self: *Transfer) void {
        if (self._conn) |conn| {
            self.client.removeConn(conn);
            self._conn = null;
        }

        self.client.deinitRequest(self.req);
        self.client.transfer_pool.destroy(self);
    }

    pub fn abort(self: *Transfer, err: anyerror) void {
        self.requestFailed(err, true);

        if (self._performing or self.client.performing) {
            // We're currently in a curl_multi_perform. We cannot call
            // curl_multi_remove_handle from a curl callback. Instead, we flag
            // this transfer and our callbacks will check for this flag.
            self.aborted = true;
            return;
        }

        self.deinit();
    }

    pub fn terminate(self: *Transfer) void {
        self.requestFailed(error.Shutdown, false);
        self.deinit();
    }

    // internal, when the frame is shutting down. Doesn't have the same ceremony
    // as abort (doesn't send a notification, doesn't invoke an error callback)
    fn kill(self: *Transfer) void {
        if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }

        if (self._performing or self.client.performing) {
            // We're currently inside of a callback. This client, and libcurl
            // generally don't expect a transfer to become deinitialized during
            // a callback. We can flag the transfer as aborted (which is what
            // we do when transfer.abort() is called in this condition) AND,
            // since this "kill()"should prevent any future callbacks, the best
            // we can do is null/noop them.
            self.aborted = true;
            self.req.start_callback = null;
            self.req.shutdown_callback = null;
            self.req.header_callback = Noop.headerCallback;
            self.req.data_callback = Noop.dataCallback;
            self.req.done_callback = Noop.doneCallback;
            self.req.error_callback = Noop.errorCallback;
            return;
        }

        self.deinit();
    }

    // We can force a failed request within a callback, which will eventually
    // result in this being called again in the more general loop. We do this
    // because we can raise a more specific error inside a callback in some cases.
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

        try conn.setURL(req.params.url);
        try conn.setMethod(req.params.method);
        if (req.params.body) |b| {
            try conn.setBody(b);
        } else {
            try conn.setGetMode();
        }

        var header_list = req.params.headers;
        try conn.secretHeaders(&header_list, &client.network.config.http_headers);
        try conn.setHeaders(&header_list);

        // Add cookies from cookie jar.
        if (try self.req.getCookieString()) |cookies| {
            try conn.setCookies(@ptrCast(cookies.ptr));
        }

        conn.transport = .{ .http = self };

        // Per-request timeout override (e.g. XHR timeout)
        if (req.params.timeout_ms > 0) {
            try conn.setTimeout(req.params.timeout_ms);
        }

        // add credentials
        if (req.params.credentials) |creds| {
            if (self._auth_challenge != null and self._auth_challenge.?.source == .proxy) {
                try conn.setProxyCredentials(creds);
            } else {
                try conn.setCredentials(creds);
            }
        }
    }

    pub fn reset(self: *Transfer) void {
        // Note: do NOT reset _auth_challenge here. It is needed by makeRequest
        // to determine whether to use setProxyCredentials vs setCredentials.
        self._notified_fail = false;
        self.response_header = null;
        self.bytes_received = 0;
        self._tries += 1;
        self._stream_buffer.clearRetainingCapacity();
        self._callback_error = null;
        self._skip_body = false;
        self._first_data_received = false;
    }

    fn buildResponseHeader(self: *Transfer, conn: *const http.Connection) !void {
        if (comptime IS_DEBUG) {
            std.debug.assert(self.response_header == null);
        }

        const url = try conn.getEffectiveUrl();

        const status: u16 = if (self._auth_challenge != null)
            407
        else
            try conn.getResponseCode();

        self.response_header = .{
            .url = url,
            .status = status,
            .redirect_count = self._redirect_count,
        };

        if (conn.getResponseHeader("content-type", 0)) |ct| {
            var hdr = &self.response_header.?;
            const value = ct.value;
            const len = @min(value.len, ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        const req = self.req;
        return writer.print("{s} {s}", .{ @tagName(req.params.method), req.params.url });
    }

    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        // for cookies
        self.url = url;

        // for the request itself
        self.req.params.url = url;
    }

    fn handleRedirect(transfer: *Transfer) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;
        const arena = transfer.req.params.arena;

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        // retrieve cookies from the redirect's response.
        if (req.params.cookie_jar) |jar| {
            var i: usize = 0;
            while (conn.getResponseHeader("set-cookie", i)) |ct| : (i += 1) {
                try jar.populateFromResponse(transfer.url, ct.value);

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
                const original_hash = URL.getHash(transfer.url);
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
            req.params.method = .GET;
            req.params.body = null;
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
        self.req.params.credentials = userpwd;
    }

    pub fn replaceRequestHeaders(self: *Transfer, allocator: Allocator, headers: []const http.Header) !void {
        self.req.params.headers.deinit();

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
        self.req.params.headers = new_headers;
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
        lp.assert(transfer._header_done_called == false, "Transfer.headerDoneCallback", .{});
        defer transfer._header_done_called = true;

        try transfer.buildResponseHeader(conn);

        if (transfer.req.params.cookie_jar) |jar| {
            var i: usize = 0;
            while (true) {
                const ct = conn.getResponseHeader("set-cookie", i);
                if (ct == null) break;
                jar.populateFromResponse(transfer.url, ct.?.value) catch |err| {
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

        const proceed = transfer.req.header_callback(Response.fromTransfer(transfer)) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        return proceed and transfer.aborted == false;
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) usize {
        // libcurl should only ever emit 1 chunk at a time
        if (comptime IS_DEBUG) {
            std.debug.assert(chunk_count == 1);
        }

        const conn: *http.Connection = @ptrCast(@alignCast(data));
        var transfer = conn.transport.http;

        if (!transfer._first_data_received) {
            transfer._first_data_received = true;

            // Skip body for responses that will be retried (redirects, auth challenges).
            const status = conn.getResponseCode() catch |err| {
                log.err(.http, "getResponseCode", .{ .err = err, .source = "body callback" });
                return http.writefunc_error;
            };
            if ((status >= 300 and status <= 399) or status == 401 or status == 407) {
                transfer._skip_body = true;
                return @intCast(chunk_len);
            }

            // Pre-size buffer from Content-Length.
            if (transfer.getContentLength()) |cl| {
                if (cl > transfer.client.max_response_size) {
                    transfer._callback_error = error.ResponseTooLarge;
                    return http.writefunc_error;
                }
                transfer._stream_buffer.ensureTotalCapacity(transfer.req.params.arena, cl) catch {};
            }
        }

        if (transfer._skip_body) return @intCast(chunk_len);

        transfer.bytes_received += chunk_len;
        if (transfer.bytes_received > transfer.client.max_response_size) {
            transfer._callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        const chunk = buffer[0..chunk_len];
        transfer._stream_buffer.appendSlice(transfer.req.params.arena, chunk) catch |err| {
            transfer._callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.aborted) {
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

        const rh = self.response_header orelse return null;
        for (rh._injected_headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        return null;
    }
};

pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.interception_layer.intercepted > 0, "HttpClient.continueTransfer", .{ .value = self.interception_layer.intercepted });
        log.debug(.http, "continue transfer", .{ .intercepted = self.interception_layer.intercepted });
    }

    self.interception_layer.intercepted -= 1;
    return self.process(transfer);
}

pub fn deinitRequest(self: *Client, req: Request) void {
    req.deinit();
    self.network.app.arena_pool.release(req.params.arena);
}

const Noop = struct {
    fn headerCallback(_: Response) !bool {
        return true;
    }
    fn dataCallback(_: Response, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

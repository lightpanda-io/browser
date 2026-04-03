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
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const lp = @import("lightpanda");
const log = lp.log;
const URL = @import("URL.zig");
const Config = @import("../Config.zig");
const Notification = @import("../Notification.zig");
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;
const WebSocket = @import("webapi/net/WebSocket.zig");

const http = @import("../network/http.zig");
const Network = @import("../network/Network.zig");

const Robots = @import("../network/Robots.zig");
const Cache = @import("../network/cache/Cache.zig");
const CachedResponse = Cache.CachedResponse;
const WebBotAuth = @import("../network/WebBotAuth.zig");

const IS_DEBUG = builtin.mode == .Debug;

pub const Method = http.Method;
pub const Headers = http.Headers;
pub const ResponseHead = http.ResponseHead;
pub const HeaderIterator = http.HeaderIterator;

pub const CacheLayer = @import("../network/layer/CacheLayer.zig");
pub const RobotsLayer = @import("../network/layer/RobotsLayer.zig");
pub const WebBotAuthLayer = @import("../network/layer/WebBotAuthLayer.zig");

pub const PerformStatus = enum { cdp_socket, normal };

pub const Transport = struct {
    active: usize = 0,

    // Count of intercepted requests. This is to help deal with intercepted
    // requests. The client doesn't track intercepted transfers. If a request
    // is intercepted, the client forgets about it and requires the interceptor
    // to continue or abort it. That works well, except if we only rely on
    // active, we might think there's no more network activity when, with
    // intercepted requests, there might be more in the future. (We really only
    // need this to properly emit a 'networkIdle' and 'networkAlmostIdle'
    // Page.lifecycleEvent in CDP).
    intercepted: usize = 0,

    handles: http.Handles,
    in_use: std.DoublyLinkedList = .{},
    dirty: std.DoublyLinkedList = .{},
    performing: bool = false,
    next_request_id: u32 = 0,
    queue: std.DoublyLinkedList = .{},
    allocator: Allocator,
    network: *Network,
    transfer_pool: std.heap.MemoryPool(Transfer),
    http_proxy: ?[:0]const u8 = null,
    use_proxy: bool,
    tls_verify: bool = true,
    cdp_client: ?CDPClient = null,
    max_response_size: usize,

    pub fn init(allocator: Allocator, net: *Network) !*Transport {
        var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
        errdefer transfer_pool.deinit();

        const t = try allocator.create(Transport);
        errdefer allocator.destroy(t);

        var handles = try http.Handles.init(net.config);
        errdefer handles.deinit();

        const http_proxy = net.config.httpProxy();
        t.* = .{
            .handles = handles,
            .network = net,
            .allocator = allocator,
            .transfer_pool = transfer_pool,
            .use_proxy = http_proxy != null,
            .http_proxy = http_proxy,
            .tls_verify = net.config.tlsVerifyHost(),
            .max_response_size = net.config.httpMaxResponseSize() orelse std.math.maxInt(usize),
        };
        return t;
    }

    pub fn deinit(self: *Transport) void {
        self.abort();
        self.handles.deinit();
        self.transfer_pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn layer(self: *Transport) Layer {
        return .{
            .ptr = self,
            .vtable = &.{ .request = _request },
        };
    }

    pub fn setTlsVerify(self: *Transport, verify: bool) !void {
        var it = self.in_use.first;
        while (it) |node| : (it = node.next) {
            const conn: *http.Connection = @fieldParentPtr("node", node);
            try conn.setTlsVerify(verify, self.use_proxy);
        }
        self.tls_verify = verify;
    }

    pub fn changeProxy(self: *Transport, proxy: ?[:0]const u8) !void {
        try self.ensureNoActiveConnection();
        self.http_proxy = proxy orelse self.network.config.httpProxy();
        self.use_proxy = self.http_proxy != null;
    }

    pub fn restoreOriginalProxy(self: *Transport) !void {
        try self.ensureNoActiveConnection();
        self.http_proxy = self.network.config.httpProxy();
        self.use_proxy = self.http_proxy != null;
    }

    pub fn newHeaders(self: *const Transport) !http.Headers {
        return http.Headers.init(self.network.config.http_headers.user_agent_header);
    }

    pub fn abort(self: *Transport) void {
        self._abort(true, 0);
    }

    pub fn abortFrame(self: *Transport, frame_id: u32) void {
        self._abort(false, frame_id);
    }

    fn _abort(self: *Transport, comptime abort_all: bool, frame_id: u32) void {
        {
            var n = self.in_use.first;
            while (n) |node| {
                n = node.next;
                const conn: *http.Connection = @fieldParentPtr("node", node);
                switch (conn.transport) {
                    .http => |transfer| {
                        if ((comptime abort_all) or transfer.req.frame_id == frame_id) {
                            transfer.kill();
                        }
                    },
                    .websocket => |ws| {
                        if ((comptime abort_all) or ws._page._frame_id == frame_id) {
                            ws.kill();
                        }
                    },
                    .none => unreachable,
                }
            }
        }

        {
            var q = &self.queue;
            var n = q.first;
            while (n) |node| {
                n = node.next;
                const transfer: *Transfer = @fieldParentPtr("_node", node);
                if (comptime abort_all) {
                    transfer.kill();
                } else if (transfer.req.frame_id == frame_id) {
                    q.remove(node);
                    transfer.kill();
                }
            }
        }

        if (comptime abort_all) {
            self.queue = .{};
        }

        if (comptime IS_DEBUG and abort_all) {
            // Even after an abort_all, we could still have transfers, but, at
            // the very least, they should all be flagged as aborted.
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
            std.debug.assert(self.active == leftover);
        }
    }

    pub fn tick(self: *Transport, timeout_ms: u32) !PerformStatus {
        while (self.queue.popFirst()) |queue_node| {
            const conn = self.network.getConnection() orelse {
                self.queue.prepend(queue_node);
                break;
            };
            try self.makeRequest(conn, @fieldParentPtr("_node", queue_node));
        }
        return self.perform(@intCast(timeout_ms));
    }

    /// Core entry point.
    pub fn _request(ptr: *anyopaque, _: Context, req: Request) !void {
        const self: *Transport = @ptrCast(@alignCast(ptr));
        const transfer = try self.makeTransfer(req);

        transfer.req.notification.dispatch(.http_request_start, &.{ .transfer = transfer });

        var wait_for_interception = false;
        transfer.req.notification.dispatch(.http_request_intercept, &.{
            .transfer = transfer,
            .wait_for_interception = &wait_for_interception,
        });
        if (wait_for_interception == false) {
            return self.process(transfer);
        }

        self.intercepted += 1;
        if (comptime IS_DEBUG) {
            log.debug(.http, "wait for interception", .{ .intercepted = self.intercepted });
        }
        transfer._intercept_state = .pending;

        if (req.blocking == false) {
            return;
        }
        if (try self.waitForInterceptedResponse(transfer)) {
            return self.process(transfer);
        }
    }

    fn waitForInterceptedResponse(self: *Transport, transfer: *Transfer) !bool {
        const cdp_client = self.cdp_client.?;
        const ctx = cdp_client.ctx;

        if (cdp_client.blocking_read_start(ctx) == false) {
            return error.BlockingInterceptFailure;
        }
        defer _ = cdp_client.blocking_read_end(ctx);

        while (true) {
            if (cdp_client.blocking_read(ctx) == false) {
                return error.BlockingInterceptFailure;
            }
            switch (transfer._intercept_state) {
                .pending => continue,
                .@"continue" => return true,
                .abort => |err| {
                    transfer.abort(err);
                    return false;
                },
                .fulfilled => {
                    transfer.deinit();
                    return false;
                },
                .not_intercepted => unreachable,
            }
        }
    }

    fn process(self: *Transport, transfer: *Transfer) !void {
        if (self.performing == false) {
            if (self.network.getConnection()) |conn| {
                return self.makeRequest(conn, transfer);
            }
        }
        self.queue.append(&transfer._node);
    }

    pub fn continueTransfer(self: *Transport, transfer: *Transfer) !void {
        if (comptime IS_DEBUG) {
            std.debug.assert(transfer._intercept_state != .not_intercepted);
            log.debug(.http, "continue transfer", .{ .intercepted = self.intercepted });
        }
        self.intercepted -= 1;
        if (!transfer.req.blocking) {
            return self.process(transfer);
        }
        transfer._intercept_state = .@"continue";
    }

    pub fn abortTransfer(self: *Transport, transfer: *Transfer) void {
        if (comptime IS_DEBUG) {
            std.debug.assert(transfer._intercept_state != .not_intercepted);
            log.debug(.http, "abort transfer", .{ .intercepted = self.intercepted });
        }
        self.intercepted -= 1;
        if (!transfer.req.blocking) {
            transfer.abort(error.Abort);
        }
        transfer._intercept_state = .{ .abort = error.Abort };
    }

    pub fn fulfillTransfer(self: *Transport, transfer: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
        if (comptime IS_DEBUG) {
            std.debug.assert(transfer._intercept_state != .not_intercepted);
            log.debug(.http, "fulfill transfer", .{ .intercepted = self.intercepted });
        }
        self.intercepted -= 1;
        try transfer.fulfill(status, headers, body);
        if (!transfer.req.blocking) {
            transfer.deinit();
            return;
        }
        transfer._intercept_state = .fulfilled;
    }

    pub fn nextReqId(self: *Transport) u32 {
        return self.next_request_id +% 1;
    }

    pub fn incrReqId(self: *Transport) u32 {
        const id = self.next_request_id +% 1;
        self.next_request_id = id;
        return id;
    }

    fn makeTransfer(self: *Transport, req: Request) !*Transfer {
        errdefer req.headers.deinit();

        const transfer = try self.transfer_pool.create();
        errdefer self.transfer_pool.destroy(transfer);

        const id = self.incrReqId();
        transfer.* = .{
            .arena = ArenaAllocator.init(self.allocator),
            .id = id,
            .url = req.url,
            .req = req,
            .client = self,
        };
        return transfer;
    }

    fn makeRequest(self: *Transport, conn: *http.Connection, transfer: *Transfer) anyerror!void {
        {
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

    fn perform(self: *Transport, timeout_ms: c_int) anyerror!PerformStatus {
        const running = blk: {
            self.performing = true;
            defer self.performing = false;
            break :blk try self.handles.perform();
        };

        while (self.dirty.popFirst()) |node| {
            const conn: *http.Connection = @fieldParentPtr("node", node);
            self.handles.remove(conn) catch |err| {
                log.fatal(.http, "multi remove handle", .{ .err = err, .src = "perform" });
                @panic("multi_remove_handle");
            };
            self.releaseConn(conn);
        }

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

    fn processOneMessage(self: *Transport, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
        // Detect auth challenge from response headers.
        // Also check on RecvError: proxy may send 407 with headers before
        // closing the connection (CONNECT tunnel not yet established).
        if (msg.err == null or msg.err.? == error.RecvError) {
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
                transfer._intercept_state = .pending;

                // Whether or not this is a blocking request, we're not going
                // to process it now. We can end the transfer, which will
                // release the easy handle back into the pool. The transfer
                // is still valid/alive (just has no handle).
                transfer.releaseConn();
                if (!transfer.req.blocking) {
                    // In the case of an async request, we can just "forget"
                    // about this transfer until it gets updated asynchronously
                    // from some CDP command.
                    return false;
                }

                // In the case of a sync request, we need to block until we
                // get the CDP command for handling this case.
                if (try self.waitForInterceptedResponse(transfer)) {
                    // we've been asked to continue with the request
                    // we can't process it here, since we're already inside
                    // a process, so we need to queue it and wait for the
                    // next tick (this is why it was safe to releaseConn
                    // above, because even in the "blocking" path, we still
                    // only process it on the next tick).
                    self.queue.append(&transfer._node);
                } else {
                    // aborted, already cleaned up
                }

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

            transfer.req.notification.dispatch(.http_response_data, &.{
                .data = body,
                .transfer = transfer,
            });

            if (transfer.aborted) {
                transfer.requestFailed(error.Abort, true);
                return true;
            }
        }

        // release conn ASAP so that it's available; some done_callbacks
        // will load more resources.
        transfer.releaseConn();

        try transfer.req.done_callback(transfer.req.ctx);

        transfer.req.notification.dispatch(.http_request_done, &.{
            .transfer = transfer,
        });

        return true;
    }

    fn processMessages(self: *Transport) !bool {
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
                            self.active -= 1;
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

    fn trackConn(self: *Transport, conn: *http.Connection) !void {
        self.in_use.append(&conn.node);
        // Set private pointer so readMessage can find the Connection.
        // Must be done each time since curl_easy_reset clears it when
        // connections are returned to pool.
        conn.setPrivate(conn) catch |err| {
            self.in_use.remove(&conn.node);
            self.releaseConn(conn);
            return err;
        };
        self.handles.add(conn) catch |err| {
            self.in_use.remove(&conn.node);
            self.releaseConn(conn);
            return err;
        };
        self.active += 1;
    }

    fn removeConn(self: *Transport, conn: *http.Connection) void {
        self.in_use.remove(&conn.node);
        self.active -= 1;
        if (self.handles.remove(conn)) {
            self.releaseConn(conn);
        } else |_| {
            self.dirty.append(&conn.node);
        }
    }

    fn releaseConn(self: *Transport, conn: *http.Connection) void {
        self.network.releaseConnection(conn);
    }

    fn ensureNoActiveConnection(self: *const Transport) !void {
        if (self.active > 0) return error.InflightConnection;
    }
};

pub const Context = struct {
    network: *Network,

    pub fn newHeaders(self: Context) !http.Headers {
        return http.Headers.init(self.network.config.http_headers.user_agent_header);
    }
};

pub const Layer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (*anyopaque, Context, Request) anyerror!void,
    };

    pub fn request(self: Layer, ctx: Context, req: Request) !void {
        return self.vtable.request(self.ptr, ctx, req);
    }
};

pub fn LayerStack(comptime layer_types: anytype) type {
    return struct {
        ptrs: [layer_types.len]*anyopaque,
        layers: [layer_types.len]Layer,

        const Self = @This();

        pub fn init(allocator: Allocator, transport: *Transport, instances: anytype) !Self {
            var ptrs: [layer_types.len]*anyopaque = undefined;
            var layers: [layer_types.len]Layer = undefined;

            inline for (layer_types, 0..) |T, i| {
                const ptr = try allocator.create(T);
                ptr.* = instances[i];
                ptrs[i] = ptr;
                layers[i] = ptr.layer();
            }

            // Wire inner: each layer's `next` points to the next layer.
            // Done after all layers are created so pointers are stable.
            inline for (layer_types, 0..) |T, i| {
                if (@hasField(T, "next")) {
                    const ptr: *T = @ptrCast(@alignCast(ptrs[i]));
                    if (i + 1 < layer_types.len) {
                        ptr.next = layers[i + 1];
                    } else {
                        ptr.next = transport.layer();
                    }
                }
            }

            return .{ .ptrs = ptrs, .layers = layers };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            inline for (layer_types, 0..) |T, i| {
                const ptr: *T = @ptrCast(@alignCast(self.ptrs[i]));
                if (@hasDecl(T, "deinit")) ptr.deinit(allocator);
                allocator.destroy(ptr);
            }
        }

        pub fn top(self: *Self) Layer {
            return self.layers[0];
        }
    };
}

pub const Layers = LayerStack(.{ RobotsLayer, WebBotAuthLayer, CacheLayer });

const Client = @This();

transport: *Transport,
layers: Layers,

pub fn init(allocator: Allocator, net: *Network) !*Client {
    const transport = try Transport.init(allocator, net);
    errdefer transport.deinit();

    var layers = try Layers.init(allocator, transport, .{
        RobotsLayer{
            .obey_robots = net.config.obeyRobots(),
            .allocator = allocator,
            .pending = .empty,
        },
        WebBotAuthLayer{
            .auth = if (network.web_bot_auth) |*wba| wba else null,
        },
        CacheLayer{},
    });
    errdefer layers.deinit(allocator);

    const client = try allocator.create(Client);
    errdefer allocator.destroy(client);

    client.* = .{ .transport = transport, .layers = layers };
    return client;
}

pub fn deinit(self: *Client) void {
    const allocator = self.transport.allocator;
    self.layers.deinit(allocator);
    self.transport.deinit();
    allocator.destroy(self);
}

pub fn setTlsVerify(self: *Client, verify: bool) !void {
    return self.transport.setTlsVerify(verify);
}

pub fn changeProxy(self: *Client, proxy: ?[:0]const u8) !void {
    return self.transport.changeProxy(proxy);
}

pub fn restoreOriginalProxy(self: *Client) !void {
    return self.transport.restoreOriginalProxy();
}

pub fn newHeaders(self: *Client) !http.Headers {
    return self.transport.newHeaders();
}

pub fn abort(self: *Client) void {
    self.transport.abort();
}

pub fn abortFrame(self: *Client, frame_id: u32) void {
    self.transport.abortFrame(frame_id);
}

pub fn tick(self: *Client, timeout_ms: u32) !PerformStatus {
    return self.transport.tick(timeout_ms);
}

/// Dispatch a request through the full middleware stack.
pub fn request(self: *Client, req: Request) !void {
    const ctx = Context{ .network = self.transport.network };
    return self.layers.top().request(ctx, req);
}

pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    return self.transport.continueTransfer(transfer);
}

pub fn abortTransfer(self: *Client, transfer: *Transfer) void {
    return self.transport.abortTransfer(transfer);
}

pub fn fulfillTransfer(self: *Client, transfer: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
    return self.transport.fulfillTransfer(transfer, status, headers, body);
}

pub fn nextReqId(self: *Client) u32 {
    return self.transport.nextReqId();
}

pub fn incrReqId(self: *Client) u32 {
    return self.transport.incrReqId();
}

pub fn setCdpClient(self: *Client, cdp_client: ?CDPClient) void {
    self.transport.cdp_client = cdp_client;
}

pub fn cdpClient(self: *Client) ?*CDPClient {
    return &self.transport.cdp_client;
}

pub fn active(self: *Client) usize {
    return self.transport.active;
}

pub fn intercepted(self: *Client) usize {
    return self.transport.intercepted;
}

pub fn network(self: *Client) *Network {
    return self.transport.network;
}

pub fn maxResponseSize(self: *Client) usize {
    return self.transport.max_response_size;
}

pub fn trackConn(self: *Client, conn: *http.Connection) !void {
    return self.transport.trackConn(conn);
}

pub fn removeConn(self: *Client, conn: *http.Connection) void {
    self.transport.removeConn(conn);
}

pub const CDPClient = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    blocking_read_start: *const fn (*anyopaque) bool,
    blocking_read: *const fn (*anyopaque) bool,
    blocking_read_end: *const fn (*anyopaque) bool,
};

pub const Request = struct {
    page_id: u32,
    frame_id: u32,
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
    blocking: bool = false,
    ctx: *anyopaque = undefined,

    start_callback: ?StartCallback = null,
    header_callback: HeaderCallback,
    data_callback: DataCallback,
    done_callback: DoneCallback,
    error_callback: ErrorCallback,
    shutdown_callback: ?ShutdownCallback = null,

    pub const StartCallback = *const fn (response: Response) anyerror!void;
    pub const HeaderCallback = *const fn (response: Response) anyerror!bool;
    pub const DataCallback = *const fn (response: Response, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    const ResourceType = enum {
        document,
        xhr,
        script,
        fetch,

        pub fn string(self: ResourceType) []const u8 {
            return switch (self) {
                .document => "Document",
                .xhr => "XHR",
                .script => "Script",
                .fetch => "Fetch",
            };
        }
    };
};

pub const Response = struct {
    ctx: *anyopaque,
    inner: union(enum) {
        transfer: *Transfer,
        cached: *const CachedResponse,
    },

    pub fn fromTransfer(transfer: *Transfer) Response {
        return .{ .ctx = transfer.req.ctx, .inner = .{ .transfer = transfer } };
    }

    pub fn fromCached(ctx: *anyopaque, resp: *const CachedResponse) Response {
        return .{ .ctx = ctx, .inner = .{ .cached = resp } };
    }

    pub fn status(self: Response) ?u16 {
        return switch (self.inner) {
            .transfer => |t| if (t.response_header) |rh| rh.status else null,
            .cached => |c| c.metadata.status,
        };
    }

    pub fn contentType(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| if (t.response_header) |*rh| rh.contentType() else null,
            .cached => |c| c.metadata.content_type,
        };
    }

    pub fn contentLength(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| t.getContentLength(),
            .cached => |c| switch (c.data) {
                .buffer => |buf| @intCast(buf.len),
                .file => |f| @intCast(f.len),
            },
        };
    }

    pub fn redirectCount(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| if (t.response_header) |rh| rh.redirect_count else null,
            .cached => 0,
        };
    }

    pub fn url(self: Response) [:0]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.url,
            .cached => |c| c.metadata.url,
        };
    }

    pub fn headerIterator(self: Response) HeaderIterator {
        return switch (self.inner) {
            .transfer => |t| t.responseHeaderIterator(),
            .cached => |c| HeaderIterator{ .list = .{ .list = c.metadata.headers } },
        };
    }

    pub fn abort(self: Response, err: anyerror) void {
        switch (self.inner) {
            .transfer => |t| t.abort(err),
            .cached => {},
        }
    }

    pub fn format(self: Response, writer: *std.Io.Writer) !void {
        return switch (self.inner) {
            .transfer => |t| try t.format(writer),
            .cached => |c| try c.format(writer),
        };
    }
};

pub const Transfer = struct {
    arena: ArenaAllocator,
    id: u32 = 0,
    req: Request,
    url: [:0]const u8,
    client: *Transport,
    bytes_received: usize = 0,
    aborted: bool = false,
    response_header: ?ResponseHead = null,
    _header_done_called: bool = false,
    _notified_fail: bool = false,
    _conn: ?*http.Connection = null,
    _detached_conn: ?*http.Connection = null,
    _auth_challenge: ?http.AuthChallenge = null,
    _tries: u8 = 0,
    _performing: bool = false,
    _redirect_count: u8 = 0,
    _skip_body: bool = false,
    _first_data_received: bool = false,
    _stream_buffer: std.ArrayList(u8) = .{},
    _callback_error: ?anyerror = null,
    _node: std.DoublyLinkedList.Node = .{},
    _intercept_state: InterceptState = .not_intercepted,

    const InterceptState = union(enum) {
        not_intercepted,
        pending,
        @"continue",
        abort: anyerror,
        fulfilled,
    };

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
        self.req.headers.deinit();
        self.arena.deinit();
        self.client.transfer_pool.destroy(self);
    }

    pub fn abort(self: *Transfer, err: anyerror) void {
        self.requestFailed(err, true);
        if (self._performing or self.client.performing) {
            self.aborted = true;
            return;
        }
        self.deinit();
    }

    pub fn terminate(self: *Transfer) void {
        self.requestFailed(error.Shutdown, false);
        self.deinit();
    }

    fn kill(self: *Transfer) void {
        if (self.req.shutdown_callback) |cb| cb(self.req.ctx);
        if (self._performing or self.client.performing) {
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

    fn requestFailed(self: *Transfer, err: anyerror, comptime execute_callback: bool) void {
        if (self._notified_fail) return;
        self._notified_fail = true;
        self.req.notification.dispatch(.http_request_fail, &.{
            .transfer = self,
            .err = err,
        });
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

        if (try self.getCookieString()) |cookies| {
            try conn.setCookies(@ptrCast(cookies.ptr));
        }

        conn.transport = .{ .http = self };

        // Per-request timeout override (e.g. XHR timeout)
        if (req.timeout_ms > 0) {
            try conn.setTimeout(req.timeout_ms);
        }

        if (req.credentials) |creds| {
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

    pub fn getCookieString(self: *Transfer) !?[:0]const u8 {
        const jar = self.req.cookie_jar orelse return null;
        var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try jar.forRequest(self.req.url, &aw.writer, .{
            .is_http = true,
            .origin_url = self.req.cookie_origin,
            .is_navigation = self.req.resource_type == .document,
        });
        const written = aw.written();
        if (written.len == 0) return null;
        try aw.writer.writeByte(0);
        return written.ptr[0..written.len :0];
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        return writer.print("{s} {s}", .{ @tagName(self.req.method), self.req.url });
    }

    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        self.url = url;
        self.req.url = url;
    }

    fn handleRedirect(transfer: *Transfer) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;
        const arena = transfer.arena.allocator();

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        if (req.cookie_jar) |jar| {
            var i: usize = 0;
            while (conn.getResponseHeader("set-cookie", i)) |ct| : (i += 1) {
                try jar.populateFromResponse(transfer.url, ct.value);
                if (i >= ct.amount) break;
            }
        }

        const location = conn.getResponseHeader("location", 0) orelse return error.LocationNotFound;
        const base_url = try conn.getEffectiveUrl();
        const url = try URL.resolve(arena, std.mem.span(base_url), location.value, .{});
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
            defer buf.clearRetainingCapacity();
            try std.fmt.format(buf.writer(allocator), "{s}: {s}", .{ hdr.name, hdr.value });
            try buf.append(allocator, 0);
            try new_headers.add(buf.items[0 .. buf.items.len - 1 :0]);
        }
        self.req.headers = new_headers;
    }

    pub fn abortAuthChallenge(self: *Transfer) void {
        if (comptime IS_DEBUG) {
            std.debug.assert(self._intercept_state != .not_intercepted);
            log.debug(.http, "abort auth transfer", .{ .intercepted = self.client.intercepted });
        }
        self.client.intercepted -= 1;
        if (!self.req.blocking) {
            self.abort(error.AbortAuthChallenge);
            return;
        }
        self._intercept_state = .{ .abort = error.AbortAuthChallenge };
    }

    fn headerDoneCallback(transfer: *Transfer, conn: *const http.Connection) !bool {
        lp.assert(transfer._header_done_called == false, "Transfer.headerDoneCallback", .{});
        defer transfer._header_done_called = true;

        try transfer.buildResponseHeader(conn);

        if (transfer.req.cookie_jar) |jar| {
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

        transfer.req.notification.dispatch(.http_response_header_done, &.{
            .transfer = transfer,
        });

        const proceed = transfer.req.header_callback(Response.fromTransfer(transfer)) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        return proceed and transfer.aborted == false;
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) usize {
        if (comptime IS_DEBUG) {
            std.debug.assert(chunk_count == 1);
        }

        const conn: *http.Connection = @ptrCast(@alignCast(data));
        var transfer = conn.transport.http;

        if (!transfer._first_data_received) {
            transfer._first_data_received = true;

            const status = conn.getResponseCode() catch |err| {
                log.err(.http, "getResponseCode", .{ .err = err, .source = "body callback" });
                return http.writefunc_error;
            };
            if ((status >= 300 and status <= 399) or status == 401 or status == 407) {
                transfer._skip_body = true;
                return @intCast(chunk_len);
            }

            if (transfer.getContentLength()) |cl| {
                if (cl > transfer.client.max_response_size) {
                    transfer._callback_error = error.ResponseTooLarge;
                    return http.writefunc_error;
                }
                transfer._stream_buffer.ensureTotalCapacity(transfer.arena.allocator(), cl) catch {};
            }
        }

        if (transfer._skip_body) return @intCast(chunk_len);

        transfer.bytes_received += chunk_len;
        if (transfer.bytes_received > transfer.client.max_response_size) {
            transfer._callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        const chunk = buffer[0..chunk_len];
        transfer._stream_buffer.appendSlice(transfer.arena.allocator(), chunk) catch |err| {
            transfer._callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.aborted) return http.writefunc_error;
        return @intCast(chunk_len);
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        if (self._conn) |conn| {
            return .{ .curl = .{ .conn = conn } };
        }
        return .{ .list = .{ .list = self.response_header.?._injected_headers } };
    }

    pub fn fulfill(transfer: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
        if (transfer._conn != null) {
            @branchHint(.unlikely);
            return error.RequestInProgress;
        }
        transfer._fulfill(status, headers, body) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
            return err;
        };
    }

    fn _fulfill(transfer: *Transfer, status: u16, headers: []const http.Header, body: ?[]const u8) !void {
        const req = &transfer.req;
        if (req.start_callback) |cb| {
            try cb(Response.fromTransfer(transfer));
        }
        transfer.response_header = .{
            .status = status,
            .url = req.url,
            .redirect_count = 0,
            ._injected_headers = headers,
        };
        for (headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                const len = @min(hdr.value.len, ResponseHead.MAX_CONTENT_TYPE_LEN);
                @memcpy(transfer.response_header.?._content_type[0..len], hdr.value[0..len]);
                transfer.response_header.?._content_type_len = len;
                break;
            }
        }
        lp.assert(transfer._header_done_called == false, "Transfer.fulfill header_done_called", .{});
        if (try req.header_callback(Response.fromTransfer(transfer)) == false) {
            transfer.abort(error.Abort);
            return;
        }
        if (body) |b| {
            try req.data_callback(Response.fromTransfer(transfer), b);
        }
        try req.done_callback(req.ctx);
    }

    pub fn getContentLength(self: *const Transfer) ?u32 {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(u32, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        if (self._conn) |conn| {
            const cl = conn.getResponseHeader("content-length", 0) orelse return null;
            return cl.value;
        }
        const rh = self.response_header orelse return null;
        for (rh._injected_headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }
        return null;
    }
};

const Noop = struct {
    fn headerCallback(_: Response) !bool {
        return true;
    }
    fn dataCallback(_: Response, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

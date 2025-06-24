// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const os = std.os;
const posix = std.posix;
const Uri = std.Uri;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const MemoryPool = std.heap.MemoryPool;
const ArenaAllocator = std.heap.ArenaAllocator;

const tls = @import("tls");
const log = @import("../log.zig");
const IO = @import("../runtime/loop.zig").IO;
const Loop = @import("../runtime/loop.zig").Loop;
const Notification = @import("../notification.zig").Notification;

// We might need to peek at the body to try and sniff the content-type.
// While we only need a few bytes, in most cases we need to ignore leading
// whitespace, so we want to get a reasonable-sized chunk.
const PEEK_BUF_LEN = 1024;

const BUFFER_LEN = 32 * 1024;

const MAX_HEADER_LINE_LEN = 4096;

pub const ProxyType = enum {
    simple,
    connect,
};

pub const ProxyAuth = union(enum) {
    basic: struct { user_pass: []const u8 },
    bearer: struct { token: []const u8 },

    pub fn header_value(self: ProxyAuth, allocator: Allocator) ![]const u8 {
        switch (self) {
            .basic => |*auth| {
                if (std.mem.indexOfScalar(u8, auth.user_pass, ':') == null) return error.InvalidProxyAuth;

                const prefix = "Basic ";
                var encoder = std.base64.standard.Encoder;
                const size = encoder.calcSize(auth.user_pass.len);
                var buffer = try allocator.alloc(u8, size + prefix.len);
                std.mem.copyForwards(u8, buffer, prefix);
                _ = std.base64.standard.Encoder.encode(buffer[prefix.len..], auth.user_pass);
                return buffer;
            },
            .bearer => |*auth| {
                const prefix = "Bearer ";
                var buffer = try allocator.alloc(u8, auth.token.len + prefix.len);
                std.mem.copyForwards(u8, buffer, prefix);
                std.mem.copyForwards(u8, buffer[prefix.len..], auth.token);
                return buffer;
            },
        }
    }
};

// Thread-safe. Holds our root certificate, connection pool and state pool
// Used to create Requests.
pub const Client = struct {
    req_id: usize,
    allocator: Allocator,
    state_pool: StatePool,
    http_proxy: ?Uri,
    proxy_type: ?ProxyType,
    proxy_auth: ?[]const u8, // Basic <user:pass; base64> or Bearer <token>
    root_ca: tls.config.CertBundle,
    tls_verify_host: bool = true,
    connection_manager: ConnectionManager,
    request_pool: std.heap.MemoryPool(Request),

    const Opts = struct {
        max_concurrent: usize = 3,
        http_proxy: ?std.Uri = null,
        proxy_type: ?ProxyType = null,
        proxy_auth: ?ProxyAuth = null,
        tls_verify_host: bool = true,
        max_idle_connection: usize = 10,
    };

    pub fn init(allocator: Allocator, opts: Opts) !Client {
        var root_ca: tls.config.CertBundle = if (builtin.is_test) .{} else try tls.config.CertBundle.fromSystem(allocator);
        errdefer root_ca.deinit(allocator);

        var state_pool = try StatePool.init(allocator, opts.max_concurrent);
        errdefer state_pool.deinit(allocator);

        var connection_manager = ConnectionManager.init(allocator, opts.max_idle_connection);
        errdefer connection_manager.deinit();

        return .{
            .req_id = 0,
            .root_ca = root_ca,
            .allocator = allocator,
            .state_pool = state_pool,
            .http_proxy = opts.http_proxy,
            .proxy_type = if (opts.http_proxy == null) null else (opts.proxy_type orelse .connect),
            .proxy_auth = if (opts.proxy_auth) |*auth| try auth.header_value(allocator) else null,
            .tls_verify_host = opts.tls_verify_host,
            .connection_manager = connection_manager,
            .request_pool = std.heap.MemoryPool(Request).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        if (builtin.is_test == false) {
            self.root_ca.deinit(allocator);
        }
        self.state_pool.deinit(allocator);
        self.connection_manager.deinit();
        self.request_pool.deinit();

        if (self.proxy_auth) |auth| {
            allocator.free(auth);
        }
    }

    pub fn request(self: *Client, method: Request.Method, uri: *const Uri) !*Request {
        const state = self.state_pool.acquireWait();
        errdefer self.state_pool.release(state);

        const req = try self.request_pool.create();
        errdefer self.request_pool.destroy(req);

        req.* = try Request.init(self, state, method, uri);
        return req;
    }

    pub fn initAsync(
        self: *Client,
        arena: Allocator,
        method: Request.Method,
        uri: *const Uri,
        ctx: *anyopaque,
        callback: AsyncQueue.Callback,
        loop: *Loop,
        opts: RequestOpts,
    ) !void {

        // See the page's DelayedNavitation for why we're doing this. TL;DR -
        // we need to keep 1 slot available for the blocking page navigation flow
        // (Almost worth keeping a dedicate State just for that flow, but keep
        // thinking we need a more permanent solution (i.e. making everything
        // non-blocking).
        if (self.freeSlotCount() > 1) {
            if (self.state_pool.acquireOrNull()) |state| {
                // if we have state ready, we can skip the loop and immediately
                // kick this request off.
                return self.asyncRequestReady(method, uri, ctx, callback, state, opts);
            }
        }

        // This cannot be a client-owned MemoryPool. The page can end before
        // this is ever completed (and the check callback will never be called).
        // As long as the loop doesn't guarantee that callbacks will be called,
        // this _has_ to be the page arena.
        const queue = try arena.create(AsyncQueue);
        queue.* = .{
            .ctx = ctx,
            .uri = uri,
            .opts = opts,
            .client = self,
            .method = method,
            .callback = callback,
            .node = .{ .func = AsyncQueue.check },
        };
        _ = try loop.timeout(10 * std.time.ns_per_ms, &queue.node);
    }

    // Either called directly from initAsync (if we have a state ready)
    // Or from when the AsyncQueue(T) is ready.
    fn asyncRequestReady(
        self: *Client,
        method: Request.Method,
        uri: *const Uri,
        ctx: *anyopaque,
        callback: AsyncQueue.Callback,
        state: *State,
        opts: RequestOpts,
    ) !void {
        errdefer self.state_pool.release(state);

        // We need the request on the heap, because it can have a longer lifetime
        // than the code making the request. That sounds odd, but consider the
        // case of an XHR request: it can still be inflight (e.g. waiting for
        // the response) when the page gets unloaded. Once the page is unloaded
        // the page arena is reset and the XHR instance becomes invalid. If the
        // XHR instance owns the `Request`, we'd crash once an async callback
        // executes.
        const req = try self.request_pool.create();
        errdefer self.request_pool.destroy(req);

        req.* = try Request.init(self, state, method, uri);
        if (opts.notification) |notification| {
            req.notification = notification;
        }

        errdefer req.deinit();
        try callback(ctx, req);
    }

    pub fn requestFactory(self: *Client, opts: RequestOpts) RequestFactory {
        return .{
            .opts = opts,
            .client = self,
        };
    }

    pub fn freeSlotCount(self: *Client) usize {
        return self.state_pool.freeSlotCount();
    }

    fn isConnectProxy(self: *const Client) bool {
        const proxy_type = self.proxy_type orelse return false;
        return proxy_type == .connect;
    }

    fn isSimpleProxy(self: *const Client) bool {
        const proxy_type = self.proxy_type orelse return false;
        return proxy_type == .simple;
    }
};

const RequestOpts = struct {
    notification: ?*Notification = null,
};

// A factory for creating requests with a given set of options.
pub const RequestFactory = struct {
    client: *Client,
    opts: RequestOpts,

    pub fn initAsync(
        self: RequestFactory,
        arena: Allocator,
        method: Request.Method,
        uri: *const Uri,
        ctx: *anyopaque,
        callback: AsyncQueue.Callback,
        loop: *Loop,
    ) !void {
        return self.client.initAsync(arena, method, uri, ctx, callback, loop, self.opts);
    }
};

const AsyncQueue = struct {
    ctx: *anyopaque,
    method: Request.Method,
    uri: *const Uri,
    client: *Client,
    opts: RequestOpts,
    node: Loop.CallbackNode,
    callback: Callback,

    const Callback = *const fn (*anyopaque, *Request) anyerror!void;

    fn check(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *AsyncQueue = @fieldParentPtr("node", node);
        self._check(repeat_delay) catch |err| {
            log.err(.http_client, "async queue check", .{ .err = err });
        };
    }

    fn _check(self: *AsyncQueue, repeat_delay: *?u63) !void {
        const client = self.client;
        const state = client.state_pool.acquireOrNull() orelse {
            // re-run this function in 10 milliseconds
            repeat_delay.* = 10 * std.time.ns_per_ms;
            return;
        };

        try client.asyncRequestReady(
            self.method,
            self.uri,
            self.ctx,
            self.callback,
            state,
            self.opts,
        );
    }
};

// We assume most connections are going to end up in the IdleConnnection pool,
// so this always end up in on the heap (as a *Connection) using the client's
// connection_pool MemoryPool.
// You'll notice that we have both this "Connection", and that both the SyncHandler
// and the AsyncHandler have a "Conn". The "Conn" are a specialized version
// of this "Connection". The SyncHandler.Conn provides a synchronous API over
// the socket/tls. The AsyncHandler.Conn provides an asynchronous API over these.
//
// The Request and IdleConnections are the only ones that deal directly with this
// "Connection" - and the variable name is "connection".
//
// The Sync/Async handlers deal only with their respective "Conn" - and the
// variable name is "conn".
const Connection = struct {
    port: u16,
    blocking: bool,
    tls: ?TLSClient,
    host: []const u8,
    socket: posix.socket_t,

    const TLSClient = union(enum) {
        blocking: tls.Connection(std.net.Stream),
        nonblocking: tls.nb.Client(),

        fn close(self: *TLSClient) void {
            switch (self.*) {
                .blocking => |*tls_client| tls_client.close() catch {},
                .nonblocking => |*tls_client| tls_client.deinit(),
            }
        }
    };

    fn deinit(self: *Connection, allocator: Allocator) void {
        allocator.free(self.host);
        if (self.tls) |*tls_client| {
            tls_client.close();
        }
        posix.close(self.socket);
    }
};

// Represents a request. Can be used to make either a synchronous or an
// asynchronous request. When a synchronous request is made, `request.deinit()`
// should be called once the response is no longer needed.
// When an asychronous request is made, the request is automatically cleaned up
// (but request.deinit() should still be called to discard the request
// before the `sendAsync` is called).
pub const Request = struct {
    id: usize,

    // The HTTP Method to use
    method: Method,

    // The URI we requested
    request_uri: *const Uri,

    // The URI that we're connecting to. Can be different than request_uri when
    // proxying is enabled
    connect_uri: *const Uri,

    // If we're redirecting, this is where we're redirecting to. The only reason
    // we really have this is so that we can set self.request_uri = &self.redirect_url.?
    redirect_uri: ?Uri = null,

    // Optional body
    body: ?[]const u8,

    // Arena used for the lifetime of the request. Most large allocations are
    // either done through the state (pre-allocated on startup + pooled) or
    // by the TLS library.
    arena: Allocator,

    // List of request headers
    headers: std.ArrayListUnmanaged(std.http.Header),

    // whether or not we expect this connection to be secure
    _secure: bool,

    // whether or not we should keep the underlying socket open and and usable
    // for other requests
    _keepalive: bool,

    // extracted from request_uri
    _request_port: u16,
    _request_host: []const u8,

    // extracted from connect_uri
    _connect_port: u16,
    _connect_host: []const u8,

    // whether or not the socket comes from the connection pool. If it does,
    // and we get an error sending the header, we might retry on a new connection
    // because it's possible the other closed the connection, and that's no
    // reason to fail the request.
    _connection_from_keepalive: bool,

    // Used to limit the # of redirects we'll follow
    _redirect_count: u16,

    // The actual connection, including the socket and, optionally, a TLS client
    _connection: ?*Connection,

    // Pooled buffers and arena
    _state: *State,

    // The parent client. Used to get the root certificates, to interact
    // with the connection pool, and to return _state to the state pool when done
    _client: *Client,

    // Whether the Host header has been set via `request.addHeader()`. If not
    // we'll set it based on `uri` before issuing the request.
    _has_host_header: bool,

    // Whether or not we should verify that the host matches the certificate CN
    _tls_verify_host: bool,

    // We only want to emit a start / complete notifications once per request.
    // Because of things like redirects and error handling, it is possible for
    // the notification functions to be called multiple times, so we guard them
    // with these booleans
    _notified_fail: bool,
    _notified_start: bool,
    _notified_complete: bool,

    // The notifier that we emit request notifications to, if any.
    notification: ?*Notification,

    // Aborting an async request is complicated, as we need to wait until all
    // in-flight IO events are completed. Our AsyncHandler is a generic type
    // that we don't have the necessary type information for in the Request,
    // so we need to rely on anyopaque.
    _aborter: ?Aborter,

    const Aborter = struct {
        ctx: *anyopaque,
        func: *const fn (*anyopaque) void,
    };

    pub const Method = enum {
        GET,
        PUT,
        HEAD,
        POST,
        DELETE,
        OPTIONS,

        pub fn format(self: Method, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return writer.writeAll(@tagName(self));
        }

        fn safeToRetry(self: Method) bool {
            return self == .GET or self == .HEAD or self == .OPTIONS;
        }
    };

    fn init(client: *Client, state: *State, method: Method, uri: *const Uri) !Request {
        const decomposed = try decomposeURL(client, uri);

        const id = client.req_id + 1;
        client.req_id = id;

        return .{
            .id = id,
            .request_uri = uri,
            .connect_uri = decomposed.connect_uri,
            .body = null,
            .headers = .{},
            .method = method,
            .notification = null,
            .arena = state.arena.allocator(),
            ._secure = decomposed.secure,
            ._connect_host = decomposed.connect_host,
            ._connect_port = decomposed.connect_port,
            ._request_host = decomposed.request_host,
            ._request_port = decomposed.request_port,
            ._state = state,
            ._client = client,
            ._aborter = null,
            ._connection = null,
            ._keepalive = false,
            ._redirect_count = 0,
            ._has_host_header = false,
            ._notified_fail = false,
            ._notified_start = false,
            ._notified_complete = false,
            ._connection_from_keepalive = false,
            ._tls_verify_host = client.tls_verify_host,
        };
    }

    pub fn deinit(self: *Request) void {
        self.releaseConnection();
        self._client.state_pool.release(self._state);
        self._client.request_pool.destroy(self);
    }

    pub fn abort(self: *Request) void {
        self.requestFailed("aborted");
        const aborter = self._aborter orelse {
            self.deinit();
            return;
        };
        aborter.func(aborter.ctx);
    }

    const DecomposedURL = struct {
        secure: bool,
        connect_port: u16,
        connect_host: []const u8,
        connect_uri: *const std.Uri,
        request_port: u16,
        request_host: []const u8,
    };
    fn decomposeURL(client: *const Client, uri: *const Uri) !DecomposedURL {
        if (uri.host == null) {
            return error.UriMissingHost;
        }
        const request_host = uri.host.?.percent_encoded;

        var connect_uri = uri;
        var connect_host = request_host;
        if (client.http_proxy) |*proxy| {
            connect_uri = proxy;
            connect_host = proxy.host.?.percent_encoded;
        }

        const is_connect_proxy = client.isConnectProxy();

        var secure: bool = undefined;
        const scheme = if (is_connect_proxy) uri.scheme else connect_uri.scheme;
        if (std.ascii.eqlIgnoreCase(scheme, "https")) {
            secure = true;
        } else if (std.ascii.eqlIgnoreCase(scheme, "http")) {
            secure = false;
        } else {
            return error.UnsupportedUriScheme;
        }
        const request_port: u16 = uri.port orelse if (secure) 443 else 80;
        const connect_port: u16 = connect_uri.port orelse (if (is_connect_proxy) 80 else request_port);

        return .{
            .secure = secure,
            .connect_port = connect_port,
            .connect_host = connect_host,
            .connect_uri = connect_uri,
            .request_port = request_port,
            .request_host = request_host,
        };
    }

    // Called in deinit, but also called when we're redirecting to another page
    fn releaseConnection(self: *Request) void {
        const connection = self._connection orelse return;
        self._connection = null;

        if (self._keepalive == false) {
            self._client.connection_manager.destroy(connection);
            return;
        }

        self._client.connection_manager.keepIdle(connection) catch |err| {
            self.destroyConnection(connection);
            log.err(.http_client, "release to pool error", .{ .err = err });
        };
    }

    fn createConnection(self: *Request, socket: posix.socket_t, blocking: bool) !*Connection {
        const client = self._client;
        const connection, const owned_host = try client.connection_manager.create(self._connect_host);

        connection.* = .{
            .tls = null,
            .socket = socket,
            .blocking = blocking,
            .host = owned_host,
            .port = self._connect_port,
        };

        return connection;
    }

    fn destroyConnection(self: *Request, connection: *Connection) void {
        self._client.connection_manager.destroy(connection);
    }

    const AddHeaderOpts = struct {
        dupe_name: bool = false,
        dupe_value: bool = false,
    };
    pub fn addHeader(self: *Request, name: []const u8, value: []const u8, opts: AddHeaderOpts) !void {
        const arena = self.arena;

        var owned_name = name;
        var owned_value = value;

        if (opts.dupe_name) {
            owned_name = try arena.dupe(u8, name);
        }
        if (opts.dupe_value) {
            owned_value = try arena.dupe(u8, value);
        }

        if (self._has_host_header == false and std.ascii.eqlIgnoreCase(name, "host")) {
            self._has_host_header = true;
        }

        try self.headers.append(arena, .{ .name = owned_name, .value = owned_value });
    }

    // TODO timeout
    const SendSyncOpts = struct {
        tls_verify_host: ?bool = null,
    };
    // Makes an synchronous request
    pub fn sendSync(self: *Request, opts: SendSyncOpts) anyerror!Response {
        if (opts.tls_verify_host) |override| {
            self._tls_verify_host = override;
        }

        try self.prepareInitialSend();
        return self.doSendSync(true);
    }

    // Called internally, follows a redirect.
    fn redirectSync(self: *Request, redirect: Reader.Redirect) anyerror!Response {
        try self.prepareToRedirect(redirect);
        return self.doSendSync(true);
    }

    fn doSendSync(self: *Request, use_pool: bool) anyerror!Response {
        // https://github.com/ziglang/zig/issues/20369
        // errdefer |err| self.requestFailed(@errorName(err));
        errdefer self.requestFailed("network error");

        if (use_pool) {
            if (self.findExistingConnection(true)) |connection| {
                self._connection = connection;
                self._connection_from_keepalive = true;
            }
        }

        if (self._connection == null) {
            const socket, const address = try self.createSocket(true);

            posix.connect(socket, &address.any, address.getOsSockLen()) catch |err| {
                posix.close(socket);
                return err;
            };

            const connection = self.createConnection(socket, true) catch |err| {
                posix.close(socket);
                return err;
            };
            self._connection = connection;

            const is_connect_proxy = self._client.isConnectProxy();
            if (is_connect_proxy) {
                try SyncHandler.connect(self);
            }

            if (self._secure) {
                self._connection.?.tls = .{
                    .blocking = try tls.client(std.net.Stream{ .handle = socket }, .{
                        .host = if (is_connect_proxy) self._request_host else self._connect_host,
                        .root_ca = self._client.root_ca,
                        .insecure_skip_verify = self._tls_verify_host == false,
                        .key_log_callback = tls.config.key_log.callback,
                    }),
                };
            }

            self._connection_from_keepalive = false;
        }

        var handler = SyncHandler{ .request = self };
        return handler.send() catch |err| {
            log.warn(.http_client, "sync error", .{
                .err = err,
                .method = self.method,
                .url = self.request_uri,
                .redirects = self._redirect_count,
            });
            return err;
        };
    }

    const SendAsyncOpts = struct {
        tls_verify_host: ?bool = null,
    };
    // Makes an asynchronous request
    pub fn sendAsync(self: *Request, loop: anytype, handler: anytype, opts: SendAsyncOpts) !void {
        if (opts.tls_verify_host) |override| {
            self._tls_verify_host = override;
        }
        try self.prepareInitialSend();
        return self.doSendAsync(loop, handler, true);
    }
    pub fn redirectAsync(self: *Request, redirect: Reader.Redirect, loop: anytype, handler: anytype) !void {
        try self.prepareToRedirect(redirect);
        return self.doSendAsync(loop, handler, true);
    }

    fn doSendAsync(self: *Request, loop: anytype, handler: anytype, use_pool: bool) !void {
        if (use_pool) {
            if (self.findExistingConnection(false)) |connection| {
                self._connection = connection;
                self._connection_from_keepalive = true;
            }
        }

        var address: std.net.Address = undefined;
        if (self._connection == null) {
            const socket, address = try self.createSocket(false);
            errdefer posix.close(socket);

            // It seems wrong to set self._connection here. While we have a
            // connection, it isn't yet connected. PLUS, if this is a secure
            // connection, we also don't have a handshake.
            // But, request._connection only ever gets released to the idle pool
            // when request._keepalive == true. And this can only be true _after_
            // we've processed the request - at which point, we'd obviously be
            // connected + handshake.
            self._connection = try self.createConnection(socket, false);
            self._connection_from_keepalive = false;
        }

        const connection = self._connection.?;
        errdefer self.destroyConnection(connection);

        const AsyncHandlerT = AsyncHandler(@TypeOf(handler), @TypeOf(loop));
        const async_handler = try self.arena.create(AsyncHandlerT);

        const state = self._state;
        async_handler.* = .{
            .loop = loop,
            .request = self,
            .handler = handler,
            .read_buf = state.read_buf,
            .write_buf = state.write_buf,
            .reader = self.newReader(),
            .socket = connection.socket,
            .conn = .{ .handler = async_handler, .protocol = .{ .plain = {} } },
        };

        if (self._secure) {
            connection.tls = .{
                .nonblocking = try tls.nb.Client().init(self._client.allocator, .{
                    .host = if (self._client.isConnectProxy()) self._request_host else self._connect_host,
                    .root_ca = self._client.root_ca,
                    .insecure_skip_verify = self._tls_verify_host == false,
                    // .key_log_callback = tls.config.key_log.callback,
                }),
            };

            async_handler.conn.protocol = .{
                .secure = &connection.tls.?.nonblocking,
            };
        }

        if (self._connection_from_keepalive) {
            // we're already connected
            async_handler.pending_connect = false;
            return async_handler.conn.connected();
        }

        self._aborter = .{
            .ctx = async_handler,
            .func = AsyncHandlerT.abort,
        };

        return loop.connect(
            AsyncHandlerT,
            async_handler,
            &async_handler.read_completion,
            AsyncHandlerT.connected,
            connection.socket,
            address,
        );
    }

    fn newReader(self: *Request) Reader {
        return Reader.init(self._state);
    }

    // Does additional setup of the request for the firsts (i.e. non-redirect) call.
    fn prepareInitialSend(self: *Request) !void {
        const arena = self.arena;
        if (self.body) |body| {
            const cl = try std.fmt.allocPrint(arena, "{d}", .{body.len});
            try self.headers.append(arena, .{ .name = "Content-Length", .value = cl });
        }

        if (!self._has_host_header) {
            try self.headers.append(arena, .{ .name = "Host", .value = self._request_host });
        }

        try self.headers.append(arena, .{ .name = "User-Agent", .value = "Lightpanda/1.0" });
        try self.headers.append(arena, .{ .name = "Accept", .value = "*/*" });

        if (self._client.isSimpleProxy()) {
            if (self._client.proxy_auth) |proxy_auth| {
                try self.headers.append(arena, .{ .name = "Proxy-Authorization", .value = proxy_auth });
            }
        }

        self.requestStarting();
    }

    // Sets up the request for redirecting.
    fn prepareToRedirect(self: *Request, redirect: Reader.Redirect) !void {
        self.releaseConnection();

        // CANNOT reset the arena (╥﹏╥)
        // We need it for self.request_uri (which we're about to use to resolve
        // redirect.location, and it might own some/all headers)

        const redirect_count = self._redirect_count;
        if (redirect_count == 10) {
            return error.TooManyRedirects;
        }

        var buf = try self.arena.alloc(u8, 2048);

        const previous_request_host = self._request_host;
        self.redirect_uri = try self.request_uri.resolve_inplace(redirect.location, &buf);

        self.request_uri = &self.redirect_uri.?;
        const decomposed = try decomposeURL(self._client, self.request_uri);
        self.connect_uri = decomposed.connect_uri;
        self._request_host = decomposed.request_host;
        self._connect_host = decomposed.connect_host;
        self._connect_port = decomposed.connect_port;
        self._secure = decomposed.secure;
        self._keepalive = false;
        self._redirect_count = redirect_count + 1;

        if (redirect.use_get) {
            // Some redirect status codes _require_ that we switch the method
            // to a GET.
            self.method = .GET;
        }
        log.debug(.http, "redirecting", .{ .method = self.method, .url = self.request_uri });

        if (self.body != null and self.method == .GET) {
            // If we have a body and the method is a GET, then we must be following
            // a redirect which switched the method. Remove the body.
            // Reset the Content-Length
            self.body = null;
            for (self.headers.items) |*hdr| {
                if (std.mem.eql(u8, hdr.name, "Content-Length")) {
                    hdr.value = "0";
                    break;
                }
            }
        }

        if (std.mem.eql(u8, previous_request_host, self._request_host) == false) {
            for (self.headers.items) |*hdr| {
                if (std.mem.eql(u8, hdr.name, "Host")) {
                    hdr.value = self._request_host;
                    break;
                }
            }
        }
    }

    fn findExistingConnection(self: *Request, blocking: bool) ?*Connection {
        // This is being overly cautious, but it's a bit risky to re-use
        // connections for other methods. It isn't so much re-using the
        // connection that's the issue, it's dealing with a write error
        // when trying to send the request and deciding whether or not we
        // should retry the request.
        if (self.method.safeToRetry() == false) {
            return null;
        }

        if (self.body != null) {
            return null;
        }

        return self._client.connection_manager.get(self._secure, self._connect_host, self._connect_port, blocking);
    }

    fn createSocket(self: *Request, blocking: bool) !struct { posix.socket_t, std.net.Address } {
        const addresses = try std.net.getAddressList(self.arena, self._connect_host, self._connect_port);
        if (addresses.addrs.len == 0) {
            return error.UnknownHostName;
        }

        // TODO: rotate?
        const address = addresses.addrs[0];

        const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | if (blocking) @as(u32, 0) else posix.SOCK.NONBLOCK;
        const socket = try posix.socket(address.any.family, sock_flags, posix.IPPROTO.TCP);
        errdefer posix.close(socket);

        if (@hasDecl(posix.TCP, "NODELAY")) {
            try posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
        }
        return .{ socket, address };
    }

    fn buildHeader(self: *Request) ![]const u8 {
        const proxied = self._client.isSimpleProxy();

        const buf = self._state.header_buf;
        var fbs = std.io.fixedBufferStream(buf);
        var writer = fbs.writer();

        try writer.writeAll(@tagName(self.method));
        try writer.writeByte(' ');
        try self.request_uri.writeToStream(.{ .scheme = proxied, .authority = proxied, .path = true, .query = true }, writer);
        try writer.writeAll(" HTTP/1.1\r\n");
        for (self.headers.items) |header| {
            try writer.writeAll(header.name);
            try writer.writeAll(": ");
            try writer.writeAll(header.value);
            try writer.writeAll("\r\n");
        }
        try writer.writeAll("\r\n");
        return buf[0..fbs.pos];
    }

    fn buildConnectHeader(self: *Request) ![]const u8 {
        const buf = self._state.header_buf;
        var fbs = std.io.fixedBufferStream(buf);
        var writer = fbs.writer();

        try writer.print("CONNECT {s}:{d} HTTP/1.1\r\n", .{ self._request_host, self._request_port });
        try writer.print("Host: {s}:{d}\r\n", .{ self._request_host, self._request_port });

        if (self._client.proxy_auth) |proxy_auth| {
            try writer.print("Proxy-Authorization: {s}\r\n", .{proxy_auth});
        }

        _ = try writer.write("\r\n");
        return buf[0..fbs.pos];
    }

    fn requestStarting(self: *Request) void {
        const notification = self.notification orelse return;
        if (self._notified_start) {
            return;
        }
        self._notified_start = true;
        notification.dispatch(.http_request_start, &.{
            .arena = self.arena,
            .id = self.id,
            .url = self.request_uri,
            .method = self.method,
            .headers = &self.headers,
            .has_body = self.body != null,
        });
    }

    fn requestFailed(self: *Request, err: []const u8) void {
        const notification = self.notification orelse return;
        if (self._notified_fail) {
            return;
        }
        self._notified_fail = true;
        notification.dispatch(.http_request_fail, &.{
            .id = self.id,
            .err = err,
            .url = self.request_uri,
        });
    }

    fn requestCompleted(self: *Request, response: ResponseHeader, can_keepalive: bool) void {
        const notification = self.notification orelse return;
        if (self._notified_complete) {
            return;
        }

        self._notified_complete = true;
        self._keepalive = can_keepalive;
        notification.dispatch(.http_request_complete, &.{
            .id = self.id,
            .url = self.request_uri,
            .status = response.status,
            .headers = response.headers.items,
        });
    }

    fn shouldProxyConnect(self: *const Request) bool {
        // if the connection comes from a keepalive pool, than we already
        // made a CONNECT request
        if (self._connection_from_keepalive) {
            return false;
        }
        return self._client.isConnectProxy();
    }
};

// Handles asynchronous requests
fn AsyncHandler(comptime H: type, comptime L: type) type {
    return struct {
        loop: L,
        handler: H,
        request: *Request,
        read_buf: []u8,

        // When we're using TLS, we'll probably need to keep read_buf intact
        // until we get a ful TLS record. `read_pos` is the position into `read_buf`
        // that we have valid, but unprocessed, data up to.
        read_pos: usize = 0,

        // need a separate read and write buf because, with TLS, messages are
        // not strictly req->resp.
        write_buf: []u8,

        socket: posix.socket_t,
        read_completion: IO.Completion = undefined,
        send_completion: IO.Completion = undefined,

        // used for parsing the response
        reader: Reader,

        // Can only ever have 1 inflight write to a socket (multiple could
        // get interleaved). You'd think this isn't normally a problem: send
        // the header, send the body (or maybe send them together!), but with TLS
        // we have no guarantee from the library whether or not it'll want us
        // to make multiple writes
        send_queue: SendQueue = .{},

        // Used to help us know if we're writing the header or the body;
        state: SendState = .handshake,

        // Abstraction over TLS and plain text socket, this is a version of
        // the request._connection (which is a *Connection) that is async-specific.
        conn: Conn,

        // This will be != null when we're supposed to redirect AND we've
        // drained the response body. We need this as a field, because we'll
        // detect this inside our TLS onRecv callback (which is executed
        // inside the TLS client, and so we can't deinitialize the tls_client)
        redirect: ?Reader.Redirect = null,

        // There can be cases where we're forced to read the whole body into
        // memory in order to process it (*cough* CloudFront incorrectly sending
        // gzipped responses *cough*)
        full_body: ?std.ArrayListUnmanaged(u8) = null,

        // Shutting down an async request requires that we wait for all inflight
        // IO to be completed. So we need to track what inflight requests we
        // have and whether or not we're shutting down
        shutdown: bool = false,
        pending_write: bool = false,
        pending_receive: bool = false,
        pending_connect: bool = true,

        const Self = @This();
        const SendQueue = std.DoublyLinkedList([]const u8);

        const SendState = enum {
            connect,
            handshake,
            header,
            body,
        };

        const ProcessStatus = enum {
            wait,
            done,
            need_more,
            handler_error,
        };

        fn deinit(self: *Self) void {
            self.request.deinit();
        }

        fn abort(ctx: *anyopaque) void {
            var self: *Self = @alignCast(@ptrCast(ctx));
            self.shutdown = true;
            posix.shutdown(self.request._connection.?.socket, .both) catch {};
            self.maybeShutdown();
        }

        fn connected(self: *Self, _: *IO.Completion, result: IO.ConnectError!void) void {
            self.pending_connect = false;
            if (self.shutdown) {
                return self.maybeShutdown();
            }

            result catch |err| return self.handleError("Connection failed", err);

            if (self.request.shouldProxyConnect()) {
                self.state = .connect;
                const header = self.request.buildConnectHeader() catch |err| {
                    return self.handleError("Failed to build CONNECT header", err);
                };
                self.send(header);
                self.receive();
                return;
            }

            self.conn.connected() catch |err| {
                self.handleError("connected handler error", err);
            };
        }

        fn send(self: *Self, data: []const u8) void {
            const node = self.request.arena.create(SendQueue.Node) catch |err| {
                self.handleError("out of memory", err);
                return;
            };

            node.data = data;
            self.send_queue.append(node);
            if (self.send_queue.len > 1) {
                // if we already had a message in the queue, then our send loop
                // is already setup.
                return;
            }

            self.pending_write = true;
            self.loop.send(
                Self,
                self,
                &self.send_completion,
                sent,
                self.socket,
                node.data,
            ) catch |err| {
                self.handleError("loop send error", err);
            };
        }

        fn sent(self: *Self, _: *IO.Completion, n_: IO.SendError!usize) void {
            self.pending_write = false;
            if (self.shutdown) {
                return self.maybeShutdown();
            }
            const n = n_ catch |err| {
                return self.handleError("Write error", err);
            };

            const node = self.send_queue.first.?;
            const data = node.data;
            var next: ?*SendQueue.Node = node;
            if (n == data.len) {
                _ = self.send_queue.popFirst();
                next = node.next;
            } else {
                // didn't send all the data, we prematurely popped this off
                // (because, in most cases, it _will_ send all the data)
                node.data = data[n..];
            }

            if (next) |next_| {
                self.pending_write = true;
                // we still have data to send
                self.loop.send(
                    Self,
                    self,
                    &self.send_completion,
                    sent,
                    self.socket,
                    next_.data,
                ) catch |err| {
                    self.handleError("loop send error", err);
                };
                return;
            }

            if (self.state == .connect) {
                // We're in a proxy CONNECT flow. There's nothing for us to
                // do except for wait for the response.
                return;
            }

            self.conn.sent() catch |err| {
                self.handleError("send handling", err);
            };
        }

        // Normally, you'd think of HTTP as being a straight up request-response
        // and that we can send, and then receive. But with TLS, we need to receive
        // while handshaking and potentially while sending data. So we're always
        // receiving.
        fn receive(self: *Self) void {
            if (self.pending_receive) {
                return;
            }

            self.pending_receive = true;
            self.loop.recv(
                Self,
                self,
                &self.read_completion,
                Self.received,
                self.socket,
                self.read_buf[self.read_pos..],
            ) catch |err| {
                self.handleError("loop recv error", err);
            };
        }

        fn received(self: *Self, _: *IO.Completion, n_: IO.RecvError!usize) void {
            self.pending_receive = false;
            if (self.shutdown) {
                return self.maybeShutdown();
            }

            const n = n_ catch |err| {
                return self.handleError("Read error", err);
            };
            if (n == 0) {
                if (self.maybeRetryRequest()) {
                    return;
                }
                return self.handleError("Connection closed", error.ConnectionResetByPeer);
            }

            const data = self.read_buf[0 .. self.read_pos + n];

            if (self.state == .connect) {
                const success = self.reader.connectResponse(data) catch |err| {
                    return self.handleError("Invalid CONNECT response", err);
                };

                if (!success) {
                    self.receive();
                } else {
                    // CONNECT was successful, resume our normal flow
                    self.state = .handshake;
                    self.reader = self.request.newReader();
                    self.conn.connected() catch |err| {
                        self.handleError("connected handler error", err);
                    };
                }
                return;
            }

            const status = self.conn.received(data) catch |err| {
                if (err == error.TlsAlertCloseNotify and self.state == .handshake and self.maybeRetryRequest()) {
                    return;
                }

                self.handleError("data processing", err);
                return;
            };

            switch (status) {
                .wait => {},
                .need_more => self.receive(),
                .handler_error => {
                    // handler should never have been called if we're redirecting
                    std.debug.assert(self.redirect == null);
                    self.request.requestCompleted(self.reader.response, self.reader.keepalive);
                    self.deinit();
                    return;
                },
                .done => {
                    const redirect = self.redirect orelse {
                        var handler = self.handler;
                        self.request.requestCompleted(self.reader.response, self.reader.keepalive);
                        self.deinit();

                        // Emit the done chunk. We expect the caller to do
                        // processing once the full request is completed. By
                        // emiting this AFTER we've relreased the connection,
                        // we free the connection and its state for re-use.
                        // If we don't do this this way, we can end up with
                        // _a lot_ of pending request/states.
                        // DO NOT USE `self` here, it's no longer valid.
                        handler.onHttpResponse(.{
                            .data = null,
                            .done = true,
                            .first = false,
                            .header = .{},
                        }) catch {};
                        return;
                    };

                    self.request.redirectAsync(redirect, self.loop, self.handler) catch |err| {
                        self.handleError("Setup async redirect", err);
                        return;
                    };
                    // redirectAsync has given up any claim to the request,
                    // including the socket.
                },
            }
        }

        fn maybeShutdown(self: *Self) void {
            std.debug.assert(self.shutdown);
            if (self.pending_write or self.pending_receive or self.pending_connect) {
                return;
            }

            // Who knows what state we're in, safer to not try to re-use the connection
            self.request._keepalive = false;
            self.request.deinit();
        }

        // If our socket came from the connection pool, it's possible that we're
        // failing because it's since timed out. If
        fn maybeRetryRequest(self: *Self) bool {
            const request = self.request;

            // We only retry if the connection came from the keepalive pool
            // We only use a keepalive connection for specific methods and if
            // there's no body.
            if (request._connection_from_keepalive == false) {
                return false;
            }

            // Because of the `self.state == .body` check above, it should be
            // impossible to be here and have this be true. This is an important
            // check, because we're about to release a connection that we know
            // is bad, and we don't want it to go back into the pool.
            std.debug.assert(request._keepalive == false);
            request.releaseConnection();

            request.doSendAsync(self.loop, self.handler, false) catch |conn_err| {
                // You probably think it's weird that we fallthrough to the:
                //   return true;
                // The caller will take the `true` and just exit. This is what
                // we want in this error case, because the next line handles
                // the error. We rather emit an "connection error" at this point
                // than whatever error we had using the pooled connection.
                self.handleError("connection error", conn_err);
            };

            return true;
        }

        fn processData(self: *Self, d: []u8) ProcessStatus {
            const reader = &self.reader;

            var data = d;
            while (true) {
                const would_be_first = reader.header_done == false;
                const result = reader.process(data) catch |err| {
                    self.handleError("Invalid server response", err);
                    return .done;
                };

                if (reader.header_done == false) {
                    // need more data
                    return .need_more;
                }

                // at this point, If `would_be_first == true`, then
                // `would_be_first` should be thought of as `is_first` because
                // we now have a complete header for the first time.
                if (reader.redirect()) |redirect| {
                    // We don't redirect until we've drained the body (to be
                    // able to re-use the connection for keepalive).
                    // Calling `reader.redirect()` over and over again might not
                    // be the most efficient (it's a very simple function though),
                    // but for a redirect response, chances are we slurped up
                    // the header and body in a single go.
                    if (result.done == false) {
                        return .need_more;
                    }
                    self.redirect = redirect;
                    return .done;
                }

                if (would_be_first) {
                    if (reader.response.get("content-encoding")) |ce| {
                        if (std.ascii.eqlIgnoreCase(ce, "gzip") == false) {
                            self.handleError("unsupported content encoding", error.UnsupportedContentEncoding);
                            return .done;
                        }
                        // Our requests _do not_ include an Accept-Encoding header
                        // but some servers (e.g. CloudFront) can send gzipped
                        // responses nonetheless. Zig's compression libraries
                        // do not work well with our async flow - they expect
                        // to be able to read(buf) more data as needed, instead
                        // of having us yield new data as it becomes available.
                        // If async ever becomes a first class citizen, we could
                        // expect this problem to go away. But, for now, we're
                        // going to read the _whole_ body into memory. It makes
                        // our life a lot easier, but it's still a mess.
                        self.full_body = .empty;
                    }
                }

                const done = result.done;

                // see a few lines up, if this isn't null, something decided
                // we should buffer the entire body into memory.
                if (self.full_body) |*full_body| {
                    if (result.data) |chunk| {
                        full_body.appendSlice(self.request.arena, chunk) catch |err| {
                            self.handleError("response buffering error", err);
                            return .done;
                        };
                    }

                    // when buffering the body into memory, we only emit it once
                    // everything is done (because we need to process the body
                    // as a whole)
                    if (done) {
                        // We should probably keep track of _why_ we're buffering
                        // the body into memory. But, for now, the only possible
                        // reason is that the response was gzipped. That means
                        // we need to decompress it.
                        var fbs = std.io.fixedBufferStream(full_body.items);
                        var decompressor = std.compress.gzip.decompressor(fbs.reader());
                        var next = decompressor.next() catch |err| {
                            self.handleError("decompression error", err);
                            return .done;
                        };

                        var first = true;
                        while (next) |chunk| {
                            // we need to know if there's another chunk so that
                            // we know if done should be true or false
                            next = decompressor.next() catch |err| {
                                self.handleError("decompression error", err);
                                return .done;
                            };

                            self.handler.onHttpResponse(.{
                                .data = chunk,
                                .first = first,
                                .done = false,
                                .header = reader.response,
                            }) catch return .handler_error;

                            first = false;
                        }
                    }
                } else if (result.data != null or would_be_first) {
                    // If we have data. Or if the request is done. Or if this is the
                    // first time we have a complete header. Emit the chunk.
                    self.handler.onHttpResponse(.{
                        .done = false,
                        .data = result.data,
                        .first = would_be_first,
                        .header = reader.response,
                    }) catch return .handler_error;
                }

                if (done == true) {
                    return .done;
                }

                // With chunked-encoding, it's possible that we we've only
                // partially processed the data. So we need to keep processing
                // any unprocessed data. It would be nice if we could just glue
                // this all together, but that would require copying bytes around
                data = result.unprocessed orelse return .need_more;
            }
        }

        fn handleError(self: *Self, comptime msg: []const u8, err: anyerror) void {
            log.err(.http_client, msg, .{
                .err = err,
                .method = self.request.method,
                .url = self.request.request_uri,
            });

            self.handler.onHttpResponse(err) catch {};
            // just to be safe
            self.request._keepalive = false;

            self.request.requestFailed(@errorName(err));
            self.request.deinit();
        }

        const Conn = struct {
            handler: *Self,
            protocol: Protocol,

            const Protocol = union(enum) {
                plain: void,
                secure: *tls.nb.Client(),
            };

            fn connected(self: *Conn) !void {
                const handler = self.handler;

                switch (self.protocol) {
                    .plain => {
                        handler.state = .header;
                        const header = try handler.request.buildHeader();
                        handler.send(header);
                    },
                    .secure => |tls_client| {
                        std.debug.assert(handler.state == .handshake);
                        // initiate the handshake
                        _, const i = try tls_client.handshake(handler.read_buf[0..0], handler.write_buf);
                        handler.send(handler.write_buf[0..i]);
                        handler.receive();
                    },
                }
            }

            fn received(self: *Conn, data: []u8) !ProcessStatus {
                const handler = self.handler;
                switch (self.protocol) {
                    .plain => return handler.processData(data),
                    .secure => |tls_client| {
                        var used: usize = 0;
                        var closed = false;
                        var cleartext_pos: usize = 0;
                        var status = ProcessStatus.need_more;

                        if (tls_client.isConnected()) {
                            used, cleartext_pos, closed = try tls_client.decrypt(data);
                        } else {
                            std.debug.assert(handler.state == .handshake);
                            // process handshake data
                            used, const i = try tls_client.handshake(data, handler.write_buf);
                            if (i > 0) {
                                handler.send(handler.write_buf[0..i]);
                            } else if (tls_client.isConnected()) {
                                // if we're done our handshake, there should be
                                // no unused data
                                handler.read_pos = 0;
                                std.debug.assert(used == data.len);
                                try self.sendSecureHeader(tls_client);
                                return .wait;
                            }
                        }

                        if (used == 0) {
                            // if nothing was used, there should have been
                            // no cleartext data to process;
                            std.debug.assert(cleartext_pos == 0);

                            // if we need more data, then it needs to be
                            // appended to the end of our existing data to
                            // build up a complete record
                            handler.read_pos = data.len;
                            return if (closed) .done else .need_more;
                        }

                        if (cleartext_pos > 0) {
                            status = handler.processData(data[0..cleartext_pos]);
                        }

                        if (closed) {
                            return .done;
                        }

                        if (used == data.len) {
                            // We used up all the data that we were given. We must
                            // reset read_pos to 0 because (a) that's more
                            // efficient and (b) we need all the available space
                            // to make sure we get a full TLS record next time
                            handler.read_pos = 0;
                            return status;
                        }

                        // We used some of the data, but have some leftover
                        // (i.e. there was 1+ full records AND an incomplete
                        // record). We need to maintain the "leftover" data
                        // for subsequent reads.

                        // Remember that our read_buf is the MAX possible TLS
                        // record size. So as long as we make sure that the start
                        // of a record is at read_buf[0], we know that we'll
                        // always have enough space for 1 record.
                        const unused = data.len - used;
                        std.mem.copyForwards(u8, handler.read_buf, data[unused..]);
                        handler.read_pos = unused;

                        // an incomplete record means there must be more data
                        return .need_more;
                    },
                }
            }

            fn sent(self: *Conn) !void {
                const handler = self.handler;
                switch (self.protocol) {
                    .plain => switch (handler.state) {
                        .handshake, .connect => unreachable,
                        .header => {
                            handler.state = .body;
                            if (handler.request.body) |body| {
                                handler.send(body);
                            }
                            handler.receive();
                        },
                        .body => {},
                    },
                    .secure => |tls_client| {
                        if (tls_client.isConnected() == false) {
                            std.debug.assert(handler.state == .handshake);
                            // still handshaking, nothing to do
                            return;
                        }
                        switch (handler.state) {
                            .connect => unreachable,
                            .handshake => return self.sendSecureHeader(tls_client),
                            .header => {
                                handler.state = .body;
                                const body = handler.request.body orelse {
                                    // We've sent the header, and there's no body
                                    // start receiving the response
                                    handler.receive();
                                    return;
                                };
                                const used, const i = try tls_client.encrypt(body, handler.write_buf);
                                std.debug.assert(body.len == used);
                                handler.send(handler.write_buf[0..i]);
                            },
                            .body => {
                                // We've sent the body, start receiving the
                                // response
                                handler.receive();
                            },
                        }
                    },
                }
            }

            // This can be called from two places because, I think, of differences
            // between TLS 1.2 and 1.3. TLS 1.3 requires 1 fewer round trip, and
            // as soon as we've written our handshake, we consider the connection
            // "connected". TLS 1.2 requires a extra round trip, and thus is
            // only connected after we receive response from the server.
            fn sendSecureHeader(self: *Conn, tls_client: *tls.nb.Client()) !void {
                const handler = self.handler;
                handler.state = .header;

                const header = try handler.request.buildHeader();
                const used, const i = try tls_client.encrypt(header, handler.write_buf);
                std.debug.assert(header.len == used);
                handler.send(handler.write_buf[0..i]);
            }
        };
    };
}

// Handles synchronous requests
const SyncHandler = struct {
    request: *Request,

    fn send(self: *SyncHandler) !Response {
        var request = self.request;

        // Take the request._connection (a *Connection), and turn it into
        // something specific to our SyncHandler, a Conn.
        var conn: Conn = blk: {
            const c = request._connection.?;
            if (c.tls) |*tls_client| {
                break :blk .{ .tls = &tls_client.blocking };
            }
            break :blk .{ .plain = c.socket };
        };

        const header = try request.buildHeader();
        try conn.sendRequest(header, request.body);

        var reader = request.newReader();
        var read_buf = request._state.read_buf;

        while (true) {
            const n = conn.read(read_buf) catch |err| {
                return self.maybeRetryOrErr(err);
            };

            const result = try reader.process(read_buf[0..n]);
            if (reader.header_done == false) {
                continue;
            }

            if (reader.redirect()) |redirect| {
                if (result.done == false) {
                    try self.drain(&reader, &conn, result.unprocessed);
                }
                return request.redirectSync(redirect);
            }

            // we have a header, and it isn't a redirect, we return our Response
            // object which can be iterated to get the body.
            std.debug.assert(result.done or reader.body_reader != null);
            std.debug.assert(result.data == null);

            // See CompressedReader for an explanation. This isn't great code. Sorry.
            if (reader.response.get("content-encoding")) |ce| {
                if (std.ascii.eqlIgnoreCase(ce, "gzip") == false) {
                    log.warn(.http_client, "unsupported content encoding", .{
                        .content_encoding = ce,
                        .uri = request.request_uri,
                    });
                    return error.UnsupportedContentEncoding;
                }

                var compress_reader = CompressedReader{
                    .over = "",
                    .inner = &reader,
                    .done = result.done,
                    .buffer = read_buf,
                    .data = result.unprocessed,
                    .conn = conn,
                };
                var body: std.ArrayListUnmanaged(u8) = .{};
                var decompressor = std.compress.gzip.decompressor(compress_reader.reader());
                try decompressor.decompress(body.writer(request.arena));

                return .{
                    .header = reader.response,
                    ._done = true,
                    ._request = request,
                    ._peek_buf = body.items,
                    ._peek_len = body.items.len,
                    ._buf = undefined,
                    ._conn = undefined,
                    ._reader = undefined,
                };
            }

            return .{
                ._conn = conn,
                ._buf = read_buf,
                ._request = request,
                ._reader = reader,
                ._done = result.done,
                ._data = result.unprocessed,
                ._peek_len = 0,
                ._peek_buf = request._state.peek_buf,
                .header = reader.response,
            };
        }
    }

    // Unfortunately, this is called from the Request doSendSync since we need
    // to do this before setting up our TLS connection.
    fn connect(request: *Request) !void {
        const socket = request._connection.?.socket;

        const header = try request.buildConnectHeader();
        try Conn.writeAll(socket, header);

        var pos: usize = 0;
        var reader = request.newReader();
        var read_buf = request._state.read_buf;

        while (true) {
            // we would never 'maybeRetryOrErr' on a CONNECT request, because
            // we only send CONNECT requests on newly established connections
            // and maybeRetryOrErr is only for connections that might have been
            // closed while being kept-alive
            const n = try posix.read(socket, read_buf[pos..]);
            if (n == 0) {
                return error.ConnectionResetByPeer;
            }
            pos += n;
            if (try reader.connectResponse(read_buf[0..pos])) {
                // returns true if we have a successful connect response
                return;
            }

            // we don't have enough data yet.
        }
    }

    fn maybeRetryOrErr(self: *SyncHandler, err: anyerror) !Response {
        var request = self.request;

        // we'll only retry if the connection came from the idle pool, because
        // these connections might have been closed while idling, so an error
        // isn't exactly surprising.
        if (request._connection_from_keepalive == false) {
            return err;
        }

        if (err != error.ConnectionResetByPeer) {
            return err;
        }

        // this should be our default, and this function should never have been
        // called at a point where this could have been set to true. This is
        // important because we're about to release a bad connection, and
        // we don't want it to go back into the idle pool.
        std.debug.assert(request._keepalive == false);
        request.releaseConnection();

        // Don't change this false to true. It ensures that we get a new
        // connection. This prevents an endless loop because, if this new
        // connection also fails, connection_from_keepalive will be false, and our
        // above guard clause will abort the retry.
        return request.doSendSync(false);
    }

    fn drain(self: SyncHandler, reader: *Reader, conn: *Conn, unprocessed: ?[]u8) !void {
        if (unprocessed) |data| {
            const result = try reader.process(data);
            if (result.done) {
                return;
            }
        }

        var buf = self.request._state.read_buf;
        while (true) {
            const n = try conn.read(buf);
            const result = try reader.process(buf[0..n]);
            if (result.done) {
                return;
            }
        }
    }

    const Conn = union(enum) {
        tls: *tls.Connection(std.net.Stream),
        plain: posix.socket_t,

        fn sendRequest(self: *Conn, header: []const u8, body: ?[]const u8) !void {
            switch (self.*) {
                .tls => |tls_client| {
                    try tls_client.writeAll(header);
                    if (body) |b| {
                        try tls_client.writeAll(b);
                    }
                },
                .plain => |socket| {
                    if (body) |b| {
                        var vec = [2]posix.iovec_const{
                            .{ .len = header.len, .base = header.ptr },
                            .{ .len = b.len, .base = b.ptr },
                        };
                        return writeAllIOVec(socket, &vec);
                    }
                    return writeAll(socket, header);
                },
            }
        }

        fn read(self: *Conn, buf: []u8) !usize {
            const n = switch (self.*) {
                .tls => |tls_client| try tls_client.read(buf),
                .plain => |socket| try posix.read(socket, buf),
            };
            if (n == 0) {
                return error.ConnectionResetByPeer;
            }
            return n;
        }

        fn writeAllIOVec(socket: posix.socket_t, vec: []posix.iovec_const) !void {
            var i: usize = 0;
            while (true) {
                var n = try posix.writev(socket, vec[i..]);
                while (n >= vec[i].len) {
                    n -= vec[i].len;
                    i += 1;
                    if (i >= vec.len) {
                        return;
                    }
                }
                vec[i].base += n;
                vec[i].len -= n;
            }
        }

        fn writeAll(socket: posix.socket_t, data: []const u8) !void {
            var i: usize = 0;
            while (i < data.len) {
                i += try posix.write(socket, data[i..]);
            }
        }
    };

    // We don't ask for encoding, but some providers (CloudFront!!)
    // encode anyways. This is an issue for our async-path because Zig's
    // decompressors aren't async-friendly - they want to pull data in
    // rather than being given data when it's available. Unfortunately
    // this is a problem for our own Reader, which is shared by both our
    // sync and async handlers, but has an async-ish API. It's hard to
    // use our Reader with Zig's decompressors. Given the way our Reader
    // is write, this is a problem even for our sync requests. For now, we
    // just read the entire body into memory, which makes things manageable.
    // Finally, we leverage the existing `peek` logic in the Response to make
    // this fully-read content available.
    // If you think about it, this CompressedReader is just a fancy "peek" over
    // the entire body.
    const CompressedReader = struct {
        done: bool,
        conn: Conn,
        buffer: []u8,
        inner: *Reader,

        // Represents data directly from the socket. It hasn't been processed
        // by the body reader. It could, for example, have chunk information in it.
        // Needed to be processed by `inner` before it can be returned
        data: ?[]u8,

        // Represents data that _was_ processed by the body reader, but coudln't
        // fit in the destination buffer given to read.
        // This adds complexity, but the reality is that we can read more data
        // from the socket than space we have in the given `dest`. Think of
        // this as doing something like a BufferedReader. We _could_ limit
        // our reads to dest.len, but we can overread when initially reading
        // the header/response, and at that point, we don't know anything about
        // this Compression stuff.
        over: []const u8,

        const IOReader = std.io.Reader(*CompressedReader, anyerror, read);

        pub fn reader(self: *CompressedReader) IOReader {
            return .{ .context = self };
        }

        fn read(self: *CompressedReader, dest: []u8) anyerror!usize {
            if (self.over.len > 0) {
                // data from a previous `read` which is ready to go as-is. i.e.
                // it's already been processed by inner (the body reader).
                const l = @min(self.over.len, dest.len);
                @memcpy(dest[0..l], self.over[0..l]);
                self.over = self.over[l..];
                return l;
            }

            var buffer = self.buffer;
            buffer = buffer[0..@min(dest.len, buffer.len)];

            while (true) {
                if (try self.processData()) |data| {
                    const l = @min(data.len, dest.len);
                    @memcpy(dest[0..l], data[0..l]);

                    // if we processed more data than fits into dest, we store
                    // it in `over` for the next call to `read`
                    self.over = data[l..];
                    return l;
                }

                if (self.done) {
                    return 0;
                }

                const n = try self.conn.read(self.buffer);
                self.data = self.buffer[0..n];
            }
        }

        fn processData(self: *CompressedReader) !?[]u8 {
            const data = self.data orelse return null;
            const result = try self.inner.process(data);

            self.done = result.done;
            self.data = result.unprocessed; // for the next call

            return result.data;
        }
    };
};

// Used for reading the response (both the header and the body)
const Reader = struct {
    // Wether, from the reader's point of view, this connection could be kept-alive
    keepalive: bool,

    // always references state.header_buf
    header_buf: []u8,

    // position in header_buf that we have valid data up until
    pos: usize,

    // for populating the response headers list
    arena: Allocator,

    response: ResponseHeader,

    body_reader: ?BodyReader,

    header_done: bool,

    // Whether or not the current header has to be skipped [because it's too long].
    skip_current_header: bool,

    fn init(state: *State) Reader {
        return .{
            .pos = 0,
            .response = .{},
            .body_reader = null,
            .header_done = false,
            .keepalive = false,
            .skip_current_header = false,
            .header_buf = state.header_buf,
            .arena = state.arena.allocator(),
        };
    }

    // Determines if we need to redirect
    fn redirect(self: *const Reader) ?Redirect {
        const use_get = switch (self.response.status) {
            201, 301, 302, 303 => true,
            307, 308 => false,
            else => return null,
        };

        const location = self.response.get("location") orelse return null;
        return .{ .use_get = use_get, .location = location };
    }

    fn connectResponse(self: *Reader, data: []u8) !bool {
        const result = try self.process(data);
        if (self.header_done == false) {
            return false;
        }

        if (result.done == false) {
            // CONNECT responses should not have a body. If the header is
            // done, then the entire response should be done.
            return error.InvalidConnectResponse;
        }

        const status = self.response.status;
        if (status < 200 or status > 299) {
            return error.InvalidConnectResponseStatus;
        }

        return true;
    }

    fn process(self: *Reader, data: []u8) ProcessError!Result {
        if (self.body_reader) |*br| {
            const ok, const result = try br.process(data);
            if (ok == false) {
                // There's something that our body reader didn't like. It wants
                // us to emit whatever data we have, but it isn't safe to keep
                // the connection alive.
                std.debug.assert(result.done == true);
            }
            return result;
        }

        // Still parsing the header

        // What data do we have leftover in `data`?
        // When header_done == true, then this is part (or all) of the body
        // When header_done == false, then this is a header line that we didn't
        // have enough data for.
        var done = false;
        var unprocessed = data;

        if (self.skip_current_header) {
            const index = std.mem.indexOfScalarPos(u8, data, 0, '\n') orelse {
                // discard all of this data, since it belongs to a header we
                // want to skip
                return .{ .done = false, .data = null, .unprocessed = null };
            };
            self.pos = 0;
            self.skip_current_header = false;
            unprocessed = data[index + 1 ..];
        }

        // Data from a previous call to process that we weren't able to parse
        const pos = self.pos;
        const header_buf = self.header_buf;

        const unparsed = header_buf[0..pos];
        if (unparsed.len > 0) {
            // This can get complicated, but we'll try to keep it simple, even
            // if that means we'll copy a bit more than we have to. At most,
            // unparsed can represent 1 header line. To have 1 complete line, we
            // need to find a \n in data.
            const line_end = (std.mem.indexOfScalarPos(u8, data, 0, '\n') orelse {
                // data doesn't represent a complete header line. We need more data
                const end = pos + data.len;
                if (end > header_buf.len) {
                    self.prepareToSkipLongHeader();
                } else {
                    self.pos = end;
                    @memcpy(self.header_buf[pos..end], data);
                }
                return .{ .done = false, .data = null, .unprocessed = null };
            }) + 1;

            const end = pos + line_end;
            if (end > header_buf.len) {
                unprocessed = &.{};
                self.prepareToSkipLongHeader();
                // we can disable this immediately, since we've essentially
                // finished skipping it this point.
                self.skip_current_header = false;
            } else {
                @memcpy(header_buf[pos..end], data[0..line_end]);
                done, unprocessed = try self.parseHeader(header_buf[0..end]);
            }

            // we gave parseHeader exactly 1 header line, there should be no leftovers
            std.debug.assert(unprocessed.len == 0);

            // we currently have no unprocessed header data
            self.pos = 0;

            // We still [probably] have data to process which was not part of
            // the previously unparsed header line
            unprocessed = data[line_end..];
        }
        if (done == false) {
            // If we're here it means that
            // 1 - Had no unparsed data, and skipped the entire block above
            // 2 - Had unparsed data, but we managed to "complete" it. AND, the
            //     unparsed data didn't represent the end of the header
            //     We're now trying to parse the rest of the `data` which was not
            //     parsed of the unparsed (unprocessed.len could be 0 here).
            done, unprocessed = try self.parseHeader(unprocessed);
            if (done == false) {
                const p = self.pos; // don't use pos, self.pos might have been altered
                const end = p + unprocessed.len;
                if (end > header_buf.len) {
                    self.prepareToSkipLongHeader();
                } else {
                    @memcpy(header_buf[p..end], unprocessed);
                    self.pos = end;
                }
                return .{ .done = false, .data = null, .unprocessed = null };
            }
        }
        var result = try self.prepareForBody();
        if (unprocessed.len > 0) {
            if (result.done == true) {
                // We think we're done reading the body, but we still have data
                // We'll return what we have as-is, but close the connection
                // because we don't know what state it's in.
                self.keepalive = false;
            } else {
                result.unprocessed = unprocessed;
            }
        }
        return result;
    }

    // We're done parsing the header, and we need to (maybe) setup the BodyReader
    fn prepareForBody(self: *Reader) !Result {
        self.header_done = true;
        const response = &self.response;

        if (response.get("connection")) |connection| {
            if (std.ascii.eqlIgnoreCase(connection, "close")) {
                self.keepalive = false;
            }
        }

        if (response.get("transfer-encoding")) |te| {
            if (std.ascii.indexOfIgnoreCase(te, "chunked") != null) {
                self.body_reader = .{ .chunked = .{
                    .size = null,
                    .missing = 0,
                    .scrap_len = 0,
                    .scrap = undefined,
                } };
                return .{ .done = false, .data = null, .unprocessed = null };
            }
        }

        const content_length = blk: {
            const cl = response.get("content-length") orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, cl, 10) catch {
                return error.InvalidContentLength;
            };
        };

        if (content_length == 0) {
            return .{
                .done = true,
                .data = null,
                .unprocessed = null,
            };
        }

        self.body_reader = .{ .content_length = .{ .len = content_length, .read = 0 } };
        return .{ .done = false, .data = null, .unprocessed = null };
    }

    fn prepareToSkipLongHeader(self: *Reader) void {
        self.skip_current_header = true;
        const buf = self.header_buf;
        const pos = std.mem.indexOfScalar(u8, buf, ':') orelse @min(buf.len, 20);
        log.warn(.http_client, "skipping long header", .{ .name = buf[0..pos] });
    }

    // returns true when done
    // returns any remaining unprocessed data
    // When done == true, the remaining data must belong to the body
    // When done == false, at least part of the remaining data must belong to
    // the header.
    fn parseHeader(self: *Reader, data: []u8) !struct { bool, []u8 } {
        var pos: usize = 0;
        const arena = self.arena;
        if (self.response.status == 0) {
            // still don't have a status line
            pos = std.mem.indexOfScalarPos(u8, data, 0, '\n') orelse {
                return .{ false, data };
            };
            if (pos < 14 or data[pos - 1] != '\r') {
                return error.InvalidStatusLine;
            }
            const protocol = data[0..9];
            if (std.mem.eql(u8, protocol, "HTTP/1.1 ")) {
                self.keepalive = true;
            } else if (std.mem.eql(u8, protocol, "HTTP/1.0 ") == false) {
                return error.InvalidStatusLine;
            }
            self.response.status = std.fmt.parseInt(u16, data[9..12], 10) catch {
                return error.InvalidStatusLine;
            };

            // skip over the \n
            pos += 1;
        }

        while (pos < data.len) {
            if (data[pos] == '\r') {
                const next = pos + 1;
                if (data.len > next and data[next] == '\n') {
                    return .{ true, data[next + 1 ..] };
                }
            }
            const value_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse {
                return .{ false, data[pos..] };
            };

            const sep = std.mem.indexOfScalarPos(u8, data[pos..value_end], 0, ':') orelse {
                return error.InvalidHeader;
            };
            const name_end = pos + sep;

            if (value_end - pos > MAX_HEADER_LINE_LEN) {
                // at this point, we could return this header, but then it would
                // be inconsistent with long headers that are split up and need
                // to be buffered.
                log.warn(.http_client, "skipping long header", .{ .name = data[pos..name_end] });
                pos = value_end + 1;
                continue;
            }

            const value_start = name_end + 1;

            if (value_end == value_start or data[value_end - 1] != '\r') {
                return error.InvalidHeader;
            }

            const name = data[pos..name_end];
            const value = data[value_start .. value_end - 1];

            // there's a limit to what whitespace is valid here, but let's be flexible
            var normalized_name = std.mem.trim(u8, name, &std.ascii.whitespace);
            const normalized_value = std.mem.trim(u8, value, &std.ascii.whitespace);

            // constCast is safe here, and necessary because the std.mem.trim API is bad / broken;
            normalized_name = std.ascii.lowerString(@constCast(normalized_name), normalized_name);
            try self.response.headers.append(self.arena, .{
                .name = try arena.dupe(u8, normalized_name),
                .value = try arena.dupe(u8, normalized_value),
            });

            // +1 to skip over the trailing \n
            pos = value_end + 1;
        }
        return .{ false, "" };
    }

    const BodyReader = union(enum) {
        chunked: Chunked,
        content_length: ContentLength,

        fn process(self: *BodyReader, data: []u8) !struct { bool, Result } {
            std.debug.assert(data.len > 0);
            switch (self.*) {
                inline else => |*br| return br.process(data),
            }
        }

        const ContentLength = struct {
            len: usize,
            read: usize,

            fn process(self: *ContentLength, d: []u8) !struct { bool, Result } {
                const len = self.len;
                var read = self.read;
                const missing = len - read;

                var data = d;
                var valid = true;

                if (d.len > missing) {
                    valid = false;
                    data = d[0..missing];
                }
                read += data.len;
                self.read = read;

                return .{ valid, .{
                    .done = read == len,
                    .data = if (data.len == 0) null else data,
                    .unprocessed = null,
                } };
            }
        };

        const Chunked = struct {
            // size of the current chunk
            size: ?u32,

            // the amount of data we're missing in the current chunk, not
            // including the tailing end-chunk marker (\r\n)
            missing: usize,

            // Our chunk reader will emit data as it becomes available, even
            // if it isn't a complete chunk. So, ideally, we don't need much state
            // But we might also get partial meta-data, like part of the chunk
            // length. For example, imagine we get data that looks like:
            //    over 9000!\r\n32
            //
            // Now, if we assume that "over 9000!" completes the current chunk
            // (which is to say that missing == 12), then the "32" would
            // indicate _part_ of the length of the next chunk. But, is the next
            // chunk 32, or is it 3293 or ??? So we need to keep the "32" around
            // to figure it out.
            scrap: [64]u8,
            scrap_len: usize,

            fn process(self: *Chunked, d: []u8) !struct { bool, Result } {
                var data = d;

                const scrap = &self.scrap;
                const scrap_len = self.scrap_len;
                const free_scrap = scrap.len - scrap_len;

                if (self.size == null) {
                    // we don't know the size of the next chunk
                    const data_header_end = std.mem.indexOfScalarPos(u8, data, 0, '\n') orelse {
                        // the data that we were given doesn't have a complete header
                        if (data.len > free_scrap) {
                            // How big can a chunk reasonably be?
                            return error.InvalidChunk;
                        }
                        const end = scrap_len + data.len;
                        // we still don't have the end of the chunk header
                        @memcpy(scrap[scrap_len..end], data);
                        self.scrap_len = end;
                        return .{ true, .{ .done = false, .data = null, .unprocessed = null } };
                    };

                    var header = data[0..data_header_end];
                    if (scrap_len > 0) {
                        const end = scrap_len + data_header_end;
                        @memcpy(scrap[scrap_len..end], data[0..data_header_end]);
                        self.scrap_len = 0;
                        header = scrap[0..end];
                    }

                    const next_size = try readChunkSize(header);
                    self.scrap_len = 0;
                    self.size = next_size;
                    self.missing = next_size + 2; // include the footer
                    data = data[data_header_end + 1 ..];
                }

                if (data.len == 0) {
                    return .{ true, .{ .data = null, .done = false, .unprocessed = null } };
                }

                const size = self.size.?;
                const missing = self.missing;

                if (data.len >= missing) {
                    self.size = null;
                    self.missing = 0;
                    if (missing == 1) {
                        if (data[0] != '\n') {
                            return error.InvalidChunk;
                        }
                        if (data.len == 1) {
                            return .{ true, .{ .data = null, .done = size == 0, .unprocessed = null } };
                        }
                        return self.process(data[1..]);
                    }

                    if (missing == 2) {
                        if (data[0] != '\r' or data[1] != '\n') {
                            return error.InvalidChunk;
                        }

                        if (data.len == 2) {
                            return .{ true, .{ .data = null, .done = size == 0, .unprocessed = null } };
                        }
                        return self.process(data[2..]);
                    }

                    // we have a complete chunk;
                    var chunk: ?[]u8 = data;
                    const last = missing - 2;
                    if (data[last] != '\r' or data[missing - 1] != '\n') {
                        return error.InvalidChunk;
                    }
                    chunk = if (last == 0) null else data[0..last];

                    const unprocessed = data[missing..];

                    return .{ true, .{
                        .data = chunk,
                        .done = size == 0,
                        .unprocessed = if (unprocessed.len == 0) null else unprocessed,
                    } };
                }

                const still_missing = missing - data.len;
                if (still_missing == 1) {
                    const last = data.len - 1;
                    if (data[last] != '\r') {
                        return error.InvalidChunk;
                    }
                    data = data[0..last];
                }
                self.missing = still_missing;

                return .{ true, .{
                    .data = data,
                    .done = false,
                    .unprocessed = null,
                } };
            }

            fn readChunkSize(data: []const u8) !u32 {
                std.debug.assert(data.len > 1);

                if (data[data.len - 1] != '\r') {
                    return error.InvalidChunk;
                }
                // ignore chunk extensions for now
                const str_len = std.mem.indexOfScalarPos(u8, data, 0, ';') orelse data.len - 1;
                return std.fmt.parseInt(u32, data[0..str_len], 16) catch return error.InvalidChunk;
            }
        };
    };

    const Redirect = struct {
        use_get: bool,
        location: []const u8,
    };

    const Result = struct {
        done: bool,
        data: ?[]u8,
        // Any unprocessed data we have from the last call to "process".
        // We can have unprocessed data when transitioning from parsing the
        // header to parsing the body. When using Chunked encoding, we'll also
        // have unprocessed data between chunks.
        unprocessed: ?[]u8 = null,
    };

    const ProcessError = error{
        HeaderTooLarge,
        OutOfMemory,
        InvalidHeader,
        InvalidStatusLine,
        InvalidContentLength,
        InvalidChunk,
    };
};

pub const ResponseHeader = struct {
    status: u16 = 0,
    headers: std.ArrayListUnmanaged(Header) = .{},

    // Stored header has already been lower-cased
    // `name` parameter should be passed in lower-cased
    pub fn get(self: *const ResponseHeader, name: []const u8) ?[]u8 {
        for (self.headers.items) |h| {
            if (std.mem.eql(u8, name, h.name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn count(self: *const ResponseHeader) usize {
        return self.headers.items.len;
    }

    pub fn iterate(self: *const ResponseHeader, name: []const u8) HeaderIterator {
        return .{
            .index = 0,
            .name = name,
            .headers = self.headers,
        };
    }
};

// We don't want to use std.http.Header, because the value is `[]const u8`.
// We _could_ use it and @constCast, but this gives us more safety.
// The main reason we want to do this is that a caller could lower-case the
// value in-place.
// The value (and key) are both safe to mutate because they're cloned from
// the byte stream by our arena.
pub const Header = struct {
    name: []const u8,
    value: []u8,
};

const HeaderIterator = struct {
    index: usize,
    name: []const u8,
    headers: std.ArrayListUnmanaged(Header),

    pub fn next(self: *HeaderIterator) ?[]u8 {
        const name = self.name;
        const index = self.index;
        for (self.headers.items[index..], index..) |h, i| {
            if (std.mem.eql(u8, name, h.name)) {
                self.index = i + 1;
                return h.value;
            }
        }
        self.index = self.headers.items.len;
        return null;
    }
};

// What we emit from the AsyncHandler
pub const Progress = struct {
    first: bool,

    // whether or not more data is expected
    done: bool,

    // part of the body
    data: ?[]const u8,

    header: ResponseHeader,
};

// The value that we return from a synchronous request.
pub const Response = struct {
    _reader: Reader,
    _request: *Request,
    _conn: SyncHandler.Conn,

    // the buffer to read the peeked data into
    _peek_buf: []u8,

    // the length of data we've peeked. The peeked_data is _peek_buf[0.._peek_len].
    // It's possible for peek_len > 0 and _done == true, in which case, the
    // _peeked data should be emitted once and subsequent calls to `next` should
    // return null.
    _peek_len: usize,

    // What we'll read from the socket into. This is the State's read_buf
    _buf: []u8,

    // Whether or not we're done reading the response. When true, next will
    // return null.
    _done: bool,

    // Data that we've read. This can be set when the Response is first created
    // from extra data received while parsing the body. Or, it can be set
    // when `next` is called and we read more data from the socket.
    _data: ?[]u8 = null,
    header: ResponseHeader,

    pub fn next(self: *Response) !?[]u8 {
        // it's possible for peek_len > - and done == true. This would happen
        // when, while peeking, we reached the end of the data. In that case,
        // we return the peeked data once, and on subsequent call, we'll return
        // null normally, because done == true;
        const pl = self._peek_len;
        if (pl > 0) {
            self._peek_len = 0;
            return self._peek_buf[0..pl];
        }

        return self._nextIgnorePeek(self._buf);
    }

    fn _nextIgnorePeek(self: *Response, buf: []u8) !?[]u8 {
        while (true) {
            if (try self.processData()) |data| {
                return data;
            }
            if (self._done) {
                self._request.requestCompleted(self.header, self._reader.keepalive);
                return null;
            }

            const n = try self._conn.read(buf);
            self._data = buf[0..n];
        }
    }

    fn processData(self: *Response) !?[]u8 {
        const data = self._data orelse return null;
        const result = try self._reader.process(data);
        self._done = result.done;
        self._data = result.unprocessed; // for the next call
        return result.data;
    }

    pub fn peek(self: *Response) ![]u8 {
        if (self._peek_len > 0) {
            // Under normal usage, this is only possible when we're dealing
            // with a compressed response (despite not asking for it). We handle
            // these responses by essentially peeking the entire body.
            return self._peek_buf[0..self._peek_len];
        }

        if (try self.processData()) |data| {
            // We already have some or all of the body. This happens because
            // we always read as much as we can, so getting the header and
            // part/all of the body is normal.
            if (data.len > 100) {
                self._peek_buf = data;
                self._peek_len = data.len;
                return data;
            }
            @memcpy(self._peek_buf[0..data.len], data);
            self._peek_len = data.len;
        }

        while (true) {
            var peek_buf = self._peek_buf;
            const peek_len = self._peek_len;

            const data = (try self._nextIgnorePeek(peek_buf[peek_len..])) orelse {
                return peek_buf[0..peek_len];
            };

            const peek_end = peek_len + data.len;
            @memcpy(peek_buf[peek_len..peek_end], data);
            self._peek_len = peek_end;

            if (peek_end > 100) {
                return peek_buf[peek_len..peek_end];
            }
        }
    }
};

// Pooled and re-used when creating a request
const State = struct {
    // We might be asked to peek at the response, i.e. to sniff the mime type.
    // This will require storing any peeked data so that, later, if we stream
    // the body, we can present a cohesive body.
    peek_buf: []u8,

    // Used for reading chunks of payload data.
    read_buf: []u8,

    // Used for writing data. If you're wondering why BOTH a read_buf and a
    // write_buf, even though HTTP is req -> resp, it's for TLS, which has
    // bidirectional data.
    write_buf: []u8,

    // Used for keeping any unparsed header line until more data is received
    // At most, this represents 1 line in the header.
    header_buf: []u8,

    // Used to optionally clone request headers, and always used to clone
    // response headers.
    arena: ArenaAllocator,

    fn init(allocator: Allocator, header_size: usize, peek_size: usize, buf_size: usize) !State {
        const peek_buf = try allocator.alloc(u8, peek_size);
        errdefer allocator.free(peek_buf);

        const read_buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(read_buf);

        const write_buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(write_buf);

        const header_buf = try allocator.alloc(u8, header_size);
        errdefer allocator.free(header_buf);

        return .{
            .peek_buf = peek_buf,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .header_buf = header_buf,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn reset(self: *State) void {
        _ = self.arena.reset(.{ .retain_with_limit = 64 * 1024 });
    }

    fn deinit(self: *State) void {
        const allocator = self.arena.child_allocator;
        allocator.free(self.peek_buf);
        allocator.free(self.read_buf);
        allocator.free(self.write_buf);
        allocator.free(self.header_buf);
        self.arena.deinit();
    }
};

const StatePool = struct {
    states: []*State,
    available: usize,
    mutex: Thread.Mutex,
    cond: Thread.Condition,

    pub fn init(allocator: Allocator, count: usize) !StatePool {
        const states = try allocator.alloc(*State, count);
        errdefer allocator.free(states);

        var started: usize = 0;
        errdefer for (0..started) |i| {
            states[i].deinit();
            allocator.destroy(states[i]);
        };

        for (0..count) |i| {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            state.* = try State.init(allocator, MAX_HEADER_LINE_LEN, PEEK_BUF_LEN, BUFFER_LEN);
            states[i] = state;
            started += 1;
        }

        return .{
            .cond = .{},
            .mutex = .{},
            .states = states,
            .available = count,
        };
    }

    pub fn deinit(self: *StatePool, allocator: Allocator) void {
        for (self.states) |state| {
            state.deinit();
            allocator.destroy(state);
        }
        allocator.free(self.states);
    }

    pub fn freeSlotCount(self: *StatePool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.available;
    }

    pub fn acquireWait(self: *StatePool) *State {
        const states = self.states;

        self.mutex.lock();
        while (true) {
            const available = self.available;
            if (available == 0) {
                self.cond.wait(&self.mutex);
                continue;
            }
            const index = available - 1;
            const state = states[index];
            self.available = index;
            self.mutex.unlock();
            return state;
        }
    }

    pub fn acquireOrNull(self: *StatePool) ?*State {
        const states = self.states;

        self.mutex.lock();
        defer self.mutex.unlock();

        const available = self.available;
        if (available == 0) {
            return null;
        }

        const index = available - 1;
        const state = states[index];
        self.available = index;
        return state;
    }

    pub fn release(self: *StatePool, state: *State) void {
        state.reset();
        var states = self.states;

        self.mutex.lock();
        const available = self.available;
        states[available] = state;
        self.available = available + 1;
        self.mutex.unlock();

        self.cond.signal();
    }
};

// Ideally, a connection could be reused as long as the host:port matches.
// But we're also having to match based on blocking and nonblocking and TLS
// and not TLS. It isn't the most efficient. For non-TLS, we could definitely
// always re-use the connection (just toggle the socket's blocking status), but
// for TLS, we'd need to see if the two different TLS objects (blocking and non
// blocking) can be converted from each other.
const ConnectionManager = struct {
    max: usize,
    idle: List,
    count: usize,
    mutex: Thread.Mutex,
    allocator: Allocator,
    node_pool: std.heap.MemoryPool(Node),
    connection_pool: std.heap.MemoryPool(Connection),

    const List = std.DoublyLinkedList(*Connection);
    const Node = List.Node;

    fn init(allocator: Allocator, max: usize) ConnectionManager {
        return .{
            .max = max,
            .count = 0,
            .idle = .{},
            .mutex = .{},
            .allocator = allocator,
            .node_pool = std.heap.MemoryPool(Node).init(allocator),
            .connection_pool = std.heap.MemoryPool(Connection).init(allocator),
        };
    }

    fn deinit(self: *ConnectionManager) void {
        const allocator = self.allocator;

        self.mutex.lock();
        defer self.mutex.unlock();
        var node = self.idle.first;
        while (node) |n| {
            const next = n.next;
            n.data.deinit(allocator);
            node = next;
        }
        self.node_pool.deinit();
        self.connection_pool.deinit();
    }

    fn get(self: *ConnectionManager, secure: bool, host: []const u8, port: u16, blocking: bool) ?*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        var node = self.idle.first;
        while (node) |n| {
            const connection = n.data;
            if (std.ascii.eqlIgnoreCase(connection.host, host) and connection.port == port and connection.blocking == blocking and ((connection.tls == null) == !secure)) {
                self.count -= 1;
                self.idle.remove(n);
                self.node_pool.destroy(n);
                return connection;
            }
            node = n.next;
        }
        return null;
    }

    fn keepIdle(self: *ConnectionManager, connection: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var node: *Node = undefined;
        if (self.count == self.max) {
            const oldest = self.idle.popFirst() orelse {
                std.debug.assert(self.max == 0);
                self.destroy(connection);
                return;
            };
            self.destroy(oldest.data);
            // re-use the node
            node = oldest;
        } else {
            node = try self.node_pool.create();
            self.count += 1;
        }

        node.data = connection;
        self.idle.append(node);
    }

    fn create(self: *ConnectionManager, host: []const u8) !struct { *Connection, []const u8 } {
        const connection = try self.connection_pool.create();
        errdefer self.connection_pool.destroy(connection);

        const owned_host = try self.allocator.dupe(u8, host);
        return .{ connection, owned_host };
    }

    fn destroy(self: *ConnectionManager, connection: *Connection) void {
        connection.deinit(self.allocator);
        self.connection_pool.destroy(connection);
    }
};

const testing = @import("../testing.zig");
test "HttpClient Reader: fuzz" {
    var state = try State.init(testing.allocator, 1024, 1024, 100);
    defer state.deinit();

    var res = TestResponse.init();
    defer res.deinit();

    // testReader randomly fragments the incoming data, hence the loop.
    for (0..1000) |_| {
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "hello\r\n\r\n"));
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "http/1.1 200 \r\n\r\n"));
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "HTTP/0.9 200 \r\n\r\n"));
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "HTTP/1.1     \r\n\r\n"));
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "HTTP/1.1 20a \r\n\r\n"));
        try testing.expectError(error.InvalidStatusLine, testReader(&state, &res, "HTTP/1.1 20A \n"));
        try testing.expectError(error.InvalidHeader, testReader(&state, &res, "HTTP/1.1 200 \r\nA\r\nB:1\r\n"));

        try testing.expectError(error.InvalidChunk, testReader(&state, &res, "HTTP/1.1 200 \r\nTransfer-Encoding: chunked\r\n\r\n abc\r\n"));
        try testing.expectError(error.InvalidChunk, testReader(&state, &res, "HTTP/1.1 200 \r\nTransfer-Encoding: chunked\r\n\r\n 123\n"));

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(0, res.body.items.len);
            try testing.expectEqual(0, res.headers.items.len);
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.0 404 \r\nError: Not-Found\r\n\r\n");
            try testing.expectEqual(404, res.status);
            try testing.expectEqual(0, res.body.items.len);
            try res.assertHeaders(&.{ "error", "Not-Found" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nSet-Cookie: a32;max-age=60\r\nContent-Length: 12\r\n\r\nOver 9000!!!");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual("Over 9000!!!", res.body.items);
            try res.assertHeaders(&.{ "set-cookie", "a32;max-age=60", "content-length", "12" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual("", res.body.items);
            try res.assertHeaders(&.{ "transfer-encoding", "chunked" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual("", res.body.items);
            try res.assertHeaders(&.{ "transfer-encoding", "chunked" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\nE\r\nHello World!!!\r\n2eE;opts\r\n" ++ ("abc" ** 250) ++ "\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual("Hello World!!!" ++ ("abc" ** 250), res.body.items);
            try res.assertHeaders(&.{ "transfer-encoding", "chunked" });
        }
    }

    for (0..10) |_| {
        {
            // large body
            const body = "abcdefghijklmnopqrstuvwxyz012345689ABCDEFGHIJKLMNOPQRSTUVWXYZ" ** 10000;
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 OK\r\n Content-Length :   610000  \r\nOther: 13391AbC93\r\n\r\n" ++ body);
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(body, res.body.items);
            try res.assertHeaders(&.{ "content-length", "610000", "other", "13391AbC93" });
        }

        {
            // skips large headers
            const data = "HTTP/1.1 200 OK\r\na: b\r\n" ++ ("a" ** 5000) ++ ": wow\r\nx:zz\r\n\r\n";
            try testReader(&state, &res, data);
            try testing.expectEqual(200, res.status);
            try res.assertHeaders(&.{ "a", "b", "x", "zz" });
        }
    }
}

test "HttpClient: invalid url" {
    var client = try testClient(.{});
    defer client.deinit();
    const uri = try Uri.parse("http:///");
    try testing.expectError(error.UriMissingHost, client.request(.GET, &uri));
}

test "HttpClient: sync connect error" {
    var client = try testClient(.{});
    defer client.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9920");
    var req = try client.request(.GET, &uri);
    defer req.deinit();

    try testing.expectError(error.ConnectionRefused, req.sendSync(.{}));
}

test "HttpClient: sync no body" {
    for (0..2) |i| {
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/simple");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{});

        if (i == 0) {
            try testing.expectEqual("", try res.peek());
        }
        try testing.expectEqual(null, try res.next());
        try testing.expectEqual(200, res.header.status);
        try testing.expectEqual(2, res.header.count());
        try testing.expectEqual("close", res.header.get("connection"));
        try testing.expectEqual("0", res.header.get("content-length"));
    }
}

test "HttpClient: sync tls no body" {
    for (0..1) |_| {
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/simple");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{ .tls_verify_host = false });

        try testing.expectEqual(null, try res.next());
        try testing.expectEqual(200, res.header.status);
        try testing.expectEqual(2, res.header.count());
        try testing.expectEqual("0", res.header.get("content-length"));
        try testing.expectEqual("Close", res.header.get("connection"));
    }
}

test "HttpClient: sync with body" {
    for (0..2) |i| {
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/echo");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{});

        if (i == 0) {
            try testing.expectEqual("over 9000!", try res.peek());
        }
        try testing.expectEqual("over 9000!", try res.next());
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual(5, res.header.count());
        try testing.expectEqual("Close", res.header.get("connection"));
        try testing.expectEqual("10", res.header.get("content-length"));
        try testing.expectEqual("127.0.0.1", res.header.get("_host"));
        try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
        try testing.expectEqual("*/*", res.header.get("_accept"));
    }
}

test "HttpClient: sync with body proxy CONNECT" {
    for (0..2) |i| {
        const proxy_uri = try Uri.parse("http://127.0.0.1:9582/");
        var client = try testClient(.{ .proxy_type = .connect, .http_proxy = proxy_uri });
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/echo");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{});

        if (i == 0) {
            try testing.expectEqual("over 9000!", try res.peek());
        }
        try testing.expectEqual("over 9000!", try res.next());
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual(5, res.header.count());
        try testing.expectEqual("Close", res.header.get("connection"));
        try testing.expectEqual("10", res.header.get("content-length"));
        try testing.expectEqual("127.0.0.1", res.header.get("_host"));
        try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
        try testing.expectEqual("*/*", res.header.get("_accept"));
    }
}

test "HttpClient: sync with gzip body" {
    for (0..2) |i| {
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/gzip");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{});

        if (i == 0) {
            try testing.expectEqual("A new browser built for machines\n", try res.peek());
        }
        try testing.expectEqual("A new browser built for machines\n", try res.next());
        try testing.expectEqual("gzip", res.header.get("content-encoding"));
    }
}

test "HttpClient: sync tls with body" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    var client = try testClient(.{});
    defer client.deinit();
    for (0..5) |_| {
        defer arr.clearRetainingCapacity();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/body");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual("1234567890abcdefhijk", arr.items);
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual(3, res.header.count());
        try testing.expectEqual("20", res.header.get("content-length"));
        try testing.expectEqual("HEaDer", res.header.get("another"));
        try testing.expectEqual("Close", res.header.get("connection"));
    }
}

test "HttpClient: sync redirect from TLS to Plaintext" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/redirect/insecure");
        var req = try client.request(.GET, &uri);
        defer req.deinit();

        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual("over 9000!", arr.items);
        try testing.expectEqual(5, res.header.count());
        try testing.expectEqual("Close", res.header.get("connection"));
        try testing.expectEqual("10", res.header.get("content-length"));
        try testing.expectEqual("127.0.0.1", res.header.get("_host"));
        try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
        try testing.expectEqual("*/*", res.header.get("_accept"));
    }
}

test "HttpClient: sync redirect plaintext to TLS" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient(.{});
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect/secure");
        var req = try client.request(.GET, &uri);
        defer req.deinit();
        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual("1234567890abcdefhijk", arr.items);
        try testing.expectEqual(3, res.header.count());
        try testing.expectEqual("20", res.header.get("content-length"));
        try testing.expectEqual("HEaDer", res.header.get("another"));
        try testing.expectEqual("Close", res.header.get("connection"));
    }
}

test "HttpClient: sync GET redirect" {
    var client = try testClient(.{});
    defer client.deinit();

    const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect");
    var req = try client.request(.GET, &uri);
    defer req.deinit();
    var res = try req.sendSync(.{ .tls_verify_host = false });

    try testing.expectEqual("over 9000!", try res.next());
    try testing.expectEqual(201, res.header.status);
    try testing.expectEqual(5, res.header.count());
    try testing.expectEqual("Close", res.header.get("connection"));
    try testing.expectEqual("10", res.header.get("content-length"));
    try testing.expectEqual("127.0.0.1", res.header.get("_host"));
    try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
    try testing.expectEqual("*/*", res.header.get("_accept"));
}

test "HttpClient: async connect error" {
    defer testing.reset();
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    const Handler = struct {
        loop: *Loop,
        reset: *Thread.ResetEvent,

        fn requestReady(ctx: *anyopaque, req: *Request) !void {
            const self: *@This() = @alignCast(@ptrCast(ctx));
            try req.sendAsync(self.loop, self, .{});
        }

        fn onHttpResponse(self: *@This(), res: anyerror!Progress) !void {
            _ = res catch |err| {
                if (err == error.ConnectionRefused) {
                    self.reset.set();
                    return;
                }
                std.debug.print("Expected error.ConnectionRefused, got error: {any}", .{err});
                return;
            };
            std.debug.print("Expected error.ConnectionRefused, got no error", .{});
        }
    };

    var reset: Thread.ResetEvent = .{};
    var client = try testClient(.{});
    defer client.deinit();

    var handler = Handler{
        .loop = &loop,
        .reset = &reset,
    };

    const uri = try Uri.parse("HTTP://127.0.0.1:9920");
    try client.initAsync(
        testing.arena_allocator,
        .GET,
        &uri,
        &handler,
        Handler.requestReady,
        &loop,
        .{},
    );

    for (0..10) |_| {
        try loop.io.run_for_ns(std.time.ns_per_ms * 10);
        if (reset.isSet()) {
            break;
        }
    } else {
        return error.Timeout;
    }
}

test "HttpClient: async no body" {
    defer testing.reset();

    var client = try testClient(.{});
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/simple");
    try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("", res.body.items);
    try testing.expectEqual(200, res.status);
    try res.assertHeaders(&.{ "content-length", "0", "connection", "close" });
}

test "HttpClient: async with body" {
    defer testing.reset();

    var client = try testClient(.{});
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/echo");
    try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("over 9000!", res.body.items);
    try testing.expectEqual(201, res.status);
    try res.assertHeaders(&.{
        "content-length", "10",
        "_host",          "127.0.0.1",
        "_user-agent",    "Lightpanda/1.0",
        "_accept",        "*/*",
        "connection",     "Close",
    });
}

test "HttpClient: async with gzip body" {
    defer testing.reset();

    var client = try testClient(.{});
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/gzip");
    try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("A new browser built for machines\n", res.body.items);
    try testing.expectEqual(200, res.status);
    try res.assertHeaders(&.{
        "content-length",   "63",
        "connection",       "close",
        "content-encoding", "gzip",
    });
}

test "HttpClient: async redirect" {
    defer testing.reset();

    var client = try testClient(.{});
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/redirect");
    try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});

    // Called twice on purpose. The initial GET resutls in the # of pending
    // events to reach 0. This causes our `run_for_ns` to return. But we then
    // start to requeue events (from the redirected request), so we need the
    // loop to process those also.
    try handler.loop.io.run_for_ns(std.time.ns_per_ms);
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("over 9000!", res.body.items);
    try testing.expectEqual(201, res.status);
    try res.assertHeaders(&.{
        "content-length", "10",
        "_host",          "127.0.0.1",
        "_user-agent",    "Lightpanda/1.0",
        "_accept",        "*/*",
        "connection",     "Close",
    });
}

test "HttpClient: async tls no body" {
    defer testing.reset();
    var client = try testClient(.{});
    defer client.deinit();
    for (0..5) |_| {
        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("HTTPs://127.0.0.1:9581/http_client/simple");
        try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual("", res.body.items);
        try testing.expectEqual(200, res.status);
        try res.assertHeaders(&.{
            "content-length",
            "0",
            "connection",
            "Close",
        });
    }
}

test "HttpClient: async tls with body" {
    defer testing.reset();
    for (0..5) |_| {
        var client = try testClient(.{});
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("HTTPs://127.0.0.1:9581/http_client/body");
        try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual("1234567890abcdefhijk", res.body.items);
        try testing.expectEqual(201, res.status);
        try res.assertHeaders(&.{
            "content-length", "20",
            "connection",     "Close",
            "another",        "HEaDer",
        });
    }
}

test "HttpClient: async redirect from TLS to Plaintext" {
    defer testing.reset();
    for (0..1) |_| {
        var client = try testClient(.{});
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/redirect/insecure");
        try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual(201, res.status);
        try testing.expectEqual("over 9000!", res.body.items);
        try res.assertHeaders(&.{
            "content-length", "10",
            "_host",          "127.0.0.1",
            "_user-agent",    "Lightpanda/1.0",
            "_accept",        "*/*",
            "connection",     "Close",
        });
    }
}

test "HttpClient: async redirect plaintext to TLS" {
    defer testing.reset();
    for (0..5) |_| {
        var client = try testClient(.{});
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect/secure");
        try client.initAsync(testing.arena_allocator, .GET, &uri, &handler, CaptureHandler.requestReady, &handler.loop, .{});
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual(201, res.status);
        try testing.expectEqual("1234567890abcdefhijk", res.body.items);
        try res.assertHeaders(&.{ "content-length", "20", "connection", "Close", "another", "HEaDer" });
    }
}

test "HttpClient: HeaderIterator" {
    var header = ResponseHeader{};
    defer header.headers.deinit(testing.allocator);

    {
        var it = header.iterate("nope");
        try testing.expectEqual(null, it.next());
        try testing.expectEqual(null, it.next());
    }

    // @constCast is totally unsafe here, but it's just a test, and we know
    // nothing is going to write to it, so it works.
    try header.headers.append(testing.allocator, .{ .name = "h1", .value = @constCast("value1") });
    try header.headers.append(testing.allocator, .{ .name = "h2", .value = @constCast("value2") });
    try header.headers.append(testing.allocator, .{ .name = "h3", .value = @constCast("value3") });
    try header.headers.append(testing.allocator, .{ .name = "h1", .value = @constCast("value4") });
    try header.headers.append(testing.allocator, .{ .name = "h1", .value = @constCast("value5") });

    {
        var it = header.iterate("nope");
        try testing.expectEqual(null, it.next());
        try testing.expectEqual(null, it.next());
    }

    {
        var it = header.iterate("h2");
        try testing.expectEqual("value2", it.next());
        try testing.expectEqual(null, it.next());
        try testing.expectEqual(null, it.next());
    }

    {
        var it = header.iterate("h3");
        try testing.expectEqual("value3", it.next());
        try testing.expectEqual(null, it.next());
        try testing.expectEqual(null, it.next());
    }

    {
        var it = header.iterate("h1");
        try testing.expectEqual("value1", it.next());
        try testing.expectEqual("value4", it.next());
        try testing.expectEqual("value5", it.next());
        try testing.expectEqual(null, it.next());
        try testing.expectEqual(null, it.next());
    }
}

const TestResponse = struct {
    status: u16,
    arena: std.heap.ArenaAllocator,
    body: std.ArrayListUnmanaged(u8),
    headers: std.ArrayListUnmanaged(Header),

    fn init() TestResponse {
        return .{
            .status = 0,
            .body = .{},
            .headers = .{},
            .arena = ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *TestResponse) void {
        self.arena.deinit();
    }

    fn reset(self: *TestResponse) void {
        _ = self.arena.reset(.{ .retain_capacity = {} });
        self.status = 0;
        self.body = .{};
        self.headers = .{};
    }

    fn assertHeaders(self: *const TestResponse, expected: []const []const u8) !void {
        const actual = self.headers.items;
        errdefer {
            std.debug.print("Actual headers:\n", .{});
            for (actual) |a| {
                std.debug.print("{s}: {s}\n", .{ a.name, a.value });
            }
        }

        try testing.expectEqual(expected.len / 2, actual.len);

        var i: usize = 0;
        while (i < expected.len) : (i += 2) {
            const a = actual[i / 2];
            try testing.expectEqual(expected[i], a.name);
            try testing.expectEqual(expected[i + 1], a.value);
        }
    }
};

const CaptureHandler = struct {
    loop: Loop,
    reset: Thread.ResetEvent,
    response: TestResponse,

    fn init() !CaptureHandler {
        return .{
            .reset = .{},
            .response = TestResponse.init(),
            .loop = try Loop.init(testing.allocator),
        };
    }

    fn deinit(self: *CaptureHandler) void {
        self.response.deinit();
        self.loop.deinit();
    }

    fn requestReady(ctx: *anyopaque, req: *Request) !void {
        const self: *CaptureHandler = @alignCast(@ptrCast(ctx));
        try req.sendAsync(&self.loop, self, .{ .tls_verify_host = false });
    }

    fn onHttpResponse(self: *CaptureHandler, progress_: anyerror!Progress) !void {
        self.process(progress_) catch |err| {
            std.debug.print("capture handler error: {}\n", .{err});
        };
    }

    fn process(self: *CaptureHandler, progress_: anyerror!Progress) !void {
        const progress = try progress_;
        const allocator = self.response.arena.allocator();
        try self.response.body.appendSlice(allocator, progress.data orelse "");
        if (progress.first) {
            std.debug.assert(!progress.done);
            self.response.status = progress.header.status;
            try self.response.headers.ensureTotalCapacity(allocator, progress.header.headers.items.len);
            for (progress.header.headers.items) |header| {
                self.response.headers.appendAssumeCapacity(.{
                    .name = try allocator.dupe(u8, header.name),
                    .value = try allocator.dupe(u8, header.value),
                });
            }
        }

        if (progress.done) {
            self.reset.set();
        }
    }

    fn waitUntilDone(self: *CaptureHandler) !void {
        for (0..20) |_| {
            try self.loop.io.run_for_ns(std.time.ns_per_ms * 25);
            if (self.reset.isSet()) {
                return;
            }
        }
        return error.TimeoutWaitingForRequestToComplete;
    }
};

fn testReader(state: *State, res: *TestResponse, data: []const u8) !void {
    var status: u16 = 0;
    var r = Reader.init(state);

    // dupe it so that we have a mutable copy
    const owned = try testing.allocator.dupe(u8, data);
    defer testing.allocator.free(owned);

    var unsent = owned;
    while (unsent.len > 0) {
        // send part of the response
        const to_send = testing.Random.intRange(usize, 1, unsent.len);
        var to_process = unsent[0..to_send];
        while (true) {
            const result = try r.process(to_process);

            if (status == 0) {
                if (r.response.status > 0) {
                    status = r.response.status;
                }
            } else {
                // once set, it should not change
                try testing.expectEqual(status, r.response.status);
            }

            if (result.data) |d| {
                try res.body.appendSlice(res.arena.allocator(), d);
            }

            if (result.done) {
                res.status = status;
                res.headers = r.response.headers;
                return;
            }
            to_process = result.unprocessed orelse break;
        }
        unsent = unsent[to_send..];
    }
    return error.NeverDone;
}

fn testClient(opts: Client.Opts) !Client {
    var o = opts;
    o.max_concurrent = 1;
    return try Client.init(testing.allocator, o);
}

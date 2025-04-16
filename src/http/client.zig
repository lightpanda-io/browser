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
const jsruntime = @import("jsruntime");
const IO = jsruntime.IO;
const Loop = jsruntime.Loop;

const log = std.log.scoped(.http_client);

const BUFFER_LEN = 32 * 1024;

// The longest individual header line that we support
const MAX_HEADER_LINE_LEN = 4096;

// Thread-safe. Holds our root certificate, connection pool and state pool
// Used to create Requests.
pub const Client = struct {
    allocator: Allocator,
    state_pool: StatePool,
    root_ca: tls.config.CertBundle,
    tls_verify_host: bool = true,

    const Opts = struct {
        tls_verify_host: bool = true,
    };

    pub fn init(allocator: Allocator, max_concurrent: usize, opts: Opts) !Client {
        var root_ca = try tls.config.CertBundle.fromSystem(allocator);
        errdefer root_ca.deinit(allocator);

        const state_pool = try StatePool.init(allocator, max_concurrent);
        errdefer state_pool.deinit(allocator);

        return .{
            .root_ca = root_ca,
            .allocator = allocator,
            .state_pool = state_pool,
            .tls_verify_host = opts.tls_verify_host,
        };
    }

    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        self.root_ca.deinit(allocator);
        self.state_pool.deinit(allocator);
    }

    pub fn request(self: *Client, method: Request.Method, uri: *const Uri) !Request {
        const state = self.state_pool.acquire();

        errdefer {
            state.reset();
            self.state_pool.release(state);
        }

        return Request.init(self, state, method, uri);
    }
};

// Represents a request. Can be used to make either a synchronous or an
// asynchronous request. When a synchronous request is made, `request.deinit()`
// should be called once the response is no longer needed.
// When an asychronous request is made, the request is automatically cleaned up
// (but request.deinit() should still be called to discard the request
// before the `sendAsync` is called).
pub const Request = struct {
    // Whether or not TLS is being used.
    secure: bool,
    // The HTTP Method to use
    method: Method,

    // The URI we're requested
    uri: *const Uri,

    // If we're redirecting, this is where we're redirecting to. The only reason
    // we really have this is so that we can set self.uri = &self.redirect_url.?
    redirect_uri: ?Uri = null,

    // Optional body
    body: ?[]const u8,

    // Arena used for the lifetime of the request. Most large allocations are
    // either done through the state (pre-allocated on startup + pooled) or
    // by the TLS library.
    arena: Allocator,

    // List of request headers
    headers: std.ArrayListUnmanaged(std.http.Header),

    // Used to limit the # of redirects we'll follow
    _redirect_count: u16,

    // The underlying socket
    _socket: ?posix.socket_t,

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
    };

    fn init(client: *Client, state: *State, method: Method, uri: *const Uri) !Request {
        if (uri.host == null) {
            return error.UriMissingHost;
        }

        return .{
            .secure = true,
            .uri = uri,
            .method = method,
            .body = null,
            .headers = .{},
            .arena = state.arena.allocator(),
            ._socket = null,
            ._state = state,
            ._client = client,
            ._redirect_count = 0,
            ._has_host_header = false,
            ._tls_verify_host = client.tls_verify_host,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self._socket) |socket| {
            posix.close(socket);
            self._socket = null;
        }
        _ = self._state.reset();
        self._client.state_pool.release(self._state);
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
        return self.doSendSync();
    }

    // Called internally, follows a redirect.
    fn redirectSync(self: *Request, redirect: Reader.Redirect) anyerror!Response {
        try self.prepareToRedirect(redirect);
        return self.doSendSync();
    }

    fn doSendSync(self: *Request) anyerror!Response {
        const socket, const address = try self.createSocket(true);
        var handler = SyncHandler{ .request = self };
        return handler.send(socket, address) catch |err| {
            log.warn("HTTP error: {any} ({any} {any} {d})", .{ err, self.method, self.uri, self._redirect_count });
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
        return self.doSendAsync(loop, handler);
    }
    pub fn redirectAsync(self: *Request, redirect: Reader.Redirect, loop: anytype, handler: anytype) !void {
        try self.prepareToRedirect(redirect);
        return self.doSendAsync(loop, handler);
    }

    fn doSendAsync(self: *Request, loop: anytype, handler: anytype) !void {
        const socket, const address = try self.createSocket(false);
        const AsyncHandlerT = AsyncHandler(@TypeOf(handler), @TypeOf(loop));
        const async_handler = try self.arena.create(AsyncHandlerT);

        async_handler.* = .{
            .loop = loop,
            .socket = socket,
            .request = self,
            .handler = handler,
            .read_buf = self._state.read_buf,
            .write_buf = self._state.write_buf,
            .reader = Reader.init(self._state),
            .connection = .{ .handler = async_handler, .protocol = .{ .plain = {} } },
        };

        if (self.secure) {
            async_handler.connection.protocol = .{
                .secure = .{
                    .tls_client = try tls.nb.Client().init(self.arena, .{
                        .host = self.host(),
                        .root_ca = self._client.root_ca,
                        .insecure_skip_verify = self._tls_verify_host == false,
                        // .key_log_callback = tls.config.key_log.callback
                    }),
                },
            };
        }

        try loop.connect(AsyncHandlerT, async_handler, &async_handler.read_completion, AsyncHandlerT.connected, socket, address);
    }

    // Does additional setup of the request for the firsts (i.e. non-redirect) call.
    fn prepareInitialSend(self: *Request) !void {
        try self.verifyUri();

        const arena = self.arena;
        if (self.body) |body| {
            const cl = try std.fmt.allocPrint(arena, "{d}", .{body.len});
            try self.headers.append(arena, .{ .name = "Content-Length", .value = cl });
        }

        if (!self._has_host_header) {
            try self.headers.append(arena, .{ .name = "Host", .value = self.host() });
        }

        try self.headers.append(arena, .{ .name = "User-Agent", .value = "Lightpanda/1.0" });
    }

    // Sets up the request for redirecting.
    fn prepareToRedirect(self: *Request, redirect: Reader.Redirect) !void {
        posix.close(self._socket.?);
        self._socket = null;

        // CANNOT reset the arena (╥﹏╥)
        // We need it for self.uri (which we're about to use to resolve
        // redirect.location, and it might own some/all headers)

        const redirect_count = self._redirect_count;
        if (redirect_count == 10) {
            return error.TooManyRedirects;
        }
        self._redirect_count = redirect_count + 1;

        var buf = try self.arena.alloc(u8, 1024);

        const previous_host = self.host();
        self.redirect_uri = try self.uri.resolve_inplace(redirect.location, &buf);

        self.uri = &self.redirect_uri.?;
        try self.verifyUri();

        if (redirect.use_get) {
            // Some redirect status codes _require_ that we switch the method
            // to a GET.
            self.method = .GET;
        }
        log.info("redirecting to: {any} {any}", .{ self.method, self.uri });

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

        const new_host = self.host();
        if (std.mem.eql(u8, previous_host, new_host) == false) {
            for (self.headers.items) |*hdr| {
                if (std.mem.eql(u8, hdr.name, "Host")) {
                    hdr.value = new_host;
                    break;
                }
            }
        }
    }

    // extracted because we re-verify this on redirect
    fn verifyUri(self: *Request) !void {
        const scheme = self.uri.scheme;
        if (std.ascii.eqlIgnoreCase(scheme, "https")) {
            self.secure = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "http")) {
            self.secure = false;
            return;
        }

        return error.UnsupportedUriScheme;
    }

    fn createSocket(self: *Request, blocking: bool) !struct { posix.socket_t, std.net.Address } {
        const host_ = self.host();
        const port: u16 = self.uri.port orelse if (self.secure) 443 else 80;

        const addresses = try std.net.getAddressList(self.arena, host_, port);
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

        self._socket = socket;
        return .{ socket, address };
    }

    fn buildHeader(self: *Request) ![]const u8 {
        const buf = self._state.header_buf;
        var fbs = std.io.fixedBufferStream(buf);
        var writer = fbs.writer();

        try writer.writeAll(@tagName(self.method));
        try writer.writeByte(' ');
        try self.uri.writeToStream(.{ .path = true, .query = true }, writer);
        try writer.writeAll(" HTTP/1.1\r\n");
        for (self.headers.items) |header| {
            try writer.writeAll(header.name);
            try writer.writeAll(": ");
            try writer.writeAll(header.value);
            try writer.writeAll("\r\n");
        }
        // TODO: remove this once we have a connection pool
        try writer.writeAll("Connection: Close\r\n");
        try writer.writeAll("\r\n");
        return buf[0..fbs.pos];
    }

    fn host(self: *const Request) []const u8 {
        return self.uri.host.?.percent_encoded;
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

        // Depending on which version of TLS, there are different places during
        // the handshake that we want to start receiving from. We can't have
        // overlapping receives (works fine on MacOS (kqueue) but not Linux (
        // io_uring)). Using this boolean as a guard, to make sure we only have
        // 1 in-flight receive is easier than trying to understand TLS.
        is_receiving: bool = false,

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

        // Abstraction over TLS and plain text socket
        connection: Connection,

        // This will be != null when we're supposed to redirect AND we've
        // drained the response body. We need this as a field, because we'll
        // detect this inside our TLS onRecv callback (which is executed
        // inside the TLS client, and so we can't deinitialize the tls_client)
        redirect: ?Reader.Redirect = null,

        const Self = @This();
        const SendQueue = std.DoublyLinkedList([]const u8);

        const SendState = enum {
            handshake,
            header,
            body,
        };

        const ProcessStatus = enum {
            wait,
            done,
            need_more,
        };

        fn deinit(self: *Self) void {
            self.connection.deinit();
            self.request.deinit();
        }

        fn connected(self: *Self, _: *IO.Completion, result: IO.ConnectError!void) void {
            result catch |err| return self.handleError("Connection failed", err);
            self.connection.connected() catch |err| {
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

            self.connection.sent() catch |err| {
                self.handleError("send handling", err);
            };
        }

        // Normally, you'd think of HTTP as being a straight up request-response
        // and that we can send, and then receive. But with TLS, we need to receive
        // while handshaking and potentially while sending data. So we're always
        // receiving.
        fn receive(self: *Self) void {
            if (self.is_receiving) {
                return;
            }

            self.is_receiving = true;
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
            self.is_receiving = false;
            const n = n_ catch |err| {
                return self.handleError("Read error", err);
            };
            if (n == 0) {
                return self.handleError("Connection closed", error.ConnectionResetByPeer);
            }

            const status = self.connection.received(self.read_buf[0 .. self.read_pos + n]) catch |err| {
                self.handleError("data processing", err);
                return;
            };

            switch (status) {
                .wait => {},
                .need_more => self.receive(),
                .done => {
                    const redirect = self.redirect orelse {
                        self.deinit();
                        return;
                    };
                    self.request.redirectAsync(redirect, self.loop, self.handler) catch |err| {
                        self.handleError("Setup async redirect", err);
                        return;
                    };
                    // redirectAsync has given up any claim to the request,
                    // including the socket. We just need to clean up our
                    // tls_client.
                    self.connection.deinit();
                },
            }
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
                    // We don't redirect until we've drained the body (because,
                    // if we ever add keepalive, we'll re-use the connection).
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

                const done = result.done;
                if (result.data != null or done or would_be_first) {
                    // If we have data. Or if the request is done. Or if this is the
                    // first time we have a complete header. Emit the chunk.
                    self.handler.onHttpResponse(.{
                        .done = done,
                        .data = result.data,
                        .first = would_be_first,
                        .header = reader.response,
                    }) catch return .done;
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
            log.err(msg ++ ": {any} ({any} {any})", .{ err, self.request.method, self.request.uri });
            self.handler.onHttpResponse(err) catch {};
            self.deinit();
        }

        const Connection = struct {
            handler: *Self,
            protocol: Protocol,

            const Protocol = union(enum) {
                plain: void,
                secure: Secure,

                const Secure = struct {
                    tls_client: tls.nb.Client(),
                    state: SecureState = .handshake,

                    const SecureState = enum {
                        handshake,
                        header,
                        body,
                    };
                };
            };

            fn deinit(self: *Connection) void {
                switch (self.protocol) {
                    .plain => {},
                    .secure => |*secure| secure.tls_client.deinit(),
                }
            }

            fn connected(self: *Connection) !void {
                const handler = self.handler;

                switch (self.protocol) {
                    .plain => {
                        // queue everything up
                        handler.state = .body;
                        const header = try handler.request.buildHeader();
                        handler.send(header);
                        if (handler.request.body) |body| {
                            handler.send(body);
                        }
                        handler.receive();
                    },
                    .secure => |*secure| {
                        // initiate the handshake
                        _, const i = try secure.tls_client.handshake(handler.read_buf[0..0], handler.write_buf);
                        handler.send(handler.write_buf[0..i]);
                        handler.receive();
                    },
                }
            }

            fn received(self: *Connection, data: []u8) !ProcessStatus {
                const handler = self.handler;
                switch (self.protocol) {
                    .plain => return handler.processData(data),
                    .secure => |*secure| {
                        var used: usize = 0;
                        var closed = false;
                        var cleartext_pos: usize = 0;
                        var status = ProcessStatus.need_more;
                        var tls_client = &secure.tls_client;

                        if (tls_client.isConnected()) {
                            used, cleartext_pos, closed = try tls_client.decrypt(data);
                        } else {
                            std.debug.assert(secure.state == .handshake);
                            // process handshake data
                            used, const i = try tls_client.handshake(data, handler.write_buf);
                            if (i > 0) {
                                handler.send(handler.write_buf[0..i]);
                            } else if (tls_client.isConnected()) {
                                // if we're done our handshake, there should be
                                // no unused data
                                handler.read_pos = 0;
                                std.debug.assert(used == data.len);
                                try self.sendSecureHeader(secure);
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

            fn sent(self: *Connection) !void {
                switch (self.protocol) {
                    .plain => {},
                    .secure => |*secure| {
                        if (secure.tls_client.isConnected() == false) {
                            std.debug.assert(secure.state == .handshake);
                            // still handshaking, nothing to do
                            return;
                        }
                        switch (secure.state) {
                            .handshake => return self.sendSecureHeader(secure),
                            .header => {
                                secure.state = .body;
                                const handler = self.handler;
                                const body = handler.request.body orelse {
                                    // We've sent the header, and there's no body
                                    // start receiving the response
                                    handler.receive();
                                    return;
                                };
                                const used, const i = try secure.tls_client.encrypt(body, handler.write_buf);
                                std.debug.assert(body.len == used);
                                handler.send(handler.write_buf[0..i]);
                            },
                            .body => {
                                // We've sent the body, start receiving the
                                // response
                                self.handler.receive();
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
            fn sendSecureHeader(self: Connection, secure: *Protocol.Secure) !void {
                secure.state = .header;
                const handler = self.handler;
                const header = try handler.request.buildHeader();
                const used, const i = try secure.tls_client.encrypt(header, handler.write_buf);
                std.debug.assert(header.len == used);
                handler.send(handler.write_buf[0..i]);
            }
        };
    };
}

// Handles synchronous requests
const SyncHandler = struct {
    request: *Request,

    // The Request owns the socket, we shouldn't close it in here.
    fn send(self: *SyncHandler, socket: posix.socket_t, address: std.net.Address) !Response {
        var request = self.request;
        try posix.connect(socket, &address.any, address.getOsSockLen());

        var connection: Connection = undefined;
        if (request.secure) {
            connection = .{
                .tls = try tls.client(std.net.Stream{ .handle = socket }, .{
                    .host = request.host(),
                    .root_ca = request._client.root_ca,
                    .insecure_skip_verify = request._tls_verify_host == false,
                    // .key_log_callback = tls.config.key_log.callback,
                }),
            };
        } else {
            connection = .{ .plain = socket };
        }

        const header = try request.buildHeader();
        try connection.sendRequest(header, request.body);

        const state = request._state;

        var buf = state.read_buf;
        var reader = Reader.init(state);

        while (true) {
            const n = try connection.read(buf);
            const result = try reader.process(buf[0..n]);

            if (reader.header_done == false) {
                continue;
            }

            if (reader.redirect()) |redirect| {
                if (result.done == false) {
                    try self.drain(&reader, &connection, result.unprocessed);
                }
                return request.redirectSync(redirect);
            }

            // we have a header, and it isn't a redirect, we return our Response
            // object which can be iterated to get the body.
            std.debug.assert(result.done or reader.body_reader != null);
            std.debug.assert(result.data == null);
            return .{
                ._buf = buf,
                ._request = request,
                ._reader = reader,
                ._done = result.done,
                ._connection = connection,
                ._data = result.unprocessed,
                .header = reader.response,
            };
        }
    }

    fn drain(self: SyncHandler, reader: *Reader, connection: *Connection, unprocessed: ?[]u8) !void {
        if (unprocessed) |data| {
            const result = try reader.process(data);
            if (result.done) {
                return;
            }
        }

        var buf = self.request._state.read_buf;
        while (true) {
            const n = try connection.read(buf);
            const result = try reader.process(buf[0..n]);
            if (result.done) {
                return;
            }
        }
    }

    const Connection = union(enum) {
        tls: tls.Connection(std.net.Stream),
        plain: posix.socket_t,

        fn sendRequest(self: *Connection, header: []const u8, body: ?[]const u8) !void {
            switch (self.*) {
                .tls => |*tls_conn| {
                    try tls_conn.writeAll(header);
                    if (body) |b| {
                        try tls_conn.writeAll(b);
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

        fn read(self: *Connection, buf: []u8) !usize {
            const n = switch (self.*) {
                .tls => |*tls_conn| try tls_conn.read(buf),
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
};

// Used for reading the response (both the header and the body)
const Reader = struct {
    // always references state.header_buf
    header_buf: []u8,

    // position in header_buf that we have valid data up until
    pos: usize,

    // for populating the response headers list
    arena: Allocator,

    response: ResponseHeader,

    body_reader: ?BodyReader,

    header_done: bool,

    fn init(state: *State) Reader {
        return .{
            .pos = 0,
            .response = .{},
            .body_reader = null,
            .header_done = false,
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

    fn process(self: *Reader, data: []u8) ProcessError!Result {
        if (self.body_reader) |*br| {
            const ok, const result = try br.process(data);
            if (ok == false) {
                // There's something that our body reader didn't like. It wants
                // us to emit whatever data we have, but it isn't safe to keep
                // the connection alive.s
                std.debug.assert(result.done == true);
                self.response.keepalive = false;
            }
            return result;
        }

        // Still parsing the header

        // what data do we have leftover in `data`.
        // When header_done == true, then this is part (or all) of the body
        // When header_done == false, then this is a header line that we didn't
        // have enough data for.
        var done = false;
        var unprocessed = data;

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
                    return error.HeaderTooLarge;
                }
                self.pos = end;
                @memcpy(self.header_buf[pos..end], data);
                return .{ .done = false, .data = null, .unprocessed = null };
            }) + 1;

            const end = pos + line_end;
            if (end > header_buf.len) {
                return error.HeaderTooLarge;
            }

            @memcpy(header_buf[pos..end], data[0..line_end]);
            done, unprocessed = try self.parseHeader(header_buf[0..end]);

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
                    return error.HeaderTooLarge;
                }
                @memcpy(header_buf[p..end], unprocessed);
                self.pos = end;
                return .{ .done = false, .data = null, .unprocessed = null };
            }
        }
        var result = try self.prepareForBody();
        if (unprocessed.len > 0) {
            if (result.done == true) {
                // We think we're done reading the body, but we still have data
                // We'll return what we have as-is, but close the connection
                // because we don't know what state it's in.
                self.response.keepalive = false;
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
                self.response.keepalive = true;
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
    keepalive: bool = false,
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
const Header = struct {
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

    // whether or not more data should be expected
    done: bool,
    // A piece of data from the body
    data: ?[]const u8,

    header: ResponseHeader,
};

// The value that we return from a synchronous requst.
pub const Response = struct {
    _reader: Reader,
    _request: *Request,

    _buf: []u8,
    _connection: SyncHandler.Connection,

    _done: bool,

    // Any data we over-read while parsing the header. This will be returned on
    // the first call to next();
    _data: ?[]u8 = null,
    header: ResponseHeader,

    pub fn next(self: *Response) !?[]u8 {
        var buf = self._buf;
        while (true) {
            if (try self.processData()) |data| {
                return data;
            }
            if (self._done) {
                return null;
            }

            const n = try self._connection.read(buf);
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
};

// Pooled and re-used when creating a request
const State = struct {
    // used for reading chunks of payload data.
    read_buf: []u8,

    // use for writing data. If you're wondering why BOTH a read_buf and a
    // write_buf, even though HTTP is req -> resp, it's for TLS, which has
    // bidirectional data.
    write_buf: []u8,

    // Used for keeping any unparsed header line until more data is received
    // At most, this represents 1 line in the header.
    header_buf: []u8,

    // Used to optionally clone request headers, and always used to clone
    // response headers.
    arena: ArenaAllocator,

    fn init(allocator: Allocator, header_size: usize, buf_size: usize) !State {
        const read_buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(read_buf);

        const write_buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(write_buf);

        const header_buf = try allocator.alloc(u8, header_size);
        errdefer allocator.free(header_buf);

        return .{
            .read_buf = read_buf,
            .write_buf = write_buf,
            .header_buf = header_buf,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn reset(self: *State) void {
        _ = self.arena.reset(.{ .retain_with_limit = 1024 * 1024 });
    }

    fn deinit(self: *State) void {
        const allocator = self.arena.child_allocator;
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
            state.* = try State.init(allocator, MAX_HEADER_LINE_LEN, BUFFER_LEN);
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

    pub fn acquire(self: *StatePool) *State {
        self.mutex.lock();
        while (true) {
            const states = self.states;
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

    pub fn release(self: *StatePool, state: *State) void {
        self.mutex.lock();
        var states = self.states;
        const available = self.available;
        states[available] = state;
        self.available = available + 1;
        self.mutex.unlock();
        self.cond.signal();
    }
};

const testing = @import("../testing.zig");
test "HttpClient Reader: fuzz" {
    var state = try State.init(testing.allocator, 1024, 1024);
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
            try testing.expectEqual(true, res.keepalive);
            try testing.expectEqual(0, res.body.items.len);
            try testing.expectEqual(0, res.headers.items.len);
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.0 404 \r\nError: Not-Found\r\n\r\n");
            try testing.expectEqual(404, res.status);
            try testing.expectEqual(false, res.keepalive);
            try testing.expectEqual(0, res.body.items.len);
            try res.assertHeaders(&.{ "error", "Not-Found" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nSet-Cookie: a32;max-age=60\r\nContent-Length: 12\r\n\r\nOver 9000!!!");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(true, res.keepalive);
            try testing.expectEqual("Over 9000!!!", res.body.items);
            try res.assertHeaders(&.{ "set-cookie", "a32;max-age=60", "content-length", "12" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(true, res.keepalive);
            try testing.expectEqual("", res.body.items);
            try res.assertHeaders(&.{ "transfer-encoding", "chunked" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(true, res.keepalive);
            try testing.expectEqual("", res.body.items);
            try res.assertHeaders(&.{ "transfer-encoding", "chunked" });
        }

        {
            res.reset();
            try testReader(&state, &res, "HTTP/1.1 200 \r\nTransFEr-ENcoding:  chunked  \r\n\r\nE\r\nHello World!!!\r\n2eE;opts\r\n" ++ ("abc" ** 250) ++ "\r\n0\r\n\r\n");
            try testing.expectEqual(200, res.status);
            try testing.expectEqual(true, res.keepalive);
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
            try testing.expectEqual(true, res.keepalive);
            try testing.expectEqual(body, res.body.items);
            try res.assertHeaders(&.{ "content-length", "610000", "other", "13391AbC93" });
        }

        {
            // header too big
            const data = "HTTP/1.1 200 OK\r\n" ++ ("a" ** 1500);
            try testing.expectError(error.HeaderTooLarge, testReader(&state, &res, data));
        }
    }
}

test "HttpClient: invalid url" {
    var client = try testClient();
    defer client.deinit();
    const uri = try Uri.parse("http:///");
    try testing.expectError(error.UriMissingHost, client.request(.GET, &uri));
}

test "HttpClient: sync connect error" {
    var client = try testClient();
    defer client.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9920");
    var req = try client.request(.GET, &uri);
    try testing.expectError(error.ConnectionRefused, req.sendSync(.{}));
}

test "HttpClient: sync no body" {
    var client = try testClient();
    defer client.deinit();

    const uri = try Uri.parse("http://127.0.0.1:9582/http_client/simple");
    var req = try client.request(.GET, &uri);
    var res = try req.sendSync(.{});

    try testing.expectEqual(null, try res.next());
    try testing.expectEqual(200, res.header.status);
    try testing.expectEqual(2, res.header.count());
    try testing.expectEqual("close", res.header.get("connection"));
    try testing.expectEqual("0", res.header.get("content-length"));
}

test "HttpClient: sync tls no body" {
    for (0..5) |_| {
        var client = try testClient();
        defer client.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/simple");
        var req = try client.request(.GET, &uri);
        var res = try req.sendSync(.{ .tls_verify_host = false });

        try testing.expectEqual(null, try res.next());
        try testing.expectEqual(200, res.header.status);
        try testing.expectEqual(1, res.header.count());
        try testing.expectEqual("0", res.header.get("content-length"));
    }
}

test "HttpClient: sync with body" {
    var client = try testClient();
    defer client.deinit();

    const uri = try Uri.parse("http://127.0.0.1:9582/http_client/echo");
    var req = try client.request(.GET, &uri);
    var res = try req.sendSync(.{});

    try testing.expectEqual("over 9000!", try res.next());
    try testing.expectEqual(201, res.header.status);
    try testing.expectEqual(5, res.header.count());
    try testing.expectEqual("close", res.header.get("connection"));
    try testing.expectEqual("10", res.header.get("content-length"));
    try testing.expectEqual("127.0.0.1", res.header.get("_host"));
    try testing.expectEqual("Close", res.header.get("_connection"));
    try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
}

test "HttpClient: sync tls with body" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient();
        defer client.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/body");
        var req = try client.request(.GET, &uri);
        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual("1234567890abcdefhijk", arr.items);
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual(2, res.header.count());
        try testing.expectEqual("20", res.header.get("content-length"));
        try testing.expectEqual("HEaDer", res.header.get("another"));
    }
}

test "HttpClient: sync redirect from TLS to Plaintext" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient();
        defer client.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/redirect/insecure");
        var req = try client.request(.GET, &uri);
        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual("over 9000!", arr.items);
        try testing.expectEqual(5, res.header.count());
        try testing.expectEqual("close", res.header.get("connection"));
        try testing.expectEqual("10", res.header.get("content-length"));
        try testing.expectEqual("127.0.0.1", res.header.get("_host"));
        try testing.expectEqual("Close", res.header.get("_connection"));
        try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
    }
}

test "HttpClient: sync redirect plaintext to TLS" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient();
        defer client.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect/secure");
        var req = try client.request(.GET, &uri);
        var res = try req.sendSync(.{ .tls_verify_host = false });

        while (try res.next()) |data| {
            arr.appendSliceAssumeCapacity(data);
        }
        try testing.expectEqual(201, res.header.status);
        try testing.expectEqual("1234567890abcdefhijk", arr.items);
        try testing.expectEqual(2, res.header.count());
        try testing.expectEqual("20", res.header.get("content-length"));
        try testing.expectEqual("HEaDer", res.header.get("another"));
    }
}

test "HttpClient: sync GET redirect" {
    var client = try testClient();
    defer client.deinit();

    const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect");
    var req = try client.request(.GET, &uri);
    var res = try req.sendSync(.{ .tls_verify_host = false });

    try testing.expectEqual("over 9000!", try res.next());
    try testing.expectEqual(201, res.header.status);
    try testing.expectEqual(5, res.header.count());
    try testing.expectEqual("close", res.header.get("connection"));
    try testing.expectEqual("10", res.header.get("content-length"));
    try testing.expectEqual("127.0.0.1", res.header.get("_host"));
    try testing.expectEqual("Close", res.header.get("_connection"));
    try testing.expectEqual("Lightpanda/1.0", res.header.get("_user-agent"));
}

test "HttpClient: async connect error" {
    var loop = try jsruntime.Loop.init(testing.allocator);
    defer loop.deinit();

    const Handler = struct {
        reset: *Thread.ResetEvent,
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
    var client = try testClient();
    defer client.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9920");
    var req = try client.request(.GET, &uri);
    try req.sendAsync(&loop, Handler{ .reset = &reset }, .{});
    try loop.io.run_for_ns(std.time.ns_per_ms);
    try reset.timedWait(std.time.ns_per_s);
}

test "HttpClient: async no body" {
    var client = try testClient();
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/simple");
    var req = try client.request(.GET, &uri);
    try req.sendAsync(&handler.loop, &handler, .{});
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("", res.body.items);
    try testing.expectEqual(200, res.status);
    try res.assertHeaders(&.{ "connection", "close", "content-length", "0" });
}

test "HttpClient: async with body" {
    var client = try testClient();
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/echo");
    var req = try client.request(.GET, &uri);
    try req.sendAsync(&handler.loop, &handler, .{});
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("over 9000!", res.body.items);
    try testing.expectEqual(201, res.status);
    try res.assertHeaders(&.{
        "connection",     "close",
        "content-length", "10",
        "_host",          "127.0.0.1",
        "_user-agent",    "Lightpanda/1.0",
        "_connection",    "Close",
    });
}

test "HttpClient: async redirect" {
    var client = try testClient();
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    const uri = try Uri.parse("HTTP://127.0.0.1:9582/http_client/redirect");
    var req = try client.request(.GET, &uri);
    try req.sendAsync(&handler.loop, &handler, .{});

    // Called twice on purpose. The initial GET resutls in the # of pending
    // events to reach 0. This causes our `run_for_ns` to return. But we then
    // start to requeue events (from the redirected request), so we need the
    //loop to process those also.
    try handler.loop.io.run_for_ns(std.time.ns_per_ms);
    try handler.waitUntilDone();

    const res = handler.response;
    try testing.expectEqual("over 9000!", res.body.items);
    try testing.expectEqual(201, res.status);
    try res.assertHeaders(&.{
        "connection",     "close",
        "content-length", "10",
        "_host",          "127.0.0.1",
        "_user-agent",    "Lightpanda/1.0",
        "_connection",    "Close",
    });
}

test "HttpClient: async tls no body" {
    for (0..5) |_| {
        var client = try testClient();
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("HTTPs://127.0.0.1:9581/http_client/simple");
        var req = try client.request(.GET, &uri);
        try req.sendAsync(&handler.loop, &handler, .{ .tls_verify_host = false });
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual("", res.body.items);
        try testing.expectEqual(200, res.status);
        try res.assertHeaders(&.{ "content-length", "0" });
    }
}

test "HttpClient: async tls with body" {
    for (0..5) |_| {
        var client = try testClient();
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("HTTPs://127.0.0.1:9581/http_client/body");
        var req = try client.request(.GET, &uri);
        try req.sendAsync(&handler.loop, &handler, .{ .tls_verify_host = false });
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual("1234567890abcdefhijk", res.body.items);
        try testing.expectEqual(201, res.status);
        try res.assertHeaders(&.{ "content-length", "20", "another", "HEaDer" });
    }
}

test "HttpClient: async redirect from TLS to Plaintext" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient();
        defer client.deinit();

        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("https://127.0.0.1:9581/http_client/redirect/insecure");
        var req = try client.request(.GET, &uri);
        try req.sendAsync(&handler.loop, &handler, .{ .tls_verify_host = false });
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual(201, res.status);
        try testing.expectEqual("over 9000!", res.body.items);
        try res.assertHeaders(&.{ "connection", "close", "content-length", "10", "_host", "127.0.0.1", "_user-agent", "Lightpanda/1.0", "_connection", "Close" });
    }
}

test "HttpClient: async redirect plaintext to TLS" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);
    try arr.ensureTotalCapacity(testing.allocator, 20);

    for (0..5) |_| {
        defer arr.clearRetainingCapacity();
        var client = try testClient();
        defer client.deinit();
        var handler = try CaptureHandler.init();
        defer handler.deinit();

        const uri = try Uri.parse("http://127.0.0.1:9582/http_client/redirect/secure");
        var req = try client.request(.GET, &uri);
        try req.sendAsync(&handler.loop, &handler, .{ .tls_verify_host = false });
        try handler.waitUntilDone();

        const res = handler.response;
        try testing.expectEqual(201, res.status);
        try testing.expectEqual("1234567890abcdefhijk", res.body.items);
        try res.assertHeaders(&.{ "content-length", "20", "another", "HEaDer" });
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
    keepalive: ?bool,
    arena: std.heap.ArenaAllocator,
    body: std.ArrayListUnmanaged(u8),
    headers: std.ArrayListUnmanaged(Header),

    fn init() TestResponse {
        return .{
            .status = 0,
            .keepalive = null,
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
        self.keepalive = null;
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
    loop: jsruntime.Loop,
    reset: Thread.ResetEvent,
    response: TestResponse,

    fn init() !CaptureHandler {
        return .{
            .reset = .{},
            .response = TestResponse.init(),
            .loop = try jsruntime.Loop.init(testing.allocator),
        };
    }

    fn deinit(self: *CaptureHandler) void {
        self.response.deinit();
        self.loop.deinit();
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
        if (progress.done) {
            self.response.status = progress.header.status;
            try self.response.headers.ensureTotalCapacity(allocator, progress.header.headers.items.len);
            for (progress.header.headers.items) |header| {
                self.response.headers.appendAssumeCapacity(.{
                    .name = try allocator.dupe(u8, header.name),
                    .value = try allocator.dupe(u8, header.value),
                });
            }
            self.response.keepalive = progress.header.keepalive;
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
                res.keepalive = r.response.keepalive;
                return;
            }
            to_process = result.unprocessed orelse break;
        }
        unsent = unsent[to_send..];
    }
    return error.NeverDone;
}

fn testClient() !Client {
    return try Client.init(testing.allocator, 1, .{});
}

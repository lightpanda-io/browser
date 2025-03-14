const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const MemoryPool = std.heap.MemoryPool;
const ArenaAllocator = std.heap.ArenaAllocator;

const tls = @import("tls");
const jsruntime = @import("jsruntime");
const IO = jsruntime.IO;
const Loop = jsruntime.Loop;

const log = std.log.scoped(.http_client);

// The longest individual header line that we support
const MAX_HEADER_LINE_LEN = 4096;

// tls.max_ciphertext_record_len which isn't exposed
const BUFFER_LEN = (1 << 14) + 256 + 5;

const TLSConnection = tls.Connection(std.net.Stream);
const HeaderList = std.ArrayListUnmanaged(std.http.Header);

pub const Client = struct {
    allocator: Allocator,
    state_pool: StatePool,
    root_ca: tls.config.CertBundle,

    pub fn init(allocator: Allocator, max_concurrent: usize) !Client {
        var root_ca = try tls.config.CertBundle.fromSystem(allocator);
        errdefer root_ca.deinit(allocator);

        const state_pool = try StatePool.init(allocator, max_concurrent);
        errdefer state_pool.deinit(allocator);

        return .{
            .root_ca = root_ca,
            .allocator = allocator,
            .state_pool = state_pool,
        };
    }

    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        self.root_ca.deinit(allocator);
        self.state_pool.deinit(allocator);
    }

    pub fn request(self: *Client, method: Request.Method, url: anytype) !Request {
        const state = self.state_pool.acquire();

        errdefer {
            state.reset();
            self.state_pool.release(state);
        }

        return Request.init(self, state, method, url);
    }
};

pub const Request = struct {
    secure: bool,
    method: Method,
    uri: std.Uri,
    body: ?[]const u8,
    arena: Allocator,
    headers: HeaderList,
    _buf: []u8,
    _socket: ?posix.socket_t,
    _state: *State,
    _client: *Client,
    _has_host_header: bool,

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

    fn init(client: *Client, state: *State, method: Method, url: anytype) !Request {
        var arena = state.arena.allocator();

        var uri: std.Uri = undefined;

        if (@TypeOf(url) == std.Uri) {
            uri = url;
        } else {
            const owned = try arena.dupe(u8, url);
            uri = try std.Uri.parse(owned);
        }

        if (uri.host == null) {
            return error.UriMissingHost;
        }

        var secure: bool = false;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
            secure = true;
        } else if (std.ascii.eqlIgnoreCase(uri.scheme, "http") == false) {
            return error.UnsupportedUriScheme;
        }

        return .{
            .secure = secure,
            .uri = uri,
            .method = method,
            .body = null,
            .headers = .{},
            .arena = arena,
            ._buf = state.buf,
            ._socket = null,
            ._state = state,
            ._client = client,
            ._has_host_header = false,
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
    const SendSyncOpts = struct {};
    pub fn sendSync(self: *Request, _: SendSyncOpts) !Response {
        try self.prepareToSend();
        const socket, const address = try self.createSocket(true);
        try posix.connect(socket, &address.any, address.getOsSockLen());

        const header = try self.buildHeader();
        var stream = std.net.Stream{ .handle = socket };

        var tls_conn: ?TLSConnection = null;
        if (self.secure) {
            var conn = try tls.client(stream, .{
                .host = self.host(),
                .root_ca = self._client.root_ca,
            });

            try conn.writeAll(header);
            if (self.body) |body| {
                try conn.writeAll(body);
            }
            tls_conn = conn;
        } else if (self.body) |body| {
            var vec = [2]posix.iovec_const{
                .{ .len = header.len, .base = header.ptr },
                .{ .len = body.len, .base = body.ptr },
            };
            try writeAllIOVec(socket, &vec);
        } else {
            try stream.writeAll(header);
        }

        var buf = self._state.buf;
        var reader = Reader.init(self._state);

        while (true) {
            var n: usize = 0;
            if (tls_conn) |*conn| {
                n = try conn.read(buf);
            } else {
                n = try stream.read(buf);
            }

            if (n == 0) {
                return error.ConnectionResetByPeer;
            }
            const result = try reader.process(buf[0..n]);
            if (result.header) {
                std.debug.assert(result.done or reader.body_reader != null);
                return .{
                    ._buf = buf,
                    ._request = self,
                    ._reader = reader,
                    ._done = result.done,
                    ._tls_conn = tls_conn,
                    ._data = result.data,
                    ._socket = self._socket.?,
                    .header = reader.response,
                };
            }
        }
    }

    const SendAsyncOpts = struct {};
    pub fn sendAsync(self: *Request, loop: anytype, handler: anytype, _: SendAsyncOpts) !void {
        try self.prepareToSend();
        // TODO: change this to nonblocking (false) when we have promise resolution
        const socket, const address = try self.createSocket(true);

        const AsyncHandlerT = AsyncHandler(@TypeOf(handler), @TypeOf(loop));
        const async_handler = try self.arena.create(AsyncHandlerT);
        async_handler.* = .{
            .loop = loop,
            .socket = socket,
            .request = self,
            .handler = handler,
            .tls_conn = null,
            .read_buf = self._state.buf,
            .reader = Reader.init(self._state),
        };
        if (self.secure) {
            async_handler.tls_conn = try tls.asyn.Client(AsyncHandlerT.TLSHandler).init(self.arena, .{ .handler = async_handler }, .{
                .host = self.host(),
                .root_ca = self._client.root_ca,
            });
        }

        loop.connect(AsyncHandlerT, async_handler, &async_handler.read_completion, AsyncHandlerT.connected, socket, address);
    }

    fn prepareToSend(self: *Request) !void {
        const arena = self.arena;

        if (self.body) |body| {
            const cl = try std.fmt.allocPrint(arena, "{d}", .{body.len});
            try self.headers.append(arena, .{ .name = "Content-Length", .value = cl });
        }

        if (!self._has_host_header) {
            try self.headers.append(arena, .{ .name = "Host", .value = self.uri.host.?.percent_encoded });
        }
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

fn AsyncHandler(comptime H: type, comptime L: type) type {
    return struct {
        loop: L,
        handler: H,
        request: *Request,
        read_buf: []u8,
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

        tls_conn: ?tls.asyn.Client(TLSHandler) = null,

        const Self = @This();
        const SendQueue = std.DoublyLinkedList([]const u8);

        const SendState = enum {
            handshake,
            header,
            body,
        };

        fn deinit(self: *Self) void {
            if (self.tls_conn) |*tls_conn| {
                tls_conn.deinit();
            }
            self.request.deinit();
        }

        fn connected(self: *Self, _: *IO.Completion, result: IO.ConnectError!void) void {
            result catch |err| return self.handleError("Connection failed", err);

            if (self.tls_conn) |*tls_conn| {
                tls_conn.onConnect() catch |err| {
                    self.handleError("TLS handshake error", err);
                };
                self.receive();
                return;
            }

            self.state = .header;
            const header = self.request.buildHeader() catch |err| {
                return self.handleError("out of memory", err);
            };
            self.send(header);
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
            );
        }

        fn sent(self: *Self, _: *IO.Completion, n_: IO.SendError!usize) void {
            const n = n_ catch |err| {
                return self.handleError("Write error", err);
            };

            const node = self.send_queue.popFirst().?;
            const data = node.data;
            if (n < data.len) {
                // didn't send all the data, we prematurely popped this off
                // (because, in most cases, it _will_ send all the data)
                node.data = data[n..];
                self.send_queue.prepend(node);
            }

            if (self.send_queue.first) |next| {
                // we still have data to send
                self.loop.send(
                    Self,
                    self,
                    &self.send_completion,
                    sent,
                    self.socket,
                    next.data,
                );
                return;
            }

            if (self.state == .handshake) {}

            switch (self.state) {
                .handshake => {
                    // We're still doing our handshake. We need to wait until
                    // that's finished before sending the header. We might have
                    // more to send until then, but it'll be triggered by the
                    // TLS layer.
                    std.debug.assert(self.tls_conn != null);
                },
                .body => {
                    // We've finished sending the body.
                    if (self.tls_conn == null) {
                        // if we aren't using TLS, then we need to start the recive loop
                        self.receive();
                    }
                },
                .header => {
                    // We've sent the header, we should send the body.
                    self.state = .body;
                    if (self.request.body) |body| {
                        if (self.tls_conn) |*tls_conn| {
                            tls_conn.send(body) catch |err| {
                                self.handleError("TLS send", err);
                            };
                        } else {
                            self.send(body);
                        }
                    } else if (self.tls_conn == null) {
                        // There is no body, and we aren't using TLS. That means
                        // our receive loop hasn't been started. Time to start.
                        self.receive();
                    }
                },
            }
        }

        // Normally, you'd thin of HTTP as being a straight up request-response
        // and that we can send, and then receive. But with TLS, we need to receive
        // while handshaking and potentially while sending data. So we're always
        // receiving.
        fn receive(self: *Self) void {
            return self.loop.recv(
                Self,
                self,
                &self.read_completion,
                Self.received,
                self.socket,
                self.read_buf,
            );
        }

        fn received(self: *Self, _: *IO.Completion, n_: IO.RecvError!usize) void {
            const n = n_ catch |err| {
                return self.handleError("Read error", err);
            };

            if (n == 0) {
                return self.handleError("Connection closed", error.ConnectionResetByPeer);
            }

            if (self.tls_conn) |*tls_conn| {
                _ = tls_conn.onRecv(self.read_buf[0..n]) catch |err| {
                    self.handleError("TLS decrypt", err);
                    return;
                };
                return;
            }

            self.processData(self.read_buf[0..n]);
        }

        fn processData(self: *Self, data: []u8) void {
            // If result.header is true, and this is true, then this is the
            // first time we're emitting a progress result
            const would_be_first = self.reader.response.status == 0;

            const result = self.reader.process(data) catch |err| {
                return self.handleError("Invalid server response", err);
            };

            const done = result.done;
            if (result.header) {
                // if we have a header, then we always emit an event, even if
                // there's no data
                self.handler.onHttpResponse(.{
                    .first = would_be_first,
                    .done = done,
                    .data = result.data,
                    .header = self.reader.response,
                }) catch return self.deinit();
            }

            if (done == true) {
                return self.deinit();
            }

            self.receive();
        }

        fn handleError(self: *Self, comptime msg: []const u8, err: anyerror) void {
            log.warn(msg ++ ": {any}  ({any})", .{ err, self.request.uri });
            self.handler.onHttpResponse(error.Failed) catch {};
            self.deinit();
        }

        // Separate struct just to keep it a bit cleaner. tls.zig requires
        // callbacks like "onConnect" and "send" which is a bit generic and
        // is confusing with the AsyncHandler which has similar concepts.
        const TLSHandler = struct {
            // reference back to the AsyncHandler
            handler: *Self,

            // Callback from tls.zig indicating that the handshake is complete
            pub fn onConnect(self: TLSHandler) void {
                var handler = self.handler;
                const header = handler.request.buildHeader() catch |err| {
                    return handler.handleError("out of memory", err);
                };
                handler.state = .header;
                handler.tls_conn.?.send(header) catch |err| {
                    return handler.handleError("TLS send", err);
                };
            }

            // tls.zig wants us to send this data
            pub fn send(self: TLSHandler, data: []const u8) !void {
                return self.handler.send(data);
            }

            // tls.zig received data, it's givingit to us in plaintext
            pub fn onRecv(self: TLSHandler, data: []u8) !void {
                if (self.handler.state != .body) {
                    // We should not receive application-level data (which is the
                    // only data tls.zig will give us), if our handler hasn't sent
                    // the body.
                    self.handler.handleError("Premature server response", error.InvalidServerResonse);
                    return error.InvalidServerResonse;
                }

                self.handler.processData(data);
            }
        };
    };
}

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

    fn init(state: *State) Reader {
        return .{
            .pos = 0,
            .response = .{},
            .body_reader = null,
            .header_buf = state.header_buf,
            .arena = state.arena.allocator(),
        };
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
                return .{ .done = false, .data = null, .header = false };
            }) + 1;

            const end = pos + line_end;
            if (end > header_buf.len) {
                return error.HeaderTooLarge;
            }

            @memcpy(header_buf[pos..end], data[0..line_end]);
            const done, unprocessed = try self.parseHeader(header_buf[0..end]);

            // we gave parseHeader exactly 1 header line, there should be no leftovers
            std.debug.assert(unprocessed.len == 0);

            // we currently have no unprocessed header data
            self.pos = 0;

            // We still [probably] have data to process which was not part of
            // the previously unparsed header line
            unprocessed = data[line_end..];

            if (done) {
                return self.prepareForBody(unprocessed);
            }
        }

        // If we're here it means that
        // 1 - Had no unparsed data, and skipped the entire block above
        // 2 - Had unparsed data, but we managed to "complete" it. AND, the
        //     unparsed data didn't represent the end of the header
        //     We're now trying to parse the rest of the `data` which was not
        //     parsed of the unparsed (unprocessed.len could be 0 here).
        const done, unprocessed = try self.parseHeader(unprocessed);
        if (done == false) {
            const p = self.pos; // don't use pos, self.pos might have been altered
            const end = p + unprocessed.len;
            if (end > header_buf.len) {
                return error.HeaderTooLarge;
            }
            @memcpy(header_buf[p..end], unprocessed);
            self.pos = end;
            return .{ .done = false, .data = null, .header = false };
        }

        return self.prepareForBody(unprocessed);
    }

    // We're done parsing the header, and we need to (maybe) setup the
    // BodyReader. `data` represents data that we have leftover after reading
    // the header which, presumably, belongs to the body.
    fn prepareForBody(self: *Reader, data: []u8) !Result {
        const response = &self.response;
        const content_length = blk: {
            const cl = response.get("content-length") orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, cl, 10) catch {
                return error.InvalidContentLength;
            };
        };

        if (content_length == 0) {
            if (data.len > 0) {
                // If the content-length is 0, then we should not extra data
                // If we did, this connection is in a weird state
                response.keepalive = false;
            }
            return .{
                .done = true,
                .data = null,
                .header = true,
            };
        }

        self.body_reader = .{ .content_length = .{ .len = content_length, .read = 0 } };

        // recursive, go we want to process whatever leftover data we have through
        // our newly setup body_reader
        return self.process(data);
    }

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
        content_length: ContentLength,

        fn process(self: *BodyReader, data: []u8) !struct { bool, Result } {
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
                    .header = true,
                } };
            }
        };
    };

    const Result = struct {
        done: bool,
        data: ?[]u8,
        header: bool,

        const NeedData = Result{ .done = true, .data = null };
    };

    const ProcessError = error{
        HeaderTooLarge,
        OutOfMemory,
        InvalidHeader,
        InvalidStatusLine,
        InvalidContentLength,
    };
};

pub const ResponseHeader = struct {
    status: u16 = 0,
    keepalive: bool = false,
    headers: HeaderList = .{},

    // Stored header has already been lower-cased, we expect name to be lowercased
    pub fn get(self: *const ResponseHeader, name: []const u8) ?[]const u8 {
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
    _socket: posix.socket_t,
    _tls_conn: ?TLSConnection,

    _done: bool,

    // Any data we over-read while parsing the header. This will be returned on
    // the first call to next();
    _data: ?[]u8 = null,
    header: ResponseHeader,

    pub fn next(self: *Response) !?[]u8 {
        if (self._data) |data| {
            self._data = null;
            return data;
        }

        if (self._done) {
            return null;
        }

        var buf = self._buf;
        var reader = &self._reader;
        std.debug.assert(reader.body_reader != null);

        while (true) {
            // Some content encoding might have data that doesn't result in a
            // chunk of information meaningful for the application.
            // So we loop

            var n: usize = 0;
            if (self._tls_conn) |*tls_conn| {
                n = try tls_conn.read(buf);
            } else {
                n = try posix.read(self._socket, buf);
            }

            if (n == 0) {
                self._done = true;
                return null;
            }
            const result = try reader.process(buf[0..n]);
            self._done = result.done;
            if (result.data) |d| {
                return d;
            }
            if (self._done) {
                return null;
            }
        }
    }
};

// Pooled and re-used when creating a request
const State = struct {
    // used for reading chunks of payload data.
    buf: []u8,

    // Used for keeping any unparsed header line until more data is received
    // At most, this represents 1 line in the header.
    header_buf: []u8,

    // Used extensively bu the TLS library. Used to optionally clone request
    // headers, and always used to clone response headers.
    arena: ArenaAllocator,

    fn init(allocator: Allocator, header_size: usize, buf_size: usize) !State {
        const buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf);

        const header_buf = try allocator.alloc(u8, header_size);
        errdefer allocator.free(header_buf);

        return .{
            .buf = buf,
            .header_buf = header_buf,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn reset(self: *State) void {
        _ = self.arena.reset(.{ .retain_with_limit = 1024 * 1024 });
    }

    fn deinit(self: *State) void {
        const allocator = self.arena.child_allocator;
        allocator.free(self.buf);
        allocator.free(self.header_buf);
        self.arena.deinit();
    }
};

pub const Error = error{
    Failed,
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

pub fn writeAllIOVec(socket: posix.socket_t, vec: []posix.iovec_const) !void {
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
    var client = try Client.init(testing.allocator, 1);
    defer client.deinit();

    try testing.expectError(error.UnsupportedUriScheme, client.request(.GET, "://localhost"));
    try testing.expectError(error.UnsupportedUriScheme, client.request(.GET, "ftp://localhost"));
    try testing.expectError(error.UriMissingHost, client.request(.GET, "http:///"));
}

test "HttpClient: sync connect error" {
    var client = try Client.init(testing.allocator, 2);
    defer client.deinit();

    var req = try client.request(.GET, "HTTP://localhost:9920");
    try testing.expectError(error.ConnectionRefused, req.sendSync(.{}));
}

test "HttpClient: sync no body" {
    var client = try Client.init(testing.allocator, 2);
    defer client.deinit();

    var req = try client.request(.GET, "http://locaLhost:9582/http_client/simple");
    var res = try req.sendSync(.{});

    try testing.expectEqual(null, try res.next());
    try testing.expectEqual(200, res.header.status);
    try testing.expectEqual(2, res.header.count());
    try testing.expectEqual("close", res.header.get("connection"));
    try testing.expectEqual("0", res.header.get("content-length"));
}

test "HttpClient: async connect error" {
    var loop = try jsruntime.Loop.init(testing.allocator);
    defer loop.deinit();

    const Handler = struct {
        reset: *Thread.ResetEvent,
        fn onHttpResponse(self: *@This(), res: Error!Progress) !void {
            _ = res catch |err| {
                if (err == error.Failed) {
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
    var client = try Client.init(testing.allocator, 2);
    defer client.deinit();

    var req = try client.request(.GET, "HTTP://localhost:9920");
    try req.sendAsync(&loop, Handler{ .reset = &reset }, .{});
    try loop.io.run_for_ns(std.time.ns_per_ms);
    try reset.timedWait(std.time.ns_per_s);
}

test "HttpClient: async no body" {
    var client = try Client.init(testing.allocator, 2);
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    var loop = try jsruntime.Loop.init(testing.allocator);
    defer loop.deinit();

    var req = try client.request(.GET, "HTTP://localhost:9582/http_client/simple");
    try req.sendAsync(&handler.loop, &handler, .{});
    try handler.loop.io.run_for_ns(std.time.ns_per_ms);
    try handler.reset.timedWait(std.time.ns_per_s);

    const res = handler.response;
    try testing.expectEqual("", res.body.items);
    try testing.expectEqual(200, res.status);
    try res.assertHeaders(&.{ "connection", "close", "content-length", "0" });
}

test "HttpClient: async with body" {
    var client = try Client.init(testing.allocator, 2);
    defer client.deinit();

    var handler = try CaptureHandler.init();
    defer handler.deinit();

    var req = try client.request(.GET, "HTTP://localhost:9582/http_client/body");
    try req.sendAsync(&handler.loop, &handler, .{});
    try handler.loop.io.run_for_ns(std.time.ns_per_ms);
    try handler.reset.timedWait(std.time.ns_per_s);

    const res = handler.response;
    try testing.expectEqual("over 9000!", res.body.items);
    try testing.expectEqual(201, res.status);
    try res.assertHeaders(&.{
        "connection",     "close",
        "content-length", "10",
        "_host",          "localhost",
        "_connection",    "Close",
    });
}

const TestResponse = struct {
    status: u16,
    keepalive: ?bool,
    arena: std.heap.ArenaAllocator,
    body: std.ArrayListUnmanaged(u8),
    headers: std.ArrayListUnmanaged(std.http.Header),

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

    fn onHttpResponse(self: *CaptureHandler, progress_: Error!Progress) !void {
        self.process(progress_) catch |err| {
            std.debug.print("error: {}\n", .{err});
        };
    }

    fn process(self: *CaptureHandler, progress_: Error!Progress) !void {
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
        const result = try r.process(unsent[0..to_send]);

        if (status == 0) {
            if (result.header) {
                status = r.response.status;
            }
        } else {
            // once set, it should not change
            try testing.expectEqual(status, r.response.status);
        }

        if (result.data) |d| {
            try testing.expectEqual(true, result.header);
            try res.body.appendSlice(res.arena.allocator(), d);
        }

        if (result.done) {
            res.status = status;
            res.headers = r.response.headers;
            res.keepalive = r.response.keepalive;
            return;
        }
        unsent = unsent[to_send..];
    }
    return error.NeverDone;
}

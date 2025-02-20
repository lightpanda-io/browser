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

const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const jsruntime = @import("jsruntime");
const Completion = jsruntime.IO.Completion;
const AcceptError = jsruntime.IO.AcceptError;
const RecvError = jsruntime.IO.RecvError;
const SendError = jsruntime.IO.SendError;
const CloseError = jsruntime.IO.CloseError;
const CancelError = jsruntime.IO.CancelOneError;
const TimeoutError = jsruntime.IO.TimeoutError;

const CDP = @import("cdp/cdp.zig").CDP;

const TimeoutCheck = std.time.ns_per_ms * 100;

const log = std.log.scoped(.server);

const MAX_HTTP_REQUEST_SIZE = 2048;

// max message size
// +14 for max websocket payload overhead
// +140 for the max control packet that might be interleaved in a message
const MAX_MESSAGE_SIZE = 256 * 1024 + 14;

pub const Client = ClientT(*Server, CDP);

const Server = struct {
    allocator: Allocator,
    loop: *jsruntime.Loop,

    // internal fields
    listener: posix.socket_t,
    client: ?*Client = null,
    timeout: u64,

    // a memory poor for our Send objects
    send_pool: std.heap.MemoryPool(Send),

    // a memory poor for our Clietns
    client_pool: std.heap.MemoryPool(Client),

    // I/O fields
    conn_completion: Completion,
    close_completion: Completion,
    accept_completion: Completion,
    timeout_completion: Completion,

    // The response to send on a GET /json/version request
    json_version_response: []const u8,

    fn deinit(self: *Server) void {
        self.send_pool.deinit();
        self.client_pool.deinit();
        self.allocator.free(self.json_version_response);
    }

    fn queueAccept(self: *Server) void {
        log.info("accepting new conn...", .{});
        self.loop.io.accept(
            *Server,
            self,
            callbackAccept,
            &self.accept_completion,
            self.listener,
        );
    }

    fn callbackAccept(
        self: *Server,
        completion: *Completion,
        result: AcceptError!posix.socket_t,
    ) void {
        std.debug.assert(self.client == null);
        std.debug.assert(completion == &self.accept_completion);

        const socket = result catch |err| {
            log.err("accept error: {any}", .{err});
            self.queueAccept();
            return;
        };

        const client = self.client_pool.create() catch |err| {
            log.err("failed to create client: {any}", .{err});
            posix.close(socket);
            return;
        };
        errdefer self.client_pool.destroy(client);

        client.* = Client.init(socket, self);

        self.client = client;

        log.info("client connected", .{});
        self.queueRead();
        self.queueTimeout();
    }

    fn queueTimeout(self: *Server) void {
        self.loop.io.timeout(
            *Server,
            self,
            callbackTimeout,
            &self.timeout_completion,
            TimeoutCheck,
        );
    }

    fn callbackTimeout(
        self: *Server,
        completion: *Completion,
        result: TimeoutError!void,
    ) void {
        std.debug.assert(completion == &self.timeout_completion);

        const client = self.client orelse return;

        if (result) |_| {
            if (now().since(client.last_active) > self.timeout) {
                // close current connection
                log.debug("conn timeout, closing...", .{});
                client.close(.timeout);
                return;
            }
        } else |err| {
            log.err("timeout error: {any}", .{err});
        }

        // We re-queue this if the timeout hasn't been exceeded or on some
        // very unlikely IO timeout error.
        // AKA: we don't requeue this if the connection timed out and we
        // closed the connection.s
        self.queueTimeout();
    }

    fn queueRead(self: *Server) void {
        if (self.client) |client| {
            self.loop.io.recv(
                *Server,
                self,
                callbackRead,
                &self.conn_completion,
                client.socket,
                client.readBuf(),
            );
        }
    }

    fn callbackRead(
        self: *Server,
        completion: *Completion,
        result: RecvError!usize,
    ) void {
        std.debug.assert(completion == &self.conn_completion);

        var client = self.client orelse return;

        const size = result catch |err| {
            log.err("read error: {any}", .{err});
            client.close(null);
            return;
        };
        if (size == 0) {
            if (self.client != null) {
                self.client = null;
            }
            self.queueAccept();
            return;
        }

        const more = client.processData(size) catch |err| {
            log.err("Client Processing Error: {any}\n", .{err});
            return;
        };

        // if more == false, the client is disconnecting
        if (more) {
            self.queueRead();
        }
    }

    fn queueSend(
        self: *Server,
        socket: posix.socket_t,
        arena: ?ArenaAllocator,
        data: []const u8,
    ) !void {
        const sd = try self.send_pool.create();
        errdefer self.send_pool.destroy(sd);

        sd.* = .{
            .unsent = data,
            .server = self,
            .socket = socket,
            .completion = undefined,
            .arena = arena,
        };
        sd.queueSend();
    }

    fn queueClose(self: *Server, socket: posix.socket_t) void {
        self.loop.io.close(
            *Server,
            self,
            callbackClose,
            &self.close_completion,
            socket,
        );
        var client = self.client.?;
        client.deinit();
        self.client_pool.destroy(client);
        self.client = null;
    }

    fn callbackClose(self: *Server, completion: *Completion, _: CloseError!void) void {
        std.debug.assert(completion == &self.close_completion);
        self.queueAccept();
    }
};

// I/O Send
// --------

// NOTE: to allow concurrent send we create each time a dedicated context
// (with its own completion), allocated on the heap.
// After the send (on the sendCbk) the dedicated context will be destroy
// and the data slice will be free.
const Send = struct { // Any unsent data we have.
    unsent: []const u8,

    server: *Server,
    completion: Completion,
    socket: posix.socket_t,

    // If we need to free anything when we're done
    arena: ?ArenaAllocator,

    fn deinit(self: *Send) void {
        var server = self.server;
        if (self.arena) |arena| {
            arena.deinit();
        }
        server.send_pool.destroy(self);
    }

    fn queueSend(self: *Send) void {
        self.server.loop.io.send(
            *Send,
            self,
            sendCallback,
            &self.completion,
            self.socket,
            self.unsent,
        );
    }

    fn sendCallback(self: *Send, _: *Completion, result: SendError!usize) void {
        const sent = result catch |err| {
            log.info("send error: {any}", .{err});
            if (self.server.client) |client| {
                client.close(null);
            }
            self.deinit();
            return;
        };

        if (sent == self.unsent.len) {
            self.deinit();
            return;
        }

        // partial send, re-queue a send for whatever we have left
        self.unsent = self.unsent[sent..];
        self.queueSend();
    }
};

// Client
// --------

// This is a generic only so that it can be unit tested. Normally, S == Server
// and when we send a message, we'll use server.send(...) to send via the server's
// IO loop. During tests, we can inject a simple mock to record (and then verify)
// the send message
fn ClientT(comptime S: type, comptime C: type) type {
    const EMPTY_PONG = [_]u8{ 138, 0 };

    // CLOSE, 2 length, code
    const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 }; // code: 1000
    const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 }; // 1009
    const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 }; //code: 1002
    // "private-use" close codes must be from 4000-49999
    const CLOSE_TIMEOUT = [_]u8{ 136, 2, 15, 160 }; // code: 4000

    return struct {
        // The client is initially serving HTTP requests but, under normal circumstances
        // should eventually be upgraded to a websocket connections
        mode: Mode,

        // The CDP instance that processes messages from this client
        // (a generic so we can test with a mock
        // null until mode == .websocket
        cdp: ?C,

        // Our Server (a generic so we can test with a mock)
        server: S,
        reader: Reader,
        socket: posix.socket_t,
        last_active: std.time.Instant,

        const Mode = enum {
            http,
            websocket,
        };

        const Self = @This();

        fn init(socket: posix.socket_t, server: S) Self {
            return .{
                .cdp = null,
                .mode = .http,
                .socket = socket,
                .server = server,
                .last_active = now(),
                .reader = .{ .allocator = server.allocator },
            };
        }

        pub fn deinit(self: *Self) void {
            self.reader.deinit();
            if (self.cdp) |*cdp| {
                cdp.deinit();
            }
        }

        pub fn close(self: *Self, close_code: ?CloseCode) void {
            if (close_code) |code| {
                if (self.mode == .websocket) {
                    switch (code) {
                        .timeout => self.send(&CLOSE_TIMEOUT) catch {},
                    }
                }
            }
            self.server.queueClose(self.socket);
        }

        fn readBuf(self: *Self) []u8 {
            return self.reader.readBuf();
        }

        fn processData(self: *Self, len: usize) !bool {
            self.last_active = now();
            self.reader.len += len;

            switch (self.mode) {
                .http => {
                    try self.processHTTPRequest();
                    return true;
                },
                .websocket => return self.processWebsocketMessage(),
            }
        }

        fn processHTTPRequest(self: *Self) !void {
            std.debug.assert(self.reader.pos == 0);
            const request = self.reader.buf[0..self.reader.len];

            errdefer self.server.queueClose(self.socket);

            if (request.len > MAX_HTTP_REQUEST_SIZE) {
                self.writeHTTPErrorResponse(413, "Request too large");
                return error.RequestTooLarge;
            }

            // we're only expecting [body-less] GET requests.
            if (std.mem.endsWith(u8, request, "\r\n\r\n") == false) {
                // we need more data, put any more data here
                return;
            }

            self.handleHTTPRequest(request) catch |err| {
                switch (err) {
                    error.NotFound => self.writeHTTPErrorResponse(404, "Not found"),
                    error.InvalidRequest => self.writeHTTPErrorResponse(400, "Invalid request"),
                    error.InvalidProtocol => self.writeHTTPErrorResponse(400, "Invalid HTTP protocol"),
                    error.MissingHeaders => self.writeHTTPErrorResponse(400, "Missing required header"),
                    error.InvalidUpgradeHeader => self.writeHTTPErrorResponse(400, "Unsupported upgrade type"),
                    error.InvalidVersionHeader => self.writeHTTPErrorResponse(400, "Invalid websocket version"),
                    error.InvalidConnectionHeader => self.writeHTTPErrorResponse(400, "Invalid connection header"),
                    else => {
                        log.err("error processing HTTP request: {any}", .{err});
                        self.writeHTTPErrorResponse(500, "Internal Server Error");
                    },
                }
                return err;
            };

            // the next incoming data can go to the front of our buffer
            self.reader.len = 0;
        }

        fn handleHTTPRequest(self: *Self, request: []u8) !void {
            if (request.len < 18) {
                // 18 is [generously] the smallest acceptable HTTP request
                return error.InvalidRequest;
            }

            if (std.mem.eql(u8, request[0..4], "GET ") == false) {
                return error.NotFound;
            }

            const url_end = std.mem.indexOfScalarPos(u8, request, 4, ' ') orelse {
                return error.InvalidRequest;
            };

            const url = request[4..url_end];

            if (std.mem.eql(u8, url, "/")) {
                return self.upgradeConnection(request);
            }

            if (std.mem.eql(u8, url, "/json/version")) {
                return self.send(self.server.json_version_response);
            }

            return error.NotFound;
        }

        fn upgradeConnection(self: *Self, request: []u8) !void {
            // our caller already confirmed that we have a trailing \r\n\r\n
            const request_line_end = std.mem.indexOfScalar(u8, request, '\r') orelse unreachable;
            const request_line = request[0..request_line_end];

            if (!std.ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
                return error.InvalidProtocol;
            }

            // we need to extract the sec-websocket-key value
            var key: []const u8 = "";

            // we need to make sure that we got all the necessary headers + values
            var required_headers: u8 = 0;

            // can't std.mem.split because it forces the iterated value to be const
            // (we could @constCast...)

            var buf = request[request_line_end + 2 ..];

            while (buf.len > 4) {
                const index = std.mem.indexOfScalar(u8, buf, '\r') orelse unreachable;
                const separator = std.mem.indexOfScalar(u8, buf[0..index], ':') orelse return error.InvalidRequest;

                const name = std.mem.trim(u8, toLower(buf[0..separator]), &std.ascii.whitespace);
                const value = std.mem.trim(u8, buf[(separator + 1)..index], &std.ascii.whitespace);

                if (std.mem.eql(u8, name, "upgrade")) {
                    if (!std.ascii.eqlIgnoreCase("websocket", value)) {
                        return error.InvalidUpgradeHeader;
                    }
                    required_headers |= 1;
                } else if (std.mem.eql(u8, name, "sec-websocket-version")) {
                    if (value.len != 2 or value[0] != '1' or value[1] != '3') {
                        return error.InvalidVersionHeader;
                    }
                    required_headers |= 2;
                } else if (std.mem.eql(u8, name, "connection")) {
                    // find if connection header has upgrade in it, example header:
                    // Connection: keep-alive, Upgrade
                    if (std.ascii.indexOfIgnoreCase(value, "upgrade") == null) {
                        return error.InvalidConnectionHeader;
                    }
                    required_headers |= 4;
                } else if (std.mem.eql(u8, name, "sec-websocket-key")) {
                    key = value;
                    required_headers |= 8;
                }

                const next = index + 2;
                buf = buf[next..];
            }

            if (required_headers != 15) {
                return error.MissingHeaders;
            }

            // our caller has already made sure this request ended in \r\n\r\n
            // so it isn't something we need to check again

            var arena = ArenaAllocator.init(self.server.allocator);
            errdefer arena.deinit();

            const response = blk: {
                // Response to an ugprade request is always this, with
                // the Sec-Websocket-Accept value a spacial sha1 hash of the
                // request "sec-websocket-version" and a magic value.

                const template =
                    "HTTP/1.1 101 Switching Protocols\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: upgrade\r\n" ++
                    "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n";

                // The response will be sent via the IO Loop and thus has to have its
                // own lifetime.
                const res = try arena.allocator().dupe(u8, template);

                // magic response
                const key_pos = res.len - 32;
                var h: [20]u8 = undefined;
                var hasher = std.crypto.hash.Sha1.init(.{});
                hasher.update(key);
                // websocket spec always used this value
                hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                hasher.final(&h);

                _ = std.base64.standard.Encoder.encode(res[key_pos .. key_pos + 28], h[0..]);

                break :blk res;
            };

            self.mode = .websocket;
            self.cdp = C.init(self.server.allocator, self, self.server.loop);
            return self.sendAlloc(arena, response);
        }

        fn writeHTTPErrorResponse(self: *Self, comptime status: u16, comptime body: []const u8) void {
            const response = std.fmt.comptimePrint(
                "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ status, body.len, body },
            );

            // we're going to close this connection anyways, swallowing any
            // error seems safe
            self.send(response) catch {};
        }

        fn processWebsocketMessage(self: *Self) !bool {
            errdefer self.server.queueClose(self.socket);

            var reader = &self.reader;

            while (true) {
                const msg = reader.next() catch |err| {
                    switch (err) {
                        error.TooLarge => self.send(&CLOSE_TOO_BIG) catch {},
                        error.NotMasked => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.ReservedFlags => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.InvalidMessageType => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.ControlTooLarge => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.InvalidContinuation => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.NestedFragementation => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                        error.OutOfMemory => {}, // don't borther trying to send an error in this case
                    }
                    return err;
                } orelse break;

                switch (msg.type) {
                    .pong => {},
                    .ping => try self.sendPong(msg.data),
                    .close => {
                        self.send(&CLOSE_NORMAL) catch {};
                        self.server.queueClose(self.socket);
                        return false;
                    },
                    .text, .binary => if (self.cdp.?.processMessage(msg.data) == false) {
                        self.close(null);
                        return false;
                    },
                }
                if (msg.cleanup_fragment) {
                    reader.cleanup();
                }
            }

            // We might have read part of the next message. Our reader potentially
            // has to move data around in its buffer to make space.
            reader.compact();
            return true;
        }

        fn sendPong(self: *Self, data: []const u8) !void {
            if (data.len == 0) {
                return self.send(&EMPTY_PONG);
            }
            var header_buf: [10]u8 = undefined;
            const header = websocketHeader(&header_buf, .pong, data.len);

            var arena = ArenaAllocator.init(self.server.allocator);
            errdefer arena.deinit();

            var framed = try arena.allocator().alloc(u8, header.len + data.len);
            @memcpy(framed[0..header.len], header);
            @memcpy(framed[header.len..], data);
            return self.sendAlloc(arena, framed);
        }

        // called by CDP
        // Websocket frames have a variable lenght header. For server-client,
        // it could be anywhere from 2 to 10 bytes. Our IO.Loop doesn't have
        // writev, so we need to get creative. We'll JSON serialize to a
        // buffer, where the first 10 bytes are reserved. We can then backfill
        // the header and send the slice.
        pub fn sendJSON(self: *Self, message: anytype, opts: std.json.StringifyOptions) !void {
            var arena = ArenaAllocator.init(self.server.allocator);
            errdefer arena.deinit();

            const allocator = arena.allocator();

            var buf: std.ArrayListUnmanaged(u8) = .{};
            try buf.ensureTotalCapacity(allocator, 512);

            // reserve space for the maximum possible header
            buf.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

            try std.json.stringify(message, opts, buf.writer(allocator));
            const framed = fillWebsocketHeader(buf);
            return self.sendAlloc(arena, framed);
        }

        pub fn sendJSONRaw(
            self: *Self,
            arena: ArenaAllocator,
            buf: std.ArrayListUnmanaged(u8),
        ) !void {
            // Dangerous API!. We assume the caller has reserved the first 10
            // bytes in `buf`.
            const framed = fillWebsocketHeader(buf);
            return self.sendAlloc(arena, framed);
        }

        fn send(self: *Self, data: []const u8) !void {
            return self.server.queueSend(self.socket, null, data);
        }

        fn sendAlloc(self: *Self, arena: ArenaAllocator, data: []const u8) !void {
            return self.server.queueSend(self.socket, arena, data);
        }
    };
}

// WebSocket message reader. Given websocket message, acts as an iterator that
// can return zero or more Messages. When next returns null, any incomplete
// message will remain in reader.data
const Reader = struct {
    allocator: Allocator,

    // position in buf of the start of the next message
    pos: usize = 0,

    // position in buf up until where we have valid data
    // (any new reads must be placed after this)
    len: usize = 0,

    // we add 140 to allow 1 control message (ping/pong/close) to be
    // fragmented into a normal message.
    buf: [MAX_MESSAGE_SIZE + 140]u8 = undefined,

    fragments: ?Fragments = null,

    fn deinit(self: *Reader) void {
        self.cleanup();
    }

    fn cleanup(self: *Reader) void {
        if (self.fragments) |*f| {
            f.message.deinit(self.allocator);
            self.fragments = null;
        }
    }

    fn readBuf(self: *Reader) []u8 {
        // We might have read a partial http or websocket message.
        // Subsequent reads must read from where we left off.
        return self.buf[self.len..];
    }

    fn next(self: *Reader) !?Message {
        LOOP: while (true) {
            var buf = self.buf[self.pos..self.len];

            const length_of_len, const message_len = extractLengths(buf) orelse {
                // we don't have enough bytes
                return null;
            };

            const byte1 = buf[0];

            if (byte1 & 112 != 0) {
                return error.ReservedFlags;
            }

            if (buf[1] & 128 != 128) {
                // client -> server messages _must_ be masked
                return error.NotMasked;
            }

            var is_control = false;
            var is_continuation = false;
            var message_type: Message.Type = undefined;
            switch (byte1 & 15) {
                0 => is_continuation = true,
                1 => message_type = .text,
                2 => message_type = .binary,
                8 => {
                    is_control = true;
                    message_type = .close;
                },
                9 => {
                    is_control = true;
                    message_type = .ping;
                },
                10 => {
                    is_control = true;
                    message_type = .pong;
                },
                else => return error.InvalidMessageType,
            }

            if (is_control) {
                if (message_len > 125) {
                    return error.ControlTooLarge;
                }
            } else if (message_len > MAX_MESSAGE_SIZE) {
                return error.TooLarge;
            }

            if (buf.len < message_len) {
                return null;
            }

            // prefix + length_of_len + mask
            const header_len = 2 + length_of_len + 4;

            const payload = buf[header_len..message_len];
            mask(buf[header_len - 4 .. header_len], payload);

            // whatever happens after this, we know where the next message starts
            self.pos += message_len;

            const fin = byte1 & 128 == 128;

            if (is_continuation) {
                const fragments = &(self.fragments orelse return error.InvalidContinuation);
                if (fragments.message.items.len + message_len > MAX_MESSAGE_SIZE) {
                    return error.TooLarge;
                }

                try fragments.message.appendSlice(self.allocator, payload);

                if (fin == false) {
                    // maybe we have more parts of the message waiting
                    continue :LOOP;
                }

                // this continuation is done!
                return .{
                    .type = fragments.type,
                    .data = fragments.message.items,
                    .cleanup_fragment = true,
                };
            }

            const can_be_fragmented = message_type == .text or message_type == .binary;
            if (self.fragments != null and can_be_fragmented) {
                // if this isn't a continuation, then we can't have fragements
                return error.NestedFragementation;
            }

            if (fin == false) {
                if (can_be_fragmented == false) {
                    return error.InvalidContinuation;
                }

                // not continuation, and not fin. It has to be the first message
                // in a fragemented message.
                var fragments = Fragments{ .message = .{}, .type = message_type };
                try fragments.message.appendSlice(self.allocator, payload);
                self.fragments = fragments;
                continue :LOOP;
            }

            return .{
                .data = payload,
                .type = message_type,
                .cleanup_fragment = false,
            };
        }
    }

    fn extractLengths(buf: []const u8) ?struct { usize, usize } {
        if (buf.len < 2) {
            return null;
        }

        const length_of_len: usize = switch (buf[1] & 127) {
            126 => 2,
            127 => 8,
            else => 0,
        };

        if (buf.len < length_of_len + 2) {
            // we definitely don't have enough buf yet
            return null;
        }

        const message_len = switch (length_of_len) {
            2 => @as(u16, @intCast(buf[3])) | @as(u16, @intCast(buf[2])) << 8,
            8 => @as(u64, @intCast(buf[9])) | @as(u64, @intCast(buf[8])) << 8 | @as(u64, @intCast(buf[7])) << 16 | @as(u64, @intCast(buf[6])) << 24 | @as(u64, @intCast(buf[5])) << 32 | @as(u64, @intCast(buf[4])) << 40 | @as(u64, @intCast(buf[3])) << 48 | @as(u64, @intCast(buf[2])) << 56,
            else => buf[1] & 127,
        } + length_of_len + 2 + 4; // +2 for header prefix, +4 for mask;

        return .{ length_of_len, message_len };
    }

    // This is called after we've processed complete websocket messages (this
    // only applies to websocket messages).
    // There are three cases:
    // 1 - We don't have any incomplete data (for a subsequent message) in buf.
    //     This is the easier to handle, we can set pos & len to 0.
    // 2 - We have part of the next message, but we know it'll fit in the
    //     remaining buf. We don't need to do anything
    // 3 - We have part of the next message, but either it won't fight into the
    //     remaining buffer, or we don't know (because we don't have enough
    //     of the header to tell the length). We need to "compact" the buffer
    fn compact(self: *Reader) void {
        const pos = self.pos;
        const len = self.len;

        std.debug.assert(pos <= len);

        // how many (if any) partial bytes do we have
        const partial_bytes = len - pos;

        if (partial_bytes == 0) {
            // We have no partial bytes. Setting these to 0 ensures that we
            // get the best utilization of our buffer
            self.pos = 0;
            self.len = 0;
            return;
        }

        const partial = self.buf[pos..len];

        // If we have enough bytes of the next message to tell its length
        // we'll be able to figure out whether we need to do anything or not.
        if (extractLengths(partial)) |length_meta| {
            const next_message_len = length_meta.@"1";
            // if this isn't true, then we have a full message and it
            // should have been processed.
            std.debug.assert(next_message_len > partial_bytes);

            const missing_bytes = next_message_len - partial_bytes;

            const free_space = self.buf.len - len;
            if (missing_bytes < free_space) {
                // we have enough space in our buffer, as is,
                return;
            }
        }

        // We're here because we either don't have enough bytes of the next
        // message, or we know that it won't fit in our buffer as-is.
        std.mem.copyForwards(u8, &self.buf, partial);
        self.pos = 0;
        self.len = partial_bytes;
    }
};

const Fragments = struct {
    type: Message.Type,
    message: std.ArrayListUnmanaged(u8),
};

const Message = struct {
    type: Type,
    data: []const u8,
    cleanup_fragment: bool,

    const Type = enum {
        text,
        binary,
        close,
        ping,
        pong,
    };
};

// These are the only websocket types that we're currently sending
const OpCode = enum(u8) {
    text = 128 | 1,
    close = 128 | 8,
    pong = 128 | 10,
};

const CloseCode = enum {
    timeout,
};

fn fillWebsocketHeader(buf: std.ArrayListUnmanaged(u8)) []const u8 {
    // can't use buf[0..10] here, because the header length
    // is variable. If it's just 2 bytes, for example, we need the
    // framed message to be:
    //     h1, h2, data
    // If we use buf[0..10], we'd get:
    //    h1, h2, 0, 0, 0, 0, 0, 0, 0, 0, data

    var header_buf: [10]u8 = undefined;

    // -10 because we reserved 10 bytes for the header above
    const header = websocketHeader(&header_buf, .text, buf.items.len - 10);
    const start = 10 - header.len;

    const message = buf.items;
    @memcpy(message[start..10], header);
    return message[start..];
}

// makes the assumption that our caller reserved the first
// 10 bytes for the header
fn websocketHeader(buf: []u8, op_code: OpCode, payload_len: usize) []const u8 {
    std.debug.assert(buf.len == 10);

    const len = payload_len;
    buf[0] = 128 | @intFromEnum(op_code); // fin | opcode

    if (len <= 125) {
        buf[1] = @intCast(len);
        return buf[0..2];
    }

    if (len < 65536) {
        buf[1] = 126;
        buf[2] = @intCast((len >> 8) & 0xFF);
        buf[3] = @intCast(len & 0xFF);
        return buf[0..4];
    }

    buf[1] = 127;
    buf[2] = 0;
    buf[3] = 0;
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = @intCast((len >> 24) & 0xFF);
    buf[7] = @intCast((len >> 16) & 0xFF);
    buf[8] = @intCast((len >> 8) & 0xFF);
    buf[9] = @intCast(len & 0xFF);
    return buf[0..10];
}

pub fn run(
    allocator: Allocator,
    address: net.Address,
    timeout: u64,
    loop: *jsruntime.Loop,
) !void {
    // create socket
    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    // TODO: Broken on darwin
    // https://github.com/ziglang/zig/issues/17260  (fixed in Zig 0.14)
    // if (@hasDecl(os.TCP, "NODELAY")) {
    //  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    // }
    try posix.setsockopt(listener, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

    // bind & listen
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1);

    // create v8 vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    const json_version_response = try buildJSONVersionResponse(allocator, address);

    var server = Server{
        .loop = loop,
        .timeout = timeout,
        .listener = listener,
        .allocator = allocator,
        .conn_completion = undefined,
        .close_completion = undefined,
        .accept_completion = undefined,
        .timeout_completion = undefined,
        .json_version_response = json_version_response,
        .send_pool = std.heap.MemoryPool(Send).init(allocator),
        .client_pool = std.heap.MemoryPool(Client).init(allocator),
    };
    defer server.deinit();

    // accept an connection
    server.queueAccept();

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.run_for_ns(10 * std.time.ns_per_ms);
        if (loop.cbk_error) {
            log.err("JS error", .{});
        }
    }
}

// Utils
// --------

fn buildJSONVersionResponse(
    allocator: Allocator,
    address: net.Address,
) ![]const u8 {
    const body_format = "{{\"webSocketDebuggerUrl\": \"ws://{}/\"}}";
    const body_len = std.fmt.count(body_format, .{address});

    const response_format =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        body_format;
    return try std.fmt.allocPrint(allocator, response_format, .{ body_len, address });
}

fn now() std.time.Instant {
    // can only fail on platforms we don't support
    return std.time.Instant.now() catch unreachable;
}

// In-place string lowercase
fn toLower(str: []u8) []u8 {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
    return str;
}

// Zig is in a weird backend transition right now. Need to determine if
// SIMD is even available.
const backend_supports_vectors = switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

// Websocket messages from client->server are masked using a 4 byte XOR mask
fn mask(m: []const u8, payload: []u8) void {
    var data = payload;

    if (!comptime backend_supports_vectors) return simpleMask(m, data);

    const vector_size = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
    if (data.len >= vector_size) {
        const mask_vector = std.simd.repeat(vector_size, @as(@Vector(4, u8), m[0..4].*));
        while (data.len >= vector_size) {
            const slice = data[0..vector_size];
            const masked_data_slice: @Vector(vector_size, u8) = slice.*;
            slice.* = masked_data_slice ^ mask_vector;
            data = data[vector_size..];
        }
    }
    simpleMask(m, data);
}

// Used when SIMD isn't available, or for any remaining part of the message
// which is too small to effectively use SIMD.
fn simpleMask(m: []const u8, payload: []u8) void {
    for (payload, 0..) |b, i| {
        payload[i] = b ^ m[i & 3];
    }
}

const testing = std.testing;
test "server: buildJSONVersionResponse" {
    const address = try net.Address.parseIp4("127.0.0.1", 9001);
    const res = try buildJSONVersionResponse(testing.allocator, address);
    defer testing.allocator.free(res);

    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 48\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9001/\"}", res);
}

test "Client: http invalid request" {
    try assertHTTPError(
        error.RequestTooLarge,
        413,
        "Request too large",
        "GET /over/9000 HTTP/1.1\r\n" ++ "Header: " ++ ("a" ** 2050) ++ "\r\n\r\n",
    );
}

test "Client: http invalid handshake" {
    try assertHTTPError(
        error.InvalidRequest,
        400,
        "Invalid request",
        "\r\n\r\n",
    );

    try assertHTTPError(
        error.NotFound,
        404,
        "Not found",
        "GET /over/9000 HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        error.NotFound,
        404,
        "Not found",
        "POST / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        error.InvalidProtocol,
        400,
        "Invalid HTTP protocol",
        "GET / HTTP/1.0\r\n\r\n",
    );

    try assertHTTPError(
        error.MissingHeaders,
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        error.MissingHeaders,
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n",
    );

    try assertHTTPError(
        error.MissingHeaders,
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n",
    );

    try assertHTTPError(
        error.MissingHeaders,
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n",
    );
}

test "Client: http valid handshake" {
    var ms = MockServer{};
    defer ms.deinit();

    var client = ClientT(*MockServer, MockCDP).init(0, &ms);
    defer client.deinit();

    const request =
        "GET /   HTTP/1.1\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "sec-websocket-version:13\r\n" ++
        "sec-websocket-key: this is my key\r\n" ++
        "Custom:  Header-Value\r\n\r\n";

    @memcpy(client.reader.buf[0..request.len], request);
    try testing.expectEqual(true, try client.processData(request.len));

    try testing.expectEqual(.websocket, client.mode);
    try testing.expectEqualStrings(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: upgrade\r\n" ++
            "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n",
        ms.sent.items[0],
    );
}

test "Client: http get json version" {
    var ms = MockServer{};
    defer ms.deinit();

    var client = ClientT(*MockServer, MockCDP).init(0, &ms);
    defer client.deinit();

    const request = "GET /json/version HTTP/1.1\r\n\r\n";

    @memcpy(client.reader.buf[0..request.len], request);
    try testing.expectEqual(true, try client.processData(request.len));

    try testing.expectEqual(.http, client.mode);

    // this is the hardcoded string in our MockServer
    try testing.expectEqualStrings("the json version response", ms.sent.items[0]);
}

test "Client: write websocket message" {
    const cases = [_]struct { expected: []const u8, message: []const u8 }{
        .{ .expected = &.{ 129, 2, '"', '"' }, .message = "" },
        .{ .expected = [_]u8{ 129, 14 } ++ "\"hello world!\"", .message = "hello world!" },
        .{ .expected = [_]u8{ 129, 126, 0, 132 } ++ "\"" ++ ("A" ** 130) ++ "\"", .message = "A" ** 130 },
    };

    for (cases) |c| {
        var ms = MockServer{};
        defer ms.deinit();

        var client = ClientT(*MockServer, MockCDP).init(0, &ms);
        defer client.deinit();

        try client.sendJSON(c.message, .{});
        try testing.expectEqual(1, ms.sent.items.len);
        try testing.expectEqualSlices(u8, c.expected, ms.sent.items[0]);
    }
}

test "Client: read invalid websocket message" {
    // 131 = 128 (fin) | 3  where 3 isn't a valid type
    try assertWebSocketError(
        error.InvalidMessageType,
        1002,
        "",
        &.{ 131, 128, 'm', 'a', 's', 'k' },
    );

    for ([_]u8{ 16, 32, 64 }) |rsv| {
        // none of the reserve flags should be set
        try assertWebSocketError(
            error.ReservedFlags,
            1002,
            "",
            &.{ rsv, 128, 'm', 'a', 's', 'k' },
        );

        // as a bitmask
        try assertWebSocketError(
            error.ReservedFlags,
            1002,
            "",
            &.{ rsv + 4, 128, 'm', 'a', 's', 'k' },
        );
    }

    // client->server messages must be masked
    try assertWebSocketError(
        error.NotMasked,
        1002,
        "",
        &.{ 129, 1, 'a' },
    );

    // control types (ping/ping/close) can't be > 125 bytes
    for ([_]u8{ 136, 137, 138 }) |op| {
        try assertWebSocketError(
            error.ControlTooLarge,
            1002,
            "",
            &.{ op, 254, 1, 1 },
        );
    }

    // length of message is 0000 0401, i.e: 1024 * 256 + 1
    try assertWebSocketError(
        error.TooLarge,
        1009,
        "",
        &.{ 129, 255, 0, 0, 0, 0, 0, 4, 0, 1, 'm', 'a', 's', 'k' },
    );

    // continuation type message must come after a normal message
    // even when not a fin frame
    try assertWebSocketError(
        error.InvalidContinuation,
        1002,
        "",
        &.{ 0, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // continuation type message must come after a normal message
    // even as a fin frame
    try assertWebSocketError(
        error.InvalidContinuation,
        1002,
        "",
        &.{ 128, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // text (non-fin) - text (non-fin)
    try assertWebSocketError(
        error.NestedFragementation,
        1002,
        "",
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 1, 128, 'k', 's', 'a', 'm' },
    );

    // text (non-fin) - text (fin) should always been continuation after non-fin
    try assertWebSocketError(
        error.NestedFragementation,
        1002,
        "",
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 129, 128, 'k', 's', 'a', 'm' },
    );

    // close must be fin
    try assertWebSocketError(
        error.InvalidContinuation,
        1002,
        "",
        &.{
            8, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // ping must be fin
    try assertWebSocketError(
        error.InvalidContinuation,
        1002,
        "",
        &.{
            9, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // pong must be fin
    try assertWebSocketError(
        error.InvalidContinuation,
        1002,
        "",
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

// Testing both HTTP and websocket messages broken up across multiple reads.
// We need to fuzz HTTP messages differently than websocket. HTTP are strictly
// req -> res with no pipelining. So there should only be 1 message at a time.
// So we can only "fuzz" on a per-message basis.
// But for websocket, we can fuzz _all_ the messages together.
test "Client: fuzz" {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    const allocator = testing.allocator;
    var websocket_messages: std.ArrayListUnmanaged(u8) = .{};
    defer websocket_messages.deinit(allocator);

    // ping with no payload
    try websocket_messages.appendSlice(
        allocator,
        &.{ 137, 128, 0, 0, 0, 0 },
    );

    // // 10 byte text message with a 0,0,0,0 mask
    try websocket_messages.appendSlice(
        allocator,
        &.{ 129, 138, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    );

    // ping with a payload
    try websocket_messages.appendSlice(
        allocator,
        &.{ 137, 133, 0, 5, 7, 10, 100, 101, 102, 103, 104 },
    );

    // pong with no payload (noop in the server)
    try websocket_messages.appendSlice(
        allocator,
        &.{ 138, 128, 10, 10, 10, 10 },
    );

    // 687 long message, with a mask
    try websocket_messages.appendSlice(
        allocator,
        [_]u8{ 129, 254, 2, 175, 1, 2, 3, 4 } ++ "A" ** 687,
    );

    // non-fin text message
    try websocket_messages.appendSlice(allocator, &.{ 1, 130, 0, 0, 0, 0, 1, 2 });

    // continuation
    try websocket_messages.appendSlice(allocator, &.{ 0, 131, 0, 0, 0, 0, 3, 4, 5 });

    // pong happening in fragement
    try websocket_messages.appendSlice(allocator, &.{ 138, 128, 0, 0, 0, 0 });

    // more continuation
    try websocket_messages.appendSlice(allocator, &.{ 0, 130, 0, 0, 0, 0, 6, 7 });

    // fin
    try websocket_messages.appendSlice(allocator, &.{ 128, 133, 0, 0, 0, 0, 8, 9, 10, 11, 12 });

    // close
    try websocket_messages.appendSlice(
        allocator,
        &.{ 136, 130, 200, 103, 34, 22, 0, 1 },
    );

    const SendRandom = struct {
        fn send(c: anytype, r: std.Random, data: []const u8) !void {
            var buf = data;
            while (buf.len > 0) {
                const to_send = r.intRangeAtMost(usize, 1, buf.len);
                @memcpy(c.readBuf()[0..to_send], buf[0..to_send]);
                if (try c.processData(to_send) == false) {
                    return;
                }
                buf = buf[to_send..];
            }
        }
    };

    for (0..100) |_| {
        var ms = MockServer{};
        defer ms.deinit();

        var client = ClientT(*MockServer, MockCDP).init(0, &ms);
        defer client.deinit();

        try SendRandom.send(&client, random, "GET /json/version HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
        try SendRandom.send(&client, random, "GET /   HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "sec-websocket-version:13\r\n" ++
            "sec-websocket-key: 1234aa93\r\n" ++
            "Custom:  Header-Value\r\n\r\n");

        // fuzz over all websocket messages
        try SendRandom.send(&client, random, websocket_messages.items);

        try testing.expectEqual(5, ms.sent.items.len);

        try testing.expectEqualStrings(
            "the json version response",
            ms.sent.items[0],
        );

        try testing.expectEqualStrings(
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: upgrade\r\n" ++
                "Sec-Websocket-Accept: KnOKWrrjHS0nGFmtfmYFQoPIGKQ=\r\n\r\n",
            ms.sent.items[1],
        );

        try testing.expectEqualSlices(u8, &.{ 138, 0 }, ms.sent.items[2]);

        try testing.expectEqualSlices(
            u8,
            &.{ 138, 5, 100, 96, 97, 109, 104 },
            ms.sent.items[3],
        );

        try testing.expectEqualSlices(
            u8,
            &.{ 136, 2, 3, 232 },
            ms.sent.items[4],
        );

        const received = client.cdp.?.messages.items;
        try testing.expectEqual(3, received.len);
        try testing.expectEqualSlices(
            u8,
            &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
            received[0],
        );

        try testing.expectEqualSlices(
            u8,
            &([_]u8{ 64, 67, 66, 69 } ** 171 ++ [_]u8{ 64, 67, 66 }),
            received[1],
        );

        try testing.expectEqualSlices(
            u8,
            &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
            received[2],
        );

        try testing.expectEqual(true, ms.closed);
    }
}

test "server: mask" {
    var buf: [4000]u8 = undefined;
    const messages = [_][]const u8{ "1234", "1234" ** 99, "1234" ** 999 };
    for (messages) |message| {
        // we need the message to be mutable since mask operates in-place
        const payload = buf[0..message.len];
        @memcpy(payload, message);

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(false, std.mem.eql(u8, payload, message));

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(true, std.mem.eql(u8, payload, message));
    }
}

test "server: 404" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /unknown HTTP/1.1\r\n\r\n");
    try testing.expectEqualStrings("HTTP/1.1 404 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 9\r\n\r\n" ++
        "Not found", res);
}

test "server: get /json/version" {
    const expected_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 48\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9583/\"}";

    {
        // twice on the same connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res1);

        const res2 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res2);
    }

    {
        // again on a new connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res1);

        const res2 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res2);
    }
}

fn assertHTTPError(
    expected_error: anyerror,
    comptime expected_status: u16,
    comptime expected_body: []const u8,
    input: []const u8,
) !void {
    var ms = MockServer{};
    defer ms.deinit();

    var client = ClientT(*MockServer, MockCDP).init(0, &ms);
    defer client.deinit();

    @memcpy(client.reader.buf[0..input.len], input);
    try testing.expectError(expected_error, client.processData(input.len));

    const expected_response = std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ expected_status, expected_body.len, expected_body },
    );

    try testing.expectEqual(1, ms.sent.items.len);
    try testing.expectEqualStrings(expected_response, ms.sent.items[0]);
}

fn assertWebSocketError(
    expected_error: anyerror,
    close_code: u16,
    close_payload: []const u8,
    input: []const u8,
) !void {
    var ms = MockServer{};
    defer ms.deinit();

    var client = ClientT(*MockServer, MockCDP).init(0, &ms);
    defer client.deinit();

    client.mode = .websocket; // force websocket message processing

    @memcpy(client.reader.buf[0..input.len], input);
    try testing.expectError(expected_error, client.processData(input.len));

    try testing.expectEqual(1, ms.sent.items.len);

    const actual = ms.sent.items[0];

    // fin | close opcode
    try testing.expectEqual(136, actual[0]);

    // message length (code + payload)
    try testing.expectEqual(2 + close_payload.len, actual[1]);

    // close code
    try testing.expectEqual(close_code, std.mem.readInt(u16, actual[2..4], .big));

    // close payload (if any)
    try testing.expectEqualStrings(close_payload, actual[4..]);
}

fn assertWebSocketMessage(
    expected: []const u8,
    input: []const u8,
) !void {
    var ms = MockServer{};
    defer ms.deinit();

    var client = ClientT(*MockServer, MockCDP).init(0, &ms);
    defer client.deinit();
    client.mode = .websocket; // force websocket message processing

    @memcpy(client.reader.buf[0..input.len], input);
    const more = try client.processData(input.len);

    try testing.expectEqual(1, ms.sent.items.len);
    try testing.expectEqualSlices(u8, expected, ms.sent.items[0]);

    // if we sent a close message, then the serve should have been told
    // to close the connection
    if (expected[0] == 136) {
        try testing.expectEqual(true, ms.closed);
        try testing.expectEqual(false, more);
    } else {
        try testing.expectEqual(false, ms.closed);
        try testing.expectEqual(true, more);
    }
}

const MockServer = struct {
    loop: *jsruntime.Loop = undefined,
    closed: bool = false,

    // record the messages we sent to the client
    sent: std.ArrayListUnmanaged([]const u8) = .{},

    allocator: Allocator = testing.allocator,

    json_version_response: []const u8 = "the json version response",

    fn deinit(self: *MockServer) void {
        const allocator = self.allocator;

        for (self.sent.items) |msg| {
            allocator.free(msg);
        }
        self.sent.deinit(allocator);
    }

    fn queueClose(self: *MockServer, _: anytype) void {
        self.closed = true;
    }

    fn queueSend(
        self: *MockServer,
        socket: posix.socket_t,
        arena: ?ArenaAllocator,
        data: []const u8,
    ) !void {
        _ = socket;
        const owned = try self.allocator.dupe(u8, data);
        try self.sent.append(self.allocator, owned);
        if (arena) |a| {
            a.deinit();
        }
    }
};


const MockCDP = struct {
    messages: std.ArrayListUnmanaged([]const u8) = .{},

    allocator: Allocator = testing.allocator,

    fn init(_: Allocator, client: anytype, loop: *jsruntime.Loop) MockCDP {
        _ = loop;
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

    fn processMessage(self: *MockCDP, message: []const u8) bool {
        const owned = self.allocator.dupe(u8, message) catch unreachable;
        self.messages.append(self.allocator, owned) catch unreachable;
        return true;
    }
};

fn createTestClient() !TestClient {
    const address = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 9583);
    const stream = try std.net.tcpConnectToAddress(address);

    const timeout = std.mem.toBytes(posix.timeval{
        .tv_sec = 2,
        .tv_usec = 0,
    });
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    return .{ .stream = stream };
}

const TestClient = struct {
    stream: std.net.Stream,
    buf: [1024]u8 = undefined,

    fn deinit(self: *TestClient) void {
        self.stream.close();
    }

    fn httpRequest(self: *TestClient, req: []const u8) ![]const u8 {
        try self.stream.writeAll(req);

        var pos: usize = 0;
        var total_length: ?usize = null;
        while (true) {
            pos += try self.stream.read(self.buf[pos..]);
            const response = self.buf[0..pos];
            if (total_length == null) {
                const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse continue;
                const header = response[0 .. header_end + 4];

                const cl_header = "Content-Length: ";
                const start = (std.mem.indexOf(u8, header, cl_header) orelse {
                    return error.MissingContentLength;
                }) + cl_header.len;

                const end = std.mem.indexOfScalarPos(u8, header, start, '\r') orelse {
                    return error.InvalidContentLength;
                };
                const cl = std.fmt.parseInt(usize, header[start..end], 10) catch {
                    return error.InvalidContentLength;
                };

                total_length = cl + header.len;
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
};

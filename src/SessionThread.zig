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

const posix = std.posix;
const net = std.net;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = @import("log.zig");
const SharedState = @import("SharedState.zig");
const SessionManager = @import("SessionManager.zig");
const LimitedAllocator = @import("LimitedAllocator.zig");
const HttpClient = @import("http/Client.zig");
const CDP = @import("cdp/cdp.zig").CDP;
const BrowserSession = @import("browser/Session.zig");

const timestamp = @import("datetime.zig").timestamp;

const MAX_HTTP_REQUEST_SIZE = 4096;
const MAX_MESSAGE_SIZE = 512 * 1024 + 14 + 140;

/// Encapsulates a single CDP session running in its own thread.
/// Each SessionThread has:
/// - Its own client socket
/// - Its own HttpClient (with shared curl_share from SharedState)
/// - Its own V8 Isolate (via Browser/CDP)
/// - Its own memory-limited allocator
const SessionThread = @This();

thread: ?std.Thread,
shutdown: std.atomic.Value(bool),
client_socket: posix.socket_t,
shared: *SharedState,
session_manager: *SessionManager,
limited_allocator: LimitedAllocator,
http_client: ?*HttpClient,
timeout_ms: u32,
json_version_response: []const u8,

pub fn spawn(
    shared: *SharedState,
    session_manager: *SessionManager,
    socket: posix.socket_t,
    timeout_ms: u32,
    json_version_response: []const u8,
    session_memory_limit: usize,
) !*SessionThread {
    const self = try shared.allocator.create(SessionThread);
    errdefer shared.allocator.destroy(self);

    self.* = .{
        .thread = null,
        .shutdown = std.atomic.Value(bool).init(false),
        .client_socket = socket,
        .shared = shared,
        .session_manager = session_manager,
        .limited_allocator = LimitedAllocator.init(shared.allocator, session_memory_limit),
        .http_client = null,
        .timeout_ms = timeout_ms,
        .json_version_response = json_version_response,
    };

    // Start the thread
    self.thread = try std.Thread.spawn(.{}, run, .{self});

    return self;
}

pub fn stop(self: *SessionThread) void {
    self.shutdown.store(true, .release);

    // Close the socket to interrupt any blocking reads
    if (self.client_socket != -1) {
        switch (builtin.target.os.tag) {
            .linux => posix.shutdown(self.client_socket, .recv) catch {},
            .macos, .freebsd, .netbsd, .openbsd => posix.close(self.client_socket),
            else => {},
        }
    }
}

pub fn join(self: *SessionThread) void {
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn deinit(self: *SessionThread) void {
    self.join();

    if (self.http_client) |client| {
        client.deinit();
        self.http_client = null;
    }

    self.shared.allocator.destroy(self);
}

fn sessionAllocator(self: *SessionThread) Allocator {
    return self.limited_allocator.allocator();
}

fn run(self: *SessionThread) void {
    defer {
        // Remove ourselves from the session manager when we're done
        self.session_manager.remove(self);
    }

    self.runInner() catch |err| {
        log.err(.app, "session thread error", .{ .err = err });
    };
}

fn runInner(self: *SessionThread) !void {
    const alloc = self.sessionAllocator();

    // Create our own HTTP client using the shared curl_share
    self.http_client = try self.shared.createHttpClient(alloc);
    errdefer {
        if (self.http_client) |client| {
            client.deinit();
            self.http_client = null;
        }
    }

    const client = try alloc.create(Client);
    defer alloc.destroy(client);

    client.* = try Client.init(self.client_socket, self);
    defer client.deinit();

    var http = self.http_client.?;
    http.cdp_client = .{
        .socket = self.client_socket,
        .ctx = client,
        .blocking_read_start = Client.blockingReadStart,
        .blocking_read = Client.blockingRead,
        .blocking_read_end = Client.blockingReadStop,
    };
    defer http.cdp_client = null;

    lp.assert(client.mode == .http, "SessionThread.run invalid mode", .{});

    const timeout_ms = self.timeout_ms;

    while (!self.shutdown.load(.acquire)) {
        const tick_result = http.tick(timeout_ms) catch .normal;
        if (tick_result != .cdp_socket) {
            log.info(.app, "CDP timeout", .{});
            return;
        }

        if (client.readSocket() == false) {
            return;
        }

        if (client.mode == .cdp) {
            break; // switch to CDP loop
        }
    }

    var cdp = &client.mode.cdp;
    var last_message = timestamp(.monotonic);
    var ms_remaining = timeout_ms;

    while (!self.shutdown.load(.acquire)) {
        switch (cdp.pageWait(ms_remaining)) {
            .cdp_socket => {
                if (client.readSocket() == false) {
                    return;
                }
                last_message = timestamp(.monotonic);
                ms_remaining = timeout_ms;
            },
            .no_page => {
                const tick_res = http.tick(ms_remaining) catch .normal;
                if (tick_res != .cdp_socket) {
                    log.info(.app, "CDP timeout", .{});
                    return;
                }
                if (client.readSocket() == false) {
                    return;
                }
                last_message = timestamp(.monotonic);
                ms_remaining = timeout_ms;
            },
            .done => {
                const elapsed = timestamp(.monotonic) - last_message;
                if (elapsed > ms_remaining) {
                    log.info(.app, "CDP timeout", .{});
                    return;
                }
                ms_remaining -= @intCast(elapsed);
            },
            .navigate => unreachable,
        }
    }
}


/// The CDP/WebSocket client - adapted from Server.zig
pub const Client = struct {
    mode: union(enum) {
        http: void,
        cdp: CDP,
    },

    session_thread: *SessionThread,
    reader: Reader(true),
    socket: posix.socket_t,
    socket_flags: usize,
    send_arena: ArenaAllocator,

    const EMPTY_PONG = [_]u8{ 138, 0 };
    const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 };
    const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 };
    const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 };
    const CLOSE_TIMEOUT = [_]u8{ 136, 2, 15, 160 };

    fn init(socket: posix.socket_t, session_thread: *SessionThread) !Client {
        const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        lp.assert(socket_flags & nonblocking == nonblocking, "Client.init blocking", .{});

        const alloc = session_thread.sessionAllocator();
        var reader = try Reader(true).init(alloc);
        errdefer reader.deinit();

        return .{
            .socket = socket,
            .session_thread = session_thread,
            .reader = reader,
            .mode = .{ .http = {} },
            .socket_flags = socket_flags,
            .send_arena = ArenaAllocator.init(alloc),
        };
    }

    fn deinit(self: *Client) void {
        switch (self.mode) {
            .cdp => |*cdp| cdp.deinit(),
            .http => {},
        }
        self.reader.deinit();
        self.send_arena.deinit();
    }

    fn blockingReadStart(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        _ = posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch |err| {
            log.warn(.app, "CDP blockingReadStart", .{ .err = err });
            return false;
        };
        return true;
    }

    fn blockingRead(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        return self.readSocket();
    }

    fn blockingReadStop(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        _ = posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
            log.warn(.app, "CDP blockingReadStop", .{ .err = err });
            return false;
        };
        return true;
    }

    fn readSocket(self: *Client) bool {
        const n = posix.read(self.socket, self.readBuf()) catch |err| {
            log.warn(.app, "CDP read", .{ .err = err });
            return false;
        };

        if (n == 0) {
            log.info(.app, "CDP disconnect", .{});
            return false;
        }

        return self.processData(n) catch false;
    }

    fn readBuf(self: *Client) []u8 {
        return self.reader.readBuf();
    }

    fn processData(self: *Client, len: usize) !bool {
        self.reader.len += len;

        switch (self.mode) {
            .cdp => |*cdp| return self.processWebsocketMessage(cdp),
            .http => return self.processHTTPRequest(),
        }
    }

    fn processHTTPRequest(self: *Client) !bool {
        lp.assert(self.reader.pos == 0, "Client.HTTP pos", .{ .pos = self.reader.pos });
        const request = self.reader.buf[0..self.reader.len];

        if (request.len > MAX_HTTP_REQUEST_SIZE) {
            self.writeHTTPErrorResponse(413, "Request too large");
            return error.RequestTooLarge;
        }

        if (std.mem.endsWith(u8, request, "\r\n\r\n") == false) {
            return true;
        }

        defer self.reader.len = 0;
        return self.handleHTTPRequest(request) catch |err| {
            switch (err) {
                error.NotFound => self.writeHTTPErrorResponse(404, "Not found"),
                error.InvalidRequest => self.writeHTTPErrorResponse(400, "Invalid request"),
                error.InvalidProtocol => self.writeHTTPErrorResponse(400, "Invalid HTTP protocol"),
                error.MissingHeaders => self.writeHTTPErrorResponse(400, "Missing required header"),
                error.InvalidUpgradeHeader => self.writeHTTPErrorResponse(400, "Unsupported upgrade type"),
                error.InvalidVersionHeader => self.writeHTTPErrorResponse(400, "Invalid websocket version"),
                error.InvalidConnectionHeader => self.writeHTTPErrorResponse(400, "Invalid connection header"),
                else => {
                    log.err(.app, "server 500", .{ .err = err, .req = request[0..@min(100, request.len)] });
                    self.writeHTTPErrorResponse(500, "Internal Server Error");
                },
            }
            return err;
        };
    }

    fn handleHTTPRequest(self: *Client, request: []u8) !bool {
        if (request.len < 18) {
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
            try self.upgradeConnection(request);
            return true;
        }

        if (std.mem.eql(u8, url, "/json/version")) {
            try self.send(self.session_thread.json_version_response);
            try posix.shutdown(self.socket, .recv);
            return false;
        }

        return error.NotFound;
    }

    fn upgradeConnection(self: *Client, request: []u8) !void {
        const request_line_end = std.mem.indexOfScalar(u8, request, '\r') orelse unreachable;
        const request_line = request[0..request_line_end];

        if (!std.ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
            return error.InvalidProtocol;
        }

        var key: []const u8 = "";
        var required_headers: u8 = 0;
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

        const alloc = self.send_arena.allocator();

        const response = blk: {
            const template =
                "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: upgrade\r\n" ++
                "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n";

            const res = try alloc.dupe(u8, template);

            const key_pos = res.len - 32;
            var h: [20]u8 = undefined;
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(key);
            hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
            hasher.final(&h);

            _ = std.base64.standard.Encoder.encode(res[key_pos .. key_pos + 28], h[0..]);

            break :blk res;
        };

        self.mode = .{ .cdp = try CDP.init(self.session_thread.shared, self.session_thread.http_client.?, self) };
        return self.send(response);
    }

    fn writeHTTPErrorResponse(self: *Client, comptime status: u16, comptime body: []const u8) void {
        const response = std.fmt.comptimePrint(
            "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ status, body.len, body },
        );
        self.send(response) catch {};
    }

    fn processWebsocketMessage(self: *Client, cdp: *CDP) !bool {
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
                    error.OutOfMemory => {},
                }
                return err;
            } orelse break;

            switch (msg.type) {
                .pong => {},
                .ping => try self.sendPong(msg.data),
                .close => {
                    self.send(&CLOSE_NORMAL) catch {};
                    return false;
                },
                .text, .binary => if (cdp.handleMessage(msg.data) == false) {
                    return false;
                },
            }
            if (msg.cleanup_fragment) {
                reader.cleanup();
            }
        }

        reader.compact();
        return true;
    }

    fn sendPong(self: *Client, data: []const u8) !void {
        if (data.len == 0) {
            return self.send(&EMPTY_PONG);
        }
        var header_buf: [10]u8 = undefined;
        const header = websocketHeader(&header_buf, .pong, data.len);

        const alloc = self.send_arena.allocator();
        var framed = try alloc.alloc(u8, header.len + data.len);
        @memcpy(framed[0..header.len], header);
        @memcpy(framed[header.len..], data);
        return self.send(framed);
    }

    pub fn sendJSON(self: *Client, message: anytype, opts: std.json.Stringify.Options) !void {
        const alloc = self.send_arena.allocator();

        var aw: std.Io.Writer.Allocating = .init(alloc);
        try aw.writer.writeAll(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        try std.json.Stringify.value(message, opts, &aw.writer);
        const written = aw.written();

        // Fill in websocket header
        var header_buf: [10]u8 = undefined;
        const payload_len = written.len - 10;
        const header = websocketHeader(&header_buf, .text, payload_len);
        const start = 10 - header.len;

        // Copy header into the reserved space
        const data = @constCast(written);
        @memcpy(data[start..10], header);
        return self.send(data[start..]);
    }

    pub fn sendJSONRaw(self: *Client, buf: std.ArrayListUnmanaged(u8)) !void {
        var header_buf: [10]u8 = undefined;
        const payload_len = buf.items.len - 10;
        const header = websocketHeader(&header_buf, .text, payload_len);
        const start = 10 - header.len;

        const message = buf.items;
        @memcpy(message[start..10], header);
        return self.send(message[start..]);
    }

    fn send(self: *Client, data: []const u8) !void {
        var pos: usize = 0;
        var changed_to_blocking: bool = false;
        defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

        defer if (changed_to_blocking) {
            _ = posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
                log.err(.app, "CDP restore nonblocking", .{ .err = err });
            };
        };

        LOOP: while (pos < data.len) {
            const written = posix.write(self.socket, data[pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    lp.assert(changed_to_blocking == false, "Client.double block", .{});
                    changed_to_blocking = true;
                    _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
                    continue :LOOP;
                },
                else => return err,
            };

            if (written == 0) {
                return error.Closed;
            }
            pos += written;
        }
    }
};

// WebSocket message reader
fn Reader(comptime EXPECT_MASK: bool) type {
    return struct {
        allocator: Allocator,
        pos: usize = 0,
        len: usize = 0,
        buf: []u8,
        fragments: ?Fragments = null,

        const Self = @This();

        fn init(alloc: Allocator) !Self {
            const buf = try alloc.alloc(u8, 16 * 1024);
            return .{
                .buf = buf,
                .allocator = alloc,
            };
        }

        fn deinit(self: *Self) void {
            self.cleanup();
            self.allocator.free(self.buf);
        }

        fn cleanup(self: *Self) void {
            if (self.fragments) |*f| {
                f.message.deinit(self.allocator);
                self.fragments = null;
            }
        }

        fn readBuf(self: *Self) []u8 {
            return self.buf[self.len..];
        }

        fn next(self: *Self) !?Message {
            LOOP: while (true) {
                var buf = self.buf[self.pos..self.len];

                const length_of_len, const message_len = extractLengths(buf) orelse {
                    return null;
                };

                const byte1 = buf[0];

                if (byte1 & 112 != 0) {
                    return error.ReservedFlags;
                }

                if (comptime EXPECT_MASK) {
                    if (buf[1] & 128 != 128) {
                        return error.NotMasked;
                    }
                } else if (buf[1] & 128 != 0) {
                    return error.Masked;
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
                } else if (message_len > self.buf.len) {
                    const len_now = self.buf.len;
                    self.buf = try growBuffer(self.allocator, self.buf, message_len);
                    buf = self.buf[0..len_now];
                    return null;
                } else if (buf.len < message_len) {
                    return null;
                }

                const header_len = 2 + length_of_len + if (comptime EXPECT_MASK) 4 else 0;
                const payload = buf[header_len..message_len];
                if (comptime EXPECT_MASK) {
                    mask(buf[header_len - 4 .. header_len], payload);
                }

                self.pos += message_len;
                const fin = byte1 & 128 == 128;

                if (is_continuation) {
                    const fragments = &(self.fragments orelse return error.InvalidContinuation);
                    if (fragments.message.items.len + message_len > MAX_MESSAGE_SIZE) {
                        return error.TooLarge;
                    }

                    try fragments.message.appendSlice(self.allocator, payload);

                    if (fin == false) {
                        continue :LOOP;
                    }

                    return .{
                        .type = fragments.type,
                        .data = fragments.message.items,
                        .cleanup_fragment = true,
                    };
                }

                const can_be_fragmented = message_type == .text or message_type == .binary;
                if (self.fragments != null and can_be_fragmented) {
                    return error.NestedFragementation;
                }

                if (fin == false) {
                    if (can_be_fragmented == false) {
                        return error.InvalidContinuation;
                    }

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
                return null;
            }

            const message_length = switch (length_of_len) {
                2 => @as(u16, @intCast(buf[3])) | @as(u16, @intCast(buf[2])) << 8,
                8 => @as(u64, @intCast(buf[9])) | @as(u64, @intCast(buf[8])) << 8 | @as(u64, @intCast(buf[7])) << 16 | @as(u64, @intCast(buf[6])) << 24 | @as(u64, @intCast(buf[5])) << 32 | @as(u64, @intCast(buf[4])) << 40 | @as(u64, @intCast(buf[3])) << 48 | @as(u64, @intCast(buf[2])) << 56,
                else => buf[1] & 127,
            } + length_of_len + 2 + if (comptime EXPECT_MASK) 4 else 0;

            return .{ length_of_len, message_length };
        }

        fn compact(self: *Self) void {
            const pos = self.pos;
            const len_now = self.len;

            lp.assert(pos <= len_now, "Client.Reader.compact precondition", .{ .pos = pos, .len = len_now });

            const partial_bytes = len_now - pos;

            if (partial_bytes == 0) {
                self.pos = 0;
                self.len = 0;
                return;
            }

            const partial = self.buf[pos..len_now];

            if (extractLengths(partial)) |length_meta| {
                const next_message_len = length_meta.@"1";
                lp.assert(pos <= len_now, "Client.Reader.compact postcondition", .{ .next_len = next_message_len, .partial = partial_bytes });

                const missing_bytes = next_message_len - partial_bytes;
                const free_space = self.buf.len - len_now;
                if (missing_bytes < free_space) {
                    return;
                }
            }

            std.mem.copyForwards(u8, self.buf, partial);
            self.pos = 0;
            self.len = partial_bytes;
        }
    };
}

fn growBuffer(alloc: Allocator, buf: []u8, required_capacity: usize) ![]u8 {
    var new_capacity = buf.len;
    while (true) {
        new_capacity +|= new_capacity / 2 + 8;
        if (new_capacity >= required_capacity) break;
    }

    log.debug(.app, "CDP buffer growth", .{ .from = buf.len, .to = new_capacity });

    if (alloc.resize(buf, new_capacity)) {
        return buf.ptr[0..new_capacity];
    }
    const new_buffer = try alloc.alloc(u8, new_capacity);
    @memcpy(new_buffer[0..buf.len], buf);
    alloc.free(buf);
    return new_buffer;
}

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

const OpCode = enum(u8) {
    text = 128 | 1,
    close = 128 | 8,
    pong = 128 | 10,
};

fn websocketHeader(buf: []u8, op_code: OpCode, payload_len: usize) []const u8 {
    lp.assert(buf.len == 10, "Websocket.Header", .{ .len = buf.len });

    const len = payload_len;
    buf[0] = 128 | @intFromEnum(op_code);

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

fn toLower(str: []u8) []u8 {
    for (str, 0..) |ch, i| {
        str[i] = std.ascii.toLower(ch);
    }
    return str;
}

const backend_supports_vectors = switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

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

fn simpleMask(m: []const u8, payload: []u8) void {
    for (payload, 0..) |b, i| {
        payload[i] = b ^ m[i & 3];
    }
}

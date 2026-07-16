// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const CDP = @import("CDP.zig");

const App = @import("../App.zig");
const Inbox = @import("../Inbox.zig");
const WS = @import("../network/WS.zig");
const ArenaPool = @import("../ArenaPool.zig");

const log = lp.log;
const posix = std.posix;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Connection = @This();

pub const State = enum { handshaking, live };

// reference to http_client.inbox
inbox: *Inbox,
arena_pool: *ArenaPool,
socket: posix.socket_t,
socket_flags: usize,
state: State = .handshaking,
reader: WS.Reader(true),
send_arena: ArenaAllocator,
metrics_enabled: bool,
max_http_message_size: usize,
json_version_response: []const u8,

pub fn init(
    self: *Connection,
    app: *App,
    socket: posix.socket_t,
    json_version_response: []const u8,
    inbox: *Inbox,
) !void {
    const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    if (builtin.is_test == false) {
        lp.assert(socket_flags & nonblocking == nonblocking, "Connection.init blocking", .{});
    }

    const config = app.config;
    const allocator = app.allocator;

    self.* = .{
        .inbox = inbox,
        .socket = socket,
        .arena_pool = &app.arena_pool,
        .socket_flags = socket_flags,
        .metrics_enabled = config.metricsEndpointEnabled(),
        .max_http_message_size = config.cdpMaxHTTPMessageSize(),
        .reader = try .init(allocator, config.cdpMaxMessageSize()),
        .send_arena = ArenaAllocator.init(allocator),
        .json_version_response = json_version_response,
    };
}

pub fn deinit(self: *Connection) void {
    self.reader.deinit();
    self.send_arena.deinit();
}

pub fn send(self: *Connection, data: []const u8) !void {
    var pos: usize = 0;
    var changed_to_blocking: bool = false;
    defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

    defer if (changed_to_blocking) {
        // We had to change our socket to blocking mode to get our write out
        // We need to change it back to non-blocking.
        _ = posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
            log.err(.app, "ws restore nonblocking", .{ .err = err });
        };
    };

    LOOP: while (pos < data.len) {
        const written = posix.write(self.socket, data[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                // self.socket is nonblocking, because we don't want to block
                // reads. But our life is a lot easier if we block writes,
                // largely, because we don't have to maintain a queue of pending
                // writes (which would each need their own allocations). So
                // if we get a WouldBlock error, we'll switch the socket to
                // blocking and switch it back to non-blocking after the write
                // is complete. Doesn't seem particularly efficiently, but
                // this should virtually never happen.
                lp.assert(changed_to_blocking == false, "Connection.double block", .{});
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

pub fn sendPong(self: *Connection, data: []const u8) !void {
    if (data.len == 0) {
        return self.send(&WS.EMPTY_PONG);
    }
    var header_buf: [10]u8 = undefined;
    const header = websocketHeader(&header_buf, .pong, data.len);

    const allocator = self.send_arena.allocator();
    const framed = try allocator.alloc(u8, header.len + data.len);
    @memcpy(framed[0..header.len], header);
    @memcpy(framed[header.len..], data);
    return self.send(framed);
}

// called by CDP
// Websocket frames have a variable length header. For server-client,
// it could be anywhere from 2 to 10 bytes. Our IO.Loop doesn't have
// writev, so we need to get creative. We'll JSON serialize to a
// buffer, where the first 10 bytes are reserved. We can then backfill
// the header and send the slice.
pub fn sendJSON(self: *Connection, message: anytype, opts: std.json.Stringify.Options) !void {
    const allocator = self.send_arena.allocator();

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);

    // reserve space for the maximum possible header
    try aw.writer.writeAll(&[_]u8{0} ** 10);
    try std.json.Stringify.value(message, opts, &aw.writer);
    const framed = fillWebsocketHeader(aw.toArrayList());
    return self.send(framed);
}

pub fn sendJSONRaw(
    self: *Connection,
    buf: std.ArrayList(u8),
) !void {
    // Dangerous API!. We assume the caller has reserved the first 10
    // bytes in `buf`.
    const framed = fillWebsocketHeader(buf);
    return self.send(framed);
}

pub const HttpResult = enum { more, upgraded, close };

pub fn handshake(self: *Connection) !bool {
    while (true) {
        var pfds = [_]posix.pollfd{.{
            .fd = self.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = try posix.poll(&pfds, 5000);
        if (n == 0) {
            log.info(.cdp, "CDP handshake timeout", .{});
            return false;
        }
        const read_bytes = self.read() catch |err| {
            log.warn(.cdp, "CDP read", .{ .err = err });
            return false;
        };
        if (read_bytes == 0) {
            log.info(.cdp, "CDP disconnect", .{});
            return false;
        }
        const result = self.processHttpRequest() catch return false;
        switch (result) {
            .more => continue,
            .upgraded => return true,
            .close => return false,
        }
    }
}

pub fn read(self: *Connection) !usize {
    const n = try posix.read(self.socket, self.reader.readBuf());
    self.reader.len += n;
    return n;
}

// Append as many bytes as fit into the reader's free space. Returns
// the number of bytes copied. Used post-handshake when the network
// thread owns socket reads.
//
// Why partial: a single network read can carry more bytes than the
// reader's current free space (e.g. one large pending frame plus the
// start of another). The caller is expected to loop:
//
//   while (remaining.len > 0) {
//       const n = conn.feedBytes(remaining);
//       remaining = remaining[n..];
//       _ = try conn.processMessages();  // extracts frames + compacts
//       // processMessages also grows the reader buffer if it sees a
//       // frame header bigger than the current capacity, so the next
//       // feedBytes call has somewhere to land.
//   }
pub fn feedBytes(self: *Connection, data: []const u8) usize {
    const dst = self.reader.readBuf();
    const n = @min(data.len, dst.len);
    @memcpy(dst[0..n], data[0..n]);
    self.reader.len += n;
    return n;
}

fn processHttpRequest(self: *Connection) !HttpResult {
    lp.assert(self.reader.pos == 0, "Connection.HTTP pos", .{ .pos = self.reader.pos });
    const request = self.reader.buf[0..self.reader.len];

    if (request.len > self.max_http_message_size) {
        log.warn(.cdp, "CDP message too big", .{ .type = "HTTP", .len = request.len, .hint = "See the --cdp-max-http-message-size <bytes>" });
        self.sendHttpError(413, "Request too large");
        return error.RequestTooLarge;
    }

    // we're only expecting [body-less] GET requests.
    if (std.mem.endsWith(u8, request, "\r\n\r\n") == false) {
        // we need more data, put any more data here
        return .more;
    }

    // the next incoming data can go to the front of our buffer
    defer self.reader.len = 0;
    return self.handleHttpRequest(request) catch |err| {
        switch (err) {
            error.NotFound => self.sendHttpError(404, "Not found"),
            error.InvalidRequest => self.sendHttpError(400, "Invalid request"),
            error.InvalidProtocol => self.sendHttpError(400, "Invalid HTTP protocol"),
            error.MissingHeaders => self.sendHttpError(400, "Missing required header"),
            error.InvalidUpgradeHeader => self.sendHttpError(400, "Unsupported upgrade type"),
            error.InvalidVersionHeader => self.sendHttpError(400, "Invalid websocket version"),
            error.InvalidConnectionHeader => self.sendHttpError(400, "Invalid connection header"),
            else => {
                log.err(.app, "server 500", .{ .err = err, .req = request[0..@min(100, request.len)] });
                self.sendHttpError(500, "Internal Server Error");
            },
        }
        return err;
    };
}

fn handleHttpRequest(self: *Connection, request: []u8) !HttpResult {
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
        try self.upgrade(request);
        return .upgraded;
    }

    if (std.mem.eql(u8, url, "/json/version") or std.mem.eql(u8, url, "/json/version/")) {
        try self.send(self.json_version_response);
        // Chromedp (a Go driver) does an http request to /json/version
        // then to / (websocket upgrade) using a different connection.
        // Since we only allow 1 connection at a time, the 2nd one (the
        // websocket upgrade) blocks until the first one times out.
        // We can avoid that by closing the connection. json_version_response
        // has a Connection: Close header too.
        self.shutdown();
        return .close;
    }

    if (std.mem.eql(u8, url, "/json/list") or std.mem.eql(u8, url, "/json/list/") or
        std.mem.eql(u8, url, "/json") or std.mem.eql(u8, url, "/json/"))
    {
        try self.send(empty_json_list_response);
        self.shutdown();
        return .close;
    }

    if (self.metrics_enabled and std.mem.eql(u8, url, "/metrics")) {
        try self.sendMetrics();
        self.shutdown();
        return .close;
    }

    return error.NotFound;
}

fn sendMetrics(self: *Connection) !void {
    const allocator = self.send_arena.allocator();

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    lp.metrics.write(&aw.writer);
    const body = aw.written();

    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n" ++
        "{s}", .{ body.len, body });
    try self.send(response);
}

const empty_json_list_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Length: 2\r\n" ++
    "Connection: Close\r\n" ++
    "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
    "[]";

// Framing-only iteration over received bytes. processMessages no
// longer auto-replies pong/close or sends close-on-error — the Network
// thread runs this loop and is read-only on the socket.
//
// Returns false if a close frame was seen (caller should drop the
// link) or the handler asked to stop; true if the loop exited because
// there were no more complete frames buffered.
pub fn processMessages(self: *Connection) !bool {
    var reader = &self.reader;
    while (true) {
        const msg = (try reader.next()) orelse break;

        const keep = switch (msg.type) {
            .pong => true,
            .ping, .text, .binary => try self.handleMessage(msg),
            .close => blk: {
                _ = try self.handleMessage(msg);
                break :blk false;
            },
        };

        if (msg.cleanup_fragment) {
            reader.cleanup();
        }

        if (!keep) {
            return false;
        }
    }

    // We might have read part of the next message. Our reader potentially
    // has to move data around in its buffer to make space.
    reader.compact();
    return true;
}

fn handleMessage(self: *Connection, msg: WS.Message) !bool {
    switch (msg.type) {
        .text, .binary => return self.pushCdp(msg.data),
        .ping => {
            const arena = try self.arena_pool.acquire(.tiny, "cdp ping");
            errdefer self.arena_pool.release(arena);
            self.inbox.push(arena, .{ .ping = try arena.dupe(u8, msg.data) });
            return true;
        },
        .close => {
            const arena = try self.arena_pool.acquire(.tiny, "cdp close");
            self.inbox.push(arena, .close);
            return true;
        },
        .pong => unreachable, // processMessages skips pong
    }
}

// Parse a CDP JSON frame on the Network thread and push it onto the
// inbox already-parsed. The consumer's allowlist check works on
// `input.method` directly (no substring matching against raw JSON),
// and the worker doesn't re-parse on dispatch. On parse failure we
// push `.disconnect(error.InvalidJSON)` so the worker tears down —
// treated the same way as a fatal WS framing error.
fn pushCdp(self: *Connection, bytes: []const u8) !bool {
    // TODO: is it worth trying to pad this for the cost overhead of parsing?
    const arena = try self.arena_pool.acquire(bytes.len, "cdp data");
    errdefer self.arena_pool.release(arena);

    const raw = try arena.dupe(u8, bytes);

    const input = std.json.parseFromSliceLeaky(
        CDP.InputMessage,
        arena,
        raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        self.inbox.push(arena, .{ .disconnect = error.InvalidJSON });
        return false;
    };

    self.inbox.push(arena, .{ .cdp = .{
        .raw = raw,
        .input = input,
    } });
    return true;
}

pub fn upgrade(self: *Connection, request: []u8) !void {
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

    const alloc = self.send_arena.allocator();

    const response = blk: {
        // Response to an upgrade request is always this, with
        // the Sec-Websocket-Accept value a spacial sha1 hash of the
        // request "sec-websocket-version" and a magic value.

        const template =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: upgrade\r\n" ++
            "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n";

        // The response will be sent via the IO Loop and thus has to have its
        // own lifetime.
        const res = try alloc.dupe(u8, template);

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

    return self.send(response);
}

pub fn sendHttpError(self: *Connection, comptime status: u16, comptime body: []const u8) void {
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ status, body.len, body },
    );

    // we're going to close this connection anyways, swallowing any
    // error seems safe
    self.send(response) catch {};
}

pub fn getAddress(self: *Connection) !std.net.Address {
    var address: std.net.Address = undefined;
    var socklen: posix.socklen_t = @sizeOf(std.net.Address);
    try posix.getpeername(self.socket, &address.any, &socklen);
    return address;
}

pub fn shutdown(self: *Connection) void {
    posix.shutdown(self.socket, .recv) catch {};
}

fn fillWebsocketHeader(buf: std.ArrayList(u8)) []const u8 {
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
fn websocketHeader(buf: []u8, op_code: WS.OpCode, payload_len: usize) []const u8 {
    lp.assert(buf.len == 10, "Websocket.Header", .{ .len = buf.len });

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

// In-place string lowercase
fn toLower(str: []u8) []u8 {
    for (str, 0..) |ch, i| {
        str[i] = std.ascii.toLower(ch);
    }
    return str;
}

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
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = @import("lightpanda").log;
const assert = @import("lightpanda").assert;
const CDP_MAX_MESSAGE_SIZE = @import("../Config.zig").CDP_MAX_MESSAGE_SIZE;

const Fragments = struct {
    type: Message.Type,
    message: std.ArrayList(u8),
};

pub const Message = struct {
    type: Type,
    data: []const u8,
    cleanup_fragment: bool,

    pub const Type = enum {
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

// WebSocket message reader. Given websocket message, acts as an iterator that
// can return zero or more Messages. When next returns null, any incomplete
// message will remain in reader.data
pub fn Reader(comptime EXPECT_MASK: bool) type {
    return struct {
        allocator: Allocator,

        // position in buf of the start of the next message
        pos: usize = 0,

        // position in buf up until where we have valid data
        // (any new reads must be placed after this)
        len: usize = 0,

        // we add 140 to allow 1 control message (ping/pong/close) to be
        // fragmented into a normal message.
        buf: []u8,

        fragments: ?Fragments = null,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            const buf = try allocator.alloc(u8, 16 * 1024);
            return .{
                .buf = buf,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cleanup();
            self.allocator.free(self.buf);
        }

        pub fn cleanup(self: *Self) void {
            if (self.fragments) |*f| {
                f.message.deinit(self.allocator);
                self.fragments = null;
            }
        }

        pub fn readBuf(self: *Self) []u8 {
            // We might have read a partial http or websocket message.
            // Subsequent reads must read from where we left off.
            return self.buf[self.len..];
        }

        pub fn next(self: *Self) !?Message {
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

                if (comptime EXPECT_MASK) {
                    if (buf[1] & 128 != 128) {
                        // client -> server messages _must_ be masked
                        return error.NotMasked;
                    }
                } else if (buf[1] & 128 != 0) {
                    // server -> client are never masked
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
                } else if (message_len > CDP_MAX_MESSAGE_SIZE) {
                    return error.TooLarge;
                } else if (message_len > self.buf.len) {
                    const len = self.buf.len;
                    self.buf = try growBuffer(self.allocator, self.buf, message_len);
                    buf = self.buf[0..len];
                    // we need more data
                    return null;
                } else if (buf.len < message_len) {
                    // we need more data
                    return null;
                }

                // prefix + length_of_len + mask
                const header_len = 2 + length_of_len + if (comptime EXPECT_MASK) 4 else 0;

                const payload = buf[header_len..message_len];
                if (comptime EXPECT_MASK) {
                    mask(buf[header_len - 4 .. header_len], payload);
                }

                // whatever happens after this, we know where the next message starts
                self.pos += message_len;

                const fin = byte1 & 128 == 128;

                if (is_continuation) {
                    const fragments = &(self.fragments orelse return error.InvalidContinuation);
                    if (fragments.message.items.len + message_len > CDP_MAX_MESSAGE_SIZE) {
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
                    // if this isn't a continuation, then we can't have fragments
                    return error.NestedFragementation;
                }

                if (fin == false) {
                    if (can_be_fragmented == false) {
                        return error.InvalidContinuation;
                    }

                    // not continuation, and not fin. It has to be the first message
                    // in a fragmented message.
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
            } + length_of_len + 2 + if (comptime EXPECT_MASK) 4 else 0; // +2 for header prefix, +4 for mask;

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
        fn compact(self: *Self) void {
            const pos = self.pos;
            const len = self.len;

            assert(pos <= len, "Client.Reader.compact precondition", .{ .pos = pos, .len = len });

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
                assert(pos <= len, "Client.Reader.compact postcondition", .{ .next_len = next_message_len, .partial = partial_bytes });

                const missing_bytes = next_message_len - partial_bytes;

                const free_space = self.buf.len - len;
                if (missing_bytes < free_space) {
                    // we have enough space in our buffer, as is,
                    return;
                }
            }

            // We're here because we either don't have enough bytes of the next
            // message, or we know that it won't fit in our buffer as-is.
            std.mem.copyForwards(u8, self.buf, partial);
            self.pos = 0;
            self.len = partial_bytes;
        }
    };
}

pub const WsConnection = struct {
    // CLOSE, 2 length, code
    const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 }; // code: 1000
    const CLOSE_GOING_AWAY = [_]u8{ 136, 2, 3, 233 }; // code: 1001
    const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 }; // 1009
    const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 }; //code: 1002
    // "private-use" close codes must be from 4000-49999
    const CLOSE_TIMEOUT = [_]u8{ 136, 2, 15, 160 }; // code: 4000

    socket: posix.socket_t,
    socket_flags: usize,
    reader: Reader(true),
    send_arena: ArenaAllocator,
    json_version_response: []const u8,
    timeout_ms: u32,

    pub fn init(socket: posix.socket_t, allocator: Allocator, json_version_response: []const u8, timeout_ms: u32) !WsConnection {
        const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        if (builtin.is_test == false) {
            assert(socket_flags & nonblocking == nonblocking, "WsConnection.init blocking", .{});
        }

        var reader = try Reader(true).init(allocator);
        errdefer reader.deinit();

        return .{
            .socket = socket,
            .socket_flags = socket_flags,
            .reader = reader,
            .send_arena = ArenaAllocator.init(allocator),
            .json_version_response = json_version_response,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *WsConnection) void {
        self.reader.deinit();
        self.send_arena.deinit();
    }

    pub fn send(self: *WsConnection, data: []const u8) !void {
        var pos: usize = 0;
        var changed_to_blocking: bool = false;
        defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

        defer if (changed_to_blocking) {
            // We had to change our socket to blocking me to get our write out
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
                    assert(changed_to_blocking == false, "WsConnection.double block", .{});
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

    const EMPTY_PONG = [_]u8{ 138, 0 };

    fn sendPong(self: *WsConnection, data: []const u8) !void {
        if (data.len == 0) {
            return self.send(&EMPTY_PONG);
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
    pub fn sendJSON(self: *WsConnection, message: anytype, opts: std.json.Stringify.Options) !void {
        const allocator = self.send_arena.allocator();

        var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);

        // reserve space for the maximum possible header
        try aw.writer.writeAll(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        try std.json.Stringify.value(message, opts, &aw.writer);
        const framed = fillWebsocketHeader(aw.toArrayList());
        return self.send(framed);
    }

    pub fn sendJSONRaw(
        self: *WsConnection,
        buf: std.ArrayList(u8),
    ) !void {
        // Dangerous API!. We assume the caller has reserved the first 10
        // bytes in `buf`.
        const framed = fillWebsocketHeader(buf);
        return self.send(framed);
    }

    pub fn read(self: *WsConnection) !usize {
        const n = try posix.read(self.socket, self.reader.readBuf());
        self.reader.len += n;
        return n;
    }

    pub fn processMessages(self: *WsConnection, handler: anytype) !bool {
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
                    return false;
                },
                .text, .binary => if (handler.handleMessage(msg.data) == false) {
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

    pub fn upgrade(self: *WsConnection, request: []u8) !void {
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

    pub fn sendHttpError(self: *WsConnection, comptime status: u16, comptime body: []const u8) void {
        const response = std.fmt.comptimePrint(
            "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ status, body.len, body },
        );

        // we're going to close this connection anyways, swallowing any
        // error seems safe
        self.send(response) catch {};
    }

    pub fn getAddress(self: *WsConnection) !std.net.Address {
        var address: std.net.Address = undefined;
        var socklen: posix.socklen_t = @sizeOf(std.net.Address);
        try posix.getpeername(self.socket, &address.any, &socklen);
        return address;
    }

    pub fn sendClose(self: *WsConnection) void {
        self.send(&CLOSE_GOING_AWAY) catch {};
    }

    pub fn shutdown(self: *WsConnection) void {
        posix.shutdown(self.socket, .recv) catch {};
    }

    pub fn setBlocking(self: *WsConnection, blocking: bool) !void {
        if (blocking) {
            _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        } else {
            _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags);
        }
    }
};

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
fn websocketHeader(buf: []u8, op_code: OpCode, payload_len: usize) []const u8 {
    assert(buf.len == 10, "Websocket.Header", .{ .len = buf.len });

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

fn growBuffer(allocator: Allocator, buf: []u8, required_capacity: usize) ![]u8 {
    // from std.ArrayList
    var new_capacity = buf.len;
    while (true) {
        new_capacity +|= new_capacity / 2 + 8;
        if (new_capacity >= required_capacity) break;
    }

    log.debug(.app, "CDP buffer growth", .{ .from = buf.len, .to = new_capacity });

    if (allocator.resize(buf, new_capacity)) {
        return buf.ptr[0..new_capacity];
    }
    const new_buffer = try allocator.alloc(u8, new_capacity);
    @memcpy(new_buffer[0..buf.len], buf);
    allocator.free(buf);
    return new_buffer;
}

// In-place string lowercase
fn toLower(str: []u8) []u8 {
    for (str, 0..) |ch, i| {
        str[i] = std.ascii.toLower(ch);
    }
    return str;
}

// Used when SIMD isn't available, or for any remaining part of the message
// which is too small to effectively use SIMD.
fn simpleMask(m: []const u8, payload: []u8) void {
    for (payload, 0..) |b, i| {
        payload[i] = b ^ m[i & 3];
    }
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

const testing = std.testing;

test "mask" {
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

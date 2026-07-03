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

const Allocator = std.mem.Allocator;

pub const EMPTY_PONG = [_]u8{ 138, 0 };

// CLOSE, 2 length, code
pub const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 }; // code: 1000
pub const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 }; // 1009
pub const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 }; //code: 1002

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
pub const OpCode = enum(u8) {
    text = 128 | 1,
    close = 128 | 8,
    pong = 128 | 10,
};

// We'll grow our buffer up to cdp-max-message-size (default 1MB), but should
// try to reclaim some of that space. A lot of drivers send large messages
// upfront (e.g. page.addScriptToEvaluateOnNewDocument) and then settle into
// smaller messages. So after RECLAIM_AFTER messages which would fit in
// RECLAIM_TO, we'll shrink the buffer.
const RECLAIM_TO = 256 * 1024;
const RECLAIM_AFTER = 8;

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

        max_message_size: usize,

        buf: []u8,

        fragments: ?Fragments = null,

        // consecutive messages we've received which fit i RECLAIM_TO
        small_message_streak: usize = 0,

        const Self = @This();

        pub fn init(allocator: Allocator, max_message_size: usize) !Self {
            const buf = try allocator.alloc(u8, 16 * 1024);
            return .{
                .buf = buf,
                .allocator = allocator,
                .max_message_size = max_message_size,
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

        pub fn next(self: *Self) NextError!?Message {
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
                } else if (message_len > self.max_message_size) {
                    lp.log.warn(.cdp, "CDP message too big", .{ .type = "WS", .len = message_len, .hint = "See the --cdp-max-message-size <bytes>" });
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

                self.pos += message_len;
                if (message_len < RECLAIM_TO) {
                    self.small_message_streak +|= 1;
                } else {
                    self.small_message_streak = 0;
                }

                const fin = byte1 & 128 == 128;

                if (is_continuation) {
                    const fragments = &(self.fragments orelse return error.InvalidContinuation);
                    const full_len = fragments.message.items.len + message_len;
                    if (full_len > self.max_message_size) {
                        lp.log.warn(.cdp, "CDP message too big", .{ .type = "WS", .len = full_len, .hint = "See the --cdp-max-message-size <bytes>" });
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
                    return error.NestedFragmentation;
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
        pub fn compact(self: *Self) void {
            const pos = self.pos;
            const len = self.len;

            lp.assert(pos <= len, "Client.Reader.compact precondition", .{ .pos = pos, .len = len });

            // how many (if any) partial bytes do we have
            const partial_bytes = len - pos;

            if (partial_bytes == 0) {
                // We have no partial bytes. Setting these to 0 ensures that we
                // get the best utilization of our buffer
                self.pos = 0;
                self.len = 0;
                self.maybeReclaim();
                return;
            }

            const partial = self.buf[pos..len];

            // If we have enough bytes of the next message to tell its length
            // we'll be able to figure out whether we need to do anything or not.
            if (extractLengths(partial)) |length_meta| {
                const next_message_len = length_meta.@"1";
                // if this isn't true, then we have a full message and it
                // should have been processed.
                lp.assert(pos <= len, "Client.Reader.compact postcondition", .{ .next_len = next_message_len, .partial = partial_bytes });

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

        fn maybeReclaim(self: *Self) void {
            const floor = @min(RECLAIM_TO, self.max_message_size);
            if (self.buf.len <= floor or self.small_message_streak < RECLAIM_AFTER) {
                return;
            }

            self.buf = self.allocator.remap(self.buf, floor) orelse blk: {
                const smaller = self.allocator.alloc(u8, floor) catch return;
                self.allocator.free(self.buf);
                break :blk smaller;
            };
            self.small_message_streak = 0;
        }
    };
}

// Map a reader error (or any error that flowed up out of one) to the
// matching server→client close frame. Takes anyerror so callers that
// hold the error in a wider type (e.g. ?anyerror across an inbox)
// don't need to narrow it first; unrecognized errors return null.
pub fn errorReply(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.TooLarge => &CLOSE_TOO_BIG,
        error.Masked,
        error.NotMasked,
        error.ReservedFlags,
        error.InvalidMessageType,
        error.ControlTooLarge,
        error.InvalidContinuation,
        error.NestedFragmentation,
        // Strictly an application-level (CDP) error, but 1002
        // "protocol error" is the closest fit and gives the peer a
        // cleaner signal than a bare TCP FIN.
        error.InvalidJSON,
        => &CLOSE_PROTOCOL_ERROR,
        else => null,
    };
}

const NextError = error{
    TooLarge,
    Masked,
    NotMasked,
    ReservedFlags,
    InvalidMessageType,
    ControlTooLarge,
    InvalidContinuation,
    NestedFragmentation,
    OutOfMemory,
};

fn growBuffer(allocator: Allocator, buf: []u8, required_capacity: usize) ![]u8 {
    // from std.ArrayList
    var new_capacity = buf.len;
    while (true) {
        new_capacity +|= new_capacity / 2 + 8;
        if (new_capacity >= required_capacity) break;
    }

    lp.log.debug(.app, "CDP buffer growth", .{ .from = buf.len, .to = new_capacity });

    if (allocator.resize(buf, new_capacity)) {
        return buf.ptr[0..new_capacity];
    }
    const new_buffer = try allocator.alloc(u8, new_capacity);
    @memcpy(new_buffer[0..buf.len], buf);
    allocator.free(buf);
    return new_buffer;
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

// Builds an unmasked (server->client) text frame.
fn writeFrame(list: *std.ArrayList(u8), allocator: Allocator, payload: []const u8) !void {
    try list.append(allocator, @intFromEnum(OpCode.text)); // FIN + text opcode
    if (payload.len <= 125) {
        try list.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 65535) {
        try list.append(allocator, 126);
        try list.append(allocator, @intCast((payload.len >> 8) & 0xff));
        try list.append(allocator, @intCast(payload.len & 0xff));
    } else {
        try list.append(allocator, 127);
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            try list.append(allocator, @intCast((payload.len >> @intCast(i * 8)) & 0xff));
        }
    }
    try list.appendSlice(allocator, payload);
}

// Drives one complete frame through the reader the way Connection does:
// feed bytes (growing when next() asks for room), drain complete messages,
// then compact.
fn feedAndDrain(reader: anytype, frame: []const u8) !void {
    var offset: usize = 0;
    while (true) {
        const free = reader.readBuf();
        if (free.len > 0 and offset < frame.len) {
            const n = @min(free.len, frame.len - offset);
            @memcpy(free[0..n], frame[offset..][0..n]);
            reader.len += n;
            offset += n;
        }
        if (try reader.next()) |_| {
            continue;
        }
        if (offset >= frame.len) {
            break;
        }
    }
    reader.compact();
}

test "reader: reclaims buffer after a run of small messages" {
    const allocator = testing.allocator;
    var reader = try Reader(false).init(allocator, 4 * 1024 * 1024);
    defer reader.deinit();

    // A large message forces the buffer to grow well past RECLAIM_TO.
    const big_payload = try allocator.alloc(u8, RECLAIM_TO + 100 * 1024);
    defer allocator.free(big_payload);
    @memset(big_payload, 'a');

    var big: std.ArrayList(u8) = .{};
    defer big.deinit(allocator);
    try writeFrame(&big, allocator, big_payload);

    try feedAndDrain(&reader, big.items);
    try testing.expect(reader.buf.len > RECLAIM_TO);
    try testing.expectEqual(@as(usize, 0), reader.small_message_streak);

    // A whole run of small messages delivered in a *single* batch must count
    // as individual messages, not as one compaction — reads don't align with
    // message boundaries over TCP. Stop one short of the threshold.
    var batch: std.ArrayList(u8) = .{};
    defer batch.deinit(allocator);
    for (0..RECLAIM_AFTER - 1) |_| {
        try writeFrame(&batch, allocator, "hello");
    }
    try feedAndDrain(&reader, batch.items);
    try testing.expectEqual(@as(usize, RECLAIM_AFTER - 1), reader.small_message_streak);
    try testing.expect(reader.buf.len > RECLAIM_TO);

    // One more small message tips the run over the threshold and shrinks.
    var small: std.ArrayList(u8) = .{};
    defer small.deinit(allocator);
    try writeFrame(&small, allocator, "hello");
    try feedAndDrain(&reader, small.items);
    try testing.expectEqual(@as(usize, RECLAIM_TO), reader.buf.len);

    // A later large message resets the run and re-grows the buffer.
    try feedAndDrain(&reader, big.items);
    try testing.expect(reader.buf.len > RECLAIM_TO);
    try testing.expectEqual(@as(usize, 0), reader.small_message_streak);
}

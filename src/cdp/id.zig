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
const IS_DEBUG = @import("builtin").mode == .Debug;

pub fn toPageId(comptime id_type: enum { frame_id, loader_id }, input: []const u8) !u32 {
    const err = switch (comptime id_type) {
        .frame_id => error.InvalidFrameId,
        .loader_id => error.InvalidLoaderId,
    };

    if (input.len < 4) {
        return err;
    }

    return std.fmt.parseInt(u32, input[4..], 10) catch err;
}

pub fn toFrameId(page_id: u32) [14]u8 {
    var buf: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "FID-{d:0>10}", .{page_id}) catch unreachable;
    return buf;
}

pub fn toLoaderId(page_id: u32) [14]u8 {
    var buf: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "LID-{d:0>10}", .{page_id}) catch unreachable;
    return buf;
}

pub fn toRequestId(page_id: u32) [14]u8 {
    var buf: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "RID-{d:0>10}", .{page_id}) catch unreachable;
    return buf;
}

pub fn toInterceptId(page_id: u32) [14]u8 {
    var buf: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "INT-{d:0>10}", .{page_id}) catch unreachable;
    return buf;
}

// Generates incrementing prefixed integers, i.e. CTX-1, CTX-2, CTX-3.
// Wraps to 0 on overflow.
// Many caveats for using this:
// - Not thread-safe.
// - Information leaking
// - The slice returned by next() is only valid:
//   - while incrementor is valid
//   - until the next call to next()
// On the positive, it's zero allocation
pub fn Incrementing(comptime T: type, comptime prefix: []const u8) type {
    // +1 for the '-' separator
    const NUMERIC_START = prefix.len + 1;
    const MAX_BYTES = NUMERIC_START + switch (T) {
        u8 => 3,
        u16 => 5,
        u32 => 10,
        u64 => 20,
        else => @compileError("Incrementing must be given an unsigned int type, got: " ++ @typeName(T)),
    };

    const buffer = blk: {
        var b = [_]u8{0} ** MAX_BYTES;
        @memcpy(b[0..prefix.len], prefix);
        b[prefix.len] = '-';
        break :blk b;
    };

    const PrefixIntType = @Type(.{ .int = .{
        .bits = NUMERIC_START * 8,
        .signedness = .unsigned,
    } });

    const PREFIX_INT_CODE: PrefixIntType = @bitCast(buffer[0..NUMERIC_START].*);

    return struct {
        counter: T = 0,
        buffer: [MAX_BYTES]u8 = buffer,

        const Self = @This();

        pub fn next(self: *Self) []const u8 {
            const counter = self.counter;
            const n = counter +% 1;
            defer self.counter = n;

            const size = std.fmt.printInt(self.buffer[NUMERIC_START..], n, 10, .lower, .{});
            return self.buffer[0 .. NUMERIC_START + size];
        }

        // extracts the numeric portion from an ID
        pub fn parse(str: []const u8) !T {
            if (str.len <= NUMERIC_START) {
                return error.InvalidId;
            }

            if (@as(PrefixIntType, @bitCast(str[0..NUMERIC_START].*)) != PREFIX_INT_CODE) {
                return error.InvalidId;
            }

            return std.fmt.parseInt(T, str[NUMERIC_START..], 10) catch {
                return error.InvalidId;
            };
        }
    };
}

const testing = @import("../testing.zig");
test "id: Incrementing.next" {
    var id = Incrementing(u16, "IDX"){};
    try testing.expectEqual("IDX-1", id.next());
    try testing.expectEqual("IDX-2", id.next());
    try testing.expectEqual("IDX-3", id.next());

    // force a wrap
    id.counter = 65533;
    try testing.expectEqual("IDX-65534", id.next());
    try testing.expectEqual("IDX-65535", id.next());
    try testing.expectEqual("IDX-0", id.next());
}

test "id: Incrementing.parse" {
    const ReqId = Incrementing(u32, "REQ");
    try testing.expectError(error.InvalidId, ReqId.parse(""));
    try testing.expectError(error.InvalidId, ReqId.parse("R"));
    try testing.expectError(error.InvalidId, ReqId.parse("RE"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ--1"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ--"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-Nope"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-4294967296"));

    try testing.expectEqual(0, try ReqId.parse("REQ-0"));
    try testing.expectEqual(99, try ReqId.parse("REQ-99"));
    try testing.expectEqual(4294967295, try ReqId.parse("REQ-4294967295"));
}

test "id: toPageId" {
    try testing.expectEqual(0, toPageId(.frame_id, "FID-0"));
    try testing.expectEqual(0, toPageId(.loader_id, "LID-0"));

    try testing.expectEqual(4294967295, toPageId(.frame_id, "FID-4294967295"));
    try testing.expectEqual(4294967295, toPageId(.loader_id, "LID-4294967295"));
    try testing.expectError(error.InvalidFrameId, toPageId(.frame_id, ""));
    try testing.expectError(error.InvalidLoaderId, toPageId(.loader_id, "LID-NOPE"));
}

test "id: toFrameId" {
    try testing.expectEqual("FID-0000000000", toFrameId(0));
    try testing.expectEqual("FID-4294967295", toFrameId(4294967295));
}

test "id: toLoaderId" {
    try testing.expectEqual("LID-0000000000", toLoaderId(0));
    try testing.expectEqual("LID-4294967295", toLoaderId(4294967295));
}

test "id: toRequestId" {
    try testing.expectEqual("RID-0000000000", toRequestId(0));
    try testing.expectEqual("RID-4294967295", toRequestId(4294967295));
}

test "id: toInterceptId" {
    try testing.expectEqual("INT-0000000000", toInterceptId(0));
    try testing.expectEqual("INT-4294967295", toInterceptId(4294967295));
}

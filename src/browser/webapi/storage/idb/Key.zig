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

const js = @import("../../../js/js.zig");

const Allocator = std.mem.Allocator;

const Key = @This();

// Type tags are the first encoded byte. The value is for correct sort order.
const Tag = enum(u8) {
    number = 10,
    // date = 20,
    string = 30,
    // binary = 40,
    // array = 50,
};

value: Value,

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
};

pub fn number(n: f64) Key {
    return .{ .value = .{ .number = n } };
}

pub fn string(s: []const u8) Key {
    return .{ .value = .{ .string = s } };
}

pub fn stringBuf(allocator: Allocator, payload_len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, 1 + payload_len);
    buf[0] = @intFromEnum(Tag.string);
    return buf;
}

pub fn encodeValue(value: js.Value, allocator: Allocator) ![]u8 {
    if (value.isString()) |s| {
        const buf = try stringBuf(allocator, s.len());
        _ = s.toSliceWithBuf(buf[1..]);
        return buf;
    }
    if (value.isNumber()) {
        return number(try value.toZig(f64)).encode(allocator);
    }
    return error.DataError;
}

// Encode into an order-preserving byte slice, allocated by `allocator`.
// Caller owns the returned memory.
fn encode(self: Key, allocator: Allocator) ![]u8 {
    switch (self.value) {
        .number => |n| {
            var buf = try allocator.alloc(u8, 1 + 8);
            buf[0] = @intFromEnum(Tag.number);
            writeOrderedF64(buf[1..9], n);
            return buf;
        },
        .string => |s| {
            const buf = try stringBuf(allocator, s.len);
            @memcpy(buf[1..], s);
            return buf;
        },
    }
}

// Map an f64 to 8 big-endian bytes whose unsigned ordering matches IEEE-754
// numeric ordering. For positive numbers flip only the sign bit; for negative
// numbers flip every bit. NaN is not a valid IDB key, so it is not handled.
fn writeOrderedF64(out: *[8]u8, n: f64) void {
    var bits: u64 = @bitCast(n);
    if (bits & (1 << 63) != 0) {
        bits = ~bits;
    } else {
        bits |= (1 << 63);
    }
    std.mem.writeInt(u64, out, bits, .big);
}

const testing = @import("../../../../testing.zig");

test "IDB - Key: number encoding round-trips ordering" {
    const cases = [_]f64{ -1e308, -100.5, -1, -0.0001, 0, 0.0001, 1, 100.5, 1e308 };
    var prev: ?[]u8 = null;
    defer if (prev) |p| testing.allocator.free(p);

    for (cases) |n| {
        const enc = try Key.number(n).encode(testing.allocator);
        if (prev) |p| {
            try testing.expect(std.mem.order(u8, p, enc) == .lt);
            testing.allocator.free(p);
        }
        prev = enc;
    }
}

test "IDB - Key: numbers sort before strings" {
    const num = try Key.number(1e308).encode(testing.allocator);
    defer testing.allocator.free(num);
    const str = try Key.string("").encode(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expect(std.mem.order(u8, num, str) == .lt);
}

test "IDB - Key: string encoding preserves byte order" {
    const a = try Key.string("apple").encode(testing.allocator);
    defer testing.allocator.free(a);
    const b = try Key.string("banana").encode(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expect(std.mem.order(u8, a, b) == .lt);
}

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
const uuidv4 = @import("../../id.zig").uuidv4;

// https://w3c.github.io/webcrypto/#crypto-interface
pub const Crypto = struct {
    pub fn _getRandomValues(_: *const Crypto, into: RandomValues) !RandomValues {
        const buf = into.asBuffer();
        if (buf.len > 65_536) {
            return error.QuotaExceededError;
        }
        std.crypto.random.bytes(buf);
        return into;
    }

    pub fn _randomUUID(_: *const Crypto) [36]u8 {
        var hex: [36]u8 = undefined;
        uuidv4(&hex);
        return hex;
    }
};

const RandomValues = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,

    fn asBuffer(self: RandomValues) []u8 {
        switch (self) {
            .int8 => |b| return (@as([]u8, @ptrCast(b)))[0..b.len],
            .uint8 => |b| return (@as([]u8, @ptrCast(b)))[0..b.len],
            .int16 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .uint16 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .int32 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .uint32 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .int64 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
            .uint64 => |b| return (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
        }
    }
};

const testing = @import("../../testing.zig");
test "Browser.Crypto" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "const a = crypto.randomUUID();", "undefined" },
        .{ "const b = crypto.randomUUID();", "undefined" },
        .{ "a.length;", "36" },
        .{ "b.length;", "36" },
        .{ "a == b;", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "try { crypto.getRandomValues(new BigUint64Array(8193)) } catch(e) { e.message == 'QuotaExceededError' }", "true" },
        .{ "let r1 = new Int32Array(5)", "undefined" },
        .{ "let r2 = crypto.getRandomValues(r1)", "undefined" },
        .{ "new Set(r1).size", "5" },
        .{ "new Set(r2).size", "5" },
        .{ "r1.every((v, i) => v === r2[i])", "true" },
    }, .{});
}

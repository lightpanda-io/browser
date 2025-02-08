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

// some utils to parser strings.
const std = @import("std");
const testing = std.testing;

pub const Reader = struct {
    s: []const u8,
    i: usize = 0,

    pub fn until(self: *Reader, c: u8) []const u8 {
        const ln = self.s.len;
        const start = self.i;
        while (self.i < ln) {
            if (c == self.s[self.i]) return self.s[start..self.i];
            self.i += 1;
        }

        return self.s[start..self.i];
    }

    pub fn tail(self: *Reader) []const u8 {
        if (self.i > self.s.len) return "";
        defer self.i = self.s.len;
        return self.s[self.i..];
    }

    pub fn skip(self: *Reader) bool {
        if (self.i >= self.s.len) return false;
        self.i += 1;
        return true;
    }
};

// converts a comptime-known string (i.e. null terminated) to an uint
pub fn asUint(comptime string: anytype) AsUintReturn(string) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++
            ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

fn AsUintReturn(comptime string: anytype) type {
    return @Type(.{
        .Int = .{
            .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
            .signedness = .unsigned,
        },
    });
}

test "Reader.skip" {
    var r = Reader{ .s = "foo" };
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(!r.skip());
    try testing.expect(!r.skip());
}

test "Reader.tail" {
    var r = Reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.tail());
    try testing.expectEqualStrings("", r.tail());
}

test "Reader.until" {
    var r = Reader{ .s = "foo.bar.baz" };
    try testing.expectEqualStrings("foo", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("bar", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("baz", r.until('.'));

    r = Reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.until('.'));

    r = Reader{ .s = "" };
    try testing.expectEqualStrings("", r.until('.'));
}

pub fn trim(s: []const u8) []const u8 {
    const ln = s.len;
    if (ln == 0) {
        return "";
    }
    var start: usize = 0;
    while (start < ln) {
        if (!std.ascii.isWhitespace(s[start])) break;
        start += 1;
    }

    var end: usize = ln;
    while (end > 0) {
        if (!std.ascii.isWhitespace(s[end - 1])) break;
        end -= 1;
    }

    return s[start..end];
}

test "trim" {
    try testing.expectEqualStrings("", trim(""));
    try testing.expectEqualStrings("foo", trim("foo"));
    try testing.expectEqualStrings("foo", trim(" \n\tfoo"));
    try testing.expectEqualStrings("foo", trim("foo \n\t"));
}

test "parser: asUint" {
    const ASCII_x = @as(u8, @bitCast([1]u8{'x'}));
    const ASCII_ab = @as(u16, @bitCast([2]u8{ 'a', 'b' }));
    const ASCII_xyz = @as(u24, @bitCast([3]u8{ 'x', 'y', 'z' }));
    const ASCII_abcd = @as(u32, @bitCast([4]u8{ 'a', 'b', 'c', 'd' }));

    try testing.expectEqual(ASCII_x, asUint("x"));
    try testing.expectEqual(ASCII_ab, asUint("ab"));
    try testing.expectEqual(ASCII_xyz, asUint("xyz"));
    try testing.expectEqual(ASCII_abcd, asUint("abcd"));

    try testing.expectEqual(u8, @TypeOf(asUint("x")));
    try testing.expectEqual(u16, @TypeOf(asUint("ab")));
    try testing.expectEqual(u24, @TypeOf(asUint("xyz")));
    try testing.expectEqual(u32, @TypeOf(asUint("abcd")));
}

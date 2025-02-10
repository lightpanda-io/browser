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

pub const Reader = struct {
    pos: usize = 0,
    data: []const u8,

    pub fn until(self: *Reader, c: u8) []const u8 {
        const pos = self.pos;
        const data = self.data;

        const index = std.mem.indexOfScalarPos(u8, data, pos, c) orelse data.len;
        self.pos = index;
        return data[pos..index];
    }

    pub fn tail(self: *Reader) []const u8 {
        const pos = self.pos;
        const data = self.data;
        if (pos > data.len) {
            return "";
        }
        self.pos = data.len;
        return data[pos..];
    }

    pub fn skip(self: *Reader) bool {
        const pos = self.pos;
        if (pos >= self.data.len) {
            return false;
        }
        self.pos = pos + 1;
        return true;
    }
};

const testing = std.testing;
test "parser.Reader: skip" {
    var r = Reader{ .data = "foo" };
    try testing.expectEqual(true, r.skip());
    try testing.expectEqual(true, r.skip());
    try testing.expectEqual(true, r.skip());
    try testing.expectEqual(false, r.skip());
    try testing.expectEqual(false, r.skip());
}

test "parser.Reader: tail" {
    var r = Reader{ .data = "foo" };
    try testing.expectEqualStrings("foo", r.tail());
    try testing.expectEqualStrings("", r.tail());
    try testing.expectEqualStrings("", r.tail());
}

test "parser.Reader: until" {
    var r = Reader{ .data = "foo.bar.baz" };
    try testing.expectEqualStrings("foo", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("bar", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("baz", r.until('.'));

    r = Reader{ .data = "foo" };
    try testing.expectEqualStrings("foo", r.until('.'));
    try testing.expectEqualStrings("", r.tail());

    r = Reader{ .data = "" };
    try testing.expectEqualStrings("", r.until('.'));
    try testing.expectEqualStrings("", r.tail());
}

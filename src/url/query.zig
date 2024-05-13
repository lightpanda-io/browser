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

const Reader = @import("../str/parser.zig").Reader;

// Values is a map with string key of string values.
pub const Values = struct {
    alloc: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(List),

    const List = std.ArrayListUnmanaged([]const u8);

    pub fn init(alloc: std.mem.Allocator) Values {
        return .{
            .alloc = alloc,
            .map = .{},
        };
    }

    pub fn deinit(self: *Values) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| self.alloc.free(v);
            entry.value_ptr.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.map.deinit(self.alloc);
    }

    // add the key value couple to the values.
    // the key and the value are duplicated.
    pub fn append(self: *Values, k: []const u8, v: []const u8) !void {
        const vv = try self.alloc.dupe(u8, v);

        if (self.map.getPtr(k)) |list| {
            return try list.append(self.alloc, vv);
        }

        const kk = try self.alloc.dupe(u8, k);
        var list = List{};
        try list.append(self.alloc, vv);
        try self.map.put(self.alloc, kk, list);
    }

    // append by taking the ownership of the key and the value
    fn appendOwned(self: *Values, k: []const u8, v: []const u8) !void {
        if (self.map.getPtr(k)) |list| {
            return try list.append(self.alloc, v);
        }

        var list = List{};
        try list.append(self.alloc, v);
        try self.map.put(self.alloc, k, list);
    }

    pub fn get(self: *Values, k: []const u8) [][]const u8 {
        if (self.map.get(k)) |list| {
            return list.items;
        }

        return &[_][]const u8{};
    }

    pub fn first(self: *Values, k: []const u8) []const u8 {
        if (self.map.getPtr(k)) |list| {
            if (list.items.len == 0) return "";
            return list.items[0];
        }

        return "";
    }

    pub fn delete(self: *Values, k: []const u8) void {
        if (self.map.getPtr(k)) |list| {
            list.deinit(self.alloc);
            _ = self.map.fetchSwapRemove(k);
        }
    }

    pub fn deleteValue(self: *Values, k: []const u8, v: []const u8) void {
        const list = self.map.getPtr(k) orelse return;

        for (list.items, 0..) |vv, i| {
            if (std.mem.eql(u8, v, vv)) {
                _ = list.swapRemove(i);
                return;
            }
        }
    }

    pub fn count(self: *Values) usize {
        return self.map.count();
    }

    // the caller owned the returned string.
    pub fn encode(self: *Values, writer: anytype) !void {
        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            defer i += 1;
            if (i > 0) try writer.writeByte('&');

            if (entry.value_ptr.items.len == 0) {
                try escape(writer, entry.key_ptr.*);
                continue;
            }

            const start = i;
            for (entry.value_ptr.items) |v| {
                defer i += 1;
                if (start < i) try writer.writeByte('&');

                try escape(writer, entry.key_ptr.*);
                if (v.len > 0) try writer.writeByte('=');
                try escape(writer, v);
            }
        }
    }
};

fn unhex(c: u8) u8 {
    if ('0' <= c and c <= '9') return c - '0';
    if ('a' <= c and c <= 'f') return c - 'a' + 10;
    if ('A' <= c and c <= 'F') return c - 'A' + 10;
    return 0;
}

// unescape decodes a percent encoded string.
// The caller owned the returned string.
pub fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);

    var i: usize = 0;
    while (i < s.len) {
        defer i += 1;

        switch (s[i]) {
            '%' => {
                if (i + 2 > s.len) return error.EscapeError;
                if (!std.ascii.isHex(s[i + 1])) return error.EscapeError;
                if (!std.ascii.isHex(s[i + 2])) return error.EscapeError;

                try buf.append(alloc, unhex(s[i + 1]) << 4 | unhex(s[i + 2]));
                i += 2;
            },
            '+' => try buf.append(alloc, ' '), // TODO should we decode or keep as it?
            else => try buf.append(alloc, s[i]),
        }
    }

    return try buf.toOwnedSlice(alloc);
}

test "unescape" {
    var v: []const u8 = undefined;
    const alloc = std.testing.allocator;

    v = try unescape(alloc, "%7E");
    try std.testing.expect(std.mem.eql(u8, "~", v));
    alloc.free(v);
}

pub fn escape(writer: anytype, raw: []const u8) !void {
    var start: usize = 0;
    for (raw, 0..) |char, index| {
        if ('a' <= char and char <= 'z' or 'A' <= char and char <= 'Z' or '0' <= char and char <= '9') {
            continue;
        }

        try writer.print("{s}%{X:0>2}", .{ raw[start..index], char });
        start = index + 1;
    }
    try writer.writeAll(raw[start..]);
}

// Parse the given query.
pub fn parseQuery(alloc: std.mem.Allocator, s: []const u8) !Values {
    var values = Values.init(alloc);
    errdefer values.deinit();

    const ln = s.len;
    if (ln == 0) return values;

    var r = Reader{ .s = s };
    while (true) {
        const param = r.until('&');
        if (param.len == 0) break;

        var rr = Reader{ .s = param };
        const k = rr.until('=');
        if (k.len == 0) continue;

        _ = rr.skip();
        const v = rr.tail();

        // decode k and v
        const kk = try unescape(alloc, k);
        const vv = try unescape(alloc, v);

        try values.appendOwned(kk, vv);

        if (!r.skip()) break;
    }

    return values;
}

test "parse empty query" {
    var values = try parseQuery(std.testing.allocator, "");
    defer values.deinit();

    try std.testing.expect(values.count() == 0);
}

test "parse empty query &" {
    var values = try parseQuery(std.testing.allocator, "&");
    defer values.deinit();

    try std.testing.expect(values.count() == 0);
}

test "parse query" {
    var values = try parseQuery(std.testing.allocator, "a=b&b=c");
    defer values.deinit();

    try std.testing.expect(values.count() == 2);
    try std.testing.expect(values.get("a").len == 1);
    try std.testing.expect(std.mem.eql(u8, values.get("a")[0], "b"));
    try std.testing.expect(std.mem.eql(u8, values.first("a"), "b"));

    try std.testing.expect(values.get("b").len == 1);
    try std.testing.expect(std.mem.eql(u8, values.get("b")[0], "c"));
    try std.testing.expect(std.mem.eql(u8, values.first("b"), "c"));
}

test "parse query no value" {
    var values = try parseQuery(std.testing.allocator, "a");
    defer values.deinit();

    try std.testing.expect(values.count() == 1);
    try std.testing.expect(std.mem.eql(u8, values.first("a"), ""));
}

test "parse query dup" {
    var values = try parseQuery(std.testing.allocator, "a=b&a=c");
    defer values.deinit();

    try std.testing.expect(values.count() == 1);
    try std.testing.expect(std.mem.eql(u8, values.first("a"), "b"));
    try std.testing.expect(values.get("a").len == 2);
}

test "encode query" {
    var values = try parseQuery(std.testing.allocator, "a=b&b=c");
    defer values.deinit();

    try values.append("a", "~");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try values.encode(buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.eql(u8, buf.items, "a=b&a=%7E&b=c"));
}

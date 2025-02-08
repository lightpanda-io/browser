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
const asUint = @import("../str/parser.zig").asUint;

// Values is a map with string key of string values.
pub const Values = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMapUnmanaged(List),

    const List = std.ArrayListUnmanaged([]const u8);

    pub fn init(allocator: std.mem.Allocator) Values {
        return .{
            .map = .{},
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Values) void {
        self.arena.deinit();
    }

    // add the key value couple to the values.
    // the key and the value are duplicated.
    pub fn append(self: *Values, k: []const u8, v: []const u8) !void {
        const allocator = self.arena.allocator();
        const owned_value = try allocator.dupe(u8, v);

        var gop = try self.map.getOrPut(allocator, k);
        if (gop.found_existing) {
            return gop.value_ptr.append(allocator, owned_value);
        }

        gop.key_ptr.* = try allocator.dupe(u8, k);

        var list = List{};
        try list.append(allocator, owned_value);
        gop.value_ptr.* = list;
    }

    // append by taking the ownership of the key and the value
    fn appendOwned(self: *Values, k: []const u8, v: []const u8) !void {
        const allocator = self.arena.allocator();
        var gop = try self.map.getOrPut(allocator, k);
        if (gop.found_existing) {
            return gop.value_ptr.append(allocator, v);
        }

        var list = List{};
        try list.append(allocator, v);
        gop.value_ptr.* = list;
    }

    pub fn get(self: *const Values, k: []const u8) []const []const u8 {
        if (self.map.get(k)) |list| {
            return list.items;
        }

        return &[_][]const u8{};
    }

    pub fn first(self: *const Values, k: []const u8) []const u8 {
        if (self.map.getPtr(k)) |list| {
            if (list.items.len == 0) return "";
            return list.items[0];
        }

        return "";
    }

    pub fn delete(self: *Values, k: []const u8) void {
        _ = self.map.fetchSwapRemove(k);
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

    pub fn count(self: *const Values) usize {
        return self.map.count();
    }

    pub fn encode(self: *const Values, writer: anytype) !void {
        var it = self.map.iterator();

        const first_entry = it.next() orelse return;
        try encodeKeyValues(first_entry, writer);

        while (it.next()) |entry| {
            try writer.writeByte('&');
            try encodeKeyValues(entry, writer);
        }
    }
};

fn encodeKeyValues(entry: anytype, writer: anytype) !void {
    const key = entry.key_ptr.*;

    try escape(key, writer);
    const values = entry.value_ptr.items;
    if (values.len == 0) {
        return;
    }

    if (values[0].len > 0) {
        try writer.writeByte('=');
        try escape(values[0], writer);
    }

    for (values[1..]) |value| {
        try writer.writeByte('&');
        try escape(key, writer);
        if (value.len > 0) {
            try writer.writeByte('=');
            try escape(value, writer);
        }
    }
}

fn escape(raw: []const u8, writer: anytype) !void {
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

    const arena = values.arena.allocator();

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
        const kk = try unescape(arena, k);
        const vv = try unescape(arena, v);

        try values.appendOwned(kk, vv);

        if (!r.skip()) break;
    }

    return values;
}

// The return'd string may or may not be allocated. Callers should use arenas
fn unescape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const HEX_CHAR = comptime blk: {
        var all = std.mem.zeroes([256]bool);
        for ('a'..('f' + 1)) |b| all[b] = true;
        for ('A'..('F' + 1)) |b| all[b] = true;
        for ('0'..('9' + 1)) |b| all[b] = true;
        break :blk all;
    };

    const HEX_DECODE = comptime blk: {
        var all = std.mem.zeroes([256]u8);
        for ('a'..('z' + 1)) |b| all[b] = b - 'a' + 10;
        for ('A'..('Z' + 1)) |b| all[b] = b - 'A' + 10;
        for ('0'..('9' + 1)) |b| all[b] = b - '0';
        break :blk all;
    };

    var has_plus = false;
    var unescaped_len = input.len;

    {
        // Figure out if we have any spaces and what the final unescaped length
        // will be (which will let us know if we have anything to unescape in
        // the first place)
        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];
            if (c == '%') {
                if (i + 2 >= input.len or !HEX_CHAR[input[i + 1]] or !HEX_CHAR[input[i + 2]]) {
                    return error.EscapeError;
                }
                i += 3;
                unescaped_len -= 2;
            } else if (c == '+') {
                has_plus = true;
                i += 1;
            } else {
                i += 1;
            }
        }
    }

    // no encoding, and no plus. nothing to unescape
    if (unescaped_len == input.len and has_plus == false) {
        return input;
    }

    var unescaped = try allocator.alloc(u8, unescaped_len);
    errdefer allocator.free(unescaped);

    var input_pos: usize = 0;
    for (0..unescaped_len) |unescaped_pos| {
        switch (input[input_pos]) {
            '+' => {
                unescaped[unescaped_pos] = ' ';
                input_pos += 1;
            },
            '%' => {
                const encoded = input[input_pos + 1 .. input_pos + 3];
                const encoded_as_uint = @as(u16, @bitCast(encoded[0..2].*));
                unescaped[unescaped_pos] = switch (encoded_as_uint) {
                    asUint("20") => ' ',
                    asUint("21") => '!',
                    asUint("22") => '"',
                    asUint("23") => '#',
                    asUint("24") => '$',
                    asUint("25") => '%',
                    asUint("26") => '&',
                    asUint("27") => '\'',
                    asUint("28") => '(',
                    asUint("29") => ')',
                    asUint("2A") => '*',
                    asUint("2B") => '+',
                    asUint("2C") => ',',
                    asUint("2F") => '/',
                    asUint("3A") => ':',
                    asUint("3B") => ';',
                    asUint("3D") => '=',
                    asUint("3F") => '?',
                    asUint("40") => '@',
                    asUint("5B") => '[',
                    asUint("5D") => ']',
                    else => HEX_DECODE[encoded[0]] << 4 | HEX_DECODE[encoded[1]],
                };
                input_pos += 3;
            },
            else => |c| {
                unescaped[unescaped_pos] = c;
                input_pos += 1;
            },
        }
    }
    return unescaped;
}

const testing = std.testing;
test "url.Query: unescape" {
    const allocator = testing.allocator;
    const cases = [_]struct { expected: []const u8, input: []const u8, free: bool }{
        .{ .expected = "", .input = "", .free = false },
        .{ .expected = "over", .input = "over", .free = false },
        .{ .expected = "Hello  World", .input = "Hello  World", .free = false },
        .{ .expected = "~", .input = "%7E", .free = true },
        .{ .expected = "~", .input = "%7e", .free = true },
        .{ .expected = "Hello~World", .input = "Hello%7eWorld", .free = true },
        .{ .expected = "Hello  World", .input = "Hello++World", .free = true },
    };

    for (cases) |case| {
        const value = try unescape(allocator, case.input);
        defer if (case.free) {
            allocator.free(value);
        };
        try testing.expectEqualStrings(case.expected, value);
    }

    try testing.expectError(error.EscapeError, unescape(undefined, "%"));
    try testing.expectError(error.EscapeError, unescape(undefined, "%a"));
    try testing.expectError(error.EscapeError, unescape(undefined, "%1"));
    try testing.expectError(error.EscapeError, unescape(undefined, "123%45%6"));
    try testing.expectError(error.EscapeError, unescape(undefined, "%zzzzz"));
    try testing.expectError(error.EscapeError, unescape(undefined, "%0\xff"));
}

test "url.Query: parseQuery" {
    try testParseQuery(.{}, "");

    try testParseQuery(.{}, "&");

    try testParseQuery(.{ .a = [_][]const u8{"b"} }, "a=b");

    try testParseQuery(.{ .hello = [_][]const u8{"world"} }, "hello=world");

    try testParseQuery(.{ .hello = [_][]const u8{ "world", "all" } }, "hello=world&hello=all");

    try testParseQuery(.{
        .a = [_][]const u8{"b"},
        .b = [_][]const u8{"c"},
    }, "a=b&b=c");

    try testParseQuery(.{ .a = [_][]const u8{""} }, "a");
    try testParseQuery(.{ .a = [_][]const u8{ "", "", "" } }, "a&a&a");

    try testParseQuery(.{ .abc = [_][]const u8{""} }, "abc");
    try testParseQuery(.{
        .abc = [_][]const u8{""},
        .dde = [_][]const u8{ "", "" },
    }, "abc&dde&dde");

    try testParseQuery(.{
        .@"power is >" = [_][]const u8{"9,000?"},
    }, "power%20is%20%3E=9%2C000%3F");
}

test "url.Query.Values: get/first/count" {
    var values = Values.init(testing.allocator);
    defer values.deinit();

    {
        // empty
        try testing.expectEqual(0, values.count());
        try testing.expectEqual(0, values.get("").len);
        try testing.expectEqualStrings("", values.first(""));
        try testing.expectEqual(0, values.get("key").len);
        try testing.expectEqualStrings("", values.first("key"));
    }

    {
        // add 1 value => key
        try values.appendOwned("key", "value");
        try testing.expectEqual(1, values.count());
        try testing.expectEqual(1, values.get("key").len);
        try testing.expectEqualSlices(
            []const u8,
            &.{"value"},
            values.get("key"),
        );
        try testing.expectEqualStrings("value", values.first("key"));
    }

    {
        // add another value for the same key
        try values.appendOwned("key", "another");
        try testing.expectEqual(1, values.count());
        try testing.expectEqual(2, values.get("key").len);
        try testing.expectEqualSlices(
            []const u8,
            &.{ "value", "another" },
            values.get("key"),
        );
        try testing.expectEqualStrings("value", values.first("key"));
    }

    {
        // add a new key (and value)
        try values.appendOwned("over", "9000!");
        try testing.expectEqual(2, values.count());
        try testing.expectEqual(2, values.get("key").len);
        try testing.expectEqual(1, values.get("over").len);
        try testing.expectEqualSlices(
            []const u8,
            &.{"9000!"},
            values.get("over"),
        );
        try testing.expectEqualStrings("9000!", values.first("over"));
    }
}

test "url.Query.Values: encode" {
    var values = try parseQuery(
        testing.allocator,
        "hello=world&i%20will%20not%20fear=%3E%3E&a=b&a=c",
    );
    defer values.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try values.encode(buf.writer(testing.allocator));
    try testing.expectEqualStrings(
        "hello=world&i%20will%20not%20fear=%3E%3E&a=b&a=c",
        buf.items,
    );
}

fn testParseQuery(expected: anytype, query: []const u8) !void {
    var values = try parseQuery(testing.allocator, query);
    defer values.deinit();

    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(expected)).Struct.fields) |f| {
        const actual = values.get(f.name);
        const expect = @field(expected, f.name);
        try testing.expectEqual(expect.len, actual.len);
        for (expect, actual) |e, a| {
            try testing.expectEqualStrings(e, a);
        }
        count += 1;
    }
    try testing.expectEqual(count, values.count());
}

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
const Allocator = std.mem.Allocator;

const M = @This();

// German-string (small string optimization)
pub const String = packed struct {
    len: i32,
    payload: packed union {
        // Zig won't let you put an array in a packed struct/union. But it will
        // let you put a vector.
        content: @Vector(12, u8),
        heap: packed struct { prefix: @Vector(4, u8), ptr: [*]const u8 },
    },

    const tombstone = -1;
    pub const empty = String{ .len = 0, .payload = .{ .content = @splat(0) } };
    pub const deleted = String{ .len = tombstone, .payload = .{ .content = @splat(0) } };

    // for packages that already have String imported, then can use String.Global
    pub const Global = M.Global;

    // Wraps an existing string. For strings with len <= 12, this can be done at
    // comptime: comptime String.wrap("id");
    // For strings with len > 12, this must be done at runtime even for a string
    // literal. This is because, at comptime, we do not have a ptr for data and
    // thus can't store it.
    pub fn wrap(input: anytype) String {
        if (@inComptime()) {
            const l = input.len;
            if (l > 12) {
                @compileError("Comptime string must be <= 12 bytes (SSO only): " ++ input);
            }

            var content: [12]u8 = @splat(0);
            @memcpy(content[0..l], input);
            return .{ .len = @intCast(l), .payload = .{ .content = content } };
        }

        // Runtime path - handle both String and []const u8
        if (@TypeOf(input) == String) {
            return input;
        }

        const l = input.len;

        if (l <= 12) {
            var content: [12]u8 = @splat(0);
            @memcpy(content[0..l], input);
            return .{ .len = @intCast(l), .payload = .{ .content = content } };
        }

        return .{
            .len = @intCast(l),
            .payload = .{ .heap = .{
                .prefix = input[0..4].*,
                .ptr = input.ptr,
            } },
        };
    }

    pub const InitOpts = struct {
        dupe: bool = true,
    };
    pub fn init(allocator: Allocator, input: []const u8, opts: InitOpts) !String {
        if (input.len >= std.math.maxInt(i32)) {
            return error.StringTooLarge;
        }
        const l: u32 = @intCast(input.len);
        if (l <= 12) {
            var content: [12]u8 = @splat(0);
            @memcpy(content[0..l], input);
            return .{ .len = @intCast(l), .payload = .{ .content = content } };
        }

        return .{
            .len = @intCast(l),
            .payload = .{ .heap = .{
                .prefix = input[0..4].*,
                .ptr = (intern(input) orelse (if (opts.dupe) (try allocator.dupe(u8, input)) else input)).ptr,
            } },
        };
    }

    pub fn deinit(self: *const String, allocator: Allocator) void {
        const len = self.len;
        if (len > 12) {
            allocator.free(self.payload.heap.ptr[0..@intCast(len)]);
        }
    }

    pub fn dupe(self: *const String, allocator: Allocator) !String {
        return .init(allocator, self.str(), .{ .dupe = true });
    }

    pub fn concat(allocator: Allocator, parts: []const []const u8) !String {
        var total_len: usize = 0;
        for (parts) |part| {
            total_len += part.len;
        }

        if (total_len <= 12) {
            var content: [12]u8 = @splat(0);
            var pos: usize = 0;
            for (parts) |part| {
                @memcpy(content[pos..][0..part.len], part);
                pos += part.len;
            }
            return .{ .len = @intCast(total_len), .payload = .{ .content = content } };
        }

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (parts) |part| {
            @memcpy(result[pos..][0..part.len], part);
            pos += part.len;
        }

        return .{
            .len = @intCast(total_len),
            .payload = .{ .heap = .{
                .prefix = result[0..4].*,
                .ptr = (intern(result) orelse result).ptr,
            } },
        };
    }

    pub fn str(self: *const String) []const u8 {
        const l = self.len;
        if (l < 0) {
            return "";
        }

        const ul: usize = @intCast(l);

        if (ul <= 12) {
            const slice: []const u8 = @ptrCast(self);
            return slice[4 .. ul + 4];
        }

        return self.payload.heap.ptr[0..ul];
    }

    pub fn isDeleted(self: *const String) bool {
        return self.len == tombstone;
    }

    pub fn format(self: String, writer: *std.Io.Writer) !void {
        return writer.writeAll(self.str());
    }

    pub fn eql(a: String, b: String) bool {
        if (@as(*const u64, @ptrCast(&a)).* != @as(*const u64, @ptrCast(&b)).*) {
            return false;
        }

        const len = a.len;
        if (len < 0 or b.len < 0) {
            return false;
        }

        if (len <= 12) {
            return @reduce(.And, a.payload.content == b.payload.content);
        }

        // a.len == b.len at this point
        const al: usize = @intCast(len);
        const bl: usize = @intCast(len);
        return std.mem.eql(u8, a.payload.heap.ptr[0..al], b.payload.heap.ptr[0..bl]);
    }

    pub fn eqlSlice(a: String, b: []const u8) bool {
        return switch (a.eqlSliceOrDeleted(b)) {
            .equal => |r| r,
            .deleted => false,
        };
    }

    const EqualOrDeleted = union(enum) {
        deleted,
        equal: bool,
    };
    pub fn eqlSliceOrDeleted(a: String, b: []const u8) EqualOrDeleted {
        if (a.len == tombstone) {
            return .deleted;
        }
        return .{ .equal = std.mem.eql(u8, a.str(), b) };
    }

    // This can be used outside of the small string optimization
    pub fn intern(input: []const u8) ?[]const u8 {
        switch (input.len) {
            1 => switch (input[0]) {
                '\n' => return "\n",
                '\r' => return "\r",
                '\t' => return "\t",
                ' ' => return " ",
                else => {},
            },
            2 => switch (@as(u16, @bitCast(input[0..2].*))) {
                asUint("id") => return "id",
                asUint("  ") => return "  ",
                asUint("\r\n") => return "\r\n",
                else => {},
            },
            3 => switch (@as(u24, @bitCast(input[0..3].*))) {
                asUint("   ") => return "   ",
                else => {},
            },
            4 => switch (@as(u32, @bitCast(input[0..4].*))) {
                asUint("    ") => return "    ",
                else => {},
            },
            5 => switch (@as(u40, @bitCast(input[0..5].*))) {
                asUint("     ") => return "     ",
                else => {},
            },
            13 => switch (@as(u104, @bitCast(input[0..13].*))) {
                asUint("border-radius") => return "border-radius",
                asUint("padding-right") => return "padding-right",
                asUint("margin-bottom") => return "margin-bottom",
                asUint("space-between") => return "space-between",
                else => {},
            },
            14 => switch (@as(u112, @bitCast(input[0..14].*))) {
                asUint("padding-bottom") => return "padding-bottom",
                asUint("text-transform") => return "text-transform",
                asUint("letter-spacing") => return "letter-spacing",
                asUint("vertical-align") => return "vertical-align",
                else => {},
            },
            15 => switch (@as(u120, @bitCast(input[0..15].*))) {
                asUint("text-decoration") => return "text-decoration",
                asUint("justify-content") => return "justify-content",
                else => {},
            },
            16 => switch (@as(u128, @bitCast(input[0..16].*))) {
                asUint("background-color") => return "background-color",
                else => {},
            },
            else => {},
        }
        return null;
    }
};

// Discriminatory type that signals the bridge to use arena instead of call_arena
// Use this for strings that need to persist beyond the current call
// The caller can unwrap and store just the underlying .str field
pub const Global = struct {
    str: String,
};

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const testing = @import("testing.zig");
test "String" {
    const other_short = try String.init(undefined, "other_short", .{});
    const other_long = try String.init(testing.allocator, "other_long" ** 100, .{});
    defer other_long.deinit(testing.allocator);

    inline for (0..100) |i| {
        const input = "a" ** i;
        const str = try String.init(testing.allocator, input, .{});
        defer str.deinit(testing.allocator);

        try testing.expectEqual(input, str.str());

        try testing.expectEqual(true, str.eql(str));
        try testing.expectEqual(true, str.eqlSlice(input));
        try testing.expectEqual(false, str.eql(other_short));
        try testing.expectEqual(false, str.eqlSlice("other_short"));

        try testing.expectEqual(false, str.eql(other_long));
        try testing.expectEqual(false, str.eqlSlice("other_long" ** 100));
    }
}

test "String.concat" {
    {
        const result = try String.concat(testing.allocator, &.{});
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.str().len);
        try testing.expectEqual("", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{"hello"});
        defer result.deinit(testing.allocator);
        try testing.expectEqual("hello", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{ "foo", "bar" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("foobar", result.str());
        try testing.expectEqual(@as(i32, 6), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "test", "ing", "1234" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("testing1234", result.str());
        try testing.expectEqual(@as(i32, 11), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "foo", "bar", "baz", "qux" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("foobarbazqux", result.str());
        try testing.expectEqual(@as(i32, 12), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "hello", " world!" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("hello world!", result.str());
        try testing.expectEqual(@as(i32, 12), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "a", "b", "c", "d", "e" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("abcde", result.str());
        try testing.expectEqual(@as(i32, 5), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "one", " ", "two", " ", "three", " ", "four" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("one two three four", result.str());
        try testing.expectEqual(@as(i32, 18), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "hello", "", "world" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("helloworld", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{ "", "", "" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("", result.str());
        try testing.expectEqual(@as(i32, 0), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "café", " ☕" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("café ☕", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{ "Hello ", "世界", " and ", "مرحبا" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("Hello 世界 and مرحبا", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{ " ", "test", " " });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(" test ", result.str());
    }

    {
        const result = try String.concat(testing.allocator, &.{ "  ", "  " });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("    ", result.str());
        try testing.expectEqual(@as(i32, 4), result.len);
    }

    {
        const result = try String.concat(testing.allocator, &.{ "Item ", "1", "2", "3" });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("Item 123", result.str());
    }

    {
        const original = "Hello, world!";
        const result = try String.concat(testing.allocator, &.{ original[0..5], original[7..] });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("Helloworld!", result.str());
    }

    {
        const original = "Hello!";
        const result = try String.concat(testing.allocator, &.{ original[0..5], " world", original[5..] });
        defer result.deinit(testing.allocator);
        try testing.expectEqual("Hello world!", result.str());
    }
}

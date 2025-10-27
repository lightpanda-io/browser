const std = @import("std");
const js = @import("browser/js/js.zig");
const Allocator = std.mem.Allocator;

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
        var prefix: [4]u8 = @splat(0);
        @memcpy(&prefix, input[0..4]);

        return .{
            .len = @intCast(l),
            .payload = .{ .heap = .{
                .prefix = prefix,
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

    pub fn fromJS(allocator: Allocator, js_obj: js.Object) !String {
        const js_str = js_obj.toString();
        return init(allocator, js_str, .{});
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
        if (a.len != b.len or a.len < 0 or b.len < 0) {
            return false;
        }

        if (a.len <= 12) {
            return @reduce(.And, a.payload.content == b.payload.content);
        }

        if (@reduce(.And, a.payload.heap.prefix == b.payload.heap.prefix) == false) {
            return false;
        }

        const al: usize = @intCast(a.len);
        const bl: usize = @intCast(a.len);
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

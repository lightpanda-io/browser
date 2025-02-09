const std = @import("std");

pub const Interfaces = .{
    U32Iterator,
};

pub const U32Iterator = struct {
    pub const mem_guarantied = true;

    length: u32,
    index: u32 = 0,

    pub const Return = struct {
        value: u32,
        done: bool,
    };

    pub fn _next(self: *U32Iterator) Return {
        const i = self.index;
        if (i >= self.length) {
            return .{
                .value = 0,
                .done = true,
            };
        }

        self.index += 1;
        return .{
            .value = i,
            .done = false,
        };
    }
};

const testing = std.testing;
test "U32Iterator" {
    const Return = U32Iterator.Return;

    {
        var it = U32Iterator{ .length = 0 };
        try testing.expectEqual(Return{ .value = 0, .done = true }, it._next());
        try testing.expectEqual(Return{ .value = 0, .done = true }, it._next());
    }

    {
        var it = U32Iterator{ .length = 3 };
        try testing.expectEqual(Return{ .value = 0, .done = false }, it._next());
        try testing.expectEqual(Return{ .value = 1, .done = false }, it._next());
        try testing.expectEqual(Return{ .value = 2, .done = false }, it._next());
        try testing.expectEqual(Return{ .value = 0, .done = true }, it._next());
        try testing.expectEqual(Return{ .value = 0, .done = true }, it._next());
    }
}

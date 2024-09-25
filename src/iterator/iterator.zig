const std = @import("std");

const generate = @import("../generate.zig");

pub const Interfaces = generate.Tuple(.{
    U32Iterator,
});

pub const U32Iterator = struct {
    pub const mem_guarantied = true;

    length: u32,
    index: u32 = 0,

    pub const Return = struct {
        value: u32,
        done: bool,
    };

    pub fn _next(self: *U32Iterator) !Return {
        const i = self.index;
        if (i >= self.length) {
            return Return{
                .value = 0,
                .done = true,
            };
        }

        self.index += 1;
        return Return{
            .value = i,
            .done = false,
        };
    }
};

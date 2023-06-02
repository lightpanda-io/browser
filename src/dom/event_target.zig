const parser = @import("../parser.zig");

pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const mem_guarantied = true;
};

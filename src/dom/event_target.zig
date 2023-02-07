const parser = @import("../parser.zig");

pub const EventTarget = struct {
    base: ?*parser.EventTarget = null,

    pub fn init(base: ?*parser.EventTarget) EventTarget {
        return .{ .base = base };
    }

    pub fn constructor() EventTarget {
        return .{};
    }
};

const std = @import("std");

const parser = @import("../netsurf.zig");

const EventTarget = @import("event_target.zig").EventTarget;

pub const Node = struct {
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;
};

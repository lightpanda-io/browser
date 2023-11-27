const parser = @import("../netsurf.zig");

const DOMException = @import("exceptions.zig").DOMException;

pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;
};

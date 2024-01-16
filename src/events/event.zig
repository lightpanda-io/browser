const std = @import("std");

const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const DOMException = @import("../dom/exceptions.zig").DOMException;

pub const Event = struct {
    pub const Self = parser.Event;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn constructor(eventType: []const u8) !*parser.Event {
        const event = try parser.eventCreate();
        try parser.eventInit(event, eventType);
        return event;
    }
};

// Event interfaces
pub const Interfaces = generate.Tuple(.{
    Event,
});
const Generated = generate.Union.compile(Interfaces);
pub const Union = Generated._union;

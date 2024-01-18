const std = @import("std");

const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const DOMException = @import("../dom/exceptions.zig").DOMException;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventTargetUnion = @import("../dom/event_target.zig").Union;

// https://dom.spec.whatwg.org/#event
pub const Event = struct {
    pub const Self = parser.Event;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub const EventInit = parser.EventInit;

    // JS
    // --

    pub const _CAPTURING_PHASE = 1;
    pub const _AT_TARGET = 2;
    pub const _BUBBLING_PHASE = 3;

    pub fn constructor(eventType: []const u8, opts: ?EventInit) !*parser.Event {
        const event = try parser.eventCreate();
        try parser.eventInit(event, eventType, opts orelse EventInit{});
        return event;
    }

    // Getters

    pub fn get_type(self: *parser.Event) ![]const u8 {
        return try parser.eventType(self);
    }

    pub fn get_target(self: *parser.Event) !?EventTargetUnion {
        const et = try parser.eventTarget(self);
        if (et == null) return null;
        return try EventTarget.toInterface(et.?);
    }

    pub fn get_currentTarget(self: *parser.Event) !?EventTargetUnion {
        const et = try parser.eventCurrentTarget(self);
        if (et == null) return null;
        return try EventTarget.toInterface(et.?);
    }

    pub fn get_eventPhase(self: *parser.Event) !u8 {
        return try parser.eventPhase(self);
    }

    pub fn get_bubbles(self: *parser.Event) !bool {
        return try parser.eventBubbles(self);
    }

    pub fn get_cancelable(self: *parser.Event) !bool {
        return try parser.eventCancelable(self);
    }

    pub fn get_defaultPrevented(self: *parser.Event) !bool {
        return try parser.eventDefaultPrevented(self);
    }

    pub fn get_isTrusted(self: *parser.Event) !bool {
        return try parser.eventIsTrusted(self);
    }

    pub fn get_timestamp(self: *parser.Event) !u32 {
        return try parser.eventTimestamp(self);
    }

    // Methods

    pub fn get_stopPropagation(self: *parser.Event) !void {
        return try parser.eventStopPropagation(self);
    }

    pub fn get_stopImmediatePropagation(self: *parser.Event) !void {
        return try parser.eventStopImmediatePropagation(self);
    }

    pub fn get_preventDefault(self: *parser.Event) !void {
        return try parser.eventPreventDefault(self);
    }
};

// Event interfaces
pub const Interfaces = generate.Tuple(.{
    Event,
});
const Generated = generate.Union.compile(Interfaces);
pub const Union = Generated._union;

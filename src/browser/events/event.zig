// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const generate = @import("../../runtime/generate.zig");

const DOMException = @import("../dom/exceptions.zig").DOMException;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventTargetUnion = @import("../dom/event_target.zig").Union;

const CustomEvent = @import("custom_event.zig").CustomEvent;
const ProgressEvent = @import("../xhr/progress_event.zig").ProgressEvent;

// Event interfaces
pub const Interfaces = .{
    Event,
    CustomEvent,
    ProgressEvent,
};

pub const Union = generate.Union(Interfaces);

// https://dom.spec.whatwg.org/#event
pub const Event = struct {
    pub const Self = parser.Event;
    pub const Exception = DOMException;

    pub const EventInit = parser.EventInit;

    // JS
    // --

    pub const _CAPTURING_PHASE = 1;
    pub const _AT_TARGET = 2;
    pub const _BUBBLING_PHASE = 3;

    pub fn toInterface(evt: *parser.Event) !Union {
        return switch (try parser.eventGetInternalType(evt)) {
            .event => .{ .Event = evt },
            .custom_event => .{ .CustomEvent = @as(*CustomEvent, @ptrCast(evt)).* },
            .progress_event => .{ .ProgressEvent = @as(*ProgressEvent, @ptrCast(evt)).* },
        };
    }

    pub fn constructor(event_type: []const u8, opts: ?EventInit) !*parser.Event {
        const event = try parser.eventCreate();
        try parser.eventInit(event, event_type, opts orelse EventInit{});
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

    pub fn _initEvent(
        self: *parser.Event,
        eventType: []const u8,
        bubbles: ?bool,
        cancelable: ?bool,
    ) !void {
        const opts = EventInit{
            .bubbles = bubbles orelse false,
            .cancelable = cancelable orelse false,
        };
        return try parser.eventInit(self, eventType, opts);
    }

    pub fn _stopPropagation(self: *parser.Event) !void {
        return try parser.eventStopPropagation(self);
    }

    pub fn _stopImmediatePropagation(self: *parser.Event) !void {
        return try parser.eventStopImmediatePropagation(self);
    }

    pub fn _preventDefault(self: *parser.Event) !void {
        return try parser.eventPreventDefault(self);
    }
};

pub const EventHandler = struct {
    callback: Function,
    node: parser.EventNode,

    const Env = @import("../env.zig").Env;
    const Function = Env.Function;

    pub const Listener = union(enum) {
        function: Function,
        object: Env.JsObject,

        pub fn callback(self: Listener, target: *parser.EventTarget) !?Function {
            return switch (self) {
                .function => |func| try func.withThis(target),
                .object => |obj| blk: {
                    const func = (try obj.getFunction("handleEvent")) orelse return null;
                    break :blk try func.withThis(try obj.persist());
                },
            };
        }
    };

    pub fn init(allocator: Allocator, callback: Function) !*EventHandler {
        const eh = try allocator.create(EventHandler);
        eh.* = .{
            .callback = callback,
            .node = .{
                .id = callback.id,
                .func = handle,
            },
        };
        return eh;
    }

    fn handle(node: *parser.EventNode, event: *parser.Event) void {
        const ievent = Event.toInterface(event) catch |err| {
            log.err(.event, "toInterface error", .{ .err = err });
            return;
        };

        const self: *EventHandler = @fieldParentPtr("node", node);
        var result: Function.Result = undefined;
        self.callback.tryCall(void, .{ievent}, &result) catch {
            log.debug(.event, "handle callback error", .{ .err = result.exception, .stack = result.stack });
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser.Event" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let content = document.getElementById('content')", "undefined" },
        .{ "let para = document.getElementById('para')", "undefined" },
        .{ "var nb = 0; var evt", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ content.addEventListener('target', function(e) {
            \\  evt = e; nb = nb + 1;
            \\  e.preventDefault();
            \\ })
            ,
            "undefined",
        },
        .{ "content.dispatchEvent(new Event('target', {bubbles: true, cancelable: true}))", "false" },
        .{ "nb", "1" },
        .{ "evt.target === content", "true" },
        .{ "evt.bubbles", "true" },
        .{ "evt.cancelable", "true" },
        .{ "evt.defaultPrevented", "true" },
        .{ "evt.isTrusted", "true" },
        .{ "evt.timestamp > 1704063600", "true" }, // 2024/01/01 00:00
        // event.type, event.currentTarget, event.phase checked in EventTarget
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0", "0" },
        .{
            \\ content.addEventListener('stop',function(e) {
            \\    e.stopPropagation();
            \\    nb = nb + 1;
            \\  }, true)
            ,
            "undefined",
        },
        // the following event listener will not be invoked
        .{
            \\  para.addEventListener('stop',function(e) {
            \\    nb = nb + 1;
            \\  })
            ,
            "undefined",
        },
        .{ "para.dispatchEvent(new Event('stop'))", "true" },
        .{ "nb", "1" }, // will be 2 if event was not stopped at content event listener
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0", "0" },
        .{
            \\  content.addEventListener('immediate', function(e) {
            \\    e.stopImmediatePropagation();
            \\    nb = nb + 1;
            \\  })
            ,
            "undefined",
        },
        // the following event listener will not be invoked
        .{
            \\  content.addEventListener('immediate', function(e) {
            \\    nb = nb + 1;
            \\  })
            ,
            "undefined",
        },
        .{ "content.dispatchEvent(new Event('immediate'))", "true" },
        .{ "nb", "1" }, // will be 2 if event was not stopped at first content event listener
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0", "0" },
        .{
            \\  content.addEventListener('legacy', function(e) {
            \\     evt = e; nb = nb + 1;
            \\  })
            ,
            "undefined",
        },
        .{ "let evtLegacy = document.createEvent('Event')", "undefined" },
        .{ "evtLegacy.initEvent('legacy')", "undefined" },
        .{ "content.dispatchEvent(evtLegacy)", "true" },
        .{ "nb", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "var nb = 0; var evt = null; function cbk(event) { nb ++; evt=event; }", "undefined" },
        .{ "document.addEventListener('count', cbk)", "undefined" },
        .{ "document.removeEventListener('count', cbk)", "undefined" },
        .{ "document.dispatchEvent(new Event('count'))", "true" },
        .{ "nb", "0" },
    }, .{});
}

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

const generate = @import("../generate.zig");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const CallbackResult = jsruntime.CallbackResult;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("netsurf");

const DOMException = @import("../dom/exceptions.zig").DOMException;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventTargetUnion = @import("../dom/event_target.zig").Union;

const ProgressEvent = @import("../xhr/progress_event.zig").ProgressEvent;

const log = std.log.scoped(.events);

// Event interfaces
pub const Interfaces = generate.Tuple(.{
    Event,
    ProgressEvent,
});
const Generated = generate.Union.compile(Interfaces);
pub const Union = Generated._union;

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

    pub fn toInterface(evt: *parser.Event) !Union {
        return switch (try parser.eventGetInternalType(evt)) {
            .event => .{ .Event = evt },
            .progress_event => .{ .ProgressEvent = @as(*ProgressEvent, @ptrCast(evt)).* },
        };
    }

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

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var common = [_]Case{
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "let para = document.getElementById('para')", .ex = "undefined" },
        .{ .src = "var nb = 0; var evt", .ex = "undefined" },
    };
    try checkCases(js_env, &common);

    var basic = [_]Case{
        .{ .src = 
        \\content.addEventListener('target',
        \\function(e) {
        \\evt = e; nb = nb + 1;
        \\e.preventDefault();
        \\})
        , .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('target', {bubbles: true, cancelable: true}))", .ex = "false" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt.target === content", .ex = "true" },
        .{ .src = "evt.bubbles", .ex = "true" },
        .{ .src = "evt.cancelable", .ex = "true" },
        .{ .src = "evt.defaultPrevented", .ex = "true" },
        .{ .src = "evt.isTrusted", .ex = "true" },
        .{ .src = "evt.timestamp > 1704063600", .ex = "true" }, // 2024/01/01 00:00
        // event.type, event.currentTarget, event.phase checked in EventTarget
    };
    try checkCases(js_env, &basic);

    var stop = [_]Case{
        .{ .src = "nb = 0", .ex = "0" },
        .{ .src = 
        \\content.addEventListener('stop',
        \\function(e) {
        \\e.stopPropagation();
        \\nb = nb + 1;
        \\}, true)
        , .ex = "undefined" },
        // the following event listener will not be invoked
        .{ .src = 
        \\para.addEventListener('stop',
        \\function(e) {
        \\nb = nb + 1;
        \\})
        , .ex = "undefined" },
        .{ .src = "para.dispatchEvent(new Event('stop'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" }, // will be 2 if event was not stopped at content event listener
    };
    try checkCases(js_env, &stop);

    var stop_immediate = [_]Case{
        .{ .src = "nb = 0", .ex = "0" },
        .{ .src = 
        \\content.addEventListener('immediate',
        \\function(e) {
        \\e.stopImmediatePropagation();
        \\nb = nb + 1;
        \\})
        , .ex = "undefined" },
        // the following event listener will not be invoked
        .{ .src = 
        \\content.addEventListener('immediate',
        \\function(e) {
        \\nb = nb + 1;
        \\})
        , .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('immediate'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" }, // will be 2 if event was not stopped at first content event listener
    };
    try checkCases(js_env, &stop_immediate);

    var legacy = [_]Case{
        .{ .src = "nb = 0", .ex = "0" },
        .{ .src = 
        \\content.addEventListener('legacy',
        \\function(e) {
        \\evt = e; nb = nb + 1;
        \\})
        , .ex = "undefined" },
        .{ .src = "let evtLegacy = document.createEvent('Event')", .ex = "undefined" },
        .{ .src = "evtLegacy.initEvent('legacy')", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(evtLegacy)", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
    };
    try checkCases(js_env, &legacy);

    var remove = [_]Case{
        .{ .src = "var nb = 0; var evt = null; function cbk(event) { nb ++; evt=event; }", .ex = "undefined" },
        .{ .src = "document.addEventListener('count', cbk)", .ex = "undefined" },
        .{ .src = "document.removeEventListener('count', cbk)", .ex = "undefined" },
        .{ .src = "document.dispatchEvent(new Event('count'))", .ex = "true" },
        .{ .src = "nb", .ex = "0" },
    };
    try checkCases(js_env, &remove);
}

pub const EventHandler = struct {
    fn handle(event: ?*parser.Event, data: parser.EventHandlerData) void {
        // TODO get the allocator by another way?
        var res = CallbackResult.init(data.cbk.nat_ctx.alloc);
        defer res.deinit();

        if (event) |evt| {
            data.cbk.trycall(.{
                Event.toInterface(evt) catch unreachable,
            }, &res) catch |e| log.err("event handler error: {any}", .{e});
        } else {
            data.cbk.trycall(.{event}, &res) catch |e| log.err("event handler error: {any}", .{e});
        }

        // in case of function error, we log the result and the trace.
        if (!res.success) {
            log.info("event handler error: {s}", .{res.result orelse "unknown"});
            log.debug("{s}", .{res.stack orelse "no stack trace"});
        }
    }
}.handle;

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

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const JSObjectID = jsruntime.JSObjectID;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("netsurf");
const EventHandler = @import("../events/event.zig").EventHandler;

const DOMException = @import("exceptions.zig").DOMException;
const Nod = @import("node.zig");

// EventTarget interfaces
pub const Union = Nod.Union;

// EventTarget implementation
pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub fn toInterface(et: *parser.EventTarget) !Union {
        // NOTE: for now we state that all EventTarget are Nodes
        // TODO: handle other types (eg. Window)
        return Nod.Node.toInterface(@as(*parser.Node, @ptrCast(et)));
    }

    // JS funcs
    // --------

    pub fn _addEventListener(
        self: *parser.EventTarget,
        alloc: std.mem.Allocator,
        eventType: []const u8,
        cbk: Callback,
        capture: ?bool,
        // TODO: hanle EventListenerOptions
        // see #https://github.com/lightpanda-io/jsruntime-lib/issues/114
    ) !void {

        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(
            self,
            eventType,
            capture orelse false,
            cbk.id(),
        );
        if (lst != null) {
            return;
        }

        try parser.eventTargetAddEventListener(
            self,
            alloc,
            eventType,
            cbk,
            capture orelse false,
            EventHandler,
        );
    }

    pub fn _removeEventListener(
        self: *parser.EventTarget,
        alloc: std.mem.Allocator,
        eventType: []const u8,
        cbk_id: JSObjectID,
        capture: ?bool,
        // TODO: hanle EventListenerOptions
        // see #https://github.com/lightpanda-io/jsruntime-lib/issues/114
    ) !void {

        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(
            self,
            eventType,
            capture orelse false,
            cbk_id.get(),
        );
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(
            self,
            alloc,
            eventType,
            lst.?,
            capture orelse false,
        );
    }

    pub fn _dispatchEvent(self: *parser.EventTarget, event: *parser.Event) !bool {
        return try parser.eventTargetDispatchEvent(self, event);
    }

    pub fn deinit(self: *parser.EventTarget, alloc: std.mem.Allocator) void {
        parser.eventTargetRemoveAllEventListeners(self, alloc) catch unreachable;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var common = [_]Case{
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "let para = document.getElementById('para')", .ex = "undefined" },
        // NOTE: as some event properties will change during the event dispatching phases
        // we need to copy thoses values in order to check them afterwards
        .{ .src = 
        \\var nb = 0; var evt; var phase; var cur;
        \\function cbk(event) {
        \\evt = event;
        \\phase = event.eventPhase;
        \\cur = event.currentTarget;
        \\nb ++;
        \\}
        , .ex = "undefined" },
    };
    try checkCases(js_env, &common);

    var basic = [_]Case{
        .{ .src = "content.addEventListener('basic', cbk)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "basic" },
        .{ .src = "phase", .ex = "2" },
        .{ .src = "cur.getAttribute('id')", .ex = "content" },
    };
    try checkCases(js_env, &basic);

    var basic_child = [_]Case{
        .{ .src = "nb = 0; evt = undefined; phase = undefined; cur = undefined", .ex = "undefined" },
        .{ .src = "para.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "0" }, // handler is not called, no capture, not the target, no bubbling
        .{ .src = "evt === undefined", .ex = "true" },
    };
    try checkCases(js_env, &basic_child);

    var basic_twice = [_]Case{
        .{ .src = "nb  = 0", .ex = "0" },
        .{ .src = "content.addEventListener('basic', cbk)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
    };
    try checkCases(js_env, &basic_twice);

    var basic_twice_capture = [_]Case{
        .{ .src = "nb  = 0", .ex = "0" },
        .{ .src = "content.addEventListener('basic', cbk, true)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "2" },
    };
    try checkCases(js_env, &basic_twice_capture);

    var basic_remove = [_]Case{
        .{ .src = "nb  = 0", .ex = "0" },
        .{ .src = "content.removeEventListener('basic', cbk)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
    };
    try checkCases(js_env, &basic_remove);

    var basic_capture_remove = [_]Case{
        .{ .src = "nb  = 0", .ex = "0" },
        .{ .src = "content.removeEventListener('basic', cbk, true)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('basic'))", .ex = "true" },
        .{ .src = "nb", .ex = "0" },
    };
    try checkCases(js_env, &basic_capture_remove);

    var capture = [_]Case{
        .{ .src = "nb = 0; evt = undefined; phase = undefined; cur = undefined", .ex = "undefined" },
        .{ .src = "content.addEventListener('capture', cbk, true)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('capture'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "capture" },
        .{ .src = "phase", .ex = "2" },
        .{ .src = "cur.getAttribute('id')", .ex = "content" },
    };
    try checkCases(js_env, &capture);

    var capture_child = [_]Case{
        .{ .src = "nb = 0; evt = undefined; phase = undefined; cur = undefined", .ex = "undefined" },
        .{ .src = "para.dispatchEvent(new Event('capture'))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "capture" },
        .{ .src = "phase", .ex = "1" },
        .{ .src = "cur.getAttribute('id')", .ex = "content" },
    };
    try checkCases(js_env, &capture_child);

    var bubbles = [_]Case{
        .{ .src = "nb = 0; evt = undefined; phase = undefined; cur = undefined", .ex = "undefined" },
        .{ .src = "content.addEventListener('bubbles', cbk)", .ex = "undefined" },
        .{ .src = "content.dispatchEvent(new Event('bubbles', {bubbles: true}))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "bubbles" },
        .{ .src = "evt.bubbles", .ex = "true" },
        .{ .src = "phase", .ex = "2" },
        .{ .src = "cur.getAttribute('id')", .ex = "content" },
    };
    try checkCases(js_env, &bubbles);

    var bubbles_child = [_]Case{
        .{ .src = "nb = 0; evt = undefined; phase = undefined; cur = undefined", .ex = "undefined" },
        .{ .src = "para.dispatchEvent(new Event('bubbles', {bubbles: true}))", .ex = "true" },
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt instanceof Event", .ex = "true" },
        .{ .src = "evt.type", .ex = "bubbles" },
        .{ .src = "phase", .ex = "3" },
        .{ .src = "cur.getAttribute('id')", .ex = "content" },
    };
    try checkCases(js_env, &bubbles_child);
}

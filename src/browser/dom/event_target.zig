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

const Env = @import("../env.zig").Env;
const parser = @import("../netsurf.zig");
const SessionState = @import("../env.zig").SessionState;

const EventHandler = @import("../events/event.zig").EventHandler;

const DOMException = @import("exceptions.zig").DOMException;
const Nod = @import("node.zig");

// EventTarget interfaces
pub const Union = Nod.Union;

// EventTarget implementation
pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;

    pub fn toInterface(et: *parser.EventTarget) !Union {
        // NOTE: for now we state that all EventTarget are Nodes
        // TODO: handle other types (eg. Window)
        return Nod.Node.toInterface(@as(*parser.Node, @ptrCast(et)));
    }

    // JS funcs
    // --------

    pub fn _addEventListener(
        self: *parser.EventTarget,
        eventType: []const u8,
        cbk: Env.Callback,
        capture: ?bool,
        state: *SessionState,
        // TODO: hanle EventListenerOptions
        // see #https://github.com/lightpanda-io/jsruntime-lib/issues/114
    ) !void {
        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(
            self,
            eventType,
            capture orelse false,
            cbk.id,
        );
        if (lst != null) {
            return;
        }

        try parser.eventTargetAddEventListener(
            self,
            state.arena,
            eventType,
            EventHandler,
            .{ .cbk = cbk },
            capture orelse false,
        );
    }

    pub fn _removeEventListener(
        self: *parser.EventTarget,
        eventType: []const u8,
        cbk: Env.Callback,
        capture: ?bool,
        state: *SessionState,
        // TODO: hanle EventListenerOptions
        // see #https://github.com/lightpanda-io/jsruntime-lib/issues/114
    ) !void {
        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(
            self,
            eventType,
            capture orelse false,
            cbk.id,
        );
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(
            self,
            state.arena,
            eventType,
            lst.?,
            capture orelse false,
        );
    }

    pub fn _dispatchEvent(self: *parser.EventTarget, event: *parser.Event) !bool {
        return try parser.eventTargetDispatchEvent(self, event);
    }

    pub fn deinit(self: *parser.EventTarget, state: *SessionState) void {
        parser.eventTargetRemoveAllEventListeners(self, state.arena) catch unreachable;
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.EventTarget" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let content = document.getElementById('content')", "undefined" },
        .{ "let para = document.getElementById('para')", "undefined" },
        // NOTE: as some event properties will change during the event dispatching phases
        // we need to copy thoses values in order to check them afterwards
        .{
            \\ var nb = 0; var evt; var phase; var cur;
            \\ function cbk(event) {
            \\   evt = event;
            \\   phase = event.eventPhase;
            \\   cur = event.currentTarget;
            \\   nb ++;
            \\ }
            ,
            "undefined",
        },
    }, .{});

    try runner.testCases(&.{
        .{ "content.addEventListener('basic', cbk)", "undefined" },
        .{ "content.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "1" },
        .{ "evt instanceof Event", "true" },
        .{ "evt.type", "basic" },
        .{ "phase", "2" },
        .{ "cur.getAttribute('id')", "content" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0; evt = undefined; phase = undefined; cur = undefined", "undefined" },
        .{ "para.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "0" }, // handler is not called, no capture, not the target, no bubbling
        .{ "evt === undefined", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb  = 0", "0" },
        .{ "content.addEventListener('basic', cbk)", "undefined" },
        .{ "content.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb  = 0", "0" },
        .{ "content.addEventListener('basic', cbk, true)", "undefined" },
        .{ "content.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "2" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb  = 0", "0" },
        .{ "content.removeEventListener('basic', cbk)", "undefined" },
        .{ "content.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb  = 0", "0" },
        .{ "content.removeEventListener('basic', cbk, true)", "undefined" },
        .{ "content.dispatchEvent(new Event('basic'))", "true" },
        .{ "nb", "0" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0; evt = undefined; phase = undefined; cur = undefined", "undefined" },
        .{ "content.addEventListener('capture', cbk, true)", "undefined" },
        .{ "content.dispatchEvent(new Event('capture'))", "true" },
        .{ "nb", "1" },
        .{ "evt instanceof Event", "true" },
        .{ "evt.type", "capture" },
        .{ "phase", "2" },
        .{ "cur.getAttribute('id')", "content" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0; evt = undefined; phase = undefined; cur = undefined", "undefined" },
        .{ "para.dispatchEvent(new Event('capture'))", "true" },
        .{ "nb", "1" },
        .{ "evt instanceof Event", "true" },
        .{ "evt.type", "capture" },
        .{ "phase", "1" },
        .{ "cur.getAttribute('id')", "content" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0; evt = undefined; phase = undefined; cur = undefined", "undefined" },
        .{ "content.addEventListener('bubbles', cbk)", "undefined" },
        .{ "content.dispatchEvent(new Event('bubbles', {bubbles: true}))", "true" },
        .{ "nb", "1" },
        .{ "evt instanceof Event", "true" },
        .{ "evt.type", "bubbles" },
        .{ "evt.bubbles", "true" },
        .{ "phase", "2" },
        .{ "cur.getAttribute('id')", "content" },
    }, .{});

    try runner.testCases(&.{
        .{ "nb = 0; evt = undefined; phase = undefined; cur = undefined", "undefined" },
        .{ "para.dispatchEvent(new Event('bubbles', {bubbles: true}))", "true" },
        .{ "nb", "1" },
        .{ "evt instanceof Event", "true" },
        .{ "evt.type", "bubbles" },
        .{ "phase", "3" },
        .{ "cur.getAttribute('id')", "content" },
    }, .{});
}

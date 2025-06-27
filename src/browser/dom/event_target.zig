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

const Env = @import("../env.zig").Env;
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const EventHandler = @import("../events/event.zig").EventHandler;

const DOMException = @import("exceptions.zig").DOMException;
const Nod = @import("node.zig");

// EventTarget interfaces
pub const Union = Nod.Union;

// EventTarget implementation
pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;

    pub fn toInterface(e: *parser.Event, et: *parser.EventTarget, page: *Page) !Union {
        // libdom assumes that all event targets are libdom nodes. They are not.

        // The window is a common non-node target, but it's easy to handle as
        // its a singleton.
        if (@intFromPtr(et) == @intFromPtr(&page.window.base)) {
            return .{ .Window = &page.window };
        }

        // AbortSignal is another non-node target. It has a distinct usage though
        // so we hijack the event internal type to identity if.
        switch (try parser.eventGetInternalType(e)) {
            .abort_signal => {
                return .{ .AbortSignal = @fieldParentPtr("proto", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
            else => {
                // some of these probably need to be special-cased like abort_signal
                return Nod.Node.toInterface(@as(*parser.Node, @ptrCast(et)));
            },
        }
    }

    // JS funcs
    // --------
    pub fn _addEventListener(
        self: *parser.EventTarget,
        typ: []const u8,
        listener: EventHandler.Listener,
        opts: ?EventHandler.Opts,
        page: *Page,
    ) !void {
        _ = try EventHandler.register(page.arena, self, typ, listener, opts);
    }

    const RemoveEventListenerOpts = union(enum) {
        opts: Opts,
        capture: bool,

        const Opts = struct {
            capture: ?bool,
        };
    };

    pub fn _removeEventListener(
        self: *parser.EventTarget,
        typ: []const u8,
        listener: EventHandler.Listener,
        opts_: ?RemoveEventListenerOpts,
    ) !void {
        var capture = false;
        if (opts_) |opts| {
            capture = switch (opts) {
                .capture => |c| c,
                .opts => |o| o.capture orelse false,
            };
        }

        const cbk = (try listener.callback(self)) orelse return;

        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(
            self,
            typ,
            capture,
            cbk.id,
        );
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(
            self,
            typ,
            lst.?,
            capture,
        );
    }

    pub fn _dispatchEvent(self: *parser.EventTarget, event: *parser.Event) !bool {
        return try parser.eventTargetDispatchEvent(self, event);
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
        .{ "content.removeEventListener('basic', cbk, {capture: true})", "undefined" },
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

    try runner.testCases(&.{
        .{ "const obj1 = {calls: 0, handleEvent: function() { this.calls += 1; } };", null },
        .{ "content.addEventListener('he', obj1);", null },
        .{ "content.dispatchEvent(new Event('he'));", null },
        .{ "obj1.calls", "1" },

        .{ "content.removeEventListener('he', obj1);", null },
        .{ "content.dispatchEvent(new Event('he'));", null },
        .{ "obj1.calls", "1" },
    }, .{});

    // doesn't crash on null receiver
    try runner.testCases(&.{
        .{ "content.addEventListener('he2', null);", null },
        .{ "content.dispatchEvent(new Event('he2'));", null },
    }, .{});
}

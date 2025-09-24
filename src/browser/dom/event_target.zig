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
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const EventHandler = @import("../events/event.zig").EventHandler;

const DOMException = @import("exceptions.zig").DOMException;
const nod = @import("node.zig");

pub const Union = union(enum) {
    node: nod.Union,
    xhr: *@import("../xhr/xhr.zig").XMLHttpRequest,
    plain: *parser.EventTarget,
    message_port: *@import("MessageChannel.zig").MessagePort,
    screen: *@import("../html/screen.zig").Screen,
    screen_orientation: *@import("../html/screen.zig").ScreenOrientation,
    performance: *@import("performance.zig").Performance,
    media_query_list: *@import("../html/media_query_list.zig").MediaQueryList,
};

// EventTarget implementation
pub const EventTarget = struct {
    pub const Self = parser.EventTarget;
    pub const Exception = DOMException;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .plain },

    pub fn toInterface(et: *parser.EventTarget, page: *Page) !Union {
        // libdom assumes that all event targets are libdom nodes. They are not.

        switch (parser.eventTargetInternalType(et)) {
            .libdom_node => {
                return .{ .node = try nod.Node.toInterface(@as(*parser.Node, @ptrCast(et))) };
            },
            .plain => return .{ .plain = et },
            .abort_signal => {
                // AbortSignal is a special case, it has its own internal type.
                // We return it as a node, but we need to handle it differently.
                return .{ .node = .{ .AbortSignal = @fieldParentPtr("proto", @as(*parser.EventTargetTBase, @ptrCast(et))) } };
            },
            .window => {
                // The window is a common non-node target, but it's easy to handle as its a singleton.
                std.debug.assert(@intFromPtr(et) == @intFromPtr(&page.window.base));
                return .{ .node = .{ .Window = &page.window } };
            },
            .xhr => {
                const XMLHttpRequestEventTarget = @import("../xhr/event_target.zig").XMLHttpRequestEventTarget;
                const base: *XMLHttpRequestEventTarget = @fieldParentPtr("base", @as(*parser.EventTargetTBase, @ptrCast(et)));
                return .{ .xhr = @fieldParentPtr("proto", base) };
            },
            .message_port => {
                return .{ .message_port = @fieldParentPtr("proto", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
            .screen => {
                return .{ .screen = @fieldParentPtr("proto", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
            .screen_orientation => {
                return .{ .screen_orientation = @fieldParentPtr("proto", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
            .performance => {
                return .{ .performance = @fieldParentPtr("base", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
            .media_query_list => {
                return .{ .media_query_list = @fieldParentPtr("base", @as(*parser.EventTargetTBase, @ptrCast(et))) };
            },
        }
    }

    // JS funcs
    // --------
    pub fn constructor(page: *Page) !*parser.EventTarget {
        const et = try page.arena.create(EventTarget);
        return @ptrCast(&et.base);
    }

    pub fn _addEventListener(
        self: *parser.EventTarget,
        typ: []const u8,
        listener: EventHandler.Listener,
        opts: ?EventHandler.Opts,
        page: *Page,
    ) !void {
        _ = try EventHandler.register(page.arena, self, typ, listener, opts);
        if (std.mem.eql(u8, typ, "slotchange")) {
            try page.registerSlotChangeMonitor();
        }
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

    pub fn _dispatchEvent(self: *parser.EventTarget, event: *parser.Event, page: *Page) !bool {
        const res = try parser.eventTargetDispatchEvent(self, event);

        if (!parser.eventBubbles(event) or parser.eventIsStopped(event)) {
            return res;
        }

        try page.window.dispatchForDocumentTarget(event);
        return true;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.EventTarget" {
    try testing.htmlRunner("dom/event_target.html");
}

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const log = @import("../../../log.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const EventTarget = @import("../EventTarget.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");

pub const NavigationEventTarget = @This();

_proto: *EventTarget,
_on_currententrychange: ?js.Function.Global = null,

pub fn asEventTarget(self: *NavigationEventTarget) *EventTarget {
    return self._proto;
}

const DispatchType = union(enum) {
    currententrychange: *NavigationCurrentEntryChangeEvent,
};

pub fn dispatch(self: *NavigationEventTarget, event_type: DispatchType, page: *Page) !void {
    const event, const field = blk: {
        break :blk switch (event_type) {
            .currententrychange => |cec| .{ cec.asEvent(), "_on_currententrychange" },
        };
    };
    defer if (!event._v8_handoff) event.deinit(false);

    if (comptime IS_DEBUG) {
        if (page.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "NavigationEventTarget.dispatch", .url = page.url });
            std.debug.assert(page.js.local != null);
        }
    }

    const func = @field(self, field) orelse return;

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    return page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        ls.toLocal(func),
        .{ .context = "Navigation" },
    );
}

pub fn getOnCurrentEntryChange(self: *NavigationEventTarget) ?js.Function.Global {
    return self._on_currententrychange;
}

pub fn setOnCurrentEntryChange(self: *NavigationEventTarget, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_currententrychange = try listen.persistWithThis(self);
    } else {
        self._on_currententrychange = null;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationEventTarget);

    pub const Meta = struct {
        pub const name = "NavigationEventTarget";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const oncurrententrychange = bridge.accessor(
        NavigationEventTarget.getOnCurrentEntryChange,
        NavigationEventTarget.setOnCurrentEntryChange,
        .{},
    );
};

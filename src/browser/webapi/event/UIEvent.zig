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

const String = @import("../../../string.zig").String;
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const Window = @import("../Window.zig");

const UIEvent = @This();

_type: Type,
_proto: *Event,
_detail: u32 = 0,
_view: ?*Window = null,

pub const Type = union(enum) {
    generic,
    mouse_event: *@import("MouseEvent.zig"),
    keyboard_event: *@import("KeyboardEvent.zig"),
    focus_event: *@import("FocusEvent.zig"),
    text_event: *@import("TextEvent.zig"),
};

pub const UIEventOptions = struct {
    detail: u32 = 0,
    view: ?*Window = null,
};

pub const Options = Event.inheritOptions(
    UIEvent,
    UIEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*UIEvent {
    const arena = try page.getArena(.{ .debug = "UIEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};
    const event = try page._factory.event(
        arena,
        type_string,
        UIEvent{
            ._type = .generic,
            ._proto = undefined,
            ._detail = opts.detail,
            ._view = opts.view orelse page.window,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *UIEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn as(self: *UIEvent, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *UIEvent, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == UIEvent) self else null,
        .mouse_event => |e| {
            if (T == @import("MouseEvent.zig")) return e;
            return e.is(T);
        },
        .keyboard_event => |e| return if (T == @import("KeyboardEvent.zig")) e else null,
        .focus_event => |e| return if (T == @import("FocusEvent.zig")) e else null,
        .text_event => |e| return if (T == @import("TextEvent.zig")) e else null,
    }
    return null;
}

pub fn populateFromOptions(self: *UIEvent, opts: anytype) void {
    self._detail = opts.detail;
    self._view = opts.view;
}

pub fn asEvent(self: *UIEvent) *Event {
    return self._proto;
}

pub fn getDetail(self: *UIEvent) u32 {
    return self._detail;
}

// sourceCapabilities not implemented

pub fn getView(self: *UIEvent, page: *Page) *Window {
    return self._view orelse page.window;
}

// deprecated `initUIEvent()` not implemented

pub const JsApi = struct {
    pub const bridge = js.Bridge(UIEvent);

    pub const Meta = struct {
        pub const name = "UIEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(UIEvent.deinit);
    };

    pub const constructor = bridge.constructor(UIEvent.init, .{});
    pub const detail = bridge.accessor(UIEvent.getDetail, null, .{});
    pub const view = bridge.accessor(UIEvent.getView, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: UIEvent" {
    try testing.htmlRunner("event/ui.html", .{});
}

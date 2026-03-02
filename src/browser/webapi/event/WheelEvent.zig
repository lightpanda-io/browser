// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const String = @import("../../../string.zig").String;
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const MouseEvent = @import("MouseEvent.zig");

const WheelEvent = @This();

_proto: *MouseEvent,
_delta_x: f64,
_delta_y: f64,
_delta_z: f64,
_delta_mode: u32,

pub const DOM_DELTA_PIXEL: u32 = 0x00;
pub const DOM_DELTA_LINE: u32 = 0x01;
pub const DOM_DELTA_PAGE: u32 = 0x02;

pub const WheelEventOptions = struct {
    deltaX: f64 = 0.0,
    deltaY: f64 = 0.0,
    deltaZ: f64 = 0.0,
    deltaMode: u32 = 0,
};

pub const Options = Event.inheritOptions(
    WheelEvent,
    WheelEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*WheelEvent {
    const arena = try page.getArena(.{ .debug = "WheelEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};

    const event = try page._factory.mouseEvent(
        arena,
        type_string,
        MouseEvent{
            ._type = .{ .wheel_event = undefined },
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = std.meta.intToEnum(MouseEvent.MouseButton, opts.button) catch return error.TypeError,
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
        },
        WheelEvent{
            ._proto = undefined,
            ._delta_x = opts.deltaX,
            ._delta_y = opts.deltaY,
            ._delta_z = opts.deltaZ,
            ._delta_mode = opts.deltaMode,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *WheelEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *WheelEvent) *Event {
    return self._proto.asEvent();
}

pub fn getDeltaX(self: *const WheelEvent) f64 {
    return self._delta_x;
}

pub fn getDeltaY(self: *const WheelEvent) f64 {
    return self._delta_y;
}

pub fn getDeltaZ(self: *const WheelEvent) f64 {
    return self._delta_z;
}

pub fn getDeltaMode(self: *const WheelEvent) u32 {
    return self._delta_mode;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WheelEvent);

    pub const Meta = struct {
        pub const name = "WheelEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(WheelEvent.deinit);
    };

    pub const constructor = bridge.constructor(WheelEvent.init, .{});
    pub const deltaX = bridge.accessor(WheelEvent.getDeltaX, null, .{});
    pub const deltaY = bridge.accessor(WheelEvent.getDeltaY, null, .{});
    pub const deltaZ = bridge.accessor(WheelEvent.getDeltaZ, null, .{});
    pub const deltaMode = bridge.accessor(WheelEvent.getDeltaMode, null, .{});
    pub const DOM_DELTA_PIXEL = bridge.property(WheelEvent.DOM_DELTA_PIXEL, .{ .template = true });
    pub const DOM_DELTA_LINE = bridge.property(WheelEvent.DOM_DELTA_LINE, .{ .template = true });
    pub const DOM_DELTA_PAGE = bridge.property(WheelEvent.DOM_DELTA_PAGE, .{ .template = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WheelEvent" {
    try testing.htmlRunner("event/wheel.html", .{});
}

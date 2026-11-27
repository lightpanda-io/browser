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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const MouseEvent = @import("MouseEvent.zig");

const String = lp.String;

const PointerEvent = @This();

pub const Proto = MouseEvent;

const PointerType = enum {
    empty,
    mouse,
    pen,
    touch,

    fn fromString(s: []const u8) PointerType {
        if (std.mem.eql(u8, s, "")) return .empty;
        if (std.mem.eql(u8, s, "mouse")) return .mouse;
        if (std.mem.eql(u8, s, "pen")) return .pen;
        if (std.mem.eql(u8, s, "touch")) return .touch;
        return .empty;
    }

    fn toString(self: PointerType) []const u8 {
        return switch (self) {
            .empty => "",
            inline else => |pt| @tagName(pt),
        };
    }
};

_proto: *MouseEvent,
_pointer_id: i32,
_pointer_type: PointerType,
_width: f64,
_height: f64,
_pressure: f64,
_tangential_pressure: f64,
_tilt_x: i32,
_tilt_y: i32,
_twist: i32,
_altitude_angle: f64,
_azimuth_angle: f64,
_is_primary: bool,

const PointerEventOptions = struct {
    altitudeAngle: f64 = std.math.pi / 2.0,
    azimuthAngle: f64 = 0.0,
    height: f64 = 1.0,
    isPrimary: bool = false,
    pointerId: i32 = 0,
    pointerType: []const u8 = "",
    pressure: f64 = 0.0,
    tangentialPressure: f64 = 0.0,
    tiltX: i32 = 0,
    tiltY: i32 = 0,
    twist: i32 = 0,
    width: f64 = 1.0,
};

const Options = Event.inheritOptions(
    PointerEvent,
    PointerEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*PointerEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*PointerEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*PointerEvent {
    const arena = try frame.getArena(.tiny, "PointerEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.mouseEvent(
        arena,
        type_string,
        MouseEvent{
            ._type = .{ .pointer_event = undefined },
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = @truncate(opts.button),
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
        },
        PointerEvent{
            ._proto = undefined,
            ._pointer_id = opts.pointerId,
            ._pointer_type = PointerType.fromString(opts.pointerType),
            ._width = opts.width,
            ._height = opts.height,
            ._pressure = opts.pressure,
            ._tangential_pressure = opts.tangentialPressure,
            ._tilt_x = opts.tiltX,
            ._tilt_y = opts.tiltY,
            ._twist = opts.twist,
            ._altitude_angle = opts.altitudeAngle,
            ._azimuth_angle = opts.azimuthAngle,
            ._is_primary = opts.isPrimary,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *PointerEvent) *Event {
    return self._proto.asEvent();
}

fn getPointerType(self: *const PointerEvent) []const u8 {
    return self._pointer_type.toString();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PointerEvent);

    pub const Meta = struct {
        pub const name = "PointerEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PointerEvent.init, .{});
    pub const pointerId = bridge.fastAccessor("_pointer_id", null);
    pub const pointerType = bridge.accessor(PointerEvent.getPointerType, null, .{});
    pub const width = bridge.fastAccessor("_width", null);
    pub const height = bridge.fastAccessor("_height", null);
    pub const pressure = bridge.fastAccessor("_pressure", null);
    pub const tangentialPressure = bridge.fastAccessor("_tangential_pressure", null);
    pub const tiltX = bridge.fastAccessor("_tilt_x", null);
    pub const tiltY = bridge.fastAccessor("_tilt_y", null);
    pub const twist = bridge.fastAccessor("_twist", null);
    pub const altitudeAngle = bridge.fastAccessor("_altitude_angle", null);
    pub const azimuthAngle = bridge.fastAccessor("_azimuth_angle", null);
    pub const isPrimary = bridge.fastAccessor("_is_primary", null);
};

const testing = @import("../../../testing.zig");
test "WebApi: PointerEvent" {
    try testing.htmlRunner("event/pointer.html", .{});
}

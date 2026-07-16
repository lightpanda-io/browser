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

const String = lp.String;
const Allocator = std.mem.Allocator;

// https://w3c.github.io/deviceorientation/#devicemotionevent
const DeviceMotionEvent = @This();

_proto: *Event,
_interval: f64 = 0,

const DeviceMotionEventOptions = struct {
    interval: f64 = 0,
};

const Options = Event.inheritOptions(DeviceMotionEvent, DeviceMotionEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*DeviceMotionEvent {
    const arena = try frame.getArena(.tiny, "DeviceMotionEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.event(
        arena,
        type_string,
        DeviceMotionEvent{
            ._proto = undefined,
            ._interval = opts.interval,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn asEvent(self: *DeviceMotionEvent) *Event {
    return self._proto;
}

// There is no motion sensor: the acceleration and rotation members are null.
pub fn getAcceleration(_: *const DeviceMotionEvent) ?bool {
    return null;
}

pub fn getAccelerationIncludingGravity(_: *const DeviceMotionEvent) ?bool {
    return null;
}

pub fn getRotationRate(_: *const DeviceMotionEvent) ?bool {
    return null;
}

pub fn getInterval(self: *const DeviceMotionEvent) f64 {
    return self._interval;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DeviceMotionEvent);

    pub const Meta = struct {
        pub const name = "DeviceMotionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DeviceMotionEvent.init, .{});
    pub const acceleration = bridge.accessor(DeviceMotionEvent.getAcceleration, null, .{});
    pub const accelerationIncludingGravity = bridge.accessor(DeviceMotionEvent.getAccelerationIncludingGravity, null, .{});
    pub const rotationRate = bridge.accessor(DeviceMotionEvent.getRotationRate, null, .{});
    pub const interval = bridge.accessor(DeviceMotionEvent.getInterval, null, .{});
};

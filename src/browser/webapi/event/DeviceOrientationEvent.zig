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

// https://w3c.github.io/deviceorientation/#deviceorientationevent
const DeviceOrientationEvent = @This();

_proto: *Event,
_alpha: ?f64 = null,
_beta: ?f64 = null,
_gamma: ?f64 = null,
_absolute: bool = false,

const DeviceOrientationEventOptions = struct {
    alpha: ?f64 = null,
    beta: ?f64 = null,
    gamma: ?f64 = null,
    absolute: bool = false,
};

const Options = Event.inheritOptions(DeviceOrientationEvent, DeviceOrientationEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*DeviceOrientationEvent {
    const arena = try frame.getArena(.tiny, "DeviceOrientationEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.event(
        arena,
        type_string,
        DeviceOrientationEvent{
            ._proto = undefined,
            ._alpha = opts.alpha,
            ._beta = opts.beta,
            ._gamma = opts.gamma,
            ._absolute = opts.absolute,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn asEvent(self: *DeviceOrientationEvent) *Event {
    return self._proto;
}

pub fn getAlpha(self: *const DeviceOrientationEvent) ?f64 {
    return self._alpha;
}

pub fn getBeta(self: *const DeviceOrientationEvent) ?f64 {
    return self._beta;
}

pub fn getGamma(self: *const DeviceOrientationEvent) ?f64 {
    return self._gamma;
}

pub fn getAbsolute(self: *const DeviceOrientationEvent) bool {
    return self._absolute;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DeviceOrientationEvent);

    pub const Meta = struct {
        pub const name = "DeviceOrientationEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DeviceOrientationEvent.init, .{});
    pub const alpha = bridge.accessor(DeviceOrientationEvent.getAlpha, null, .{});
    pub const beta = bridge.accessor(DeviceOrientationEvent.getBeta, null, .{});
    pub const gamma = bridge.accessor(DeviceOrientationEvent.getGamma, null, .{});
    pub const absolute = bridge.accessor(DeviceOrientationEvent.getAbsolute, null, .{});
};

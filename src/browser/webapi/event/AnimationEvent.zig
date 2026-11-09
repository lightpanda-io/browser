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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");

const String = lp.String;

// https://drafts.csswg.org/css-animations-1/#interface-animationevent
const AnimationEvent = @This();

pub const Proto = Event;

_proto: *Event,
_animation_name: []const u8,
_elapsed_time: f64,
_pseudo_element: []const u8,

const AnimationEventOptions = struct {
    animationName: []const u8 = "",
    elapsedTime: f64 = 0,
    pseudoElement: []const u8 = "",
};

const Options = Event.inheritOptions(AnimationEvent, AnimationEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*AnimationEvent {
    const arena = try frame.getArena(.tiny, "AnimationEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*AnimationEvent {
    const arena = try frame.getArena(.tiny, "AnimationEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*AnimationEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        AnimationEvent{
            ._proto = undefined,
            ._animation_name = try arena.dupe(u8, opts.animationName),
            ._elapsed_time = opts.elapsedTime,
            ._pseudo_element = try arena.dupe(u8, opts.pseudoElement),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *AnimationEvent) *Event {
    return self._proto;
}

fn getAnimationName(self: *const AnimationEvent) []const u8 {
    return self._animation_name;
}

fn getElapsedTime(self: *const AnimationEvent) f64 {
    return self._elapsed_time;
}

fn getPseudoElement(self: *const AnimationEvent) []const u8 {
    return self._pseudo_element;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimationEvent);

    pub const Meta = struct {
        pub const name = "AnimationEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AnimationEvent.init, .{});
    pub const animationName = bridge.accessor(AnimationEvent.getAnimationName, null, .{});
    pub const elapsedTime = bridge.accessor(AnimationEvent.getElapsedTime, null, .{});
    pub const pseudoElement = bridge.accessor(AnimationEvent.getPseudoElement, null, .{});
};

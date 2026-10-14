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

// https://drafts.csswg.org/web-animations-1/#the-animationplaybackevent-interface
const AnimationPlaybackEvent = @This();

pub const Proto = Event;

_proto: *Event,
_current_time: ?f64,
_timeline_time: ?f64,

const AnimationPlaybackEventOptions = struct {
    currentTime: ?f64 = null,
    timelineTime: ?f64 = null,
};

const Options = Event.inheritOptions(AnimationPlaybackEvent, AnimationPlaybackEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*AnimationPlaybackEvent {
    const arena = try frame.getArena(.tiny, "AnimationPlaybackEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*AnimationPlaybackEvent {
    const arena = try frame.getArena(.tiny, "AnimationPlaybackEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*AnimationPlaybackEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        AnimationPlaybackEvent{
            ._proto = undefined,
            ._current_time = opts.currentTime,
            ._timeline_time = opts.timelineTime,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *AnimationPlaybackEvent) *Event {
    return self._proto;
}

fn getCurrentTime(self: *const AnimationPlaybackEvent) ?f64 {
    return self._current_time;
}

fn getTimelineTime(self: *const AnimationPlaybackEvent) ?f64 {
    return self._timeline_time;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimationPlaybackEvent);

    pub const Meta = struct {
        pub const name = "AnimationPlaybackEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AnimationPlaybackEvent.init, .{});
    pub const currentTime = bridge.accessor(AnimationPlaybackEvent.getCurrentTime, null, .{});
    pub const timelineTime = bridge.accessor(AnimationPlaybackEvent.getTimelineTime, null, .{});
};

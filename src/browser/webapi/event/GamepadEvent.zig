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

// https://w3c.github.io/gamepad/#gamepadevent-interface
const GamepadEvent = @This();

_proto: *Event,

const GamepadEventOptions = struct {};

const Options = Event.inheritOptions(GamepadEvent, GamepadEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*GamepadEvent {
    const arena = try frame.getArena(.tiny, "GamepadEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.event(
        arena,
        type_string,
        GamepadEvent{
            ._proto = undefined,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn asEvent(self: *GamepadEvent) *Event {
    return self._proto;
}

// There are no gamepads in a headless browser.
pub fn getGamepad(_: *const GamepadEvent) ?bool {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GamepadEvent);

    pub const Meta = struct {
        pub const name = "GamepadEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(GamepadEvent.init, .{});
    pub const gamepad = bridge.accessor(GamepadEvent.getGamepad, null, .{});
};

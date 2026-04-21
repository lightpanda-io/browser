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
const UIEvent = @import("UIEvent.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const InputEvent = @This();

_proto: *UIEvent,
_data: ?[]const u8,
// TODO: add dataTransfer
_input_type: []const u8,
_is_composing: bool,

pub const InputEventOptions = struct {
    data: ?[]const u8 = null,
    inputType: ?[]const u8 = null,
    isComposing: bool = false,
};

const Options = Event.inheritOptions(
    InputEvent,
    InputEventOptions,
);

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*InputEvent {
    const arena = try frame.getArena(.tiny, "InputEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*InputEvent {
    const arena = try frame.getArena(.tiny, "InputEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*InputEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
        arena,
        typ,
        InputEvent{
            ._proto = undefined,
            ._data = if (opts.data) |d| try arena.dupe(u8, d) else null,
            ._input_type = if (opts.inputType) |it| try arena.dupe(u8, it) else "",
            ._is_composing = opts.isComposing,
        },
    );

    Event.populatePrototypes(event, opts, trusted);

    // https://developer.mozilla.org/en-US/docs/Web/API/Element/input_event
    const rootevt = event._proto._proto;
    rootevt._bubbles = true;
    rootevt._cancelable = false;
    rootevt._composed = true;

    return event;
}

pub fn asEvent(self: *InputEvent) *Event {
    return self._proto.asEvent();
}

pub fn getData(self: *const InputEvent) ?[]const u8 {
    return self._data;
}

pub fn getInputType(self: *const InputEvent) []const u8 {
    return self._input_type;
}

pub fn getIsComposing(self: *const InputEvent) bool {
    return self._is_composing;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(InputEvent);

    pub const Meta = struct {
        pub const name = "InputEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(InputEvent.init, .{});
    pub const data = bridge.accessor(InputEvent.getData, null, .{});
    pub const inputType = bridge.accessor(InputEvent.getInputType, null, .{});
    pub const isComposing = bridge.accessor(InputEvent.getIsComposing, null, .{});
};

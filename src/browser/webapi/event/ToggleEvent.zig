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
const HtmlElement = @import("../element/Html.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

/// https://html.spec.whatwg.org/multipage/popover.html#toggleevent
const ToggleEvent = @This();

_proto: *Event,
_old_state: []const u8 = "",
_new_state: []const u8 = "",
_source: ?*HtmlElement = null,

const ToggleEventOptions = struct {
    oldState: []const u8 = "",
    newState: []const u8 = "",
    source: ?*HtmlElement = null,
};

const Options = Event.inheritOptions(ToggleEvent, ToggleEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*ToggleEvent {
    const arena = try frame.getArena(.tiny, "ToggleEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*ToggleEvent {
    const arena = try frame.getArena(.tiny, "ToggleEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*ToggleEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        ToggleEvent{
            ._proto = undefined,
            ._old_state = if (opts.oldState.len > 0) try arena.dupe(u8, opts.oldState) else "",
            ._new_state = if (opts.newState.len > 0) try arena.dupe(u8, opts.newState) else "",
            ._source = opts.source,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *ToggleEvent) *Event {
    return self._proto;
}

pub fn getOldState(self: *const ToggleEvent) []const u8 {
    return self._old_state;
}

pub fn getNewState(self: *const ToggleEvent) []const u8 {
    return self._new_state;
}

pub fn getSource(self: *const ToggleEvent) ?*HtmlElement {
    return self._source;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ToggleEvent);

    pub const Meta = struct {
        pub const name = "ToggleEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ToggleEvent.init, .{});
    pub const oldState = bridge.accessor(ToggleEvent.getOldState, null, .{});
    pub const newState = bridge.accessor(ToggleEvent.getNewState, null, .{});
    pub const source = bridge.accessor(ToggleEvent.getSource, null, .{});
};

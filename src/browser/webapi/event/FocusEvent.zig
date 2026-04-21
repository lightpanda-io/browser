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
const EventTarget = @import("../EventTarget.zig");
const UIEvent = @import("UIEvent.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const FocusEvent = @This();

_proto: *UIEvent,
_related_target: ?*EventTarget = null,

pub const FocusEventOptions = struct {
    relatedTarget: ?*EventTarget = null,
};

pub const Options = Event.inheritOptions(
    FocusEvent,
    FocusEventOptions,
);

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*FocusEvent {
    const arena = try frame.getArena(.tiny, "FocusEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*FocusEvent {
    const arena = try frame.getArena(.tiny, "FocusEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*FocusEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
        arena,
        typ,
        FocusEvent{
            ._proto = undefined,
            ._related_target = opts.relatedTarget,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *FocusEvent) *Event {
    return self._proto.asEvent();
}

pub fn getRelatedTarget(self: *const FocusEvent) ?*EventTarget {
    return self._related_target;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FocusEvent);

    pub const Meta = struct {
        pub const name = "FocusEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FocusEvent.init, .{});
    pub const relatedTarget = bridge.accessor(FocusEvent.getRelatedTarget, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FocusEvent" {
    try testing.htmlRunner("event/focus.html", .{});
}

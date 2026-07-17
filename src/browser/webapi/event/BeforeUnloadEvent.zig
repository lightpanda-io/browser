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

// https://html.spec.whatwg.org/multipage/browsing-the-web.html#the-beforeunloadevent-interface
const BeforeUnloadEvent = @This();

_proto: *Event,
_return_value: []const u8 = "",

const Options = Event.inheritOptions(BeforeUnloadEvent, struct {});

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*BeforeUnloadEvent {
    const arena = try frame.getArena(.tiny, "BeforeUnloadEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*BeforeUnloadEvent {
    const arena = try frame.getArena(.tiny, "BeforeUnloadEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*BeforeUnloadEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        BeforeUnloadEvent{
            ._proto = undefined,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *BeforeUnloadEvent) *Event {
    return self._proto;
}

pub fn getReturnValue(self: *const BeforeUnloadEvent) []const u8 {
    return self._return_value;
}

pub fn setReturnValue(self: *BeforeUnloadEvent, value: []const u8) !void {
    self._return_value = try self._proto._arena.dupe(u8, value);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BeforeUnloadEvent);

    pub const Meta = struct {
        pub const name = "BeforeUnloadEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Per spec BeforeUnloadEvent has no constructor.
    pub const returnValue = bridge.accessor(BeforeUnloadEvent.getReturnValue, BeforeUnloadEvent.setReturnValue, .{});
};

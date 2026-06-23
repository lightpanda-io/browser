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

// https://developer.mozilla.org/en-US/docs/Web/API/HashChangeEvent
const HashChangeEvent = @This();

_proto: *Event,
_old_url: []const u8,
_new_url: []const u8,

const HashChangeEventOptions = struct {
    oldURL: []const u8 = "",
    newURL: []const u8 = "",
};

const Options = Event.inheritOptions(HashChangeEvent, HashChangeEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*HashChangeEvent {
    const arena = try frame.getArena(.tiny, "HashChangeEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*HashChangeEvent {
    const arena = try frame.getArena(.tiny, "HashChangeEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*HashChangeEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        HashChangeEvent{
            ._proto = undefined,
            ._old_url = try arena.dupe(u8, opts.oldURL),
            ._new_url = try arena.dupe(u8, opts.newURL),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *HashChangeEvent) *Event {
    return self._proto;
}

pub fn getOldURL(self: *const HashChangeEvent) []const u8 {
    return self._old_url;
}

pub fn getNewURL(self: *const HashChangeEvent) []const u8 {
    return self._new_url;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HashChangeEvent);

    pub const Meta = struct {
        pub const name = "HashChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(HashChangeEvent.init, .{});
    pub const oldURL = bridge.accessor(HashChangeEvent.getOldURL, null, .{});
    pub const newURL = bridge.accessor(HashChangeEvent.getNewURL, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: HashChangeEvent" {
    try testing.htmlRunner("event/hashchange.html", .{});
}

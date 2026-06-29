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

const js = @import("../../../js/js.zig");

const Event = @import("../../Event.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;
const Execution = js.Execution;

const IDBVersionChangeEvent = @This();

_proto: *Event,
_old_version: u64,
_new_version: ?u64,

const IDBVersionChangeEventOptions = struct {
    oldVersion: u64 = 0,
    newVersion: ?u64 = null,
};

const Options = Event.inheritOptions(IDBVersionChangeEvent, IDBVersionChangeEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, exec: *const Execution) !*IDBVersionChangeEvent {
    const arena = try exec.getArena(.tiny, "IDBVersionChangeEvent");
    errdefer exec.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, exec);
}

pub fn initTrusted(typ: String, old_version: u64, new_version: ?u64, exec: *const Execution) !*IDBVersionChangeEvent {
    const arena = try exec.getArena(.tiny, "IDBVersionChangeEvent.trusted");
    errdefer exec.releaseArena(arena);
    return initWithTrusted(arena, typ, .{ .oldVersion = old_version, .newVersion = new_version }, true, exec);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool, exec: *const Execution) !*IDBVersionChangeEvent {
    const opts = opts_ orelse Options{};

    const event = try exec._factory.event(arena, typ, IDBVersionChangeEvent{
        ._proto = undefined,
        ._old_version = opts.oldVersion,
        ._new_version = opts.newVersion,
    });

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *IDBVersionChangeEvent) *Event {
    return self._proto;
}

pub fn getOldVersion(self: *const IDBVersionChangeEvent) u64 {
    return self._old_version;
}

pub fn getNewVersion(self: *const IDBVersionChangeEvent) ?u64 {
    return self._new_version;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBVersionChangeEvent);

    pub const Meta = struct {
        pub const name = "IDBVersionChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(IDBVersionChangeEvent.init, .{});
    pub const oldVersion = bridge.accessor(IDBVersionChangeEvent.getOldVersion, null, .{});
    pub const newVersion = bridge.accessor(IDBVersionChangeEvent.getNewVersion, null, .{ .null_as_undefined = true });
};

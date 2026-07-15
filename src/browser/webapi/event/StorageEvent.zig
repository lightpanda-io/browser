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

// https://html.spec.whatwg.org/multipage/webstorage.html#the-storageevent-interface
const StorageEvent = @This();

_proto: *Event,
_key: ?[]const u8 = null,
_old_value: ?[]const u8 = null,
_new_value: ?[]const u8 = null,
_url: []const u8 = "",

const StorageEventOptions = struct {
    key: ?[]const u8 = null,
    oldValue: ?[]const u8 = null,
    newValue: ?[]const u8 = null,
    url: []const u8 = "",
};

const Options = Event.inheritOptions(StorageEvent, StorageEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*StorageEvent {
    const arena = try frame.getArena(.tiny, "StorageEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*StorageEvent {
    const arena = try frame.getArena(.tiny, "StorageEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*StorageEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        StorageEvent{
            ._proto = undefined,
            ._key = if (opts.key) |k| try arena.dupe(u8, k) else null,
            ._old_value = if (opts.oldValue) |v| try arena.dupe(u8, v) else null,
            ._new_value = if (opts.newValue) |v| try arena.dupe(u8, v) else null,
            ._url = try arena.dupe(u8, opts.url),
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *StorageEvent) *Event {
    return self._proto;
}

pub fn getKey(self: *const StorageEvent) ?[]const u8 {
    return self._key;
}

pub fn getOldValue(self: *const StorageEvent) ?[]const u8 {
    return self._old_value;
}

pub fn getNewValue(self: *const StorageEvent) ?[]const u8 {
    return self._new_value;
}

pub fn getUrl(self: *const StorageEvent) []const u8 {
    return self._url;
}

// The initiating Storage object is not tracked; always null.
pub fn getStorageArea(_: *const StorageEvent) ?bool {
    return null;
}

pub fn initStorageEvent(
    self: *StorageEvent,
    typ: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    key: ?[]const u8,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
    url: ?[]const u8,
) !void {
    const event = self._proto;
    if (event._event_phase != .none) {
        return;
    }

    const arena = event._arena;
    event._initialized = true;
    event._type_string = try String.init(arena, typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    self._key = if (key) |k| try arena.dupe(u8, k) else null;
    self._old_value = if (old_value) |v| try arena.dupe(u8, v) else null;
    self._new_value = if (new_value) |v| try arena.dupe(u8, v) else null;
    self._url = if (url) |u| try arena.dupe(u8, u) else "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageEvent);

    pub const Meta = struct {
        pub const name = "StorageEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(StorageEvent.init, .{});
    pub const key = bridge.accessor(StorageEvent.getKey, null, .{});
    pub const oldValue = bridge.accessor(StorageEvent.getOldValue, null, .{});
    pub const newValue = bridge.accessor(StorageEvent.getNewValue, null, .{});
    pub const url = bridge.accessor(StorageEvent.getUrl, null, .{});
    pub const storageArea = bridge.accessor(StorageEvent.getStorageArea, null, .{});
    pub const initStorageEvent = bridge.function(StorageEvent.initStorageEvent, .{});
};

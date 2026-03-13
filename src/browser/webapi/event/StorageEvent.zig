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

const String = @import("../../../string.zig").String;
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const storage = @import("../storage/storage.zig");
const Allocator = std.mem.Allocator;

const StorageEvent = @This();

_proto: *Event,
_key: ?[]const u8 = null,
_old_value: ?[]const u8 = null,
_new_value: ?[]const u8 = null,
_url: []const u8 = "",
_storage_area: ?*storage.Lookup = null,

pub const StorageEventOptions = struct {
    key: ?[]const u8 = null,
    oldValue: ?[]const u8 = null,
    newValue: ?[]const u8 = null,
    url: ?[]const u8 = null,
    storageArea: ?*storage.Lookup = null,
};

const Options = Event.inheritOptions(StorageEvent, StorageEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*StorageEvent {
    const arena = try page.getArena(.{ .debug = "StorageEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*StorageEvent {
    const arena = try page.getArena(.{ .debug = "StorageEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*StorageEvent {
    const opts = opts_ orelse Options{};

    const event = try page._factory.event(
        arena,
        typ,
        StorageEvent{
            ._proto = undefined,
            ._key = if (opts.key) |value| try arena.dupe(u8, value) else null,
            ._old_value = if (opts.oldValue) |value| try arena.dupe(u8, value) else null,
            ._new_value = if (opts.newValue) |value| try arena.dupe(u8, value) else null,
            ._url = if (opts.url) |value| try arena.dupe(u8, value) else "",
            ._storage_area = opts.storageArea,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *StorageEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
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

pub fn getStorageArea(self: *const StorageEvent) ?*storage.Lookup {
    return self._storage_area;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageEvent);

    pub const Meta = struct {
        pub const name = "StorageEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(StorageEvent.deinit);
    };

    pub const constructor = bridge.constructor(StorageEvent.init, .{});
    pub const key = bridge.accessor(StorageEvent.getKey, null, .{});
    pub const oldValue = bridge.accessor(StorageEvent.getOldValue, null, .{});
    pub const newValue = bridge.accessor(StorageEvent.getNewValue, null, .{});
    pub const url = bridge.accessor(StorageEvent.getUrl, null, .{});
    pub const storageArea = bridge.accessor(StorageEvent.getStorageArea, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: StorageEvent" {
    try testing.htmlRunner("storage.html", .{});
}

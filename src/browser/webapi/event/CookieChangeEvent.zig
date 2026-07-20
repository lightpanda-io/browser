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
const Notification = @import("../../../Notification.zig");

const Event = @import("../Event.zig");
const CookieStore = @import("../storage/CookieStore.zig");

const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

// https://developer.mozilla.org/en-US/docs/Web/API/CookieChangeEvent
const CookieChangeEvent = @This();

_proto: *Event,
_changed: []CookieStore.CookieListItem,
_deleted: []CookieStore.CookieListItem,

const CookieChangeEventOptions = struct {
    changed: ?[]CookieStore.CookieListItem = null,
    deleted: ?[]CookieStore.CookieListItem = null,
};

const Options = Event.inheritOptions(CookieChangeEvent, CookieChangeEventOptions);

pub fn init(typ: []const u8, _opts: ?Options, exec: *const Execution) !*CookieChangeEvent {
    const arena = try exec.getArena(.tiny, "CookieChangeEvent");
    errdefer exec.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};

    const event = try exec._factory.event(
        arena,
        type_string,
        CookieChangeEvent{
            ._proto = undefined,
            ._changed = try cloneListItems(arena, opts.changed),
            ._deleted = try cloneListItems(arena, opts.deleted),
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

/// Internal constructor used by the change-notification dispatcher to
/// build a trusted "change" event from a single-cookie mutation snapshot.
/// The CookieListItem is materialised on the event's own arena.
pub fn initSingle(
    kind: Notification.CookieChanged.Kind,
    snapshot: Notification.CookieChanged,
    exec: *const Execution,
) !*CookieChangeEvent {
    const arena = try exec.getArena(.tiny, "CookieChangeEvent");
    errdefer exec.releaseArena(arena);
    const type_string = try String.init(arena, "change", .{});

    const item = try arena.create(CookieStore.CookieListItem);
    item.* = .{
        .name = try String.init(arena, snapshot.name, .{}),
        // Deletions report no value (the `deleted` accessor serializes the
        // resulting null as undefined); changes carry the new value.
        .value = if (kind == .deleted) null else try String.init(arena, snapshot.value, .{}),
        .domain = if (snapshot.domain.len > 0 and snapshot.domain[0] == '.')
            try String.init(arena, snapshot.domain[1..], .{})
        else
            null,
        .path = try String.init(arena, snapshot.path, .{}),
        .expires = null,
        .secure = snapshot.secure,
        .sameSite = switch (snapshot.same_site) {
            .strict => "strict",
            .lax => "lax",
            .none => "none",
        },
        .partitioned = false,
    };

    const event = try exec._factory.event(
        arena,
        type_string,
        CookieChangeEvent{
            ._proto = undefined,
            ._changed = if (kind == .changed) item[0..1] else &.{},
            ._deleted = if (kind == .deleted) item[0..1] else &.{},
        },
    );

    Event.populatePrototypes(event, Options{}, true);
    return event;
}

// Passed in from V8, everything is call_arena allocated, need to dupe it into our arena.
fn cloneListItems(arena: Allocator, items_: ?[]CookieStore.CookieListItem) ![]CookieStore.CookieListItem {
    const items = items_ orelse return &.{};
    const out = try arena.alloc(CookieStore.CookieListItem, items.len);
    for (items, out) |src, *dst| {
        dst.* = .{
            .name = try String.init(arena, src.name.str(), .{}),
            .value = if (src.value) |v| try String.init(arena, v.str(), .{}) else null,
            .domain = if (src.domain) |d| try String.init(arena, d.str(), .{}) else null,
            .path = try String.init(arena, src.path.str(), .{}),
            .expires = src.expires,
            .secure = src.secure,
            .sameSite = try arena.dupe(u8, src.sameSite),
            .partitioned = src.partitioned,
        };
    }
    return out;
}

pub fn asEvent(self: *CookieChangeEvent) *Event {
    return self._proto;
}

pub fn getChanged(self: *const CookieChangeEvent) []CookieStore.CookieListItem {
    return self._changed;
}

pub fn getDeleted(self: *const CookieChangeEvent) []CookieStore.CookieListItem {
    return self._deleted;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CookieChangeEvent);

    pub const Meta = struct {
        pub const name = "CookieChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CookieChangeEvent.init, .{});
    pub const changed = bridge.accessor(CookieChangeEvent.getChanged, null, .{});
    // null_as_undefined trickles down to the serialization of the CookieListItem fields
    pub const deleted = bridge.accessor(CookieChangeEvent.getDeleted, null, .{ .null_as_undefined = true });
};

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const NavigationHistoryEntry = @import("../navigation/NavigationHistoryEntry.zig");
const NavigationType = @import("../navigation/root.zig").NavigationType;
const Allocator = std.mem.Allocator;

const NavigationCurrentEntryChangeEvent = @This();

_proto: *Event,
_from: *NavigationHistoryEntry,
_navigation_type: ?NavigationType,

const NavigationCurrentEntryChangeEventOptions = struct {
    from: *NavigationHistoryEntry,
    navigationType: ?[]const u8 = null,
};

const Options = Event.inheritOptions(
    NavigationCurrentEntryChangeEvent,
    NavigationCurrentEntryChangeEventOptions,
);

pub fn init(typ: []const u8, opts: Options, page: *Page) !*NavigationCurrentEntryChangeEvent {
    const arena = try page.getArena(.{ .debug = "NavigationCurrentEntryChangeEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts, false, page);
}

pub fn initTrusted(typ: String, opts: Options, page: *Page) !*NavigationCurrentEntryChangeEvent {
    const arena = try page.getArena(.{ .debug = "NavigationCurrentEntryChangeEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts, true, page);
}

fn initWithTrusted(
    arena: Allocator,
    typ: String,
    opts: Options,
    trusted: bool,
    page: *Page,
) !*NavigationCurrentEntryChangeEvent {
    const navigation_type = if (opts.navigationType) |nav_type_str|
        std.meta.stringToEnum(NavigationType, nav_type_str)
    else
        null;

    const event = try page._factory.event(
        arena,
        typ,
        NavigationCurrentEntryChangeEvent{
            ._proto = undefined,
            ._from = opts.from,
            ._navigation_type = navigation_type,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *NavigationCurrentEntryChangeEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
}

pub fn asEvent(self: *NavigationCurrentEntryChangeEvent) *Event {
    return self._proto;
}

pub fn getFrom(self: *NavigationCurrentEntryChangeEvent) *NavigationHistoryEntry {
    return self._from;
}

pub fn getNavigationType(self: *const NavigationCurrentEntryChangeEvent) ?[]const u8 {
    return if (self._navigation_type) |nav_type| @tagName(nav_type) else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationCurrentEntryChangeEvent);

    pub const Meta = struct {
        pub const name = "NavigationCurrentEntryChangeEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(NavigationCurrentEntryChangeEvent.deinit);
    };

    pub const constructor = bridge.constructor(NavigationCurrentEntryChangeEvent.init, .{});
    pub const from = bridge.accessor(NavigationCurrentEntryChangeEvent.getFrom, null, .{});
    pub const navigationType = bridge.accessor(NavigationCurrentEntryChangeEvent.getNavigationType, null, .{});
};

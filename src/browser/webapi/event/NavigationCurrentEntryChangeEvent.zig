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
const Event = @import("../Event.zig");
const Page = @import("../../Page.zig");
const Navigaton = @import("../navigation/Navigation.zig");
const NavigationHistoryEntry = @import("../navigation/NavigationHistoryEntry.zig");
const NavigationType = @import("../navigation/root.zig").NavigationType;
const js = @import("../../js/js.zig");

const NavigationCurrentEntryChangeEvent = @This();

_proto: *Event,
_from: *NavigationHistoryEntry,
_navigation_type: ?NavigationType,

pub const EventInit = struct {
    from: *NavigationHistoryEntry,
    navigationType: ?[]const u8 = null,
};

pub fn init(
    typ: []const u8,
    init_obj: EventInit,
    page: *Page,
) !*NavigationCurrentEntryChangeEvent {
    const navigation_type = if (init_obj.navigationType) |nav_type_str|
        std.meta.stringToEnum(NavigationType, nav_type_str)
    else
        null;

    return page._factory.event(typ, NavigationCurrentEntryChangeEvent{
        ._proto = undefined,
        ._from = init_obj.from,
        ._navigation_type = navigation_type,
    });
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
    };

    pub const constructor = bridge.constructor(NavigationCurrentEntryChangeEvent.init, .{});
    pub const from = bridge.accessor(NavigationCurrentEntryChangeEvent.getFrom, null, .{});
    pub const navigationType = bridge.accessor(NavigationCurrentEntryChangeEvent.getNavigationType, null, .{});
};

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
const js = @import("../../js/js.zig");

const NavigationType = @import("root.zig").NavigationType;
const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationActivation
const NavigationActivation = @This();

_entry: *NavigationHistoryEntry,
_from: ?*NavigationHistoryEntry = null,
_type: NavigationType,

pub fn getEntry(self: *const NavigationActivation) *NavigationHistoryEntry {
    return self._entry;
}

pub fn getFrom(self: *const NavigationActivation) ?*NavigationHistoryEntry {
    return self._from;
}

pub fn getNavigationType(self: *const NavigationActivation) []const u8 {
    return @tagName(self._type);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationActivation);

    pub const Meta = struct {
        pub const name = "NavigationActivation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const entry = bridge.accessor(NavigationActivation.getEntry, null, .{});
    pub const from = bridge.accessor(NavigationActivation.getFrom, null, .{});
    pub const navigationType = bridge.accessor(NavigationActivation.getNavigationType, null, .{});
};

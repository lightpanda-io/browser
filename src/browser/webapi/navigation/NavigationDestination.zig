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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationDestination
const NavigationDestination = @This();

_url: []const u8,
_entry: ?*NavigationHistoryEntry = null,
_same_document: bool,
// null for the History API and plain navigations (getState() is then undefined)
_state: ?[]const u8 = null,

fn getUrl(self: *const NavigationDestination) []const u8 {
    return self._url;
}

fn getKey(self: *const NavigationDestination) []const u8 {
    const entry = self._entry orelse return "";
    return entry._key;
}

fn getId(self: *const NavigationDestination) []const u8 {
    const entry = self._entry orelse return "";
    return entry._id;
}

// Live, like Chrome: -1 once the entry has left the history.
fn getIndex(self: *const NavigationDestination, frame: *Frame) i64 {
    const entry = self._entry orelse return -1;
    return entry.index(frame);
}

fn getSameDocument(self: *const NavigationDestination) bool {
    return self._same_document;
}

const StateReturn = union(enum) { value: ?js.Value, undefined: void };

fn getState(self: *const NavigationDestination, frame: *Frame) !StateReturn {
    const state = self._state orelse return .undefined;
    return .{ .value = try frame.js.local.?.parseJSON(state) };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationDestination);

    pub const Meta = struct {
        pub const name = "NavigationDestination";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const url = bridge.accessor(NavigationDestination.getUrl, null, .{});
    pub const key = bridge.accessor(NavigationDestination.getKey, null, .{});
    pub const id = bridge.accessor(NavigationDestination.getId, null, .{});
    pub const index = bridge.accessor(NavigationDestination.getIndex, null, .{});
    pub const sameDocument = bridge.accessor(NavigationDestination.getSameDocument, null, .{});
    pub const getState = bridge.function(NavigationDestination.getState, .{});
};

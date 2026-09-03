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

const lp = @import("lightpanda");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const NavigationType = @import("root.zig").NavigationType;
const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/NavigationDestination
const NavigationDestination = @This();

_arena: *lp.Arena,
_id: []const u8,
_index: i32,
_key: []const u8,
_same_document: bool,
_url: []const u8,
_state: ?js.Value.Global,

pub const InitOpts = struct {
    id: []const u8 = "",
    key: []const u8 = "",
    index: i32 = -1,
    same_document: bool,
    url: []const u8,
    state: ?js.Value = null,
};

pub fn init(opts: InitOpts, frame: *Frame) !*NavigationDestination {
    const arena = try frame.getArena(.tiny, "NavigationDestination");
    errdefer arena.release();

    const state: ?js.Value.Global = if (opts.state) |s| try s.persist() else null;

    const self = try arena.create(NavigationDestination);
    self.* = .{
        ._arena = arena,
        ._id = try arena.allocator().dupe(u8, opts.id),
        ._index = opts.index,
        ._key = try arena.allocator().dupe(u8, opts.key),
        ._same_document = opts.same_document,
        ._url = try arena.allocator().dupeZ(u8, opts.url),
        ._state = state,
    };

    arena.report();
    return self;
}

pub fn getUrl(self: *const NavigationDestination) []const u8 {
    return self._url;
}

pub fn getKey(self: *const NavigationDestination) []const u8 {
    return self._key;
}

pub fn getId(self: *const NavigationDestination) []const u8 {
    return self._id;
}

pub fn getIndex(self: *const NavigationDestination) i32 {
    return self._index;
}

pub fn getSameDocument(self: *const NavigationDestination) bool {
    return self._same_document;
}

pub fn getState(self: *const NavigationDestination, exec: *const js.Execution) ?js.Value {
    if (self._state) |state| {
        return exec.js.local.?.toLocal(state);
    }

    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigationDestination);

    pub const Meta = struct {
        pub const name = "NavigationDestination";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const url = bridge.accessor(NavigationDestination.getUrl, null, .{});
    pub const key = bridge.accessor(NavigationDestination.getKey, null, .{});
    pub const id = bridge.accessor(NavigationDestination.getId, null, .{});
    pub const index = bridge.accessor(NavigationDestination.getIndex, null, .{});
    pub const sameDocument = bridge.accessor(NavigationDestination.getSameDocument, null, .{});
    pub const getState = bridge.function(NavigationDestination.getState, .{});
};

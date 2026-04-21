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

const SVGStringList = @This();

const js = @import("../../js/js.zig");

_items: [max_items][]const u8 = undefined,
_length: u32 = 0,

const max_items = 64;

pub fn getLength(self: *const SVGStringList) u32 {
    return self._length;
}

pub fn getNumberOfItems(self: *const SVGStringList) u32 {
    return self._length;
}

pub fn clear(self: *SVGStringList) void {
    self._length = 0;
}

pub fn initialize(self: *SVGStringList, item: []const u8) []const u8 {
    self._items[0] = item;
    self._length = 1;
    return item;
}

pub fn getItem(self: *const SVGStringList, index: u32) ?[]const u8 {
    if (index >= self._length) return null;
    return self._items[index];
}

pub fn insertItemBefore(self: *SVGStringList, item: []const u8, index: u32) ?[]const u8 {
    if (self._length >= max_items) return null;
    const idx = @min(index, self._length);
    var i = self._length;
    while (i > idx) : (i -= 1) {
        self._items[i] = self._items[i - 1];
    }
    self._items[idx] = item;
    self._length += 1;
    return item;
}

pub fn replaceItem(self: *SVGStringList, item: []const u8, index: u32) ?[]const u8 {
    if (index >= self._length) return null;
    self._items[index] = item;
    return item;
}

pub fn removeItem(self: *SVGStringList, index: u32) ?[]const u8 {
    if (index >= self._length) return null;
    const removed = self._items[index];
    var i = index;
    while (i + 1 < self._length) : (i += 1) {
        self._items[i] = self._items[i + 1];
    }
    self._length -= 1;
    return removed;
}

pub fn appendItem(self: *SVGStringList, item: []const u8) ?[]const u8 {
    if (self._length >= max_items) return null;
    self._items[self._length] = item;
    self._length += 1;
    return item;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGStringList);

    pub const Meta = struct {
        pub const name = "SVGStringList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(SVGStringList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(SVGStringList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(SVGStringList.clear, .{});
    pub const initialize = bridge.function(SVGStringList.initialize, .{});
    pub const getItem = bridge.function(SVGStringList.getItem, .{});
    pub const insertItemBefore = bridge.function(SVGStringList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(SVGStringList.replaceItem, .{});
    pub const removeItem = bridge.function(SVGStringList.removeItem, .{});
    pub const appendItem = bridge.function(SVGStringList.appendItem, .{});
};

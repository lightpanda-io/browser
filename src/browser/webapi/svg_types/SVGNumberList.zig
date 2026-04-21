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

const SVGNumberList = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const SVGNumber = @import("SVGNumber.zig");

_items: [max_items]*SVGNumber = undefined,
_length: u32 = 0,

const max_items = 64;

pub fn getLength(self: *const SVGNumberList) u32 {
    return self._length;
}

pub fn getNumberOfItems(self: *const SVGNumberList) u32 {
    return self._length;
}

pub fn clear(self: *SVGNumberList) void {
    self._length = 0;
}

pub fn initialize(self: *SVGNumberList, item: *SVGNumber) *SVGNumber {
    self._items[0] = item;
    self._length = 1;
    return item;
}

pub fn getItem(self: *const SVGNumberList, index: u32) ?*SVGNumber {
    if (index >= self._length) return null;
    return self._items[index];
}

pub fn insertItemBefore(self: *SVGNumberList, item: *SVGNumber, index: u32) ?*SVGNumber {
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

pub fn replaceItem(self: *SVGNumberList, item: *SVGNumber, index: u32) ?*SVGNumber {
    if (index >= self._length) return null;
    self._items[index] = item;
    return item;
}

pub fn removeItem(self: *SVGNumberList, index: u32) ?*SVGNumber {
    if (index >= self._length) return null;
    const removed = self._items[index];
    var i = index;
    while (i + 1 < self._length) : (i += 1) {
        self._items[i] = self._items[i + 1];
    }
    self._length -= 1;
    return removed;
}

pub fn appendItem(self: *SVGNumberList, item: *SVGNumber) ?*SVGNumber {
    if (self._length >= max_items) return null;
    self._items[self._length] = item;
    self._length += 1;
    return item;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGNumberList);

    pub const Meta = struct {
        pub const name = "SVGNumberList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(SVGNumberList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(SVGNumberList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(SVGNumberList.clear, .{});
    pub const initialize = bridge.function(SVGNumberList.initialize, .{});
    pub const getItem = bridge.function(SVGNumberList.getItem, .{});
    pub const insertItemBefore = bridge.function(SVGNumberList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(SVGNumberList.replaceItem, .{});
    pub const removeItem = bridge.function(SVGNumberList.removeItem, .{});
    pub const appendItem = bridge.function(SVGNumberList.appendItem, .{});
};

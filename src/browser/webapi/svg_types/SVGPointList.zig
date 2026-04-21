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

const SVGPointList = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const DOMPoint = @import("../DOMPoint.zig");

_items: std.ArrayList(*DOMPoint) = .empty,
_allocator: std.mem.Allocator = std.heap.page_allocator,

pub fn getLength(self: *const SVGPointList) u32 {
    return @intCast(self._items.items.len);
}

pub fn getNumberOfItems(self: *const SVGPointList) u32 {
    return @intCast(self._items.items.len);
}

pub fn clear(self: *SVGPointList) void {
    self._items.clearRetainingCapacity();
}

pub fn initialize(self: *SVGPointList, item: *DOMPoint) !*DOMPoint {
    self._items.clearRetainingCapacity();
    try self._items.append(self._allocator, item);
    return item;
}

pub fn getItem(self: *const SVGPointList, index: u32) ?*DOMPoint {
    if (index >= self._items.items.len) return null;
    return self._items.items[index];
}

pub fn insertItemBefore(self: *SVGPointList, item: *DOMPoint, index: u32) !*DOMPoint {
    const idx = @min(index, @as(u32, @intCast(self._items.items.len)));
    try self._items.insert(self._allocator, idx, item);
    return item;
}

pub fn replaceItem(self: *SVGPointList, item: *DOMPoint, index: u32) ?*DOMPoint {
    if (index >= self._items.items.len) return null;
    self._items.items[index] = item;
    return item;
}

pub fn removeItem(self: *SVGPointList, index: u32) ?*DOMPoint {
    if (index >= self._items.items.len) return null;
    return self._items.orderedRemove(index);
}

pub fn appendItem(self: *SVGPointList, item: *DOMPoint) !*DOMPoint {
    try self._items.append(self._allocator, item);
    return item;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGPointList);

    pub const Meta = struct {
        pub const name = "SVGPointList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(SVGPointList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(SVGPointList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(SVGPointList.clear, .{});
    pub const initialize = bridge.function(SVGPointList.initialize, .{});
    pub const getItem = bridge.function(SVGPointList.getItem, .{});
    pub const insertItemBefore = bridge.function(SVGPointList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(SVGPointList.replaceItem, .{});
    pub const removeItem = bridge.function(SVGPointList.removeItem, .{});
    pub const appendItem = bridge.function(SVGPointList.appendItem, .{});
};

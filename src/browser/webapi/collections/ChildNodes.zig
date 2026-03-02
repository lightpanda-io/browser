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

const Node = @import("../Node.zig");
const Page = @import("../../Page.zig");
const GenericIterator = @import("iterator.zig").Entry;

// Optimized for node.childNodes, which has to be a live list.
// No need to go through a TreeWalker or add any filtering.
const ChildNodes = @This();

_arena: std.mem.Allocator,
_last_index: usize,
_last_length: ?u32,
_last_node: ?*std.DoublyLinkedList.Node,
_cached_version: usize,
_node: *Node,

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub fn init(node: *Node, page: *Page) !*ChildNodes {
    const arena = try page.getArena(.{ .debug = "ChildNodes" });
    errdefer page.releaseArena(arena);

    const self = try arena.create(ChildNodes);
    self.* = .{
        ._node = node,
        ._arena = arena,
        ._last_index = 0,
        ._last_node = null,
        ._last_length = null,
        ._cached_version = page.version,
    };
    return self;
}

pub fn deinit(self: *const ChildNodes, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn length(self: *ChildNodes, page: *Page) !u32 {
    if (self.versionCheck(page)) {
        if (self._last_length) |cached_length| {
            return cached_length;
        }
    }
    const children = self._node._children orelse return 0;

    // O(N)
    const len = children.len();
    self._last_length = len;
    return len;
}

pub fn getAtIndex(self: *ChildNodes, index: usize, page: *Page) !?*Node {
    _ = self.versionCheck(page);

    var current = self._last_index;
    var node: ?*std.DoublyLinkedList.Node = null;
    if (index < current) {
        current = 0;
        node = self.first() orelse return null;
    } else {
        node = self._last_node orelse self.first() orelse return null;
    }
    defer self._last_index = current;

    while (node) |n| {
        if (index == current) {
            self._last_node = n;
            return Node.linkToNode(n);
        }
        current += 1;
        node = n.next;
    }
    self._last_node = null;
    return null;
}

pub fn first(self: *const ChildNodes) ?*std.DoublyLinkedList.Node {
    return &(self._node._children orelse return null).first()._child_link;
}

pub fn keys(self: *ChildNodes, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *ChildNodes, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *ChildNodes, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

fn versionCheck(self: *ChildNodes, page: *Page) bool {
    const current = page.version;
    if (current == self._cached_version) {
        return true;
    }
    self._last_index = 0;
    self._last_node = null;
    self._last_length = null;
    self._cached_version = current;
    return false;
}

const NodeList = @import("NodeList.zig");
pub fn runtimeGenericWrap(self: *ChildNodes, page: *Page) !*NodeList {
    return page._factory.create(NodeList{ ._data = .{ .child_nodes = self } });
}

const Iterator = struct {
    index: u32 = 0,
    list: *ChildNodes,

    const Entry = struct { u32, *Node };

    pub fn next(self: *Iterator, page: *Page) !?Entry {
        const index = self.index;
        const node = try self.list.getAtIndex(index, page) orelse return null;
        self.index = index + 1;
        return .{ index, node };
    }
};

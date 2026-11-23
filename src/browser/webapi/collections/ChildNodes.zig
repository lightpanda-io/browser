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

const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");

// Optimized for node.childNodes, which has to be a live list.
// No need to go through a TreeWalker or add any filtering.
const ChildNodes = @This();

_last_index: usize,
_last_length: ?u32,
_last_node: ?*Node,
_cached_version: usize,
_node: *Node,

// Held by value in the NodeList that exposes it, so it needs no allocation of
// its own.
pub fn init(node: *Node, frame: *const Frame) ChildNodes {
    return .{
        ._node = node,
        ._last_index = 0,
        ._last_node = null,
        ._last_length = null,
        ._cached_version = frame.page.dom_version,
    };
}

pub fn length(self: *ChildNodes, frame: *const Frame) u32 {
    if (self.versionCheck(frame)) {
        if (self._last_length) |cached_length| {
            return cached_length;
        }
    }
    // O(N)
    var len: u32 = 0;
    var it = self._node.childrenIterator();
    while (it.next()) |_| {
        len += 1;
    }
    self._last_length = len;
    return len;
}

pub fn getAtIndex(self: *ChildNodes, index: usize, frame: *const Frame) ?*Node {
    _ = self.versionCheck(frame);

    var current = self._last_index;
    var node: ?*Node = null;
    if (index < current or self._last_node == null) {
        current = 0;
        node = self.first() orelse return null;
    } else {
        node = self._last_node;
    }
    defer self._last_index = current;

    while (node) |n| {
        if (index == current) {
            self._last_node = n;
            return n;
        }
        current += 1;
        node = n.nextSibling();
    }
    self._last_node = null;
    return null;
}

pub fn first(self: *const ChildNodes) ?*Node {
    return self._node.firstChild();
}

fn versionCheck(self: *ChildNodes, frame: *const Frame) bool {
    const current = frame.page.dom_version;
    if (current == self._cached_version) {
        return true;
    }
    self._last_index = 0;
    self._last_node = null;
    self._last_length = null;
    self._cached_version = current;
    return false;
}

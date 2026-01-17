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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const NodeFilter = @import("NodeFilter.zig");
pub const FilterOpts = NodeFilter.FilterOpts;

const DOMNodeIterator = @This();

_root: *Node,
_what_to_show: u32,
_filter: NodeFilter,
_reference_node: *Node,
_pointer_before_reference_node: bool,

pub fn init(root: *Node, what_to_show: u32, filter: ?FilterOpts, page: *Page) !*DOMNodeIterator {
    const node_filter = try NodeFilter.init(filter);
    return page._factory.create(DOMNodeIterator{
        ._root = root,
        ._filter = node_filter,
        ._reference_node = root,
        ._what_to_show = what_to_show,
        ._pointer_before_reference_node = true,
    });
}

pub fn getRoot(self: *const DOMNodeIterator) *Node {
    return self._root;
}

pub fn getReferenceNode(self: *const DOMNodeIterator) *Node {
    return self._reference_node;
}

pub fn getPointerBeforeReferenceNode(self: *const DOMNodeIterator) bool {
    return self._pointer_before_reference_node;
}

pub fn getWhatToShow(self: *const DOMNodeIterator) u32 {
    return self._what_to_show;
}

pub fn getFilter(self: *const DOMNodeIterator) ?FilterOpts {
    return self._filter._original_filter;
}

pub fn nextNode(self: *DOMNodeIterator, page: *Page) !?*Node {
    var node = self._reference_node;
    var before_node = self._pointer_before_reference_node;

    while (true) {
        if (before_node) {
            before_node = false;
            const result = try self.filterNode(node, page);
            if (result == NodeFilter.FILTER_ACCEPT) {
                self._reference_node = node;
                self._pointer_before_reference_node = false;
                return node;
            }
        } else {
            // Move to next node in tree order
            const next = self.getNextInTree(node);
            if (next == null) {
                return null;
            }
            node = next.?;

            const result = try self.filterNode(node, page);
            if (result == NodeFilter.FILTER_ACCEPT) {
                self._reference_node = node;
                self._pointer_before_reference_node = false;
                return node;
            }
        }
    }
}

pub fn previousNode(self: *DOMNodeIterator, page: *Page) !?*Node {
    var node = self._reference_node;
    var before_node = self._pointer_before_reference_node;

    while (true) {
        if (!before_node) {
            const result = try self.filterNode(node, page);
            if (result == NodeFilter.FILTER_ACCEPT) {
                self._reference_node = node;
                self._pointer_before_reference_node = true;
                return node;
            }
            before_node = true;
        }

        // Move to previous node in tree order
        const prev = self.getPreviousInTree(node);
        if (prev == null) {
            return null;
        }
        node = prev.?;
        before_node = false;
    }
}

fn filterNode(self: *const DOMNodeIterator, node: *Node, page: *Page) !i32 {
    // First check whatToShow
    if (!NodeFilter.shouldShow(node, self._what_to_show)) {
        return NodeFilter.FILTER_SKIP;
    }

    // Then check the filter callback
    // For NodeIterator, REJECT and SKIP are equivalent - both skip the node
    // but continue with its descendants
    const result = try self._filter.acceptNode(node, page.js.local.?);
    return result;
}

fn getNextInTree(self: *const DOMNodeIterator, node: *Node) ?*Node {
    // Depth-first traversal within the root subtree
    if (node._children) |children| {
        return children.first();
    }

    var current = node;
    while (current != self._root) {
        if (current.nextSibling()) |sibling| {
            return sibling;
        }
        current = current._parent orelse return null;
    }

    return null;
}

fn getPreviousInTree(self: *const DOMNodeIterator, node: *Node) ?*Node {
    if (node == self._root) {
        return null;
    }

    if (node.previousSibling()) |sibling| {
        // Go to the last descendant of the sibling
        var last = sibling;
        while (last.lastChild()) |child| {
            last = child;
        }
        return last;
    }

    return node._parent;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMNodeIterator);

    pub const Meta = struct {
        pub const name = "NodeIterator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const root = bridge.accessor(DOMNodeIterator.getRoot, null, .{});
    pub const referenceNode = bridge.accessor(DOMNodeIterator.getReferenceNode, null, .{});
    pub const pointerBeforeReferenceNode = bridge.accessor(DOMNodeIterator.getPointerBeforeReferenceNode, null, .{});
    pub const whatToShow = bridge.accessor(DOMNodeIterator.getWhatToShow, null, .{});
    pub const filter = bridge.accessor(DOMNodeIterator.getFilter, null, .{});

    pub const nextNode = bridge.function(DOMNodeIterator.nextNode, .{});
    pub const previousNode = bridge.function(DOMNodeIterator.previousNode, .{});
};

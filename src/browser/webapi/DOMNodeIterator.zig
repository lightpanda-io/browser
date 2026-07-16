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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const NodeFilter = @import("NodeFilter.zig");
pub const FilterOpts = NodeFilter.FilterOpts;

const DOMNodeIterator = @This();

_rc: lp.RC(u8) = .{},
_root: *Node,
_what_to_show: u32,
_filter: NodeFilter,
_reference_node: *Node,
_pointer_before_reference_node: bool,
_active: bool = false,
_frame_loader_id: u32,
_iterator_link: std.DoublyLinkedList.Node = .{},

pub fn init(root: *Node, what_to_show: u32, filter: ?FilterOpts, frame: *Frame) !*DOMNodeIterator {
    const node_filter = try NodeFilter.init(filter);
    const iterator = try frame._factory.create(DOMNodeIterator{
        ._root = root,
        ._filter = node_filter,
        ._reference_node = root,
        ._what_to_show = what_to_show,
        ._frame_loader_id = frame._loader_id,
        ._pointer_before_reference_node = true,
    });
    frame._live_node_iterators.append(&iterator._iterator_link);
    return iterator;
}

pub fn deinit(self: *DOMNodeIterator, page: *Page) void {
    if (page.findFrameByLoaderId(self._frame_loader_id)) |frame| {
        frame._live_node_iterators.remove(&self._iterator_link);
    }
    self._filter.deinit();
    page.factory.destroy(self);
}

pub fn releaseRef(self: *DOMNodeIterator, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *DOMNodeIterator) void {
    self._rc.acquire();
}

pub fn getRoot(self: *const DOMNodeIterator) *Node {
    return self._root;
}

// DOM "node iterator pre-removing steps", run while the tree still contains
// to_be_removed.
pub fn nodeWillBeRemoved(self: *DOMNodeIterator, to_be_removed: *Node) void {
    if (to_be_removed.contains(self._root)) {
        // Removing the root or one of its ancestors leaves the iterator alone.
        return;
    }
    if (to_be_removed != self._reference_node and to_be_removed.contains(self._reference_node) == false) {
        return;
    }

    if (self._pointer_before_reference_node) {
        // The first node following to_be_removed's subtree, if any.
        var node = to_be_removed;
        while (node != self._root) {
            if (node.nextSibling()) |sibling| {
                self._reference_node = sibling;
                return;
            }
            node = node.parentNode() orelse break;
        }
        self._pointer_before_reference_node = false;
    }

    // The node immediately preceding to_be_removed in tree order: the
    // previous sibling's last inclusive descendant, or the parent.
    if (to_be_removed.previousSibling()) |prev| {
        var node = prev;
        while (node.lastChild()) |child| {
            node = child;
        }
        self._reference_node = node;
    } else {
        self._reference_node = to_be_removed.parentNode() orelse self._root;
    }
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
    return self._filter._opts;
}

pub fn nextNode(self: *DOMNodeIterator, frame: *Frame) !?*Node {
    if (self._active) {
        return error.InvalidStateError;
    }

    self._active = true;
    defer self._active = false;

    var node = self._reference_node;
    var before_node = self._pointer_before_reference_node;

    while (true) {
        if (before_node) {
            before_node = false;
            const result = try self.filterNode(node, frame);
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

            const result = try self.filterNode(node, frame);
            if (result == NodeFilter.FILTER_ACCEPT) {
                self._reference_node = node;
                self._pointer_before_reference_node = false;
                return node;
            }
        }
    }
}

pub fn previousNode(self: *DOMNodeIterator, frame: *Frame) !?*Node {
    if (self._active) {
        return error.InvalidStateError;
    }

    self._active = true;
    defer self._active = false;

    var node = self._reference_node;
    var before_node = self._pointer_before_reference_node;

    while (true) {
        if (!before_node) {
            const result = try self.filterNode(node, frame);
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

pub fn detach(_: *const DOMNodeIterator) void {
    // no-op legacy
}

fn filterNode(self: *const DOMNodeIterator, node: *Node, frame: *Frame) !i32 {
    // First check whatToShow
    if (!NodeFilter.shouldShow(node, self._what_to_show)) {
        return NodeFilter.FILTER_SKIP;
    }

    // Then check the filter callback
    // For NodeIterator, REJECT and SKIP are equivalent - both skip the node
    // but continue with its descendants
    const result = try self._filter.acceptNode(node, frame.js.local.?);
    return result;
}

fn getNextInTree(self: *const DOMNodeIterator, node: *Node) ?*Node {
    // Depth-first traversal within the root subtree
    if (node._children) |children| {
        return Node.linkToNode(children.first.?);
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
    pub const detach = bridge.function(DOMNodeIterator.detach, .{});
};

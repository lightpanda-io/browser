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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const NodeFilter = @import("NodeFilter.zig");
pub const FilterOpts = NodeFilter.FilterOpts;

const DOMTreeWalker = @This();

_rc: lp.RC(u8) = .{},
_root: *Node,
_what_to_show: u32,
_filter: NodeFilter,
_current: *Node,
_active: bool = false,

pub fn init(root: *Node, what_to_show: u32, filter: ?FilterOpts, frame: *Frame) !*DOMTreeWalker {
    const node_filter = try NodeFilter.init(filter);
    return frame._factory.create(DOMTreeWalker{
        ._root = root,
        ._current = root,
        ._filter = node_filter,
        ._what_to_show = what_to_show,
    });
}

pub fn deinit(self: *DOMTreeWalker, page: *Page) void {
    self._filter.deinit();
    page.factory.destroy(self);
}

pub fn releaseRef(self: *DOMTreeWalker, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *DOMTreeWalker) void {
    self._rc.acquire();
}

pub fn getRoot(self: *const DOMTreeWalker) *Node {
    return self._root;
}

pub fn getWhatToShow(self: *const DOMTreeWalker) u32 {
    return self._what_to_show;
}

pub fn getFilter(self: *const DOMTreeWalker) ?FilterOpts {
    return self._filter._opts;
}

pub fn getCurrentNode(self: *const DOMTreeWalker) *Node {
    return self._current;
}

pub fn setCurrentNode(self: *DOMTreeWalker, node: *Node) void {
    self._current = node;
}

// Navigation methods
pub fn parentNode(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    var node = self._current._parent;
    while (node) |n| {
        if (n == self._root._parent) {
            return null;
        }
        if (try self.acceptNode(n, frame) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = n._parent;
    }
    return null;
}

pub fn firstChild(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    var node = self._current.firstChild();

    while (node) |n| {
        const filter_result = try self.acceptNode(n, frame);

        if (filter_result == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }

        if (filter_result == NodeFilter.FILTER_SKIP) {
            // Descend into children of this skipped node
            if (n.firstChild()) |child| {
                node = child;
                continue;
            }
        }

        // REJECT or SKIP with no children - find next sibling, walking up if necessary
        var current_node = n;
        while (true) {
            if (current_node.nextSibling()) |sibling| {
                node = sibling;
                break;
            }

            // No sibling, go up to parent
            const parent = current_node._parent orelse return null;
            if (parent == self._current) {
                // We've exhausted all children of self._current
                return null;
            }
            current_node = parent;
        }
    }

    return null;
}

pub fn lastChild(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    var node = self._current.lastChild();

    while (node) |n| {
        const filter_result = try self.acceptNode(n, frame);

        if (filter_result == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }

        if (filter_result == NodeFilter.FILTER_SKIP) {
            // Descend into children of this skipped node
            if (n.lastChild()) |child| {
                node = child;
                continue;
            }
        }

        // REJECT or SKIP with no children - find previous sibling, walking up if necessary
        var current_node = n;
        while (true) {
            if (current_node.previousSibling()) |sibling| {
                node = sibling;
                break;
            }

            // No sibling, go up to parent
            const parent = current_node._parent orelse return null;
            if (parent == self._current) {
                // We've exhausted all children of self._current
                return null;
            }
            current_node = parent;
        }
    }

    return null;
}

pub fn previousSibling(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    return self.traverseSiblings(.previous, frame);
}

pub fn nextSibling(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    return self.traverseSiblings(.next, frame);
}

// The spec's "traverse siblings" algorithm: a skipped (but not rejected)
// sibling's children are still candidates, and when the siblings run out the
// walk climbs to the parent and continues from its siblings, stopping at the
// root or at an accepted parent.
fn traverseSiblings(self: *DOMTreeWalker, comptime direction: enum { next, previous }, frame: *Frame) !?*Node {
    var node = self._current;
    if (node == self._root) return null;

    while (true) {
        var sibling: ?*Node = if (direction == .next)
            self.nextSiblingOrNull(node)
        else
            self.previousSiblingOrNull(node);

        while (sibling) |sib| {
            node = sib;
            const result = try self.acceptNode(node, frame);
            if (result == NodeFilter.FILTER_ACCEPT) {
                self._current = node;
                return node;
            }
            sibling = if (direction == .next)
                self.firstChildOrNull(node)
            else
                self.lastChildOrNull(node);
            if (result == NodeFilter.FILTER_REJECT or sibling == null) {
                sibling = if (direction == .next)
                    self.nextSiblingOrNull(node)
                else
                    self.previousSiblingOrNull(node);
            }
        }

        node = node.parentNode() orelse return null;
        if (node == self._root) return null;
        if (try self.acceptNode(node, frame) == NodeFilter.FILTER_ACCEPT) {
            return null;
        }
    }
}

pub fn previousNode(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    var node = self._current;
    while (node != self._root) {
        var sibling = self.previousSiblingOrNull(node);
        while (sibling) |sib| {
            node = sib;

            // Check if this sibling is rejected before descending into it
            const sib_result = try self.acceptNode(node, frame);
            if (sib_result == NodeFilter.FILTER_REJECT) {
                // Skip this sibling and its descendants entirely
                sibling = self.previousSiblingOrNull(node);
                continue;
            }

            // Descend to the deepest last child, but respect FILTER_REJECT
            while (true) {
                var child = self.lastChildOrNull(node);

                // Find the rightmost non-rejected child
                while (child) |c| {
                    if (!self.isInSubtree(c)) break;

                    const filter_result = try self.acceptNode(c, frame);
                    if (filter_result == NodeFilter.FILTER_REJECT) {
                        // Skip this child and try its previous sibling
                        child = self.previousSiblingOrNull(c);
                    } else {
                        // ACCEPT or SKIP - use this child
                        break;
                    }
                }

                if (child == null) break; // No acceptable children

                // Descend into this child
                node = child.?;
            }

            if (try self.acceptNode(node, frame) == NodeFilter.FILTER_ACCEPT) {
                self._current = node;
                return node;
            }
            sibling = self.previousSiblingOrNull(node);
        }

        if (node == self._root) {
            return null;
        }

        const parent = node._parent orelse return null;
        if (try self.acceptNode(parent, frame) == NodeFilter.FILTER_ACCEPT) {
            self._current = parent;
            return parent;
        }
        node = parent;
    }
    return null;
}

pub fn nextNode(self: *DOMTreeWalker, frame: *Frame) !?*Node {
    var node = self._current;

    while (true) {
        // Try children first (depth-first)
        if (node.firstChild()) |child| {
            node = child;
            const filter_result = try self.acceptNode(node, frame);
            if (filter_result == NodeFilter.FILTER_ACCEPT) {
                self._current = node;
                return node;
            }
            // If REJECT, skip this entire subtree; if SKIP, try children
            if (filter_result == NodeFilter.FILTER_REJECT) {
                // Skip this node and its children - continue with siblings
                // Don't update node, will try siblings below
            } else {
                // SKIP - already moved to child, will try its children on next iteration
                continue;
            }
        }

        // No (more) children, try siblings
        while (true) {
            if (node == self._root) {
                return null;
            }

            if (node.nextSibling()) |sibling| {
                node = sibling;
                const filter_result = try self.acceptNode(node, frame);
                if (filter_result == NodeFilter.FILTER_ACCEPT) {
                    self._current = node;
                    return node;
                }
                // If REJECT, skip subtree; if SKIP, try children
                if (filter_result == NodeFilter.FILTER_REJECT) {
                    // Continue sibling loop to get next sibling
                    continue;
                } else {
                    // SKIP - try this node's children
                    break;
                }
            }

            // No sibling, go up to parent
            node = node._parent orelse return null;
        }
    }
}

// Helper methods
fn acceptNode(self: *DOMTreeWalker, node: *Node, frame: *Frame) !i32 {
    if (self._active) {
        return error.InvalidStateError;
    }

    // First check whatToShow
    if (!NodeFilter.shouldShow(node, self._what_to_show)) {
        return NodeFilter.FILTER_SKIP;
    }

    // Then check the filter callback
    // For TreeWalker, REJECT means reject node and its descendants
    // SKIP means skip node but check its descendants
    // ACCEPT means accept the node
    self._active = true;
    defer self._active = false;
    return try self._filter.acceptNode(node, frame.js.local.?);
}

fn isInSubtree(self: *const DOMTreeWalker, node: *Node) bool {
    var current = node;
    while (current._parent) |parent| {
        if (parent == self._root) {
            return true;
        }
        current = parent;
    }
    return current == self._root;
}

fn firstChildOrNull(self: *const DOMTreeWalker, node: *Node) ?*Node {
    _ = self;
    return node.firstChild();
}

fn lastChildOrNull(self: *const DOMTreeWalker, node: *Node) ?*Node {
    _ = self;
    return node.lastChild();
}

fn nextSiblingOrNull(self: *const DOMTreeWalker, node: *Node) ?*Node {
    _ = self;
    return node.nextSibling();
}

fn previousSiblingOrNull(self: *const DOMTreeWalker, node: *Node) ?*Node {
    _ = self;
    return node.previousSibling();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMTreeWalker);

    pub const Meta = struct {
        pub const name = "TreeWalker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const root = bridge.accessor(DOMTreeWalker.getRoot, null, .{});
    pub const whatToShow = bridge.accessor(DOMTreeWalker.getWhatToShow, null, .{});
    pub const filter = bridge.accessor(DOMTreeWalker.getFilter, null, .{});
    pub const currentNode = bridge.accessor(DOMTreeWalker.getCurrentNode, DOMTreeWalker.setCurrentNode, .{});

    pub const parentNode = bridge.function(DOMTreeWalker.parentNode, .{});
    pub const firstChild = bridge.function(DOMTreeWalker.firstChild, .{});
    pub const lastChild = bridge.function(DOMTreeWalker.lastChild, .{});
    pub const previousSibling = bridge.function(DOMTreeWalker.previousSibling, .{});
    pub const nextSibling = bridge.function(DOMTreeWalker.nextSibling, .{});
    pub const previousNode = bridge.function(DOMTreeWalker.previousNode, .{});
    pub const nextNode = bridge.function(DOMTreeWalker.nextNode, .{});
};

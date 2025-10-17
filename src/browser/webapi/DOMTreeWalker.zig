const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const NodeFilter = @import("NodeFilter.zig");
pub const FilterOpts = NodeFilter.FilterOpts;

const DOMTreeWalker = @This();

_root: *Node,
_what_to_show: u32,
_filter: NodeFilter,
_current: *Node,

pub fn init(root: *Node, what_to_show: u32, filter: ?FilterOpts, page: *Page) !*DOMTreeWalker {
    const node_filter = try NodeFilter.init(filter);
    return page._factory.create(DOMTreeWalker{
        ._root = root,
        ._current = root,
        ._filter = node_filter,
        ._what_to_show = what_to_show,
    });
}

pub fn getRoot(self: *const DOMTreeWalker) *Node {
    return self._root;
}

pub fn getWhatToShow(self: *const DOMTreeWalker) u32 {
    return self._what_to_show;
}

pub fn getFilter(self: *const DOMTreeWalker) ?FilterOpts {
    return self._filter._original_filter;
}

pub fn getCurrentNode(self: *const DOMTreeWalker) *Node {
    return self._current;
}

pub fn setCurrentNode(self: *DOMTreeWalker, node: *Node) void {
    self._current = node;
}

// Navigation methods
pub fn parentNode(self: *DOMTreeWalker) !?*Node {
    var node = self._current._parent;
    while (node) |n| {
        if (n == self._root._parent) {
            return null;
        }
        if (try self.acceptNode(n) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = n._parent;
    }
    return null;
}

pub fn firstChild(self: *DOMTreeWalker) !?*Node {
    var node = self._current.firstChild();
    while (node) |n| {
        if (try self.acceptNode(n) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = self.nextSiblingOrNull(n);
    }
    return null;
}

pub fn lastChild(self: *DOMTreeWalker) !?*Node {
    var node = self._current.lastChild();
    while (node) |n| {
        if (try self.acceptNode(n) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = self.previousSiblingOrNull(n);
    }
    return null;
}

pub fn previousSibling(self: *DOMTreeWalker) !?*Node {
    var node = self.previousSiblingOrNull(self._current);
    while (node) |n| {
        if (try self.acceptNode(n) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = self.previousSiblingOrNull(n);
    }
    return null;
}

pub fn nextSibling(self: *DOMTreeWalker) !?*Node {
    var node = self.nextSiblingOrNull(self._current);
    while (node) |n| {
        if (try self.acceptNode(n) == NodeFilter.FILTER_ACCEPT) {
            self._current = n;
            return n;
        }
        node = self.nextSiblingOrNull(n);
    }
    return null;
}

pub fn previousNode(self: *DOMTreeWalker) !?*Node {
    var node = self._current;
    while (node != self._root) {
        var sibling = self.previousSiblingOrNull(node);
        while (sibling) |sib| {
            node = sib;
            var child = self.lastChildOrNull(node);
            while (child) |c| {
                if (self.isInSubtree(c)) {
                    node = c;
                    child = self.lastChildOrNull(node);
                } else {
                    break;
                }
            }
            if (try self.acceptNode(node) == NodeFilter.FILTER_ACCEPT) {
                self._current = node;
                return node;
            }
            sibling = self.previousSiblingOrNull(node);
        }

        if (node == self._root) {
            return null;
        }

        const parent = node._parent orelse return null;
        if (try self.acceptNode(parent) == NodeFilter.FILTER_ACCEPT) {
            self._current = parent;
            return parent;
        }
        node = parent;
    }
    return null;
}

pub fn nextNode(self: *DOMTreeWalker) !?*Node {
    var node = self._current;

    while (true) {
        // Try children first (depth-first)
        if (node.firstChild()) |child| {
            node = child;
            const filter_result = try self.acceptNode(node);
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
                const filter_result = try self.acceptNode(node);
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
fn acceptNode(self: *const DOMTreeWalker, node: *Node) !i32 {
    // First check whatToShow
    if (!NodeFilter.shouldShow(node, self._what_to_show)) {
        return NodeFilter.FILTER_SKIP;
    }

    // Then check the filter callback
    // For TreeWalker, REJECT means reject node and its descendants
    // SKIP means skip node but check its descendants
    // ACCEPT means accept the node
    return try self._filter.acceptNode(node);
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
        pub var class_index: u16 = 0;
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

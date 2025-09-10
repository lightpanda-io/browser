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

const parser = @import("../netsurf.zig");
const Env = @import("../env.zig").Env;
const NodeFilter = @import("node_filter.zig");
const Node = @import("node.zig").Node;
const NodeUnion = @import("node.zig").Union;
const DOMException = @import("exceptions.zig").DOMException;

// https://developer.mozilla.org/en-US/docs/Web/API/NodeIterator
// While this is similar to TreeWalker it has its own implementation as there are several subtle differences
// For example:
// - nextNode returns the reference node, whereas TreeWalker returns the next node
// - Skip and reject are equivalent for NodeIterator, for TreeWalker they are different
pub const NodeIterator = struct {
    pub const Exception = DOMException;

    root: *parser.Node,
    reference_node: *parser.Node,
    what_to_show: u32,
    filter: ?NodeIteratorOpts,
    filter_func: ?Env.Function,
    pointer_before_current: bool = true,
    // used to track / block recursive filters
    is_in_callback: bool = false,

    // One of the few cases where null and undefined resolve to different default.
    // We need the raw JsObject so that we can probe the tri state:
    // null, undefined or i32.
    pub const WhatToShow = Env.JsObject;

    pub const NodeIteratorOpts = union(enum) {
        function: Env.Function,
        object: struct { acceptNode: Env.Function },
    };

    pub fn init(node: *parser.Node, what_to_show_: ?WhatToShow, filter: ?NodeIteratorOpts) !NodeIterator {
        var filter_func: ?Env.Function = null;
        if (filter) |f| {
            filter_func = switch (f) {
                .function => |func| func,
                .object => |o| o.acceptNode,
            };
        }

        var what_to_show: u32 = undefined;
        if (what_to_show_) |wts| {
            switch (try wts.triState(NodeIterator, "what_to_show", u32)) {
                .null => what_to_show = 0,
                .undefined => what_to_show = NodeFilter.NodeFilter._SHOW_ALL,
                .value => |v| what_to_show = v,
            }
        } else {
            what_to_show = NodeFilter.NodeFilter._SHOW_ALL;
        }

        return .{
            .root = node,
            .reference_node = node,
            .what_to_show = what_to_show,
            .filter = filter,
            .filter_func = filter_func,
        };
    }

    pub fn get_filter(self: *const NodeIterator) ?NodeIteratorOpts {
        return self.filter;
    }

    pub fn get_pointerBeforeReferenceNode(self: *const NodeIterator) bool {
        return self.pointer_before_current;
    }

    pub fn get_referenceNode(self: *const NodeIterator) !NodeUnion {
        return try Node.toInterface(self.reference_node);
    }

    pub fn get_root(self: *const NodeIterator) !NodeUnion {
        return try Node.toInterface(self.root);
    }

    pub fn get_whatToShow(self: *const NodeIterator) u32 {
        return self.what_to_show;
    }

    pub fn _nextNode(self: *NodeIterator) !?NodeUnion {
        try self.callbackStart();
        defer self.callbackEnd();

        if (self.pointer_before_current) {
            // Unlike TreeWalker, NodeIterator starts at the first node
            if (.accept == try NodeFilter.verify(self.what_to_show, self.filter_func, self.reference_node)) {
                self.pointer_before_current = false;
                return try Node.toInterface(self.reference_node);
            }
        }

        if (try self.firstChild(self.reference_node)) |child| {
            self.reference_node = child;
            return try Node.toInterface(child);
        }

        var current = self.reference_node;
        while (current != self.root) {
            if (try self.nextSibling(current)) |sibling| {
                self.reference_node = sibling;
                return try Node.toInterface(sibling);
            }

            current = (try parser.nodeParentNode(current)) orelse break;
        }

        return null;
    }

    pub fn _previousNode(self: *NodeIterator) !?NodeUnion {
        try self.callbackStart();
        defer self.callbackEnd();

        if (!self.pointer_before_current) {
            if (.accept == try NodeFilter.verify(self.what_to_show, self.filter_func, self.reference_node)) {
                self.pointer_before_current = true;
                // Still need to verify as last may be first as well
                return try Node.toInterface(self.reference_node);
            }
        }
        if (self.reference_node == self.root) {
            return null;
        }

        var current = self.reference_node;
        while (try parser.nodePreviousSibling(current)) |previous| {
            current = previous;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, current)) {
                .accept => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.reference_node = child;
                        return try Node.toInterface(child);
                    }

                    // Otherwise, this node is our previous one.
                    self.reference_node = current;
                    return try Node.toInterface(current);
                },
                .reject, .skip => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.reference_node = child;
                        return try Node.toInterface(child);
                    }
                },
            }
        }

        if (current != self.root) {
            if (try self.parentNode(current)) |parent| {
                self.reference_node = parent;
                return try Node.toInterface(parent);
            }
        }

        return null;
    }

    pub fn _detach(self: *const NodeIterator) void {
        // no-op as per spec
        _ = self;
    }

    fn firstChild(self: *const NodeIterator, node: *parser.Node) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(node);
        const child_count = try parser.nodeListLength(children);

        for (0..child_count) |i| {
            const index: u32 = @intCast(i);
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, child)) {
                .accept => return child, // NOTE: Skip and reject are equivalent for NodeIterator, this is different from TreeWalker
                .reject, .skip => if (try self.firstChild(child)) |gchild| return gchild,
            }
        }

        return null;
    }

    fn lastChild(self: *const NodeIterator, node: *parser.Node) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(node);
        const child_count = try parser.nodeListLength(children);

        var index: u32 = child_count;
        while (index > 0) {
            index -= 1;
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, child)) {
                .accept => return child, // NOTE: Skip and reject are equivalent for NodeIterator, this is different from TreeWalker
                .reject, .skip => if (try self.lastChild(child)) |gchild| return gchild,
            }
        }

        return null;
    }

    // This implementation is actually the same as :TreeWalker
    fn parentNode(self: *const NodeIterator, node: *parser.Node) !?*parser.Node {
        if (self.root == node) return null;

        var current = node;
        while (true) {
            if (current == self.root) return null;
            current = (try parser.nodeParentNode(current)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, current)) {
                .accept => return current,
                .reject, .skip => continue,
            }
        }
    }

    // This implementation is actually the same as :TreeWalker
    fn nextSibling(self: *const NodeIterator, node: *parser.Node) !?*parser.Node {
        var current = node;

        while (true) {
            current = (try parser.nodeNextSibling(current)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, current)) {
                .accept => return current,
                .skip, .reject => continue,
            }
        }

        return null;
    }

    fn callbackStart(self: *NodeIterator) !void {
        if (self.is_in_callback) {
            // this is the correct DOMExeption
            return error.InvalidState;
        }
        self.is_in_callback = true;
    }

    fn callbackEnd(self: *NodeIterator) void {
        self.is_in_callback = false;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.NodeIterator" {
    try testing.htmlRunner("dom/node_iterator.html");
}

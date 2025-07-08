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
const TreeWalker = @import("tree_walker.zig").TreeWalker;

// https://developer.mozilla.org/en-US/docs/Web/API/NodeIterator
pub const NodeIterator = struct {
    walker: TreeWalker,
    pointer_before_current: bool = true,

    pub fn init(node: *parser.Node, what_to_show: ?u32, filter: ?TreeWalker.TreeWalkerOpts) !NodeIterator {
        return .{ .walker = try TreeWalker.init(node, what_to_show, filter) };
    }

    pub fn get_filter(self: *const NodeIterator) ?Env.Function {
        return self.walker.filter;
    }

    pub fn get_pointerBeforeReferenceNode(self: *const NodeIterator) bool {
        return self.pointer_before_current;
    }

    pub fn get_referenceNode(self: *const NodeIterator) *parser.Node {
        return self.walker.current_node;
    }

    pub fn get_root(self: *const NodeIterator) *parser.Node {
        return self.walker.root;
    }

    pub fn get_whatToShow(self: *const NodeIterator) u32 {
        return self.walker.what_to_show;
    }

    pub fn _nextNode(self: *NodeIterator) !?*parser.Node {
        if (self.pointer_before_current) { // Unlike TreeWalker, NodeIterator starts at the first node
            self.pointer_before_current = false;
            if (.accept == try self.walker.verify(self.walker.current_node)) {
                return self.walker.current_node;
            }
        }

        if (try self.firstChild(self.walker.current_node)) |child| {
            self.walker.current_node = child;
            return child;
        }

        var current = self.walker.current_node;
        while (current != self.walker.root) {
            if (try self.walker.nextSibling(current)) |sibling| {
                self.walker.current_node = sibling;
                return sibling;
            }

            current = (try parser.nodeParentNode(current)) orelse break;
        }

        return null;
    }

    pub fn _previousNode(self: *NodeIterator) !?*parser.Node {
        if (!self.pointer_before_current) {
            self.pointer_before_current = true;
            if (.accept == try self.walker.verify(self.walker.current_node)) {
                return self.walker.current_node; // Still need to verify as last may be first as well
            }
        }
        if (self.walker.current_node == self.walker.root) return null;

        var current = self.walker.current_node;
        while (try parser.nodePreviousSibling(current)) |previous| {
            current = previous;

            switch (try self.walker.verify(current)) {
                .accept => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.walker.current_node = child;
                        return child;
                    }

                    // Otherwise, this node is our previous one.
                    self.walker.current_node = current;
                    return current;
                },
                .reject, .skip => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.walker.current_node = child;
                        return child;
                    }
                },
            }
        }

        if (current != self.walker.root) {
            if (try self.walker.parentNode(current)) |parent| {
                self.walker.current_node = parent;
                return parent;
            }
        }

        return null;
    }

    fn firstChild(self: *const NodeIterator, node: *parser.Node) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(node);
        const child_count = try parser.nodeListLength(children);

        for (0..child_count) |i| {
            const index: u32 = @intCast(i);
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            switch (try self.walker.verify(child)) {
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

            switch (try self.walker.verify(child)) {
                .accept => return child, // NOTE: Skip and reject are equivalent for NodeIterator, this is different from TreeWalker
                .reject, .skip => if (try self.lastChild(child)) |gchild| return gchild,
            }
        }

        return null;
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.NodeFilter" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{
            \\ const nodeIterator = document.createNodeIterator(
            \\   document.body,
            \\   NodeFilter.SHOW_ELEMENT,
            \\   {
            \\     acceptNode(node) {
            \\       return NodeFilter.FILTER_ACCEPT;
            \\     },
            \\   },
            \\ );
            \\ nodeIterator.nextNode().nodeName;
            ,
            "BODY",
        },
        .{ "nodeIterator.nextNode().nodeName", "DIV" },
        .{ "nodeIterator.nextNode().nodeName", "A" },
        .{ "nodeIterator.previousNode().nodeName", "A" }, // pointer_before_current flips
        .{ "nodeIterator.nextNode().nodeName", "A" }, // pointer_before_current flips
        .{ "nodeIterator.previousNode().nodeName", "A" }, // pointer_before_current flips
        .{ "nodeIterator.previousNode().nodeName", "DIV" },
        .{ "nodeIterator.previousNode().nodeName", "BODY" },
        .{ "nodeIterator.previousNode()", "null" }, // Not HEAD since body is root
        .{ "nodeIterator.previousNode()", "null" }, // Keeps returning null
        .{ "nodeIterator.nextNode().nodeName", "BODY" },

        .{ "nodeIterator.nextNode().nodeName", null },
        .{ "nodeIterator.nextNode().nodeName", null },
        .{ "nodeIterator.nextNode().nodeName", null },
        .{ "nodeIterator.nextNode().nodeName", "SPAN" },
        .{ "nodeIterator.nextNode().nodeName", "P" },
        .{ "nodeIterator.nextNode()", "null" }, // Just the last one
        .{ "nodeIterator.nextNode()", "null" }, // Keeps returning null
        .{ "nodeIterator.previousNode().nodeName", "P" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ const notationIterator = document.createNodeIterator(
            \\   document.body,
            \\   NodeFilter.SHOW_NOTATION,
            \\ );
            \\ notationIterator.nextNode();
            ,
            "null",
        },
        .{ "notationIterator.previousNode()", "null" },
    }, .{});
}

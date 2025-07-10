// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const NodeFilter = @import("node_filter.zig");
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;
const Node = @import("node.zig").Node;
const NodeUnion = @import("node.zig").Union;

// https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker
pub const TreeWalker = struct {
    root: *parser.Node,
    current_node: *parser.Node,
    what_to_show: u32,
    filter: ?TreeWalkerOpts,
    filter_func: ?Env.Function,

    pub const TreeWalkerOpts = union(enum) {
        function: Env.Function,
        object: struct { acceptNode: Env.Function },
    };

    pub fn init(node: *parser.Node, what_to_show: ?u32, filter: ?TreeWalkerOpts) !TreeWalker {
        var filter_func: ?Env.Function = null;

        if (filter) |f| {
            filter_func = switch (f) {
                .function => |func| func,
                .object => |o| o.acceptNode,
            };
        }

        return .{
            .root = node,
            .current_node = node,
            .what_to_show = what_to_show orelse NodeFilter.NodeFilter._SHOW_ALL,
            .filter = filter,
            .filter_func = filter_func,
        };
    }

    pub fn get_root(self: *TreeWalker) !NodeUnion {
        return try Node.toInterface(self.root);
    }

    pub fn get_currentNode(self: *TreeWalker) !NodeUnion {
        return try Node.toInterface(self.current_node);
    }

    pub fn get_whatToShow(self: *TreeWalker) u32 {
        return self.what_to_show;
    }

    pub fn get_filter(self: *TreeWalker) ?TreeWalkerOpts {
        return self.filter;
    }

    pub fn set_currentNode(self: *TreeWalker, node: *parser.Node) !void {
        self.current_node = node;
    }

    fn firstChild(self: *const TreeWalker, node: *parser.Node) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(node);
        const child_count = try parser.nodeListLength(children);

        for (0..child_count) |i| {
            const index: u32 = @intCast(i);
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, child)) {
                .accept => return child,
                .reject => continue,
                .skip => if (try self.firstChild(child)) |gchild| return gchild,
            }
        }

        return null;
    }

    fn lastChild(self: *const TreeWalker, node: *parser.Node) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(node);
        const child_count = try parser.nodeListLength(children);

        var index: u32 = child_count;
        while (index > 0) {
            index -= 1;
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, child)) {
                .accept => return child,
                .reject => continue,
                .skip => if (try self.lastChild(child)) |gchild| return gchild,
            }
        }

        return null;
    }

    fn nextSibling(self: *const TreeWalker, node: *parser.Node) !?*parser.Node {
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

    fn previousSibling(self: *const TreeWalker, node: *parser.Node) !?*parser.Node {
        var current = node;

        while (true) {
            current = (try parser.nodePreviousSibling(current)) orelse return null;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, current)) {
                .accept => return current,
                .skip, .reject => continue,
            }
        }

        return null;
    }

    fn parentNode(self: *const TreeWalker, node: *parser.Node) !?*parser.Node {
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

    pub fn _firstChild(self: *TreeWalker) !?NodeUnion {
        if (try self.firstChild(self.current_node)) |child| {
            self.current_node = child;
            return try Node.toInterface(child);
        }

        return null;
    }

    pub fn _lastChild(self: *TreeWalker) !?NodeUnion {
        if (try self.lastChild(self.current_node)) |child| {
            self.current_node = child;
            return try Node.toInterface(child);
        }

        return null;
    }

    pub fn _nextNode(self: *TreeWalker) !?NodeUnion {
        if (try self.firstChild(self.current_node)) |child| {
            self.current_node = child;
            return try Node.toInterface(child);
        }

        var current = self.current_node;
        while (current != self.root) {
            if (try self.nextSibling(current)) |sibling| {
                self.current_node = sibling;
                return try Node.toInterface(sibling);
            }

            current = (try parser.nodeParentNode(current)) orelse break;
        }

        return null;
    }

    pub fn _nextSibling(self: *TreeWalker) !?NodeUnion {
        if (try self.nextSibling(self.current_node)) |sibling| {
            self.current_node = sibling;
            return try Node.toInterface(sibling);
        }

        return null;
    }

    pub fn _parentNode(self: *TreeWalker) !?NodeUnion {
        if (try self.parentNode(self.current_node)) |parent| {
            self.current_node = parent;
            return try Node.toInterface(parent);
        }

        return null;
    }

    pub fn _previousNode(self: *TreeWalker) !?NodeUnion {
        if (self.current_node == self.root) return null;

        var current = self.current_node;
        while (try parser.nodePreviousSibling(current)) |previous| {
            current = previous;

            switch (try NodeFilter.verify(self.what_to_show, self.filter_func, current)) {
                .accept => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.current_node = child;
                        return try Node.toInterface(child);
                    }

                    // Otherwise, this node is our previous one.
                    self.current_node = current;
                    return try Node.toInterface(current);
                },
                .reject => continue,
                .skip => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.current_node = child;
                        return try Node.toInterface(child);
                    }
                },
            }
        }

        if (current != self.root) {
            if (try self.parentNode(current)) |parent| {
                self.current_node = parent;
                return try Node.toInterface(parent);
            }
        }

        return null;
    }

    pub fn _previousSibling(self: *TreeWalker) !?NodeUnion {
        if (try self.previousSibling(self.current_node)) |sibling| {
            self.current_node = sibling;
            return try Node.toInterface(sibling);
        }

        return null;
    }
};

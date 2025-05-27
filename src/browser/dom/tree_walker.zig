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

const NodeFilter = @import("node_filter.zig").NodeFilter;
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

// https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker
pub const TreeWalker = struct {
    root: *parser.Node,
    current_node: *parser.Node,
    what_to_show: u32,
    filter: ?Env.Function,

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
            .what_to_show = what_to_show orelse NodeFilter._SHOW_ALL,
            .filter = filter_func,
        };
    }

    const VerifyResult = enum { accept, skip, reject };

    fn verify(self: *const TreeWalker, node: *parser.Node) !VerifyResult {
        const node_type = try parser.nodeType(node);
        const what_to_show = self.what_to_show;

        // Verify that we can show this node type.
        if (!switch (node_type) {
            .attribute => what_to_show & NodeFilter._SHOW_ATTRIBUTE != 0,
            .cdata_section => what_to_show & NodeFilter._SHOW_CDATA_SECTION != 0,
            .comment => what_to_show & NodeFilter._SHOW_COMMENT != 0,
            .document => what_to_show & NodeFilter._SHOW_DOCUMENT != 0,
            .document_fragment => what_to_show & NodeFilter._SHOW_DOCUMENT_FRAGMENT != 0,
            .document_type => what_to_show & NodeFilter._SHOW_DOCUMENT_TYPE != 0,
            .element => what_to_show & NodeFilter._SHOW_ELEMENT != 0,
            .entity => what_to_show & NodeFilter._SHOW_ENTITY != 0,
            .entity_reference => what_to_show & NodeFilter._SHOW_ENTITY_REFERENCE != 0,
            .notation => what_to_show & NodeFilter._SHOW_NOTATION != 0,
            .processing_instruction => what_to_show & NodeFilter._SHOW_PROCESSING_INSTRUCTION != 0,
            .text => what_to_show & NodeFilter._SHOW_TEXT != 0,
        }) return .reject;

        // Verify that we aren't filtering it out.
        if (self.filter) |f| {
            const filter = try f.call(u32, .{node});
            return switch (filter) {
                NodeFilter._FILTER_ACCEPT => .accept,
                NodeFilter._FILTER_REJECT => .reject,
                NodeFilter._FILTER_SKIP => .skip,
                else => .reject,
            };
        } else return .accept;
    }

    pub fn get_root(self: *TreeWalker) *parser.Node {
        return self.root;
    }

    pub fn get_currentNode(self: *TreeWalker) *parser.Node {
        return self.current_node;
    }

    pub fn get_whatToShow(self: *TreeWalker) u32 {
        return self.what_to_show;
    }

    pub fn get_filter(self: *TreeWalker) ?Env.Function {
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

            switch (try self.verify(child)) {
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

            switch (try self.verify(child)) {
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

            switch (try self.verify(current)) {
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

            switch (try self.verify(current)) {
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

            switch (try self.verify(current)) {
                .accept => return current,
                .reject, .skip => continue,
            }
        }
    }

    pub fn _firstChild(self: *TreeWalker) !?*parser.Node {
        if (try self.firstChild(self.current_node)) |child| {
            self.current_node = child;
            return child;
        }

        return null;
    }

    pub fn _lastChild(self: *TreeWalker) !?*parser.Node {
        if (try self.lastChild(self.current_node)) |child| {
            self.current_node = child;
            return child;
        }

        return null;
    }

    pub fn _nextNode(self: *TreeWalker) !?*parser.Node {
        if (try self.firstChild(self.current_node)) |child| {
            self.current_node = child;
            return child;
        }

        var current = self.current_node;
        while (current != self.root) {
            if (try self.nextSibling(current)) |sibling| {
                self.current_node = sibling;
                return sibling;
            }

            current = (try parser.nodeParentNode(current)) orelse break;
        }

        return null;
    }

    pub fn _nextSibling(self: *TreeWalker) !?*parser.Node {
        if (try self.nextSibling(self.current_node)) |sibling| {
            self.current_node = sibling;
            return sibling;
        }

        return null;
    }

    pub fn _parentNode(self: *TreeWalker) !?*parser.Node {
        if (try self.parentNode(self.current_node)) |parent| {
            self.current_node = parent;
            return parent;
        }

        return null;
    }

    pub fn _previousNode(self: *TreeWalker) !?*parser.Node {
        var current = self.current_node;
        while (try parser.nodePreviousSibling(current)) |previous| {
            current = previous;

            switch (try self.verify(current)) {
                .accept => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.current_node = child;
                        return child;
                    }

                    // Otherwise, this node is our previous one.
                    self.current_node = current;
                    return current;
                },
                .reject => continue,
                .skip => {
                    // Get last child if it has one.
                    if (try self.lastChild(current)) |child| {
                        self.current_node = child;
                        return child;
                    }
                },
            }
        }

        if (current != self.root) {
            if (try self.parentNode(current)) |parent| {
                self.current_node = parent;
                return parent;
            }
        }

        return null;
    }

    pub fn _previousSibling(self: *TreeWalker) !?*parser.Node {
        if (try self.previousSibling(self.current_node)) |sibling| {
            self.current_node = sibling;
            return sibling;
        }

        return null;
    }
};

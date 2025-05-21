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

// https://developer.mozilla.org/en-US/docs/Web/API/TreeWalker
pub const TreeWalker = struct {
    root: *parser.Node,
    current_node: *parser.Node,
    what_to_show: u32,
    filter: ?Env.Function,

    depth: usize,

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
            .depth = 0,
        };
    }

    fn verify_what_to_show(self: *const TreeWalker, node: *parser.Node) !bool {
        const node_type = try parser.nodeType(node);
        const what_to_show = self.what_to_show;
        return switch (node_type) {
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
        };
    }

    fn verify_filter(self: *const TreeWalker, node: *parser.Node) !bool {
        if (self.filter) |f| {
            const filter = try f.call(u32, .{node});
            return switch (filter) {
                NodeFilter._FILTER_ACCEPT => true,
                else => false,
            };
        } else return true;
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

    pub fn _firstChild(self: *TreeWalker) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(self.current_node);
        const child_count = try parser.nodeListLength(children);

        for (0..child_count) |i| {
            const index: u32 = @intCast(i);
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            if (!try self.verify_what_to_show(child)) continue;
            if (!try self.verify_filter(child)) continue;

            self.depth += 1;
            self.current_node = child;
            return child;
        }

        return null;
    }

    pub fn _lastChild(self: *TreeWalker) !?*parser.Node {
        const children = try parser.nodeGetChildNodes(self.current_node);
        const child_count = try parser.nodeListLength(children);

        for (0..child_count) |i| {
            const index: u32 = @intCast(child_count - 1 - i);
            const child = (try parser.nodeListItem(children, index)) orelse return null;

            if (!try self.verify_what_to_show(child)) continue;
            if (!try self.verify_filter(child)) continue;

            self.depth += 1;
            self.current_node = child;
            return child;
        }

        return null;
    }

    pub fn _nextNode(self: *TreeWalker) !?*parser.Node {
        return self._firstChild();
    }

    pub fn _nextSibling(self: *TreeWalker) !?*parser.Node {
        var current = self.current_node;

        while (true) {
            current = (try parser.nodeNextSibling(current)) orelse return null;
            if (!try self.verify_what_to_show(current)) continue;
            if (!try self.verify_filter(current)) continue;
            break;
        }

        return current;
    }

    pub fn _parentNode(self: *TreeWalker) !?*parser.Node {
        if (self.depth == 0) return null;

        const parent = (try parser.nodeParentNode(self.current_node)) orelse return null;

        if (!try self.verify_what_to_show(parent)) return null;
        if (!try self.verify_filter(parent)) return null;

        self.depth -= 1;
        self.current_node = parent;
        return parent;
    }

    pub fn _previousNode(self: *TreeWalker) !?*parser.Node {
        return self._parentNode();
    }

    pub fn _previousSibling(self: *TreeWalker) !?*parser.Node {
        var current = self.current_node;

        while (true) {
            current = (try parser.nodePreviousSibling(current)) orelse return null;
            if (!try self.verify_what_to_show(current)) continue;
            if (!try self.verify_filter(current)) continue;
            break;
        }

        return current;
    }
};

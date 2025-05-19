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
    filter: ?Env.Callback,

    pub fn init(node: *parser.Node, what_to_show: ?u32, filter: ?Env.Callback) TreeWalker {
        return .{
            .root = node,
            .current_node = node,
            .what_to_show = what_to_show orelse NodeFilter._SHOW_ALL,
            .filter = filter,
        };
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

    pub fn get_filter(self: *TreeWalker) ?Env.Callback {
        return self.filter;
    }

    pub fn _firstChild(self: *TreeWalker) ?*parser.Node {
        const first_child = parser.nodeFirstChild(self.current_node) catch return null;
        self.current_node = first_child orelse return null;
        return first_child;
    }

    pub fn _lastChild(self: *TreeWalker) ?*parser.Node {
        const last_child = parser.nodeLastChild(self.current_node) catch return null;
        self.current_node = last_child orelse return null;
        return last_child;
    }

    pub fn _nextNode(self: *TreeWalker) ?*parser.Node {
        return self._firstChild();
    }

    pub fn _nextSibling(self: *TreeWalker) ?*parser.Node {
        const next_sibling = parser.nodeNextSibling(self.current_node) catch return null;
        self.current_node = next_sibling orelse return null;
        return next_sibling;
    }

    pub fn _parentNode(self: *TreeWalker) ?*parser.Node {
        const parent = parser.nodeParentNode(self.current_node) catch return null;
        self.current_node = parent orelse return null;
        return parent;
    }

    pub fn _previousNode(self: *TreeWalker) ?*parser.Node {
        return self._parentNode();
    }

    pub fn _previousSibling(self: *TreeWalker) ?*parser.Node {
        const previous_sibling = parser.nodePreviousSibling(self.current_node) catch return null;
        self.current_node = previous_sibling orelse return null;
        return previous_sibling;
    }
};

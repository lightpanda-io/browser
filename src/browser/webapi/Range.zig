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
const DocumentFragment = @import("DocumentFragment.zig");

const Range = @This();

_end_offset: u32,
_start_offset: u32,
_end_container: *Node,
_start_container: *Node,

pub fn init(page: *Page) !*Range {
    // Per spec, a new range starts collapsed at the document's first position
    const doc = page.document.asNode();
    return page._factory.create(Range{
        ._end_offset = 0,
        ._start_offset = 0,
        ._end_container = doc,
        ._start_container = doc,
    });
}

pub fn getStartContainer(self: *const Range) *Node {
    return self._start_container;
}

pub fn getStartOffset(self: *const Range) u32 {
    return self._start_offset;
}

pub fn getEndContainer(self: *const Range) *Node {
    return self._end_container;
}

pub fn getEndOffset(self: *const Range) u32 {
    return self._end_offset;
}

pub fn getCollapsed(self: *const Range) bool {
    return self._start_container == self._end_container and
        self._start_offset == self._end_offset;
}

pub fn setStart(self: *Range, node: *Node, offset: u32) !void {
    self._start_container = node;
    self._start_offset = offset;

    // If start is now after end, collapse to start
    if (self.isStartAfterEnd()) {
        self._end_container = self._start_container;
        self._end_offset = self._start_offset;
    }
}

pub fn setEnd(self: *Range, node: *Node, offset: u32) !void {
    self._end_container = node;
    self._end_offset = offset;

    // If end is now before start, collapse to end
    if (self.isStartAfterEnd()) {
        self._start_container = self._end_container;
        self._start_offset = self._end_offset;
    }
}

pub fn setStartBefore(self: *Range, node: *Node) !void {
    const parent = node.parentNode() orelse return error.InvalidNodeType;
    const offset = parent.getChildIndex(node) orelse return error.NotFound;
    try self.setStart(parent, offset);
}

pub fn setStartAfter(self: *Range, node: *Node) !void {
    const parent = node.parentNode() orelse return error.InvalidNodeType;
    const offset = parent.getChildIndex(node) orelse return error.NotFound;
    try self.setStart(parent, offset + 1);
}

pub fn setEndBefore(self: *Range, node: *Node) !void {
    const parent = node.parentNode() orelse return error.InvalidNodeType;
    const offset = parent.getChildIndex(node) orelse return error.NotFound;
    try self.setEnd(parent, offset);
}

pub fn setEndAfter(self: *Range, node: *Node) !void {
    const parent = node.parentNode() orelse return error.InvalidNodeType;
    const offset = parent.getChildIndex(node) orelse return error.NotFound;
    try self.setEnd(parent, offset + 1);
}

pub fn selectNode(self: *Range, node: *Node) !void {
    const parent = node.parentNode() orelse return error.InvalidNodeType;
    const offset = parent.getChildIndex(node) orelse return error.NotFound;
    try self.setStart(parent, offset);
    try self.setEnd(parent, offset + 1);
}

pub fn selectNodeContents(self: *Range, node: *Node) !void {
    const length = node.getLength();
    try self.setStart(node, 0);
    try self.setEnd(node, length);
}

pub fn collapse(self: *Range, to_start: ?bool) void {
    if (to_start orelse true) {
        self._end_container = self._start_container;
        self._end_offset = self._start_offset;
    } else {
        self._start_container = self._end_container;
        self._start_offset = self._end_offset;
    }
}

pub fn cloneRange(self: *const Range, page: *Page) !*Range {
    return page._factory.create(Range{
        ._end_offset = self._end_offset,
        ._start_offset = self._start_offset,
        ._end_container = self._end_container,
        ._start_container = self._start_container,
    });
}

pub fn insertNode(self: *Range, node: *Node, page: *Page) !void {
    // Insert node at the start of the range
    const container = self._start_container;
    const offset = self._start_offset;

    if (container.is(Node.CData)) |_| {
        // If container is a text node, we need to split it
        const parent = container.parentNode() orelse return error.InvalidNodeType;

        if (offset == 0) {
            _ = try parent.insertBefore(node, container, page);
        } else {
            const text_data = container.getData();
            if (offset >= text_data.len) {
                _ = try parent.insertBefore(node, container.nextSibling(), page);
            } else {
                // Split the text node into before and after parts
                const before_text = text_data[0..offset];
                const after_text = text_data[offset..];

                const before = try page.createTextNode(before_text);
                const after = try page.createTextNode(after_text);

                _ = try parent.replaceChild(before, container, page);
                _ = try parent.insertBefore(node, before.nextSibling(), page);
                _ = try parent.insertBefore(after, node.nextSibling(), page);
            }
        }
    } else {
        // Container is an element, insert at offset
        const ref_child = container.getChildAt(offset);
        _ = try container.insertBefore(node, ref_child, page);
    }

    // Update range to be after the inserted node
    if (self._start_container == self._end_container) {
        self._end_offset += 1;
    }
}

pub fn deleteContents(self: *Range, page: *Page) !void {
    if (self.getCollapsed()) {
        return;
    }

    // Simple case: same container
    if (self._start_container == self._end_container) {
        if (self._start_container.is(Node.CData)) |_| {
            // Delete part of text node
            const text_data = self._start_container.getData();
            const new_text = try std.mem.concat(
                page.arena,
                u8,
                &.{ text_data[0..self._start_offset], text_data[self._end_offset..] },
            );
            self._start_container.setData(new_text);
        } else {
            // Delete child nodes in range
            var offset = self._start_offset;
            while (offset < self._end_offset) : (offset += 1) {
                if (self._start_container.getChildAt(self._start_offset)) |child| {
                    _ = try self._start_container.removeChild(child, page);
                }
            }
        }
        self.collapse(true);
        return;
    }

    // Complex case: different containers - simplified implementation
    // Just collapse the range for now
    self.collapse(true);
}

pub fn cloneContents(self: *const Range, page: *Page) !*DocumentFragment {
    const fragment = try DocumentFragment.init(page);

    if (self.getCollapsed()) return fragment;

    // Simple case: same container
    if (self._start_container == self._end_container) {
        if (self._start_container.is(Node.CData)) |_| {
            // Clone part of text node
            const text_data = self._start_container.getData();
            if (self._start_offset < text_data.len and self._end_offset <= text_data.len) {
                const cloned_text = text_data[self._start_offset..self._end_offset];
                const text_node = try page.createTextNode(cloned_text);
                _ = try fragment.asNode().appendChild(text_node, page);
            }
        } else {
            // Clone child nodes in range
            var offset = self._start_offset;
            while (offset < self._end_offset) : (offset += 1) {
                if (self._start_container.getChildAt(offset)) |child| {
                    const cloned = try child.cloneNode(true, page);
                    _ = try fragment.asNode().appendChild(cloned, page);
                }
            }
        }
    }

    return fragment;
}

pub fn extractContents(self: *Range, page: *Page) !*DocumentFragment {
    const fragment = try self.cloneContents(page);
    try self.deleteContents(page);
    return fragment;
}

pub fn surroundContents(self: *Range, new_parent: *Node, page: *Page) !void {
    // Extract contents
    const contents = try self.extractContents(page);

    // Insert the new parent
    try self.insertNode(new_parent, page);

    // Move contents into new parent
    _ = try new_parent.appendChild(contents.asNode(), page);

    // Select the new parent's contents
    try self.selectNodeContents(new_parent);
}

pub fn createContextualFragment(self: *const Range, html: []const u8, page: *Page) !*DocumentFragment {
    var context_node = self._start_container;

    // If start container is a text node, use its parent as context
    if (context_node.is(Node.CData)) |_| {
        context_node = context_node.parentNode() orelse context_node;
    }

    const fragment = try DocumentFragment.init(page);

    if (html.len == 0) {
        return fragment;
    }

    // Create a temporary element of the same type as the context for parsing
    // This preserves the parsing context without modifying the original node
    const temp_node = if (context_node.is(Node.Element)) |el|
        try page.createElement(el._namespace.toUri(), el.getTagNameLower(), null)
    else
        try page.createElement(null, "div", null);

    try page.parseHtmlAsChildren(temp_node, html);

    // Move all parsed children to the fragment
    // Keep removing first child until temp element is empty
    const fragment_node = fragment.asNode();
    while (temp_node.firstChild()) |child| {
        page.removeNode(temp_node, child, .{ .will_be_reconnected = true });
        try page.appendNode(fragment_node, child, .{ .child_already_connected = false });
    }

    return fragment;
}

pub fn toString(self: *const Range, page: *Page) ![]const u8 {
    // Simplified implementation: just extract text content
    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    try self.writeTextContent(&buf.writer);
    return buf.written();
}

fn writeTextContent(self: *const Range, writer: *std.Io.Writer) !void {
    if (self.getCollapsed()) {
        return;
    }

    if (self._start_container == self._end_container) {
        if (self._start_container.is(Node.CData)) |cdata| {
            const data = cdata.getData();
            if (self._start_offset < data.len and self._end_offset <= data.len) {
                try writer.writeAll(data[self._start_offset..self._end_offset]);
            }
        }
        // For elements, would need to iterate children
        return;
    }

    // Complex case: different containers - would need proper tree walking
    // For now, just return empty
}

fn isStartAfterEnd(self: *const Range) bool {
    return compareBoundaryPoints(
        self._start_container,
        self._start_offset,
        self._end_container,
        self._end_offset,
    ) == .after;
}

const BoundaryComparison = enum {
    before,
    equal,
    after,
};

/// Compare two boundary points in tree order
/// Returns whether (nodeA, offsetA) is before/equal/after (nodeB, offsetB)
fn compareBoundaryPoints(
    node_a: *Node,
    offset_a: u32,
    node_b: *Node,
    offset_b: u32,
) BoundaryComparison {
    // If same container, just compare offsets
    if (node_a == node_b) {
        if (offset_a < offset_b) return .before;
        if (offset_a > offset_b) return .after;
        return .equal;
    }

    // Check if one contains the other
    if (isAncestorOf(node_a, node_b)) {
        // A contains B, so A's position comes before B
        // But we need to check if the offset in A comes after B
        var child = node_b;
        var parent = child.parentNode();
        while (parent) |p| {
            if (p == node_a) {
                const child_index = p.getChildIndex(child) orelse unreachable;
                if (offset_a <= child_index) {
                    return .before;
                }
                return .after;
            }
            child = p;
            parent = p.parentNode();
        }
        unreachable;
    }

    if (isAncestorOf(node_b, node_a)) {
        // B contains A, so B's position comes before A
        var child = node_a;
        var parent = child.parentNode();
        while (parent) |p| {
            if (p == node_b) {
                const child_index = p.getChildIndex(child) orelse unreachable;
                if (child_index < offset_b) {
                    return .before;
                }
                return .after;
            }
            child = p;
            parent = p.parentNode();
        }
        unreachable;
    }

    // Neither contains the other, find their relative position in tree order
    // Walk up from A to find all ancestors
    var current = node_a;
    var a_count: usize = 0;
    var a_ancestors: [64]*Node = undefined;
    while (a_count < 64) {
        a_ancestors[a_count] = current;
        a_count += 1;
        current = current.parentNode() orelse break;
    }

    // Walk up from B and find first common ancestor
    current = node_b;
    while (current.parentNode()) |parent| {
        for (a_ancestors[0..a_count]) |ancestor| {
            if (ancestor != parent) {
                continue;
            }

            // Found common ancestor
            // Now compare positions of the children in this ancestor
            const a_child = blk: {
                var node = node_a;
                while (node.parentNode()) |p| {
                    if (p == parent) break :blk node;
                    node = p;
                }
                unreachable;
            };
            const b_child = current;

            const a_index = parent.getChildIndex(a_child) orelse unreachable;
            const b_index = parent.getChildIndex(b_child) orelse unreachable;

            if (a_index < b_index) {
                return .before;
            }
            if (a_index > b_index) {
                return .after;
            }
            return .equal;
        }
        current = parent;
    }

    // Should not reach here if nodes are in the same tree
    return .before;
}

fn isAncestorOf(potential_ancestor: *Node, node: *Node) bool {
    var current = node.parentNode();
    while (current) |parent| {
        if (parent == potential_ancestor) {
            return true;
        }
        current = parent.parentNode();
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Range);

    pub const Meta = struct {
        pub const name = "Range";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Range.init, .{});
    pub const startContainer = bridge.accessor(Range.getStartContainer, null, .{});
    pub const startOffset = bridge.accessor(Range.getStartOffset, null, .{});
    pub const endContainer = bridge.accessor(Range.getEndContainer, null, .{});
    pub const endOffset = bridge.accessor(Range.getEndOffset, null, .{});
    pub const collapsed = bridge.accessor(Range.getCollapsed, null, .{});
    pub const setStart = bridge.function(Range.setStart, .{});
    pub const setEnd = bridge.function(Range.setEnd, .{});
    pub const setStartBefore = bridge.function(Range.setStartBefore, .{});
    pub const setStartAfter = bridge.function(Range.setStartAfter, .{});
    pub const setEndBefore = bridge.function(Range.setEndBefore, .{});
    pub const setEndAfter = bridge.function(Range.setEndAfter, .{});
    pub const selectNode = bridge.function(Range.selectNode, .{});
    pub const selectNodeContents = bridge.function(Range.selectNodeContents, .{});
    pub const collapse = bridge.function(Range.collapse, .{});
    pub const cloneRange = bridge.function(Range.cloneRange, .{});
    pub const insertNode = bridge.function(Range.insertNode, .{});
    pub const deleteContents = bridge.function(Range.deleteContents, .{});
    pub const cloneContents = bridge.function(Range.cloneContents, .{});
    pub const extractContents = bridge.function(Range.extractContents, .{});
    pub const surroundContents = bridge.function(Range.surroundContents, .{});
    pub const createContextualFragment = bridge.function(Range.createContextualFragment, .{});
    pub const toString = bridge.function(Range.toString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Range" {
    try testing.htmlRunner("range.html", .{});
}

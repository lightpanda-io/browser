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
const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const DocumentFragment = @import("DocumentFragment.zig");
const AbstractRange = @import("AbstractRange.zig");

const Range = @This();

_proto: *AbstractRange,

pub fn asAbstractRange(self: *Range) *AbstractRange {
    return self._proto;
}

pub fn init(page: *Page) !*Range {
    return page._factory.abstractRange(Range{ ._proto = undefined }, page);
}

pub fn setStart(self: *Range, node: *Node, offset: u32) !void {
    if (node._type == .document_type) {
        return error.InvalidNodeType;
    }

    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    self._proto._start_container = node;
    self._proto._start_offset = offset;

    // If start is now after end, or nodes are in different trees, collapse to start
    const end_root = self._proto._end_container.getRootNode(null);
    const start_root = node.getRootNode(null);
    if (end_root != start_root or self._proto.isStartAfterEnd()) {
        self._proto._end_container = self._proto._start_container;
        self._proto._end_offset = self._proto._start_offset;
    }
}

pub fn setEnd(self: *Range, node: *Node, offset: u32) !void {
    if (node._type == .document_type) {
        return error.InvalidNodeType;
    }

    // Validate offset
    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    self._proto._end_container = node;
    self._proto._end_offset = offset;

    // If end is now before start, or nodes are in different trees, collapse to end
    const start_root = self._proto._start_container.getRootNode(null);
    const end_root = node.getRootNode(null);
    if (start_root != end_root or self._proto.isStartAfterEnd()) {
        self._proto._start_container = self._proto._end_container;
        self._proto._start_offset = self._proto._end_offset;
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
        self._proto._end_container = self._proto._start_container;
        self._proto._end_offset = self._proto._start_offset;
    } else {
        self._proto._start_container = self._proto._end_container;
        self._proto._start_offset = self._proto._end_offset;
    }
}

pub fn detach(_: *Range) void {
    // Legacy no-op method kept for backwards compatibility
    // Modern spec: "The detach() method must do nothing."
}

pub fn compareBoundaryPoints(self: *const Range, how_raw: i32, source_range: *const Range) !i16 {
    // Convert how parameter per WebIDL unsigned short conversion
    // This handles negative numbers and out-of-range values
    const how_mod = @mod(how_raw, 65536);
    const how: u16 = if (how_mod < 0) @intCast(@as(i32, how_mod) + 65536) else @intCast(how_mod);

    // If how is not one of 0, 1, 2, or 3, throw NotSupportedError
    if (how > 3) {
        return error.NotSupported;
    }

    // If the two ranges' root is different, throw WrongDocumentError
    const this_root = self._proto._start_container.getRootNode(null);
    const source_root = source_range._proto._start_container.getRootNode(null);
    if (this_root != source_root) {
        return error.WrongDocument;
    }

    // Determine which boundary points to compare based on how parameter
    const result = switch (how) {
        0 => AbstractRange.compareBoundaryPoints( // START_TO_START
            self._proto._start_container,
            self._proto._start_offset,
            source_range._proto._start_container,
            source_range._proto._start_offset,
        ),
        1 => AbstractRange.compareBoundaryPoints( // START_TO_END
            self._proto._end_container,
            self._proto._end_offset,
            source_range._proto._start_container,
            source_range._proto._start_offset,
        ),
        2 => AbstractRange.compareBoundaryPoints( // END_TO_END
            self._proto._end_container,
            self._proto._end_offset,
            source_range._proto._end_container,
            source_range._proto._end_offset,
        ),
        3 => AbstractRange.compareBoundaryPoints( // END_TO_START
            self._proto._start_container,
            self._proto._start_offset,
            source_range._proto._end_container,
            source_range._proto._end_offset,
        ),
        else => unreachable,
    };

    return switch (result) {
        .before => -1,
        .equal => 0,
        .after => 1,
    };
}

pub fn comparePoint(self: *const Range, node: *Node, offset: u32) !i16 {
    // Check if node is in a different tree than the range
    const node_root = node.getRootNode(null);
    const start_root = self._proto._start_container.getRootNode(null);
    if (node_root != start_root) {
        return error.WrongDocument;
    }

    if (node._type == .document_type) {
        return error.InvalidNodeType;
    }

    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    // Compare point with start boundary
    const cmp_start = AbstractRange.compareBoundaryPoints(
        node,
        offset,
        self._proto._start_container,
        self._proto._start_offset,
    );

    if (cmp_start == .before) {
        return -1;
    }

    const cmp_end = AbstractRange.compareBoundaryPoints(
        node,
        offset,
        self._proto._end_container,
        self._proto._end_offset,
    );

    return if (cmp_end == .after) 1 else 0;
}

pub fn isPointInRange(self: *const Range, node: *Node, offset: u32) !bool {
    // If node's root is different from the context object's root, return false
    const node_root = node.getRootNode(null);
    const start_root = self._proto._start_container.getRootNode(null);
    if (node_root != start_root) {
        return false;
    }

    if (node._type == .document_type) {
        return error.InvalidNodeType;
    }

    // If offset is greater than node's length, throw IndexSizeError
    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    // If (node, offset) is before start or after end, return false
    const cmp_start = AbstractRange.compareBoundaryPoints(
        node,
        offset,
        self._proto._start_container,
        self._proto._start_offset,
    );

    if (cmp_start == .before) {
        return false;
    }

    const cmp_end = AbstractRange.compareBoundaryPoints(
        node,
        offset,
        self._proto._end_container,
        self._proto._end_offset,
    );

    return cmp_end != .after;
}

pub fn intersectsNode(self: *const Range, node: *Node) bool {
    // If node's root is different from the context object's root, return false
    const node_root = node.getRootNode(null);
    const start_root = self._proto._start_container.getRootNode(null);
    if (node_root != start_root) {
        return false;
    }

    // Let parent be node's parent
    const parent = node.parentNode() orelse {
        // If parent is null, return true
        return true;
    };

    // Let offset be node's index
    const offset = parent.getChildIndex(node) orelse {
        // Should not happen if node has a parent
        return false;
    };

    // If (parent, offset) is before end and (parent, offset + 1) is after start, return true
    const before_end = AbstractRange.compareBoundaryPoints(
        parent,
        offset,
        self._proto._end_container,
        self._proto._end_offset,
    );

    const after_start = AbstractRange.compareBoundaryPoints(
        parent,
        offset + 1,
        self._proto._start_container,
        self._proto._start_offset,
    );

    if (before_end == .before and after_start == .after) {
        return true;
    }

    // Return false
    return false;
}

pub fn cloneRange(self: *const Range, page: *Page) !*Range {
    const clone = try page._factory.abstractRange(Range{ ._proto = undefined }, page);
    clone._proto._end_offset = self._proto._end_offset;
    clone._proto._start_offset = self._proto._start_offset;
    clone._proto._end_container = self._proto._end_container;
    clone._proto._start_container = self._proto._start_container;
    return clone;
}

pub fn insertNode(self: *Range, node: *Node, page: *Page) !void {
    // Insert node at the start of the range
    const container = self._proto._start_container;
    const offset = self._proto._start_offset;

    if (container.is(Node.CData)) |_| {
        // If container is a text node, we need to split it
        const parent = container.parentNode() orelse return error.InvalidNodeType;

        if (offset == 0) {
            _ = try parent.insertBefore(node, container, page);
        } else {
            const text_data = container.getData().str();
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
    if (self._proto._start_container == self._proto._end_container) {
        self._proto._end_offset += 1;
    }
}

pub fn deleteContents(self: *Range, page: *Page) !void {
    if (self._proto.getCollapsed()) {
        return;
    }
    page.domChanged();

    // Simple case: same container
    if (self._proto._start_container == self._proto._end_container) {
        if (self._proto._start_container.is(Node.CData)) |cdata| {
            // Delete part of text node
            const old_value = cdata.getData();
            const text_data = old_value.str();
            cdata._data = try String.concat(
                page.arena,
                &.{ text_data[0..self._proto._start_offset], text_data[self._proto._end_offset..] },
            );
            page.characterDataChange(self._proto._start_container, old_value);
        } else {
            // Delete child nodes in range
            var offset = self._proto._start_offset;
            while (offset < self._proto._end_offset) : (offset += 1) {
                if (self._proto._start_container.getChildAt(self._proto._start_offset)) |child| {
                    _ = try self._proto._start_container.removeChild(child, page);
                }
            }
        }
        self.collapse(true);
        return;
    }

    // Complex case: different containers
    // Handle start container - if it's a text node, truncate it
    if (self._proto._start_container.is(Node.CData)) |cdata| {
        const text_data = cdata._data.str();
        if (self._proto._start_offset < text_data.len) {
            // Keep only the part before start_offset
            const new_text = text_data[0..self._proto._start_offset];
            try self._proto._start_container.setData(new_text, page);
        }
    }

    // Handle end container - if it's a text node, truncate it
    if (self._proto._end_container.is(Node.CData)) |cdata| {
        const text_data = cdata._data.str();
        if (self._proto._end_offset < text_data.len) {
            // Keep only the part from end_offset onwards
            const new_text = text_data[self._proto._end_offset..];
            try self._proto._end_container.setData(new_text, page);
        } else if (self._proto._end_offset == text_data.len) {
            // If we're at the end, set to empty (will be removed if needed)
            try self._proto._end_container.setData("", page);
        }
    }

    // Remove nodes between start and end containers
    // For now, handle the common case where they're siblings
    if (self._proto._start_container.parentNode() == self._proto._end_container.parentNode()) {
        var current = self._proto._start_container.nextSibling();
        while (current != null and current != self._proto._end_container) {
            const next = current.?.nextSibling();
            if (current.?.parentNode()) |parent| {
                _ = try parent.removeChild(current.?, page);
            }
            current = next;
        }
    }

    self.collapse(true);
}

pub fn cloneContents(self: *const Range, page: *Page) !*DocumentFragment {
    const fragment = try DocumentFragment.init(page);

    if (self._proto.getCollapsed()) return fragment;

    // Simple case: same container
    if (self._proto._start_container == self._proto._end_container) {
        if (self._proto._start_container.is(Node.CData)) |_| {
            // Clone part of text node
            const text_data = self._proto._start_container.getData().str();
            if (self._proto._start_offset < text_data.len and self._proto._end_offset <= text_data.len) {
                const cloned_text = text_data[self._proto._start_offset..self._proto._end_offset];
                const text_node = try page.createTextNode(cloned_text);
                _ = try fragment.asNode().appendChild(text_node, page);
            }
        } else {
            // Clone child nodes in range
            var offset = self._proto._start_offset;
            while (offset < self._proto._end_offset) : (offset += 1) {
                if (self._proto._start_container.getChildAt(offset)) |child| {
                    const cloned = try child.cloneNode(true, page);
                    _ = try fragment.asNode().appendChild(cloned, page);
                }
            }
        }
    } else {
        // Complex case: different containers
        // Clone partial start container
        if (self._proto._start_container.is(Node.CData)) |_| {
            const text_data = self._proto._start_container.getData().str();
            if (self._proto._start_offset < text_data.len) {
                // Clone from start_offset to end of text
                const cloned_text = text_data[self._proto._start_offset..];
                const text_node = try page.createTextNode(cloned_text);
                _ = try fragment.asNode().appendChild(text_node, page);
            }
        }

        // Clone nodes between start and end containers (siblings case)
        if (self._proto._start_container.parentNode() == self._proto._end_container.parentNode()) {
            var current = self._proto._start_container.nextSibling();
            while (current != null and current != self._proto._end_container) {
                const cloned = try current.?.cloneNode(true, page);
                _ = try fragment.asNode().appendChild(cloned, page);
                current = current.?.nextSibling();
            }
        }

        // Clone partial end container
        if (self._proto._end_container.is(Node.CData)) |_| {
            const text_data = self._proto._end_container.getData().str();
            if (self._proto._end_offset > 0 and self._proto._end_offset <= text_data.len) {
                // Clone from start to end_offset
                const cloned_text = text_data[0..self._proto._end_offset];
                const text_node = try page.createTextNode(cloned_text);
                _ = try fragment.asNode().appendChild(text_node, page);
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
    var context_node = self._proto._start_container;

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
        try page.createElementNS(el._namespace, el.getTagNameLower(), null)
    else
        try page.createElementNS(.html, "div", null);

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
    if (self._proto.getCollapsed()) return;

    const start_node = self._proto._start_container;
    const end_node = self._proto._end_container;
    const start_offset = self._proto._start_offset;
    const end_offset = self._proto._end_offset;

    // Same text node — just substring
    if (start_node == end_node) {
        if (start_node.is(Node.CData)) |cdata| {
            if (!isCommentOrPI(cdata)) {
                const data = cdata.getData().str();
                const s = @min(start_offset, data.len);
                const e = @min(end_offset, data.len);
                try writer.writeAll(data[s..e]);
            }
            return;
        }
    }

    const root = self._proto.getCommonAncestorContainer();

    // Partial start: if start container is a text node, write from offset to end
    if (start_node.is(Node.CData)) |cdata| {
        if (!isCommentOrPI(cdata)) {
            const data = cdata.getData().str();
            const s = @min(start_offset, data.len);
            try writer.writeAll(data[s..]);
        }
    }

    // Walk fully-contained text nodes between the boundaries.
    // For text containers, the walk starts after that node.
    // For element containers, the walk starts at the child at offset.
    const walk_start: ?*Node = if (start_node.is(Node.CData) != null)
        nextInTreeOrder(start_node, root)
    else
        start_node.getChildAt(start_offset) orelse nextAfterSubtree(start_node, root);

    const walk_end: ?*Node = if (end_node.is(Node.CData) != null)
        end_node
    else
        end_node.getChildAt(end_offset) orelse nextAfterSubtree(end_node, root);

    if (walk_start) |start| {
        var current: ?*Node = start;
        while (current) |n| {
            if (walk_end) |we| {
                if (n == we) break;
            }
            if (n.is(Node.CData)) |cdata| {
                if (!isCommentOrPI(cdata)) {
                    try writer.writeAll(cdata.getData().str());
                }
            }
            current = nextInTreeOrder(n, root);
        }
    }

    // Partial end: if end container is a different text node, write from start to offset
    if (start_node != end_node) {
        if (end_node.is(Node.CData)) |cdata| {
            if (!isCommentOrPI(cdata)) {
                const data = cdata.getData().str();
                const e = @min(end_offset, data.len);
                try writer.writeAll(data[0..e]);
            }
        }
    }
}

fn isCommentOrPI(cdata: *Node.CData) bool {
    return cdata.is(Node.CData.Comment) != null or cdata.is(Node.CData.ProcessingInstruction) != null;
}

fn nextInTreeOrder(node: *Node, root: *Node) ?*Node {
    if (node.firstChild()) |child| return child;
    return nextAfterSubtree(node, root);
}

fn nextAfterSubtree(node: *Node, root: *Node) ?*Node {
    var current = node;
    while (current != root) {
        if (current.nextSibling()) |sibling| return sibling;
        current = current.parentNode() orelse return null;
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Range);

    pub const Meta = struct {
        pub const name = "Range";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Constants for compareBoundaryPoints
    pub const START_TO_START = bridge.property(0, .{ .template = true });
    pub const START_TO_END = bridge.property(1, .{ .template = true });
    pub const END_TO_END = bridge.property(2, .{ .template = true });
    pub const END_TO_START = bridge.property(3, .{ .template = true });

    pub const constructor = bridge.constructor(Range.init, .{});
    pub const setStart = bridge.function(Range.setStart, .{ .dom_exception = true });
    pub const setEnd = bridge.function(Range.setEnd, .{ .dom_exception = true });
    pub const setStartBefore = bridge.function(Range.setStartBefore, .{ .dom_exception = true });
    pub const setStartAfter = bridge.function(Range.setStartAfter, .{ .dom_exception = true });
    pub const setEndBefore = bridge.function(Range.setEndBefore, .{ .dom_exception = true });
    pub const setEndAfter = bridge.function(Range.setEndAfter, .{ .dom_exception = true });
    pub const selectNode = bridge.function(Range.selectNode, .{ .dom_exception = true });
    pub const selectNodeContents = bridge.function(Range.selectNodeContents, .{});
    pub const collapse = bridge.function(Range.collapse, .{ .dom_exception = true });
    pub const detach = bridge.function(Range.detach, .{});
    pub const compareBoundaryPoints = bridge.function(Range.compareBoundaryPoints, .{ .dom_exception = true });
    pub const comparePoint = bridge.function(Range.comparePoint, .{ .dom_exception = true });
    pub const isPointInRange = bridge.function(Range.isPointInRange, .{ .dom_exception = true });
    pub const intersectsNode = bridge.function(Range.intersectsNode, .{});
    pub const cloneRange = bridge.function(Range.cloneRange, .{ .dom_exception = true });
    pub const insertNode = bridge.function(Range.insertNode, .{ .dom_exception = true });
    pub const deleteContents = bridge.function(Range.deleteContents, .{ .dom_exception = true });
    pub const cloneContents = bridge.function(Range.cloneContents, .{ .dom_exception = true });
    pub const extractContents = bridge.function(Range.extractContents, .{ .dom_exception = true });
    pub const surroundContents = bridge.function(Range.surroundContents, .{ .dom_exception = true });
    pub const createContextualFragment = bridge.function(Range.createContextualFragment, .{ .dom_exception = true });
    pub const toString = bridge.function(Range.toString, .{ .dom_exception = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Range" {
    try testing.htmlRunner("range.html", .{});
}

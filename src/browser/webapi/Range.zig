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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const DocumentFragment = @import("DocumentFragment.zig");
const AbstractRange = @import("AbstractRange.zig");
const DOMRect = @import("DOMRect.zig");

const String = lp.String;

const Range = @This();

_proto: *AbstractRange,

pub fn init(frame: *Frame) !*Range {
    return initIn(frame.document.asNode(), frame);
}

// Both boundary points start at (container, 0); document.createRange()
// passes the document it was called on, which is not necessarily the
// frame's main document.
pub fn initIn(container: *Node, frame: *Frame) !*Range {
    const arena = try frame.getArena(.medium, "Range");
    errdefer frame.releaseArena(arena);
    const range = try frame._factory.abstractRange(arena, Range{ ._proto = undefined }, frame);
    range._proto._start_container = container;
    range._proto._end_container = container;
    return range;
}

pub fn asAbstractRange(self: *Range) *AbstractRange {
    return self._proto;
}

pub fn getCommonAncestorContainer(self: *const Range) *Node {
    return self._proto.getCommonAncestorContainer();
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
    const end_root = self._proto._end_container.getRootNode(.{});
    const start_root = node.getRootNode(.{});
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
    const start_root = self._proto._start_container.getRootNode(.{});
    const end_root = node.getRootNode(.{});
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
    // Per spec, toStart defaults to false: collapse to the end point.
    if (to_start orelse false) {
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
    const this_root = self._proto._start_container.getRootNode(.{});
    const source_root = source_range._proto._start_container.getRootNode(.{});
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
    const node_root = node.getRootNode(.{});
    const start_root = self._proto._start_container.getRootNode(.{});
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
    const node_root = node.getRootNode(.{});
    const start_root = self._proto._start_container.getRootNode(.{});
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
    const node_root = node.getRootNode(.{});
    const start_root = self._proto._start_container.getRootNode(.{});
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

pub fn cloneRange(self: *const Range, frame: *Frame) !*Range {
    const arena = try frame.getArena(.medium, "Range.clone");
    errdefer frame.releaseArena(arena);

    const clone = try frame._factory.abstractRange(arena, Range{ ._proto = undefined }, frame);
    clone._proto._end_offset = self._proto._end_offset;
    clone._proto._start_offset = self._proto._start_offset;
    clone._proto._end_container = self._proto._end_container;
    clone._proto._start_container = self._proto._start_container;
    return clone;
}

pub fn insertNode(self: *Range, node: *Node, frame: *Frame) !void {
    // Insert node at the start of the range
    const container = self._proto._start_container;
    const offset = self._proto._start_offset;

    // Per spec: if range is collapsed, end offset should extend to include
    // the inserted node. Capture before insertion since live range updates
    // in the insert path will adjust non-collapsed ranges automatically.
    const was_collapsed = self._proto.getCollapsed();

    if (container.is(Node.CData)) |_| {
        // If container is a text node, we need to split it
        const parent = container.parentNode() orelse return error.InvalidNodeType;

        if (offset == 0) {
            _ = try parent.insertBefore(node, container, frame);
        } else {
            const text_data = container.getData().str();
            const byte_off = byteOffset(text_data, offset);
            const text = if (byte_off < text_data.len) container.is(Node.CData.Text) else null;
            if (text) |t| {
                // Split the text node in place and insert before the second
                // half. splitText keeps live ranges updated and produces the
                // records browsers do (one for the split-off node, one for
                // the inserted node).
                const second = try t.splitText(offset, frame);
                _ = try parent.insertBefore(node, second._proto.asNode(), frame);
            } else {
                _ = try parent.insertBefore(node, container.nextSibling(), frame);
            }
        }
    } else {
        // Container is an element, insert at offset
        const ref_child = container.getChildAt(offset);
        _ = try container.insertBefore(node, ref_child, frame);
    }

    // Per spec step 11: if range was collapsed, extend end to include inserted node.
    // Non-collapsed ranges are already handled by the live range update in the insert path.
    if (was_collapsed) {
        self._proto._end_offset = self._proto._start_offset + 1;
    }
}

// Range offsets in CharacterData are UTF-16 code units; convert one to a
// byte index into the UTF-8 data. An offset inside a surrogate pair rounds
// down to the code point and out-of-range offsets clamp to the end — the
// conversion is monotonic, so a (start, end) offset pair always converts to
// ordered byte offsets (an error-clamp here turned a mid-surrogate start
// into data.len, producing start > end and a slice panic).
fn byteOffset(data: []const u8, utf16_offset: u32) usize {
    return Node.CData.utf16OffsetToUtf8Floor(data, utf16_offset);
}

pub fn deleteContents(self: *Range, frame: *Frame) !void {
    if (self._proto.getCollapsed()) {
        return;
    }
    frame.domChanged();

    const start_node = self._proto._start_container;
    const start_offset = self._proto._start_offset;
    const end_node = self._proto._end_container;
    const end_offset = self._proto._end_offset;

    // Same CharacterData container: replace the data in place.
    if (start_node == end_node) {
        if (start_node.is(Node.CData)) |cdata| {
            try cdata.replaceData(start_offset, end_offset - start_offset, "", frame);
            try self.setStart(start_node, start_offset);
            try self.setEnd(start_node, start_offset);
            return;
        }
    }

    // Contained nodes whose parent isn't also contained, in tree order.
    var to_remove: std.ArrayList(*Node) = .empty;
    try self.collectContained(self._proto.getCommonAncestorContainer(), &to_remove, frame.call_arena);

    // Where the collapsed range ends up: the start point if the start node
    // is an inclusive ancestor of the end node; otherwise just after the
    // highest partially-contained ancestor of the start node.
    var new_node = start_node;
    var new_offset = start_offset;
    if (start_node != end_node and !start_node.contains(end_node)) {
        var reference = start_node;
        while (reference.parentNode()) |parent| {
            if (parent == end_node or parent.contains(end_node)) break;
            reference = parent;
        }
        new_node = reference.parentNode().?;
        new_offset = (new_node.getChildIndex(reference) orelse 0) + 1;
    }

    if (start_node.is(Node.CData)) |cdata| {
        const length: u32 = @intCast(cdata.getLength());
        try cdata.replaceData(start_offset, length - start_offset, "", frame);
    }

    for (to_remove.items) |node| {
        if (node.parentNode()) |parent| {
            _ = try parent.removeChild(node, frame);
        }
    }

    if (end_node.is(Node.CData)) |cdata| {
        try cdata.replaceData(0, end_offset, "", frame);
    }

    try self.setStart(new_node, new_offset);
    try self.setEnd(new_node, new_offset);
}

// A node is contained in the range when its whole extent lies between the
// range's boundary points. Appends the top-most contained nodes (those whose
// parent isn't contained) under `node`, without descending into them.
fn collectContained(self: *const Range, node: *Node, list: *std.ArrayList(*Node), arena: std.mem.Allocator) !void {
    var it = node.childrenIterator();
    while (it.next()) |c| {
        if (self.nodeContained(c)) {
            try list.append(arena, c);
        } else if (c.contains(self._proto._start_container) or c.contains(self._proto._end_container)) {
            // A non-contained child either straddles a boundary point or lies
            // entirely outside the range; only the former can have contained
            // descendants, so don't descend into the rest.
            try self.collectContained(c, list, arena);
        }
    }
}

fn nodeContained(self: *const Range, node: *Node) bool {
    return containedBetween(
        node,
        self._proto._start_container,
        self._proto._start_offset,
        self._proto._end_container,
        self._proto._end_offset,
    );
}

pub fn cloneContents(self: *const Range, frame: *Frame) !*DocumentFragment {
    const fragment = try DocumentFragment.init(frame);
    if (self._proto.getCollapsed()) return fragment;

    try cloneContentsBetween(
        frame,
        fragment.asNode(),
        self._proto._start_container,
        self._proto._start_offset,
        self._proto._end_container,
        self._proto._end_offset,
    );
    return fragment;
}

// The DOM "clone the contents of a range" algorithm, on explicit boundary
// points so the partially-contained recursion doesn't need Range objects.
fn cloneContentsBetween(frame: *Frame, out: *Node, start_node: *Node, start_offset: u32, end_node: *Node, end_offset: u32) !void {
    if (start_node == end_node) {
        if (start_node.is(Node.CData)) |cdata| {
            const data = cdata.getData().str();
            const cloned = (try start_node.cloneNodeForAppending(false, frame)) orelse return;
            try cloned.setData(data[byteOffset(data, start_offset)..byteOffset(data, end_offset)], frame);
            _ = try out.appendChild(cloned, frame);
            return;
        }
    }

    // The closest common ancestor of the two boundary points.
    var common = start_node;
    while (common != end_node and !common.contains(end_node)) {
        common = common.parentNode() orelse break;
    }

    var child = common.firstChild();
    while (child) |c| : (child = c.nextSibling()) {
        const contains_start = c == start_node or c.contains(start_node);
        const contains_end = c == end_node or c.contains(end_node);

        if (contains_start) {
            // First partially contained child.
            if (c.is(Node.CData)) |cdata| {
                // c is the start node itself.
                const data = cdata.getData().str();
                const cloned = (try c.cloneNodeForAppending(false, frame)) orelse continue;
                try cloned.setData(data[byteOffset(data, start_offset)..], frame);
                _ = try out.appendChild(cloned, frame);
            } else {
                const cloned = (try c.cloneNodeForAppending(false, frame)) orelse continue;
                _ = try out.appendChild(cloned, frame);
                try cloneContentsBetween(frame, cloned, start_node, start_offset, c, c.getLength());
            }
        } else if (contains_end) {
            // Last partially contained child.
            if (c.is(Node.CData)) |cdata| {
                // c is the end node itself.
                const data = cdata.getData().str();
                const cloned = (try c.cloneNodeForAppending(false, frame)) orelse continue;
                try cloned.setData(data[0..byteOffset(data, end_offset)], frame);
                _ = try out.appendChild(cloned, frame);
            } else {
                const cloned = (try c.cloneNodeForAppending(false, frame)) orelse continue;
                _ = try out.appendChild(cloned, frame);
                try cloneContentsBetween(frame, cloned, c, 0, end_node, end_offset);
            }
        } else if (containedBetween(c, start_node, start_offset, end_node, end_offset)) {
            if (c._type == .document_type) {
                return error.HierarchyError;
            }
            const cloned = (try c.cloneNodeForAppending(true, frame)) orelse continue;
            _ = try out.appendChild(cloned, frame);
        }
    }
}

fn containedBetween(node: *Node, start_node: *Node, start_offset: u32, end_node: *Node, end_offset: u32) bool {
    const after_start = AbstractRange.compareBoundaryPoints(node, 0, start_node, start_offset) == .after;
    if (!after_start) return false;
    return AbstractRange.compareBoundaryPoints(node, node.getLength(), end_node, end_offset) == .before;
}

pub fn extractContents(self: *Range, frame: *Frame) !*DocumentFragment {
    const fragment = try DocumentFragment.init(frame);
    if (self._proto.getCollapsed()) return fragment;

    frame.domChanged();

    const start_node = self._proto._start_container;
    const start_offset = self._proto._start_offset;
    const end_node = self._proto._end_container;
    const end_offset = self._proto._end_offset;

    // Where the range collapses to afterwards; same rule as deleteContents.
    var new_node = start_node;
    var new_offset = start_offset;
    if (start_node != end_node and !start_node.contains(end_node)) {
        var reference = start_node;
        while (reference.parentNode()) |parent| {
            if (parent == end_node or parent.contains(end_node)) break;
            reference = parent;
        }
        new_node = reference.parentNode().?;
        new_offset = (new_node.getChildIndex(reference) orelse 0) + 1;
    }

    try extractContentsBetween(frame, fragment.asNode(), start_node, start_offset, end_node, end_offset);

    try self.setStart(new_node, new_offset);
    try self.setEnd(new_node, new_offset);
    return fragment;
}

// The DOM "extract" algorithm: contained nodes MOVE into the output
// (preserving identity); only the partially contained boundary
// CharacterData nodes and the partially contained element shells are cloned.
// Children are classified before anything moves, since moving a contained
// child shifts the indices the boundary comparisons rely on.
fn extractContentsBetween(frame: *Frame, out: *Node, start_node: *Node, start_offset: u32, end_node: *Node, end_offset: u32) !void {
    if (start_node == end_node) {
        if (start_node.is(Node.CData)) |cdata| {
            const data = cdata.getData().str();
            const cloned = (try start_node.cloneNodeForAppending(false, frame)) orelse return;
            try cloned.setData(data[byteOffset(data, start_offset)..byteOffset(data, end_offset)], frame);
            _ = try out.appendChild(cloned, frame);
            try cdata.replaceData(start_offset, end_offset - start_offset, "", frame);
            return;
        }
    }

    var common = start_node;
    while (common != end_node and !common.contains(end_node)) {
        common = common.parentNode() orelse break;
    }

    var first_partial: ?*Node = null;
    var last_partial: ?*Node = null;
    var contained: std.ArrayList(*Node) = .empty;

    var child = common.firstChild();
    while (child) |c| : (child = c.nextSibling()) {
        if (c == start_node or c.contains(start_node)) {
            first_partial = c;
        } else if (c == end_node or c.contains(end_node)) {
            last_partial = c;
        } else if (containedBetween(c, start_node, start_offset, end_node, end_offset)) {
            if (c._type == .document_type) {
                return error.HierarchyError;
            }
            try contained.append(frame.call_arena, c);
        }
    }

    if (first_partial) |c| {
        if (c.is(Node.CData)) |cdata| {
            // c is the start node itself.
            const data = cdata.getData().str();
            const byte_start = byteOffset(data, start_offset);
            const cloned = (try c.cloneNodeForAppending(false, frame)) orelse return;
            try cloned.setData(data[byte_start..], frame);
            _ = try out.appendChild(cloned, frame);
            const length: u32 = @intCast(cdata.getLength());
            try cdata.replaceData(start_offset, length - start_offset, "", frame);
        } else {
            const cloned = (try c.cloneNodeForAppending(false, frame)) orelse return;
            _ = try out.appendChild(cloned, frame);
            try extractContentsBetween(frame, cloned, start_node, start_offset, c, c.getLength());
        }
    }

    for (contained.items) |c| {
        _ = try out.appendChild(c, frame);
    }

    if (last_partial) |c| {
        if (c.is(Node.CData)) |cdata| {
            // c is the end node itself.
            const data = cdata.getData().str();
            const cloned = (try c.cloneNodeForAppending(false, frame)) orelse return;
            try cloned.setData(data[0..byteOffset(data, end_offset)], frame);
            _ = try out.appendChild(cloned, frame);
            try cdata.replaceData(0, end_offset, "", frame);
        } else {
            const cloned = (try c.cloneNodeForAppending(false, frame)) orelse return;
            _ = try out.appendChild(cloned, frame);
            try extractContentsBetween(frame, cloned, c, 0, end_node, end_offset);
        }
    }
}

pub fn surroundContents(self: *Range, new_parent: *Node, frame: *Frame) !void {
    // Extract contents
    const contents = try self.extractContents(frame);

    // Insert the new parent
    try self.insertNode(new_parent, frame);

    // Move contents into new parent
    _ = try new_parent.appendChild(contents.asNode(), frame);

    // Select the new parent's contents
    try self.selectNodeContents(new_parent);
}

pub fn createContextualFragment(self: *const Range, html: []const u8, frame: *Frame) !*DocumentFragment {
    var context_node = self._proto._start_container;

    // If start container is a text node, use its parent as context
    if (context_node.is(Node.CData)) |_| {
        context_node = context_node.parentNode() orelse context_node;
    }

    const fragment = try DocumentFragment.init(frame);

    if (html.len == 0) {
        return fragment;
    }

    // Create a temporary element of the same type as the context for parsing
    // This preserves the parsing context without modifying the original node
    const temp_node = if (context_node.is(Node.Element)) |el|
        try Frame.node_factory.createElementNS(frame, el._namespace, el.getTagNameLower(), null)
    else
        try Frame.node_factory.createElementNS(frame, .html, "div", null);

    try frame.parseContextualFragment(temp_node, html);

    // Move all parsed children to the fragment
    // Keep removing first child until temp element is empty
    const fragment_node = fragment.asNode();
    while (temp_node.firstChild()) |child| {
        frame.removeNode(temp_node, child, .{ .will_be_reconnected = true });
        try frame.appendNode(fragment_node, child, .{ .child_already_connected = false });
    }

    return fragment;
}

pub fn toString(self: *const Range, frame: *Frame) ![]const u8 {
    // Simplified implementation: just extract text content
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
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
                const s = byteOffset(data, start_offset);
                const e = byteOffset(data, end_offset);
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
            const s = byteOffset(data, start_offset);
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
                const e = byteOffset(data, end_offset);
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

pub fn getBoundingClientRect(self: *const Range, frame: *Frame) !*DOMRect {
    if (self._proto.getCollapsed()) {
        return DOMRect.create(.{}, frame._factory);
    }
    const element = self.getContainerElement() orelse {
        return DOMRect.create(.{}, frame._factory);
    };
    return element.getBoundingClientRect(frame);
}

pub fn getClientRects(self: *const Range, frame: *Frame) ![]*DOMRect {
    if (self._proto.getCollapsed()) {
        return &.{};
    }
    const element = self.getContainerElement() orelse {
        return &.{};
    };
    return element.getClientRects(frame);
}

fn getContainerElement(self: *const Range) ?*Node.Element {
    const container = self._proto.getCommonAncestorContainer();
    if (container.is(Node.Element)) |el| return el;
    const parent = container.parentNode() orelse return null;
    return parent.is(Node.Element);
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
    pub const commonAncestorContainer = bridge.accessor(Range.getCommonAncestorContainer, null, .{});
    pub const setStart = bridge.function(Range.setStart, .{});
    pub const setEnd = bridge.function(Range.setEnd, .{});
    pub const setStartBefore = bridge.function(Range.setStartBefore, .{});
    pub const setStartAfter = bridge.function(Range.setStartAfter, .{});
    pub const setEndBefore = bridge.function(Range.setEndBefore, .{});
    pub const setEndAfter = bridge.function(Range.setEndAfter, .{});
    pub const selectNode = bridge.function(Range.selectNode, .{});
    pub const selectNodeContents = bridge.function(Range.selectNodeContents, .{});
    pub const collapse = bridge.function(Range.collapse, .{});
    pub const detach = bridge.function(Range.detach, .{});
    pub const compareBoundaryPoints = bridge.function(Range.compareBoundaryPoints, .{});
    pub const comparePoint = bridge.function(Range.comparePoint, .{});
    pub const isPointInRange = bridge.function(Range.isPointInRange, .{});
    pub const intersectsNode = bridge.function(Range.intersectsNode, .{});
    pub const cloneRange = bridge.function(Range.cloneRange, .{});
    pub const insertNode = bridge.function(Range.insertNode, .{ .ce_reactions = true });
    pub const deleteContents = bridge.function(Range.deleteContents, .{ .ce_reactions = true });
    pub const cloneContents = bridge.function(Range.cloneContents, .{ .ce_reactions = true });
    pub const extractContents = bridge.function(Range.extractContents, .{ .ce_reactions = true });
    pub const surroundContents = bridge.function(Range.surroundContents, .{ .ce_reactions = true });
    pub const createContextualFragment = bridge.function(Range.createContextualFragment, .{ .ce_reactions = true });
    pub const toString = bridge.function(Range.toString, .{});
    pub const getBoundingClientRect = bridge.function(Range.getBoundingClientRect, .{});
    pub const getClientRects = bridge.function(Range.getClientRects, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Range" {
    try testing.htmlRunner("range.html", .{});
}
test "WebApi: Range mutations" {
    try testing.htmlRunner("range_mutations.html", .{});
}

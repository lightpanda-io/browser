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
const Page = @import("../page.zig").Page;

const Node = @import("node.zig").Node;
const NodeUnion = @import("node.zig").Union;
const DOMException = @import("exceptions.zig").DOMException;

pub const Interfaces = .{
    AbstractRange,
    Range,
};

pub const AbstractRange = struct {
    collapsed: bool,
    end_node: *parser.Node,
    end_offset: u32,
    start_node: *parser.Node,
    start_offset: u32,

    pub fn updateCollapsed(self: *AbstractRange) void {
        // TODO: Eventually, compare properly.
        self.collapsed = false;
    }

    pub fn get_collapsed(self: *const AbstractRange) bool {
        return self.collapsed;
    }

    pub fn get_endContainer(self: *const AbstractRange) !NodeUnion {
        return Node.toInterface(self.end_node);
    }

    pub fn get_endOffset(self: *const AbstractRange) u32 {
        return self.end_offset;
    }

    pub fn get_startContainer(self: *const AbstractRange) !NodeUnion {
        return Node.toInterface(self.start_node);
    }

    pub fn get_startOffset(self: *const AbstractRange) u32 {
        return self.start_offset;
    }
};

pub const Range = struct {
    pub const Exception = DOMException;
    pub const prototype = *AbstractRange;

    proto: AbstractRange,

    pub const _START_TO_START = 0;
    pub const _START_TO_END = 1;
    pub const _END_TO_END = 2;
    pub const _END_TO_START = 3;

    // The Range() constructor returns a newly created Range object whose start
    // and end is the global Document object.
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/Range
    pub fn constructor(page: *Page) Range {
        const proto: AbstractRange = .{
            .collapsed = true,
            .end_node = parser.documentHTMLToNode(page.window.document),
            .end_offset = 0,
            .start_node = parser.documentHTMLToNode(page.window.document),
            .start_offset = 0,
        };

        return .{ .proto = proto };
    }

    pub fn _setStart(self: *Range, node: *parser.Node, offset_: i32) !void {
        try ensureValidOffset(node, offset_);
        const offset: u32 = @intCast(offset_);
        const position = compare(node, offset, self.proto.start_node, self.proto.start_offset) catch |err| switch (err) {
            error.WrongDocument => blk: {
                // allow a node with a different root than the current, or
                // a disconnected one. Treat it as if it's "after", so that
                // we also update the end_offset and end_node.
                break :blk 1;
            },
            else => return err,
        };

        if (position == 1) {
            // if we're setting the node after the current start, the end must
            // be set too.
            self.proto.end_offset = offset;
            self.proto.end_node = node;
        }
        self.proto.start_node = node;
        self.proto.start_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setStartBefore(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.start_node = parent;
        self.proto.start_offset = index;
    }

    pub fn _setStartAfter(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.start_node = parent;
        self.proto.start_offset = index + 1;
    }

    pub fn _setEnd(self: *Range, node: *parser.Node, offset_: i32) !void {
        try ensureValidOffset(node, offset_);
        const offset: u32 = @intCast(offset_);

        const position = compare(node, offset, self.proto.start_node, self.proto.start_offset) catch |err| switch (err) {
            error.WrongDocument => blk: {
                // allow a node with a different root than the current, or
                // a disconnected one. Treat it as if it's "before", so that
                // we also update the end_offset and end_node.
                break :blk -1;
            },
            else => return err,
        };

        if (position == -1) {
            // if we're setting the node before the current start, the start
            // must be set too.
            self.proto.start_offset = offset;
            self.proto.start_node = node;
        }

        self.proto.end_node = node;
        self.proto.end_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setEndBefore(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.end_node = parent;
        self.proto.end_offset = index;
    }

    pub fn _setEndAfter(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.end_node = parent;
        self.proto.end_offset = index + 1;
    }

    pub fn _createContextualFragment(_: *Range, fragment: []const u8, page: *Page) !*parser.DocumentFragment {
        const document_html = page.window.document;
        const document = parser.documentHTMLToDocument(document_html);
        const doc_frag = try parser.documentParseFragmentFromStr(document, fragment);
        return doc_frag;
    }

    pub fn _selectNodeContents(self: *Range, node: *parser.Node) !void {
        self.proto.start_node = node;
        self.proto.start_offset = 0;
        self.proto.end_node = node;

        // Set end_offset
        switch (parser.nodeType(node)) {
            .text, .cdata_section, .comment, .processing_instruction => {
                // For text-like nodes, end_offset should be the length of the text data
                if (parser.nodeValue(node)) |text_data| {
                    self.proto.end_offset = @intCast(text_data.len);
                } else {
                    self.proto.end_offset = 0;
                }
            },
            else => {
                // For element and other nodes, end_offset is the number of children
                const child_nodes = try parser.nodeGetChildNodes(node);
                const child_count = parser.nodeListLength(child_nodes);
                self.proto.end_offset = @intCast(child_count);
            },
        }

        self.proto.updateCollapsed();
    }

    // creates a copy
    pub fn _cloneRange(self: *const Range) Range {
        return .{
            .proto = .{
                .collapsed = self.proto.collapsed,
                .end_node = self.proto.end_node,
                .end_offset = self.proto.end_offset,
                .start_node = self.proto.start_node,
                .start_offset = self.proto.start_offset,
            },
        };
    }

    pub fn _comparePoint(self: *const Range, node: *parser.Node, offset_: i32) !i32 {
        const start = self.proto.start_node;
        if (parser.nodeGetRootNode(start) != parser.nodeGetRootNode(node)) {
            // WPT really wants this error to be first. Later, when we check
            // if the relative position is 'disconnected', it'll also catch this
            // case, but WPT will complain because it sometimes also sends
            // invalid offsets, and it wants WrongDocument to be raised.
            return error.WrongDocument;
        }

        if (parser.nodeType(node) == .document_type) {
            return error.InvalidNodeType;
        }

        try ensureValidOffset(node, offset_);

        const offset: u32 = @intCast(offset_);
        if (try compare(node, offset, start, self.proto.start_offset) == -1) {
            return -1;
        }

        if (try compare(node, offset, self.proto.end_node, self.proto.end_offset) == 1) {
            return 1;
        }

        return 0;
    }

    pub fn _isPointInRange(self: *const Range, node: *parser.Node, offset_: i32) !bool {
        return self._comparePoint(node, offset_) catch |err| switch (err) {
            error.WrongDocument => return false,
            else => return err,
        } == 0;
    }

    pub fn _intersectsNode(self: *const Range, node: *parser.Node) !bool {
        const start_root = parser.nodeGetRootNode(self.proto.start_node);
        const node_root = parser.nodeGetRootNode(node);
        if (start_root != node_root) {
            return false;
        }

        const parent, const index = getParentAndIndex(node) catch |err| switch (err) {
            error.InvalidNodeType => return true, // if node has no parent, we return true.
            else => return err,
        };

        if (try compare(parent, index + 1, self.proto.start_node, self.proto.start_offset) != 1) {
            // node isn't after start, can't intersect
            return false;
        }

        if (try compare(parent, index, self.proto.end_node, self.proto.end_offset) != -1) {
            // node isn't before end, can't intersect
            return false;
        }

        return true;
    }

    pub fn _compareBoundaryPoints(self: *const Range, how: i32, other: *const Range) !i32 {
        return switch (how) {
            _START_TO_START => compare(self.proto.start_node, self.proto.start_offset, other.proto.start_node, other.proto.start_offset),
            _START_TO_END => compare(self.proto.start_node, self.proto.start_offset, other.proto.end_node, other.proto.end_offset),
            _END_TO_END => compare(self.proto.end_node, self.proto.end_offset, other.proto.end_node, other.proto.end_offset),
            _END_TO_START => compare(self.proto.end_node, self.proto.end_offset, other.proto.start_node, other.proto.start_offset),
            else => error.NotSupported, // this is the correct DOM Exception to return
        };
    }

    // The Range.detach() method does nothing. It used to disable the Range
    // object and enable the browser to release associated resources. The
    // method has been kept for compatibility.
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/detach
    pub fn _detach(_: *Range) void {}
};

fn ensureValidOffset(node: *parser.Node, offset: i32) !void {
    if (offset < 0) {
        return error.IndexSize;
    }

    // not >= because 0 seems to represent the node itself.
    if (offset > try nodeLength(node)) {
        return error.IndexSize;
    }
}

fn nodeLength(node: *parser.Node) !usize {
    switch (try isTextual(node)) {
        true => return ((parser.nodeTextContent(node)) orelse "").len,
        false => {
            const children = try parser.nodeGetChildNodes(node);
            return @intCast(parser.nodeListLength(children));
        },
    }
}

fn isTextual(node: *parser.Node) !bool {
    return switch (parser.nodeType(node)) {
        .text, .comment, .cdata_section => true,
        else => false,
    };
}

fn getParentAndIndex(child: *parser.Node) !struct { *parser.Node, u32 } {
    const parent = (parser.nodeParentNode(child)) orelse return error.InvalidNodeType;
    const children = try parser.nodeGetChildNodes(parent);
    const ln = parser.nodeListLength(children);
    var i: u32 = 0;
    while (i < ln) {
        defer i += 1;
        const c = parser.nodeListItem(children, i) orelse continue;
        if (c == child) {
            return .{ parent, i };
        }
    }

    // should not be possible to reach this point
    return error.InvalidNodeType;
}

// implementation is largely copied from the WPT helper called getPosition in
// the common.js of the dom folder.
fn compare(node_a: *parser.Node, offset_a: u32, node_b: *parser.Node, offset_b: u32) !i32 {
    if (node_a == node_b) {
        // This is a simple and common case, where the two nodes are the same
        // We just need to compare their offsets
        if (offset_a == offset_b) {
            return 0;
        }
        return if (offset_a < offset_b) -1 else 1;
    }

    // We're probably comparing two different nodes. "Probably", because the
    // above case on considered the offset if the two nodes were the same
    // as-is. They could still be the same here, if we first consider the
    // offset.
    const position = try Node._compareDocumentPosition(node_b, node_a);
    if (position & @intFromEnum(parser.DocumentPosition.disconnected) == @intFromEnum(parser.DocumentPosition.disconnected)) {
        return error.WrongDocument;
    }

    if (position & @intFromEnum(parser.DocumentPosition.following) == @intFromEnum(parser.DocumentPosition.following)) {
        return switch (try compare(node_b, offset_b, node_a, offset_a)) {
            -1 => 1,
            1 => -1,
            else => unreachable,
        };
    }

    if (position & @intFromEnum(parser.DocumentPosition.contains) == @intFromEnum(parser.DocumentPosition.contains)) {
        // node_a contains node_b
        var child = node_b;
        while (parser.nodeParentNode(child)) |parent| {
            if (parent == node_a) {
                // child.parentNode == node_a
                break;
            }
            child = parent;
        } else {
            // this should not happen, because  Node._compareDocumentPosition
            // has told us that node_a contains node_b, so one of node_b's
            // parent's MUST be node_a. But somehow we do end up here sometimes.
            return -1;
        }

        const child_parent, const child_index = try getParentAndIndex(child);
        std.debug.assert(node_a == child_parent);
        return if (child_index < offset_a) -1 else 1;
    }

    return -1;
}

const testing = @import("../../testing.zig");
test "Browser: Range" {
    try testing.htmlRunner("dom/range.html");
}

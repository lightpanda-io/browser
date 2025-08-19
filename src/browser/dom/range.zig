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
    end_container: *parser.Node,
    end_offset: u32,
    start_container: *parser.Node,
    start_offset: u32,

    pub fn updateCollapsed(self: *AbstractRange) void {
        // TODO: Eventually, compare properly.
        self.collapsed = false;
    }

    pub fn get_collapsed(self: *const AbstractRange) bool {
        return self.collapsed;
    }

    pub fn get_endContainer(self: *const AbstractRange) !NodeUnion {
        return Node.toInterface(self.end_container);
    }

    pub fn get_endOffset(self: *const AbstractRange) u32 {
        return self.end_offset;
    }

    pub fn get_startContainer(self: *const AbstractRange) !NodeUnion {
        return Node.toInterface(self.start_container);
    }

    pub fn get_startOffset(self: *const AbstractRange) u32 {
        return self.start_offset;
    }
};

pub const Range = struct {
    pub const Exception = DOMException;
    pub const prototype = *AbstractRange;

    proto: AbstractRange,

    // The Range() constructor returns a newly created Range object whose start
    // and end is the global Document object.
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/Range
    pub fn constructor(page: *Page) Range {
        const proto: AbstractRange = .{
            .collapsed = true,
            .end_container = parser.documentHTMLToNode(page.window.document),
            .end_offset = 0,
            .start_container = parser.documentHTMLToNode(page.window.document),
            .start_offset = 0,
        };

        return .{ .proto = proto };
    }

    pub fn _setStart(self: *Range, node: *parser.Node, offset_: i32) !void {
        const relative = self._comparePoint(node, offset_) catch |err| switch (err) {
            error.WrongDocument => blk: {
                // comparePoint doesn't check this on WrongDocument.
                try ensureValidOffset(node, offset_);

                // allow a node with a different root than the current, or
                // a disconnected one. Treat it as if it's "after", so that
                // we also update the end_offset and end_container.
                break :blk 1;
            },
            else => return err,
        };

        const offset: u32 = @intCast(offset_);
        if (relative == 1) {
            // if we're setting the node after the current start, the end must
            // be set too.
            self.proto.end_offset = offset;
            self.proto.end_container = node;
        }
        self.proto.start_container = node;
        self.proto.start_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setStartBefore(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.start_container = parent;
        self.proto.start_offset = index;
    }

    pub fn _setStartAfter(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.start_container = parent;
        self.proto.start_offset = index + 1;
    }

    pub fn _setEnd(self: *Range, node: *parser.Node, offset_: i32) !void {
        const relative = self._comparePoint(node, offset_) catch |err| switch (err) {
            error.WrongDocument => blk: {
                // comparePoint doesn't check this on WrongDocument.
                try ensureValidOffset(node, offset_);

                // allow a node with a different root than the current, or
                // a disconnected one. Treat it as if it's "before", so that
                // we also update the end_offset and end_container.
                break :blk -1;
            },
            else => return err,
        };

        const offset: u32 = @intCast(offset_);
        if (relative == -1) {
            // if we're setting the node before the current start, the start
            // must be
            self.proto.start_offset = offset;
            self.proto.start_container = node;
        }

        self.proto.end_container = node;
        self.proto.end_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setEndBefore(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.end_container = parent;
        self.proto.end_offset = index;
    }

    pub fn _setEndAfter(self: *Range, node: *parser.Node) !void {
        const parent, const index = try getParentAndIndex(node);
        self.proto.end_container = parent;
        self.proto.end_offset = index + 1;
    }

    pub fn _createContextualFragment(_: *Range, fragment: []const u8, page: *Page) !*parser.DocumentFragment {
        const document_html = page.window.document;
        const document = parser.documentHTMLToDocument(document_html);
        const doc_frag = try parser.documentParseFragmentFromStr(document, fragment);
        return doc_frag;
    }

    pub fn _selectNodeContents(self: *Range, node: *parser.Node) !void {
        self.proto.start_container = node;
        self.proto.start_offset = 0;
        self.proto.end_container = node;

        // Set end_offset
        switch (try parser.nodeType(node)) {
            .text, .cdata_section, .comment, .processing_instruction => {
                // For text-like nodes, end_offset should be the length of the text data
                if (try parser.nodeValue(node)) |text_data| {
                    self.proto.end_offset = @intCast(text_data.len);
                } else {
                    self.proto.end_offset = 0;
                }
            },
            else => {
                // For element and other nodes, end_offset is the number of children
                const child_nodes = try parser.nodeGetChildNodes(node);
                const child_count = try parser.nodeListLength(child_nodes);
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
                .end_container = self.proto.end_container,
                .end_offset = self.proto.end_offset,
                .start_container = self.proto.start_container,
                .start_offset = self.proto.start_offset,
            },
        };
    }

    pub fn _comparePoint(self: *const Range, ref_node: *parser.Node, offset_: i32) !i32 {
        const start = self.proto.start_container;
        if (try parser.nodeGetRootNode(start) != try parser.nodeGetRootNode(ref_node)) {
            // WPT really wants this error to be first. Later, when we check
            // if the relative position is 'disconnected', it'll also catch this
            // case, but WPT will complain because it sometimes also sends
            // invalid offsets, and it wants WrongDocument to be raised.
            return error.WrongDocument;
        }

        if (try parser.nodeType(ref_node) == .document_type) {
            return error.InvalidNodeType;
        }

        try ensureValidOffset(ref_node, offset_);

        const offset: u32 = @intCast(offset_);
        if (ref_node == start) {
            // This is a simple and common case, where the reference node and
            // our start node are the same, so we just have to compare the offsets
            const start_offset = self.proto.start_offset;
            if (offset == start_offset) {
                return 0;
            }
            return if (offset < start_offset) -1 else 1;
        }

        // We're probably comparing two different nodes. "Probably", because the
        // above case on considered the offset if the two nodes were the same
        // as-is. They could still be the same here, if we first consider the
        // offset.
        // Furthermore, as far as I can tell, if either or both nodes are textual,
        // then we're doing a node comparison of their parents. This kind of
        // makes sense, one/two text nodes which aren't the same, can only
        // be positionally compared in relation to it/their parents.

        const adjusted_start = try getNodeForCompare(start, self.proto.start_offset);
        const adjusted_ref_node = try getNodeForCompare(ref_node, offset);

        const relative = try Node._compareDocumentPosition(adjusted_start, adjusted_ref_node);

        if (relative & @intFromEnum(parser.DocumentPosition.disconnected) == @intFromEnum(parser.DocumentPosition.disconnected)) {
            return error.WrongDocument;
        }

        if (relative & @intFromEnum(parser.DocumentPosition.preceding) == @intFromEnum(parser.DocumentPosition.preceding)) {
            return -1;
        }

        if (relative & @intFromEnum(parser.DocumentPosition.following) == @intFromEnum(parser.DocumentPosition.following)) {
            return 1;
        }

        // DUNNO
        // unreachable??
        return 0;
    }

    pub fn _isPointInRange(self: *const Range, ref_node: *parser.Node, offset_: i32) !bool {
        return self._comparePoint(ref_node, offset_) catch |err| switch (err) {
            error.WrongDocument => return false,
            else => return err,
        } == 0;
    }

    // The Range.detach() method does nothing. It used to disable the Range
    // object and enable the browser to release associated resources. The
    // method has been kept for compatibility.
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/detach
    pub fn _detach(_: *Range) void {}
};

fn getNodeForCompare(node: *parser.Node, offset: u32) !*parser.Node {
    if (try isTextual(node)) {
        // when we're comparing a text node to another node which is not the same
        // then we're really compare the position of the parent. It doesn't
        // matter if the other node is a text node itself or not, all that matters
        // is we're sure it isn't the same text node (because if they are the
        // same text node, then we're comparing the offset (character position)
        // of the text node)

        // not sure this is the correct error
        return (try parser.nodeParentNode(node)) orelse return error.WrongDocument;
    }
    if (offset == 0) {
        return node;
    }

    const children = try parser.nodeGetChildNodes(node);

    // not sure about this error
    // - 1 because, while the offset is 0 based, 0 seems to represent the parent
    return (try parser.nodeListItem(children, offset - 1)) orelse error.IndexSize;
}

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
        true => return ((try parser.nodeTextContent(node)) orelse "").len,
        false => {
            const children = try parser.nodeGetChildNodes(node);
            return @intCast(try parser.nodeListLength(children));
        },
    }
}

fn isTextual(node: *parser.Node) !bool {
    return switch (try parser.nodeType(node)) {
        .text, .comment, .cdata_section => true,
        else => false,
    };
}

fn getParentAndIndex(child: *parser.Node) !struct { *parser.Node, u32 } {
    const parent = (try parser.nodeParentNode(child)) orelse return error.InvalidNodeType;
    const children = try parser.nodeGetChildNodes(parent);
    const ln = try parser.nodeListLength(children);
    var i: u32 = 0;
    while (i < ln) {
        defer i += 1;
        const c = try parser.nodeListItem(children, i) orelse continue;
        if (c == child) {
            return .{ parent, i };
        }
    }

    // should not be possible to reach this point
    return error.InvalidNodeType;
}

const testing = @import("../../testing.zig");
test "Browser.Range" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        // Test Range constructor
        .{ "let range = new Range()", "undefined" },
        .{ "range instanceof Range", "true" },
        .{ "range instanceof AbstractRange", "true" },

        // Test initial state - collapsed range
        .{ "range.collapsed", "true" },
        .{ "range.startOffset", "0" },
        .{ "range.endOffset", "0" },
        .{ "range.startContainer instanceof HTMLDocument", "true" },
        .{ "range.endContainer instanceof HTMLDocument", "true" },

        // Test document.createRange()
        .{ "let docRange = document.createRange()", "undefined" },
        .{ "docRange instanceof Range", "true" },
        .{ "docRange.collapsed", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "const container = document.getElementById('content');", null },

        // Test text range
        .{ "const commentNode = container.childNodes[7];", null },
        .{ "commentNode.nodeValue", "comment" },
        .{ "const textRange = document.createRange();", null },
        .{ "textRange.selectNodeContents(commentNode)", "undefined" },
        .{ "textRange.startOffset", "0" },
        .{ "textRange.endOffset", "7" }, // length of `comment`

        // Test Node range
        .{ "const nodeRange = document.createRange();", null },
        .{ "nodeRange.selectNodeContents(container)", "undefined" },
        .{ "nodeRange.startOffset", "0" },
        .{ "nodeRange.endOffset", "9" }, // length of container.childNodes
    }, .{});
}

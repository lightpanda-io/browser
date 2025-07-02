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

const NodeUnion = @import("node.zig").Union;
const Node = @import("node.zig").Node;

pub const Interfaces = .{
    AbstractRange,
    Range,
};

pub const AbstractRange = struct {
    collapsed: bool,
    end_container: *parser.Node,
    end_offset: i32,
    start_container: *parser.Node,
    start_offset: i32,

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

    pub fn get_endOffset(self: *const AbstractRange) i32 {
        return self.end_offset;
    }

    pub fn get_startContainer(self: *const AbstractRange) !NodeUnion {
        return Node.toInterface(self.start_container);
    }

    pub fn get_startOffset(self: *const AbstractRange) i32 {
        return self.start_offset;
    }
};

pub const Range = struct {
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

    pub fn _setStart(self: *Range, node: *parser.Node, offset: i32) void {
        self.proto.start_container = node;
        self.proto.start_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setEnd(self: *Range, node: *parser.Node, offset: i32) void {
        self.proto.end_container = node;
        self.proto.end_offset = offset;
        self.proto.updateCollapsed();
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

    // The Range.detach() method does nothing. It used to disable the Range
    // object and enable the browser to release associated resources. The
    // method has been kept for compatibility.
    // https://developer.mozilla.org/en-US/docs/Web/API/Range/detach
    pub fn _detach(_: *Range) void {}
};

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

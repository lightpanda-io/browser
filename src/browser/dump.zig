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

const parser = @import("netsurf.zig");
const Walker = @import("dom/walker.zig").WalkerChildren;

// writer must be a std.io.Writer
pub fn writeHTML(doc: *parser.Document, writer: anytype) !void {
    try writer.writeAll("<!DOCTYPE html>\n");
    try writeChildren(parser.documentToNode(doc), writer);
    try writer.writeAll("\n");
}

// Spec: https://www.w3.org/TR/xml/#sec-prolog-dtd
pub fn writeDocType(doc_type: *parser.DocumentType, writer: anytype) !void {
    try writer.writeAll("<!DOCTYPE ");
    try writer.writeAll(try parser.documentTypeGetName(doc_type));

    const public_id = try parser.documentTypeGetPublicId(doc_type);
    const system_id = try parser.documentTypeGetSystemId(doc_type);
    if (public_id.len != 0 and system_id.len != 0) {
        try writer.writeAll(" PUBLIC \"");
        try writeEscapedAttributeValue(writer, public_id);
        try writer.writeAll("\" \"");
        try writeEscapedAttributeValue(writer, system_id);
        try writer.writeAll("\"");
    } else if (public_id.len != 0) {
        try writer.writeAll(" PUBLIC \"");
        try writeEscapedAttributeValue(writer, public_id);
        try writer.writeAll("\"");
    } else if (system_id.len != 0) {
        try writer.writeAll(" SYSTEM \"");
        try writeEscapedAttributeValue(writer, system_id);
        try writer.writeAll("\"");
    }
    // Internal subset is not implemented
    try writer.writeAll(">");
}

pub fn writeNode(node: *parser.Node, writer: anytype) anyerror!void {
    switch (try parser.nodeType(node)) {
        .element => {
            // open the tag
            const tag = try parser.nodeLocalName(node);
            try writer.writeAll("<");
            try writer.writeAll(tag);

            // write the attributes
            const _map = try parser.nodeGetAttributes(node);
            if (_map) |map| {
                const ln = try parser.namedNodeMapGetLength(map);
                for (0..ln) |i| {
                    const attr = try parser.namedNodeMapItem(map, @intCast(i)) orelse break;
                    try writer.writeAll(" ");
                    try writer.writeAll(try parser.attributeGetName(attr));
                    try writer.writeAll("=\"");
                    const attribute_value = try parser.attributeGetValue(attr) orelse "";
                    try writeEscapedAttributeValue(writer, attribute_value);
                    try writer.writeAll("\"");
                }
            }

            try writer.writeAll(">");

            // void elements can't have any content.
            if (try isVoid(parser.nodeToElement(node))) return;

            // write the children
            // TODO avoid recursion
            try writeChildren(node, writer);

            // close the tag
            try writer.writeAll("</");
            try writer.writeAll(tag);
            try writer.writeAll(">");
        },
        .text => {
            const v = try parser.nodeValue(node) orelse return;
            try writeEscapedTextNode(writer, v);
        },
        .cdata_section => {
            const v = try parser.nodeValue(node) orelse return;
            try writer.writeAll("<![CDATA[");
            try writer.writeAll(v);
            try writer.writeAll("]]>");
        },
        .comment => {
            const v = try parser.nodeValue(node) orelse return;
            try writer.writeAll("<!--");
            try writer.writeAll(v);
            try writer.writeAll("-->");
        },
        // TODO handle processing instruction dump
        .processing_instruction => return,
        // document fragment is outside of the main document DOM, so we
        // don't output it.
        .document_fragment => return,
        // document will never be called, but required for completeness.
        .document => return,
        // done globally instead, but required for completeness. Only the outer DOCTYPE should be written
        .document_type => return,
        // deprecated
        .attribute => return,
        .entity_reference => return,
        .entity => return,
        .notation => return,
    }
}

// writer must be a std.io.Writer
pub fn writeChildren(root: *parser.Node, writer: anytype) !void {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    while (true) {
        next = try walker.get_next(root, next) orelse break;
        try writeNode(next.?, writer);
    }
}

// area, base, br, col, embed, hr, img, input, link, meta, source, track, wbr
// https://html.spec.whatwg.org/#void-elements
fn isVoid(elem: *parser.Element) !bool {
    const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(elem)));
    return switch (tag) {
        .area, .base, .br, .col, .embed, .hr, .img, .input, .link => true,
        .meta, .source, .track, .wbr => true,
        else => false,
    };
}

fn writeEscapedTextNode(writer: anytype, value: []const u8) !void {
    var v = value;
    while (v.len > 0) {
        const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '&', '<', '>' }) orelse {
            return writer.writeAll(v);
        };
        try writer.writeAll(v[0..index]);
        switch (v[index]) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => unreachable,
        }
        v = v[index + 1 ..];
    }
}

fn writeEscapedAttributeValue(writer: anytype, value: []const u8) !void {
    var v = value;
    while (v.len > 0) {
        const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '&', '<', '>', '"' }) orelse {
            return writer.writeAll(v);
        };
        try writer.writeAll(v[0..index]);
        switch (v[index]) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => unreachable,
        }
        v = v[index + 1 ..];
    }
}

const testing = std.testing;
test "dump.writeHTML" {
    try parser.init();
    defer parser.deinit();

    try testWriteHTML(
        "<div id=\"content\">Over 9000!</div>",
        "<div id=\"content\">Over 9000!</div>",
    );

    try testWriteHTML(
        "<root><!-- a comment --></root>",
        "<root><!-- a comment --></root>",
    );

    try testWriteHTML(
        "<p>&lt; &gt; &amp;</p>",
        "<p>&lt; &gt; &amp;</p>",
    );

    try testWriteHTML(
        "<p id=\"&quot;&gt;&lt;&amp;&quot;''\">wat?</p>",
        "<p id='\">&lt;&amp;&quot;&#39;&apos;'>wat?</p>",
    );

    try testWriteFullHTML(
        \\<!DOCTYPE html>
        \\<html><head><title>It's over what?</title><meta name="a" value="b">
        \\</head><body>9000</body></html>
        \\
    , "<html><title>It's over what?</title><meta name=a value=\"b\">\n<body>9000");
}

fn testWriteHTML(comptime expected_body: []const u8, src: []const u8) !void {
    const expected =
        "<!DOCTYPE html>\n<html><head></head><body>" ++
        expected_body ++
        "</body></html>\n";
    return testWriteFullHTML(expected, src);
}

fn testWriteFullHTML(comptime expected: []const u8, src: []const u8) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(testing.allocator);

    const doc_html = try parser.documentHTMLParseFromStr(src);
    defer parser.documentHTMLClose(doc_html) catch {};

    const doc = parser.documentHTMLToDocument(doc_html);
    try writeHTML(doc, buf.writer(testing.allocator));
    try testing.expectEqualStrings(expected, buf.items);
}

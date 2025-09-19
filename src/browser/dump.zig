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
const Page = @import("page.zig").Page;
const Walker = @import("dom/walker.zig").WalkerChildren;

pub const Opts = struct {
    // set to include element shadowroots in the dump
    page: ?*const Page = null,

    strip_mode: StripMode = .{},

    pub const StripMode = struct {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
    };
};

// writer must be a std.io.Writer
pub fn writeHTML(doc: *parser.Document, opts: Opts, writer: *std.Io.Writer) !void {
    try writer.writeAll("<!DOCTYPE html>\n");
    try writeChildren(parser.documentToNode(doc), opts, writer);
    try writer.writeAll("\n");
}

// Spec: https://www.w3.org/TR/xml/#sec-prolog-dtd
pub fn writeDocType(doc_type: *parser.DocumentType, writer: *std.Io.Writer) !void {
    try writer.writeAll("<!DOCTYPE ");
    try writer.writeAll(try parser.documentTypeGetName(doc_type));

    const public_id = parser.documentTypeGetPublicId(doc_type);
    const system_id = parser.documentTypeGetSystemId(doc_type);
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

pub fn writeNode(node: *parser.Node, opts: Opts, writer: *std.Io.Writer) anyerror!void {
    switch (parser.nodeType(node)) {
        .element => {
            // open the tag
            const tag_type = try parser.nodeHTMLGetTagType(node) orelse .undef;
            if (try isStripped(tag_type, node, opts.strip_mode)) {
                return;
            }

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

            if (opts.page) |page| {
                if (page.getNodeState(node)) |state| {
                    if (state.shadow_root) |sr| {
                        try writeChildren(@ptrCast(@alignCast(sr.proto)), opts, writer);
                    }
                }
            }

            // void elements can't have any content.
            if (try isVoid(parser.nodeToElement(node))) return;

            if (tag_type == .script) {
                try writer.writeAll(parser.nodeTextContent(node) orelse "");
            } else {
                // write the children
                // TODO avoid recursion
                try writeChildren(node, opts, writer);
            }

            // close the tag
            try writer.writeAll("</");
            try writer.writeAll(tag);
            try writer.writeAll(">");
        },
        .text => {
            const v = parser.nodeValue(node) orelse return;
            try writeEscapedTextNode(writer, v);
        },
        .cdata_section => {
            const v = parser.nodeValue(node) orelse return;
            try writer.writeAll("<![CDATA[");
            try writer.writeAll(v);
            try writer.writeAll("]]>");
        },
        .comment => {
            const v = parser.nodeValue(node) orelse return;
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
pub fn writeChildren(root: *parser.Node, opts: Opts, writer: *std.Io.Writer) !void {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    while (true) {
        next = try walker.get_next(root, next) orelse break;
        try writeNode(next.?, opts, writer);
    }
}

fn isStripped(tag_type: parser.Tag, node: *parser.Node, strip_mode: Opts.StripMode) !bool {
    if (strip_mode.js and try isJsRelated(tag_type, node)) {
        return true;
    }

    if (strip_mode.css and try isCssRelated(tag_type, node)) {
        return true;
    }

    if (strip_mode.ui and try isUIRelated(tag_type, node)) {
        return true;
    }
    return false;
}

fn isJsRelated(tag_type: parser.Tag, node: *parser.Node) !bool {
    if (tag_type == .script) {
        return true;
    }
    if (tag_type == .link) {
        const el = parser.nodeToElement(node);
        const as = try parser.elementGetAttribute(el, "as") orelse return false;
        if (!std.ascii.eqlIgnoreCase(as, "script")) {
            return false;
        }

        const rel = try parser.elementGetAttribute(el, "rel") orelse return false;
        return std.ascii.eqlIgnoreCase(rel, "preload");
    }
    return false;
}

fn isCssRelated(tag_type: parser.Tag, node: *parser.Node) !bool {
    if (tag_type == .style) {
        return true;
    }
    if (tag_type == .link) {
        const el = parser.nodeToElement(node);
        const rel = try parser.elementGetAttribute(el, "rel") orelse return false;
        return std.ascii.eqlIgnoreCase(rel, "stylesheet");
    }
    return false;
}

fn isUIRelated(tag_type: parser.Tag, node: *parser.Node) !bool {
    if (try isCssRelated(tag_type, node)) {
        return true;
    }
    if (tag_type == .img or tag_type == .picture or tag_type == .video) {
        return true;
    }
    if (tag_type == .undef) {
        const name = try parser.nodeLocalName(node);
        if (std.mem.eql(u8, name, "svg")) {
            return true;
        }
    }
    return false;
}

// area, base, br, col, embed, hr, img, input, link, meta, source, track, wbr
// https://html.spec.whatwg.org/#void-elements
fn isVoid(elem: *parser.Element) !bool {
    const tag = try parser.elementTag(elem);
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
    parser.init();
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

    try testWriteHTML(
        "<p>hi</p><script>alert(power > 9000)</script>",
        "<p>hi</p><script>alert(power > 9000)</script>",
    );
}

fn testWriteHTML(comptime expected_body: []const u8, src: []const u8) !void {
    const expected =
        "<!DOCTYPE html>\n<html><head></head><body>" ++
        expected_body ++
        "</body></html>\n";
    return testWriteFullHTML(expected, src);
}

fn testWriteFullHTML(comptime expected: []const u8, src: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    const doc_html = try parser.documentHTMLParseFromStr(src);
    defer parser.documentHTMLClose(doc_html) catch {};

    const doc = parser.documentHTMLToDocument(doc_html);
    try writeHTML(doc, .{}, &aw.writer);
    try testing.expectEqualStrings(expected, aw.written());
}

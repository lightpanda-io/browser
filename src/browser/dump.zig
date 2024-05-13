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
const File = std.fs.File;

const parser = @import("../netsurf.zig");
const Walker = @import("../dom/walker.zig").WalkerChildren;

// writer must be a std.io.Writer
pub fn writeHTML(doc: *parser.Document, writer: anytype) !void {
    try writer.writeAll("<!DOCTYPE html>\n");
    try writeNode(parser.documentToNode(doc), writer);
    try writer.writeAll("\n");
}

// writer must be a std.io.Writer
pub fn writeNode(root: *parser.Node, writer: anytype) !void {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    while (true) {
        next = try walker.get_next(root, next) orelse break;
        switch (try parser.nodeType(next.?)) {
            .element => {
                // open the tag
                const tag = try parser.nodeLocalName(next.?);
                try writer.writeAll("<");
                try writer.writeAll(tag);

                // write the attributes
                const map = try parser.nodeGetAttributes(next.?);
                const ln = try parser.namedNodeMapGetLength(map);
                var i: u32 = 0;
                while (i < ln) {
                    const attr = try parser.namedNodeMapItem(map, i) orelse break;
                    try writer.writeAll(" ");
                    try writer.writeAll(try parser.attributeGetName(attr));
                    try writer.writeAll("=\"");
                    try writer.writeAll(try parser.attributeGetValue(attr) orelse "");
                    try writer.writeAll("\"");
                    i += 1;
                }

                try writer.writeAll(">");

                // void elements can't have any content.
                if (try isVoid(parser.nodeToElement(next.?))) continue;

                // write the children
                // TODO avoid recursion
                try writeNode(next.?, writer);

                // close the tag
                try writer.writeAll("</");
                try writer.writeAll(tag);
                try writer.writeAll(">");
            },
            .text => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try writer.writeAll(v);
            },
            .cdata_section => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try writer.writeAll("<![CDATA[");
                try writer.writeAll(v);
                try writer.writeAll("]]>");
            },
            .comment => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try writer.writeAll("<!--");
                try writer.writeAll(v);
                try writer.writeAll("-->");
            },
            // TODO handle processing instruction dump
            .processing_instruction => continue,
            // document fragment is outside of the main document DOM, so we
            // don't output it.
            .document_fragment => continue,
            // document will never be called, but required for completeness.
            .document => continue,
            // done globally instead, but required for completeness.
            .document_type => continue,
            // deprecated
            .attribute => continue,
            .entity_reference => continue,
            .entity => continue,
            .notation => continue,
        }
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

test "dump.writeHTML" {
    const out = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer out.close();

    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    const doc_html = try parser.documentHTMLParse(file.reader(), "UTF-8");
    // ignore close error
    defer parser.documentHTMLClose(doc_html) catch {};

    const doc = parser.documentHTMLToDocument(doc_html);

    try writeHTML(doc, out);
}

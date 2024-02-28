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

// writeHTMLTestFn is run by run_tests.zig
pub fn writeHTMLTestFn(out: File) !void {
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    const doc_html = try parser.documentHTMLParse(file.reader(), "UTF-8");
    // ignore close error
    defer parser.documentHTMLClose(doc_html) catch {};

    const doc = parser.documentHTMLToDocument(doc_html);

    try writeHTML(doc, out);
}

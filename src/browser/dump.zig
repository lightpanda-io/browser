const std = @import("std");
const File = std.fs.File;

const parser = @import("../netsurf.zig");
const Walker = @import("../dom/html_collection.zig").WalkerChildren;

pub fn htmlFile(root: *parser.Element, out: File) !void {
    try out.writeAll("<!DOCTYPE html>\n<html>");
    try nodeFile(root, out);
    try out.writeAll("</html>\n");
}

fn nodeFile(root: *parser.Element, out: File) !void {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    while (true) {
        next = try walker.get_next(parser.elementToNode(root), next) orelse break;
        switch (try parser.nodeType(next.?)) {
            .element => {
                // open the tag
                const tag = try parser.nodeLocalName(next.?);
                try out.writeAll("<");
                try out.writeAll(tag);

                // write the attributes
                const map = try parser.nodeGetAttributes(next.?);
                const ln = try parser.namedNodeMapGetLength(map);
                var i: u32 = 0;
                while (i < ln) {
                    const attr = try parser.namedNodeMapItem(map, i) orelse break;
                    try out.writeAll(" ");
                    try out.writeAll(try parser.attributeGetName(attr));
                    try out.writeAll("=\"");
                    try out.writeAll(try parser.attributeGetValue(attr));
                    try out.writeAll("\"");
                    i += 1;
                }

                try out.writeAll(">");

                // write the children
                // TODO avoid recursion
                try nodeFile(parser.nodeToElement(next.?), out);

                // close the tag
                try out.writeAll("</");
                try out.writeAll(tag);
                try out.writeAll(">");
            },
            .text => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try out.writeAll(v);
            },
            .cdata_section => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try out.writeAll("<![CDATA[");
                try out.writeAll(v);
                try out.writeAll("]]>");
            },
            .comment => {
                const v = try parser.nodeValue(next.?) orelse continue;
                try out.writeAll("<!--");
                try out.writeAll(v);
                try out.writeAll("-->");
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

// HTMLFileTestFn is run by run_tests.zig
pub fn HTMLFileTestFn(out: File) !void {
    const doc_html = try parser.documentHTMLParseFromFileAlloc(std.testing.allocator, "test.html");
    // ignore close error
    defer parser.documentHTMLClose(doc_html) catch {};

    const doc = parser.documentHTMLToDocument(doc_html);
    const root = try parser.documentGetDocumentElement(doc) orelse return error.DocumentNullRoot;

    try htmlFile(root, out);
}

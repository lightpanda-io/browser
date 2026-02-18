// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Parser = @import("../parser/Parser.zig");

const HTMLDocument = @import("HTMLDocument.zig");
const XMLDocument = @import("XMLDocument.zig");
const Document = @import("Document.zig");

const DOMParser = @This();

pub fn init() DOMParser {
    return .{};
}

pub fn parseFromString(
    _: *const DOMParser,
    html: []const u8,
    mime_type: []const u8,
    page: *Page,
) !*Document {
    const target_mime = std.meta.stringToEnum(enum {
        @"text/html",
        @"text/xml",
        @"application/xml",
        @"application/xhtml+xml",
        @"image/svg+xml",
    }, mime_type) orelse return error.NotSupported;

    const arena = try page.getArena(.{ .debug = "DOMParser.parseFromString" });
    defer page.releaseArena(arena);

    return switch (target_mime) {
        .@"text/html" => {
            // Create a new HTMLDocument
            const doc = try page._factory.document(HTMLDocument{
                ._proto = undefined,
            });

            var normalized = std.mem.trim(u8, html, &std.ascii.whitespace);
            if (normalized.len == 0) {
                normalized = "<html></html>";
            }

            // Parse HTML into the document
            var parser = Parser.init(arena, doc.asNode(), page);
            parser.parse(normalized);

            if (parser.err) |pe| {
                return pe.err;
            }

            return doc.asDocument();
        },
        else => {
            // Create a new XMLDocument.
            const doc = try page._factory.document(XMLDocument{
                ._proto = undefined,
            });

            // Parse XML into XMLDocument.
            const doc_node = doc.asNode();
            var parser = Parser.init(arena, doc_node, page);
            parser.parseXML(html);

            if (parser.err) |pe| {
                return pe.err;
            }

            // If first node is a `ProcessingInstruction`, skip it.
            const first_child = doc_node.firstChild() orelse {
                // Parsing should fail if there aren't any nodes.
                unreachable;
            };

            if (first_child.getNodeType() == .processing_instruction) {
                // We're sure that firstChild exist, this cannot fail.
                _ = doc_node.removeChild(first_child, page) catch unreachable;
            }

            return doc.asDocument();
        },
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMParser);

    pub const Meta = struct {
        pub const name = "DOMParser";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(DOMParser.init, .{});
    pub const parseFromString = bridge.function(DOMParser.parseFromString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMParser" {
    try testing.htmlRunner("domparser.html", .{});
}

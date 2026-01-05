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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const HTMLDocument = @import("HTMLDocument.zig");
const XMLDocument = @import("XMLDocument.zig");

const DOMParser = @This();

pub fn init() DOMParser {
    return .{};
}

pub const HTMLDocumentOrXMLDocument = union(enum) {
    html_document: *HTMLDocument,
    xml_document: *XMLDocument,
};

pub fn parseFromString(
    _: *const DOMParser,
    html: []const u8,
    mime_type: []const u8,
    page: *Page,
) !HTMLDocumentOrXMLDocument {
    if (std.mem.eql(u8, mime_type, "text/html")) {
        // Create a new HTMLDocument
        const doc = try page._factory.document(HTMLDocument{
            ._proto = undefined,
        });

        var normalized = std.mem.trim(u8, html, &std.ascii.whitespace);
        if (normalized.len == 0) {
            normalized = "<html></html>";
        }

        // Parse HTML into the document
        const Parser = @import("../parser/Parser.zig");
        var parser = Parser.init(page.arena, doc.asNode(), page);
        parser.parse(normalized);

        if (parser.err) |pe| {
            return pe.err;
        }

        return .{ .html_document = doc };
    }

    if (std.mem.eql(u8, mime_type, "text/xml")) {
        // Create a new XMLDocument.
        const doc = try page._factory.document(XMLDocument{
            ._proto = undefined,
        });

        // Parse XML into XMLDocument.
        const Parser = @import("../parser/Parser.zig");
        var parser = Parser.init(page.arena, doc.asNode(), page);
        parser.parseXML(html);

        if (parser.err) |pe| {
            return pe.err;
        }

        return .{ .xml_document = doc };
    }

    return error.NotSupported;
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

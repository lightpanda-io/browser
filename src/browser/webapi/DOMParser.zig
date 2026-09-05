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

const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");

const Node = @import("Node.zig");
const Document = @import("Document.zig");
const HTMLDocument = @import("HTMLDocument.zig");

const DOMParser = @This();

_frame: *Frame,

pub fn init(frame: *Frame) !*DOMParser {
    return frame._factory.create(DOMParser{ ._frame = frame });
}

pub fn parseFromString(
    self: *const DOMParser,
    html: []const u8,
    mime_type: []const u8,
) !*Document {
    const frame = self._frame;
    const target_mime = std.meta.stringToEnum(SupportedType, mime_type) orelse return error.TypeError;

    switch (target_mime) {
        .@"text/html" => {
            const arena = try frame.getArena(.medium, "DOMParser.parseFromString");
            defer arena.release();

            // DOMParser builds a detached Document. Borrow the same fragment
            // parse-mode that `Frame.parse` uses so frame-side hooks
            // triggered from `Build.created` / `nodeIsReady` (external
            // stylesheet fetches, script execution, mutation-observer fan-out,
            // default-script injection) treat the parsed nodes as detached and
            // skip side effects on the live document. The frame's
            // `_parse_mode` is restored on exit.
            const previous_parse_mode = frame._parse_mode;
            frame._parse_mode = .fragment;
            defer frame._parse_mode = previous_parse_mode;

            // No browsing context, so no custom element registry.
            const previous_creation = frame._custom_element_creation;
            frame._custom_element_creation = .undefined;
            defer frame._custom_element_creation = previous_creation;

            // Create a new HTMLDocument
            const doc = try frame._factory.document(HTMLDocument{
                ._proto = undefined,
            });
            doc.asDocument()._url = frame.url;

            var normalized = std.mem.trim(u8, html, &std.ascii.whitespace);
            if (normalized.len == 0) {
                normalized = "<html></html>";
            }

            // Parse HTML into the document
            var parser = Parser.init(arena.allocator(), doc.asNode(), frame, .{});
            parser.parse(normalized);
            if (parser.terminated) {
                return error.ExecutionTerminated;
            }

            if (parser.err) |pe| {
                return pe.err;
            }

            return doc.asDocument();
        },
        else => {
            const xml_doc = (try Frame.parse.xmlDocument(frame, html)) orelse try parserErrorDocument(frame);
            const doc = xml_doc.asDocument();
            doc._url = frame.url;
            doc._content_type = @tagName(target_mime);
            return doc;
        },
    }
}

const SupportedType = enum {
    @"text/html",
    @"text/xml",
    @"application/xml",
    @"application/xhtml+xml",
    @"image/svg+xml",
};

const parsererror_ns = "http://www.mozilla.org/newlayout/xml/parsererror.xml";

// Per spec, a well-formedness error yields a document whose only child is
// <parsererror> in the Mozilla error namespace.
fn parserErrorDocument(frame: *Frame) !*Document.XMLDocument {
    const doc = try frame._factory.document(Document.XMLDocument{ ._proto = undefined });
    const root = try Frame.node_factory.createElementNS(frame, .unknown, "parsererror", null);
    try frame._element_namespace_uris.put(frame.arena, root.as(Node.Element), parsererror_ns);
    const text = try Frame.node_factory.createTextNode(frame, "error");
    _ = try root.appendChild(text, frame);
    _ = try doc.asNode().appendChild(root, frame);
    return doc;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMParser);

    pub const Meta = struct {
        pub const name = "DOMParser";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMParser.init, .{});
    pub const parseFromString = bridge.function(DOMParser.parseFromString, .{ .ce_reactions = true });
};

const testing = @import("../../testing.zig");
test "WebApi: DOMParser" {
    try testing.htmlRunner("domparser.html", .{});
}

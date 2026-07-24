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

const HTMLDocument = @import("HTMLDocument.zig");
const Document = @import("Document.zig");

const DOMParser = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn init() DOMParser {
    return .{};
}

pub fn parseFromString(
    _: *const DOMParser,
    html: []const u8,
    mime_type: []const u8,
    frame: *Frame,
) !*Document {
    const target_mime = std.meta.stringToEnum(enum {
        @"text/html",
        @"text/xml",
        @"application/xml",
        @"application/xhtml+xml",
        @"image/svg+xml",
    }, mime_type) orelse return error.NotSupported;

    return switch (target_mime) {
        .@"text/html" => {
            const arena = try frame.getArena(.medium, "DOMParser.parseFromString");
            defer frame.releaseArena(arena);

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

            // Create a new HTMLDocument
            const doc = try frame._factory.document(HTMLDocument{
                ._proto = undefined,
            });

            var normalized = std.mem.trim(u8, html, &std.ascii.whitespace);
            if (normalized.len == 0) {
                normalized = "<html></html>";
            }

            // Parse HTML into the document
            var parser = Parser.init(arena, doc.asNode(), frame, .{});
            parser.parse(normalized);

            if (parser.err) |pe| {
                return pe.err;
            }

            return doc.asDocument();
        },
        else => {
            const doc = (try Frame.parse.xmlDocument(frame, html)) orelse blk: {
                // Return a document with a <parsererror> element per spec.
                break :blk (try Frame.parse.xmlDocument(frame, "<parsererror xmlns=\"http://www.mozilla.org/newlayout/xml/parsererror.xml\">error</parsererror>")).?;
            };
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
    pub const parseFromString = bridge.function(DOMParser.parseFromString, .{ .ce_reactions = true });
};

const testing = @import("../../testing.zig");
test "WebApi: DOMParser" {
    try testing.htmlRunner("domparser.html", .{});
}

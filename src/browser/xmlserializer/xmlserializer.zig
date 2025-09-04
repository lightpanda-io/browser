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
//
const std = @import("std");

const Page = @import("../page.zig").Page;

const dump = @import("../dump.zig");
const parser = @import("../netsurf.zig");

pub const Interfaces = .{
    XMLSerializer,
};

// https://w3c.github.io/DOM-Parsing/#dom-xmlserializer-constructor
pub const XMLSerializer = struct {
    pub fn constructor() !XMLSerializer {
        return .{};
    }

    pub fn _serializeToString(_: *const XMLSerializer, root: *parser.Node, page: *Page) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(page.call_arena);
        switch (try parser.nodeType(root)) {
            .document => try dump.writeHTML(@as(*parser.Document, @ptrCast(root)), .{}, &aw.writer),
            .document_type => try dump.writeDocType(@as(*parser.DocumentType, @ptrCast(root)), &aw.writer),
            else => try dump.writeNode(root, .{}, &aw.writer),
        }
        return aw.written();
    }
};

const testing = @import("../../testing.zig");
test "Browser: XMLSerializer" {
    try testing.htmlRunner("xmlserializer.html");
}

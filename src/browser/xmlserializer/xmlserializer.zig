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
        var buf = std.ArrayList(u8).init(page.arena);
        switch (try parser.nodeType(root)) {
            .document => try dump.writeHTML(@as(*parser.Document, @ptrCast(root)), buf.writer()),
            .document_type => try dump.writeDocType(@as(*parser.DocumentType, @ptrCast(root)), buf.writer()),
            else => try dump.writeNode(root, buf.writer()),
        }
        return buf.items;
    }
};

const testing = @import("../../testing.zig");
test "Browser.XMLSerializer" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "const s = new XMLSerializer()", "undefined" },
        .{ "s.serializeToString(document.getElementById('para'))", "<p id=\"para\"> And</p>" },
    }, .{});
}
test "Browser.XMLSerializer with DOCTYPE" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = "<!DOCTYPE html><html><head></head><body></body></html>" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "new XMLSerializer().serializeToString(document.doctype)", "<!DOCTYPE html>" },
    }, .{});
}
test
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

const parser = @import("../netsurf.zig");
const SessionState = @import("../env.zig").SessionState;

const Document = @import("document.zig").Document;
const DocumentType = @import("document_type.zig").DocumentType;
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#domimplementation
pub const DOMImplementation = struct {
    pub const Exception = DOMException;

    pub fn _createDocumentType(
        _: *DOMImplementation,
        state: *SessionState,
        qname: []const u8,
        publicId: []const u8,
        systemId: []const u8,
    ) !*parser.DocumentType {
        const allocator = state.arena;
        const cqname = try allocator.dupeZ(u8, qname);
        defer allocator.free(cqname);

        const cpublicId = try allocator.dupeZ(u8, publicId);
        defer allocator.free(cpublicId);

        const csystemId = try allocator.dupeZ(u8, systemId);
        defer allocator.free(csystemId);

        return try parser.domImplementationCreateDocumentType(cqname, cpublicId, csystemId);
    }

    pub fn _createDocument(
        _: *DOMImplementation,
        state: *SessionState,
        namespace: ?[]const u8,
        qname: ?[]const u8,
        doctype: ?*parser.DocumentType,
    ) !*parser.Document {
        const allocator = state.arena;
        var cnamespace: ?[:0]const u8 = null;
        if (namespace) |ns| {
            cnamespace = try allocator.dupeZ(u8, ns);
        }
        defer if (cnamespace) |v| allocator.free(v);

        var cqname: ?[:0]const u8 = null;
        if (qname) |qn| {
            cqname = try allocator.dupeZ(u8, qn);
        }
        defer if (cqname) |v| allocator.free(v);

        return try parser.domImplementationCreateDocument(cnamespace, cqname, doctype);
    }

    pub fn _createHTMLDocument(_: *DOMImplementation, title: ?[]const u8) !*parser.DocumentHTML {
        return try parser.domImplementationCreateHTMLDocument(title);
    }

    pub fn _hasFeature(_: *DOMImplementation) bool {
        return true;
    }

    pub fn deinit(_: *DOMImplementation, _: std.mem.Allocator) void {}
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser.DOM.Implementation" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let impl = document.implementation", "undefined" },
        .{ "impl.createHTMLDocument();", "[object HTMLDocument]" },
        .{ "impl.createHTMLDocument('foo');", "[object HTMLDocument]" },
        .{ "impl.createDocument(null, 'foo');", "[object Document]" },
        .{ "impl.createDocumentType('foo', 'bar', 'baz')", "[object DocumentType]" },
        .{ "impl.hasFeature()", "true" },
    }, .{});
}

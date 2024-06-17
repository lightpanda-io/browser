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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("document.zig").Document;
const DocumentType = @import("document_type.zig").DocumentType;
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#domimplementation
pub const DOMImplementation = struct {
    pub const mem_guarantied = true;

    pub const Exception = DOMException;

    pub fn _createDocumentType(
        _: *DOMImplementation,
        alloc: std.mem.Allocator,
        qname: []const u8,
        publicId: []const u8,
        systemId: []const u8,
    ) !*parser.DocumentType {
        const cqname = try alloc.dupeZ(u8, qname);
        defer alloc.free(cqname);

        const cpublicId = try alloc.dupeZ(u8, publicId);
        defer alloc.free(cpublicId);

        const csystemId = try alloc.dupeZ(u8, systemId);
        defer alloc.free(csystemId);

        return try parser.domImplementationCreateDocumentType(cqname, cpublicId, csystemId);
    }

    pub fn _createDocument(
        _: *DOMImplementation,
        alloc: std.mem.Allocator,
        namespace: ?[]const u8,
        qname: ?[]const u8,
        doctype: ?*parser.DocumentType,
    ) !*parser.Document {
        var cnamespace: ?[:0]const u8 = null;
        if (namespace) |ns| {
            cnamespace = try alloc.dupeZ(u8, ns);
        }
        defer if (cnamespace) |v| alloc.free(v);

        var cqname: ?[:0]const u8 = null;
        if (qname) |qn| {
            cqname = try alloc.dupeZ(u8, qn);
        }
        defer if (cqname) |v| alloc.free(v);

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

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var getImplementation = [_]Case{
        .{ .src = "let impl = document.implementation", .ex = "undefined" },
        .{ .src = "impl.createHTMLDocument();", .ex = "[object HTMLDocument]" },
        .{ .src = "impl.createHTMLDocument('foo');", .ex = "[object HTMLDocument]" },
        .{ .src = "impl.createDocument(null, 'foo');", .ex = "[object Document]" },
        .{ .src = "impl.createDocumentType('foo', 'bar', 'baz')", .ex = "[object DocumentType]" },
        .{ .src = "impl.hasFeature()", .ex = "true" },
    };
    try checkCases(js_env, &getImplementation);
}

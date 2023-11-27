const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("document.zig").Document;
const DocumentType = @import("document_type.zig").DocumentType;

// WEB IDL https://dom.spec.whatwg.org/#domimplementation
pub const DOMImplementation = struct {
    pub const mem_guarantied = true;

    pub fn _createDocumentType(
        self: *DOMImplementation,
        allocator: std.mem.Allocator,
        qname: []const u8,
        publicId: []const u8,
        systemId: []const u8,
    ) !*parser.DocumentType {
        _ = self;
        const cqname = try allocator.dupeZ(u8, qname);
        defer allocator.free(cqname);

        const cpublicId = try allocator.dupeZ(u8, publicId);
        defer allocator.free(cpublicId);

        const csystemId = try allocator.dupeZ(u8, systemId);
        defer allocator.free(csystemId);

        const dt = parser.domImplementationCreateDocumentType(cqname, cpublicId, csystemId);
        return dt;
    }

    pub fn _createDocument(
        self: *DOMImplementation,
        allocator: std.mem.Allocator,
        namespace: ?[]const u8,
        qname: ?[]const u8,
        doctype: ?*parser.DocumentType,
    ) !*parser.Document {
        _ = self;
        var cnamespace: ?[:0]const u8 = null;
        if (namespace != null) {
            cnamespace = try allocator.dupeZ(u8, namespace.?);
            defer allocator.free(cnamespace.?);
        }

        var cqname: ?[:0]const u8 = null;
        if (qname != null) {
            cqname = try allocator.dupeZ(u8, qname.?);
            defer allocator.free(cqname.?);
        }

        const doc = parser.domImplementationCreateDocument(cnamespace, cqname, doctype);
        return doc;
    }

    pub fn _createHTMLDocument(_: *DOMImplementation, title: ?[]const u8) *parser.Document {
        const doc = parser.domImplementationCreateHTMLDocument(title);
        return doc;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var getImplementation = [_]Case{
        .{ .src = "let impl = document.implementation", .ex = "undefined" },
        .{ .src = "impl.createHTMLDocument();", .ex = "[object Document]" },
        .{ .src = "impl.createDocument(null, 'foo');", .ex = "[object Document]" },
        .{ .src = "impl.createDocumentType('foo', 'bar', 'baz');", .ex = "[object DocumentType]" },
    };
    try checkCases(js_env, &getImplementation);
}

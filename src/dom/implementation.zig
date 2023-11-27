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
       _: *DOMImplementation,
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

        return parser.domImplementationCreateDocumentType(cqname, cpublicId, csystemId);
    }

    pub fn _createDocument(
       _: *DOMImplementation,
        allocator: std.mem.Allocator,
        namespace: ?[]const u8,
        qname: ?[]const u8,
        doctype: ?*parser.DocumentType,
    ) !*parser.Document {
        _ = self;
        var cnamespace: ?[:0]const u8 = null;
        if (namespace) |ns| {
            cnamespace = try allocator.dupeZ(u8, ns);
            defer allocator.free(cnamespace.?);
        }

        var cqname: ?[:0]const u8 = null;
        if (qname) |qn| {
            cqname = try allocator.dupeZ(u8, qn);
            defer allocator.free(cqname.?);
        }

        return parser.domImplementationCreateDocument(cnamespace, cqname, doctype);
    }

    pub fn _createHTMLDocument(_: *DOMImplementation, title: ?[]const u8) *parser.Document {
        return parser.domImplementationCreateHTMLDocument(title);
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
    comptime _: []jsruntime.API,
) !void {
    var getImplementation = [_]Case{
        .{ .src = "let impl = document.implementation", .ex = "undefined" },
        .{ .src = "impl.createHTMLDocument();", .ex = "[object Document]" },
        .{ .src = "impl.createDocument(null, 'foo');", .ex = "[object Document]" },
        .{ .src = "impl.createDocumentType('foo', 'bar', 'baz')", .ex = "[object DocumentType]" },
        .{ .src = "impl.hasFeature()", .ex = "true" },
    };
    try checkCases(js_env, &getImplementation);
}

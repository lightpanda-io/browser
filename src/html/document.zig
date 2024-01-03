const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("../dom/document.zig").Document;
const HTMLElem = @import("elements.zig");

// WEB IDL https://html.spec.whatwg.org/#the-document-object
pub const HTMLDocument = struct {
    pub const Self = parser.DocumentHTML;
    pub const prototype = *Document;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn get_domain(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetDomain(self);
    }

    pub fn set_domain(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return parser.DOMError.NotSupported;
    }

    pub fn get_referrer(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetReferrer(self);
    }

    pub fn set_referrer(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return parser.DOMError.NotSupported;
    }

    pub fn get_body(self: *parser.DocumentHTML) !?*parser.Body {
        return try parser.documentHTMLBody(self);
    }

    // TODO: not implemented by libdom
    pub fn get_cookie(_: *parser.DocumentHTML) ![]const u8 {
        return error.NotImplemented;
    }

    // TODO: not implemented by libdom
    pub fn set_cookie(_: *parser.DocumentHTML, _: []const u8) ![]const u8 {
        return parser.DOMError.NotSupported;
    }

    pub fn get_title(self: *parser.DocumentHTML) ![]const u8 {
        return try parser.documentHTMLGetTitle(self);
    }

    pub fn set_title(self: *parser.DocumentHTML, v: []const u8) ![]const u8 {
        try parser.documentHTMLSetTitle(self, v);
        return v;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var constructor = [_]Case{
        .{ .src = "document.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.body.localName == 'body'", .ex = "true" },
    };
    try checkCases(js_env, &constructor);

    var getters = [_]Case{
        .{ .src = "document.domain", .ex = "" },
        .{ .src = "document.referrer", .ex = "" },
        .{ .src = "document.title", .ex = "" },
    };
    try checkCases(js_env, &getters);

    var titles = [_]Case{
        .{ .src = "document.title = 'foo'", .ex = "foo" },
        .{ .src = "document.title", .ex = "foo" },
        .{ .src = "document.title = ''", .ex = "" },
    };
    try checkCases(js_env, &titles);
}

const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("../dom/document.zig").Document;
const NodeList = @import("../dom/nodelist.zig").NodeList;
const HTMLElem = @import("elements.zig");
const collection = @import("../dom/html_collection.zig");

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

    pub fn set_body(self: *parser.DocumentHTML, elt: ?*parser.ElementHTML) !?*parser.Body {
        try parser.documentHTMLSetBody(self, elt);
        return try get_body(self);
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

    pub fn _getElementsByName(self: *parser.DocumentHTML, alloc: std.mem.Allocator, name: []const u8) !NodeList {
        var list = try NodeList.init();
        errdefer list.deinit(alloc);

        if (name.len == 0) return list;

        const root = try rootNode(self) orelse return list;

        var c = try collection.HTMLCollectionByName(alloc, root, name, false);

        const ln = try c.get_length();
        var i: u32 = 0;
        while (i < ln) {
            const n = try c.item(i) orelse break;
            try list.append(alloc, n);
            i += 1;
        }

        return list;
    }

    inline fn rootNode(self: *parser.DocumentHTML) !?*parser.Node {
        const doc = parser.documentHTMLToDocument(self);
        const elt = try parser.documentGetDocumentElement(doc) orelse return null;
        return parser.elementToNode(elt);
    }

    pub fn get_images(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, try rootNode(self), "img", false);
    }

    pub fn get_embeds(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, try rootNode(self), "embed", false);
    }

    pub fn get_plugins(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return get_embeds(self, alloc);
    }

    pub fn get_forms(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, try rootNode(self), "form", false);
    }

    pub fn get_scripts(self: *parser.DocumentHTML, alloc: std.mem.Allocator) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(alloc, try rootNode(self), "script", false);
    }

    pub fn get_links(self: *parser.DocumentHTML) !collection.HTMLCollection {
        return try collection.HTMLCollectionByLinks(try rootNode(self), false);
    }

    pub fn deinit(_: *parser.DocumentHTML, _: std.mem.Allocator) void {}
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
        .{ .src = "document.body.tagName", .ex = "BODY" },
        .{ .src = "document.images.length", .ex = "0" },
        .{ .src = "document.embeds.length", .ex = "0" },
        .{ .src = "document.plugins.length", .ex = "0" },
        .{ .src = "document.scripts.length", .ex = "0" },
        .{ .src = "document.forms.length", .ex = "0" },
        .{ .src = "document.links.length", .ex = "1" },
    };
    try checkCases(js_env, &getters);

    var titles = [_]Case{
        .{ .src = "document.title = 'foo'", .ex = "foo" },
        .{ .src = "document.title", .ex = "foo" },
        .{ .src = "document.title = ''", .ex = "" },
    };
    try checkCases(js_env, &titles);

    var getElementsByName = [_]Case{
        .{ .src = "document.getElementById('link').setAttribute('name', 'foo')", .ex = "undefined" },
        .{ .src = "let list = document.getElementsByName('foo')", .ex = "undefined" },
        .{ .src = "list.length", .ex = "1" },
    };
    try checkCases(js_env, &getElementsByName);
}

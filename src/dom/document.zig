const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("node.zig").Node;

const collection = @import("html_collection.zig");

const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;

// WEB IDL https://dom.spec.whatwg.org/#document
pub const Document = struct {
    pub const Self = parser.Document;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // pub fn constructor() *parser.Document {
    //     // TODO
    //     return .{};
    // }

    // JS funcs
    // --------

    pub fn _getElementById(self: *parser.Document, id: []const u8) ?ElementUnion {
        const e = parser.documentGetElementById(self, id) orelse return null;
        return Element.toInterface(e);
    }

    pub fn _createElement(self: *parser.Document, tag_name: []const u8) ElementUnion {
        const e = parser.documentCreateElement(self, tag_name);
        return Element.toInterface(e);
    }

    pub fn _createElementNS(self: *parser.Document, ns: []const u8, tag_name: []const u8) ElementUnion {
        const e = parser.documentCreateElementNS(self, ns, tag_name);
        return Element.toInterface(e);
    }

    // We can't simply use libdom dom_document_get_elements_by_tag_name here.
    // Indeed, netsurf implemented a previous dom spec when
    // getElementsByTagName returned a NodeList.
    // But since
    // https://github.com/whatwg/dom/commit/190700b7c12ecfd3b5ebdb359ab1d6ea9cbf7749
    // the spec changed to return an HTMLCollection instead.
    // That's why we reimplemented getElementsByTagName by using an
    // HTMLCollection in zig here.
    pub fn _getElementsByTagName(self: *parser.Document, tag_name: []const u8) !collection.HTMLCollection {
        const root = parser.documentGetDocumentElement(self);
        return collection.HTMLCollectionByTagName(parser.elementToNode(root), tag_name);
    }

    pub fn _getElementsByClassName(self: *parser.Document, classNames: []const u8) !collection.HTMLCollection {
        const root = parser.documentGetDocumentElement(self);
        return collection.HTMLCollectionByClassName(parser.elementToNode(root), classNames);
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
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.__proto__.__proto__.__proto__.constructor.name", .ex = "Node" },
        .{ .src = "document.__proto__.__proto__.__proto__.__proto__.constructor.name", .ex = "EventTarget" },
    };
    try checkCases(js_env, &constructor);

    var getElementById = [_]Case{
        .{ .src = "let getElementById = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "getElementById.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "getElementById.localName", .ex = "div" },
    };
    try checkCases(js_env, &getElementById);

    var getElementsByTagName = [_]Case{
        .{ .src = "let getElementsByTagName = document.getElementsByTagName('p')", .ex = "undefined" },
        .{ .src = "getElementsByTagName.length", .ex = "2" },
        .{ .src = "getElementsByTagName.item(0).localName", .ex = "p" },
        .{ .src = "getElementsByTagName.item(1).localName", .ex = "p" },
        .{ .src = "let getElementsByTagNameAll = document.getElementsByTagName('*')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameAll.length", .ex = "8" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(7).localName", .ex = "p" },
        .{ .src = "getElementsByTagNameAll.namedItem('para-empty-child').localName", .ex = "span" },
    };
    try checkCases(js_env, &getElementsByTagName);

    var getElementsByClassName = [_]Case{
        .{ .src = "let ok = document.getElementsByClassName('ok')", .ex = "undefined" },
        .{ .src = "ok.length", .ex = "2" },
        .{ .src = "let empty = document.getElementsByClassName('empty')", .ex = "undefined" },
        .{ .src = "empty.length", .ex = "1" },
        .{ .src = "let emptyok = document.getElementsByClassName('empty ok')", .ex = "undefined" },
        .{ .src = "emptyok.length", .ex = "1" },
    };
    try checkCases(js_env, &getElementsByClassName);

    const tags = comptime parser.Tag.all();
    comptime var createElements: [(tags.len) * 2]Case = undefined;
    inline for (tags, 0..) |tag, i| {
        const tag_name = @tagName(tag);
        createElements[i * 2] = Case{
            .src = "var " ++ tag_name ++ "Elem = document.createElement('" ++ tag_name ++ "')",
            .ex = "undefined",
        };
        createElements[(i * 2) + 1] = Case{
            .src = tag_name ++ "Elem.localName",
            .ex = tag_name,
        };
    }
    try checkCases(js_env, &createElements);
}

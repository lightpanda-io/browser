const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("../dom/document.zig").Document;
const HTMLElem = @import("elements.zig");

pub const HTMLDocument = struct {
    pub const Self = parser.DocumentHTML;
    pub const prototype = *Document;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn get_body(self: *parser.DocumentHTML) ?*parser.Body {
        return parser.documentHTMLBody(self);
    }

    pub fn _getElementById(self: *parser.DocumentHTML, id: []u8) ?HTMLElem.Union {
        const doc = parser.documentHTMLToDocument(self);
        const elem_dom = parser.documentGetElementById(doc, id);
        if (elem_dom) |elem| {
            return HTMLElem.toInterface(HTMLElem.Union, elem);
        }
        return null;
    }

    pub fn _createElement(self: *parser.DocumentHTML, tag_name: []const u8) HTMLElem.Union {
        const doc_dom = parser.documentHTMLToDocument(self);
        const base = parser.documentCreateElement(doc_dom, tag_name);
        return HTMLElem.toInterface(HTMLElem.Union, base);
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
        .{ .src = "document.__proto__.__proto__.__proto__.constructor.name", .ex = "Node" },
        .{ .src = "document.__proto__.__proto__.__proto__.__proto__.constructor.name", .ex = "EventTarget" },
        .{ .src = "document.body.localName == 'body'", .ex = "true" },
    };
    try checkCases(js_env, &constructor);

    var getElementById = [_]Case{
        .{ .src = "let getElementById = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "getElementById.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "getElementById.localName", .ex = "div" },
    };
    try checkCases(js_env, &getElementById);

    const tags = comptime parser.Tag.all();
    const elements = comptime parser.Tag.allElements();
    comptime var createElements: [(tags.len) * 3]Case = undefined;
    inline for (tags, elements, 0..) |tag, element_name, i| {
        // if (tag == .undef) {
        //     continue;
        // }
        const tag_name = @tagName(tag);
        createElements[i * 3] = Case{
            .src = "var " ++ tag_name ++ "Elem = document.createElement('" ++ tag_name ++ "')",
            .ex = "undefined",
        };
        createElements[(i * 3) + 1] = Case{
            .src = tag_name ++ "Elem.constructor.name",
            .ex = "HTML" ++ element_name ++ "Element",
        };
        createElements[(i * 3) + 2] = Case{
            .src = tag_name ++ "Elem.localName",
            .ex = tag_name,
        };
    }
    try checkCases(js_env, &createElements);
}

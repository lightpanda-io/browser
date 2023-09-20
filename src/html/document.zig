const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("../dom/document.zig").Document;

const E = @import("elements.zig");

pub const HTMLDocument = struct {
    pub const Self = parser.DocumentHTML;
    pub const prototype = *Document;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn get_body(self: *parser.DocumentHTML) ?*parser.Body {
        return parser.documentHTMLBody(self);
    }

    pub fn _getElementById(self: *parser.DocumentHTML, id: []u8) ?*parser.ElementHTML {
        const doc = parser.documentHTMLToDocument(self);
        const elem = parser.documentGetElementById(doc, id);
        if (elem) |value| {
            return @as(*parser.ElementHTML, @ptrCast(value));
        }
        return null;
    }

    pub fn _createElement(self: *parser.DocumentHTML, tag_name: []const u8) E.HTMLElements {
        const doc_dom = parser.documentHTMLToDocument(self);
        const base = parser.documentCreateElement(doc_dom, tag_name);
        return E.ElementToHTMLElementInterface(base);
    }
};

// Tests
// -----

pub fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var constructor = [_]Case{
        .{ .src = "document.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.__proto__.__proto__.__proto__.constructor.name", .ex = "Node" },
        .{ .src = "document.__proto__.__proto__.__proto__.__proto__.constructor.name", .ex = "EventTarget" },
    };
    try checkCases(js_env, &constructor);

    var getElementById = [_]Case{
        .{ .src = "let getElementById = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "getElementById.constructor.name", .ex = "HTMLElement" },
        .{ .src = "getElementById.localName", .ex = "main" },
    };
    try checkCases(js_env, &getElementById);

    const tags = comptime parser.Tag.all();
    const elements = comptime parser.Tag.allElements();
    var createElements: [(tags.len - 1) * 3]Case = undefined;
    inline for (tags, 0..) |tag, i| {
        if (tag == .undef) {
            continue;
        }
        const tag_name = @tagName(tag);
        const element_name = elements[i];
        createElements[i * 3] = Case{
            .src = try std.fmt.allocPrint(alloc, "var {s}Elem = document.createElement('{s}')", .{ tag_name, tag_name }),
            .ex = "undefined",
        };
        createElements[(i * 3) + 1] = Case{
            .src = try std.fmt.allocPrint(alloc, "{s}Elem.constructor.name", .{tag_name}),
            .ex = try std.fmt.allocPrint(alloc, "HTML{s}Element", .{element_name}),
        };
        createElements[(i * 3) + 2] = Case{
            .src = try std.fmt.allocPrint(alloc, "{s}Elem.localName", .{tag_name}),
            .ex = tag_name,
        };
    }
    try checkCases(js_env, &createElements);

    var unknown = [_]Case{
        .{ .src = "let unknown = document.createElement('unknown')", .ex = "undefined" },
        .{ .src = "unknown.constructor.name", .ex = "HTMLUnknownElement" },
    };
    try checkCases(js_env, &unknown);
}

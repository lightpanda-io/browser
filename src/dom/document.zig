const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("node.zig").Node;

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

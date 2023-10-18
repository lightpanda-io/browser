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

    pub fn get_body(self: *parser.DocumentHTML) ?*parser.Body {
        return parser.documentHTMLBody(self);
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
}

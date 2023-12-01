const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("node.zig").Node;
const HTMLElem = @import("../html/elements.zig");
pub const Union = @import("../html/elements.zig").Union;

// WEB IDL https://dom.spec.whatwg.org/#element
pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn toInterface(e: *parser.Element) !Union {
        return try HTMLElem.toInterface(Union, e);
    }

    // JS funcs
    // --------

    pub fn get_localName(self: *parser.Element) ![]const u8 {
        return try parser.elementLocalName(self);
    }

    pub fn _getAttribute(self: *parser.Element, qname: []const u8) !?[]const u8 {
        return try parser.elementGetAttribute(self, qname);
    }

    pub fn _setAttribute(self: *parser.Element, qname: []const u8, value: []const u8) !void {
        return try parser.elementSetAttribute(self, qname, value);
    }

    pub fn _removeAttribute(self: *parser.Element, qname: []const u8) !void {
        return try parser.elementRemoveAttribute(self, qname);
    }

    pub fn _hasAttribute(self: *parser.Element, qname: []const u8) !bool {
        return try parser.elementHasAttribute(self, qname);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var attribute = [_]Case{
        .{ .src = "let div = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "div.getAttribute('id')", .ex = "content" },

        .{ .src = "div.hasAttribute('foo')", .ex = "false" },
        .{ .src = "div.getAttribute('foo')", .ex = "null" },

        .{ .src = "div.setAttribute('foo', 'bar')", .ex = "undefined" },
        .{ .src = "div.hasAttribute('foo')", .ex = "true" },
        .{ .src = "div.getAttribute('foo')", .ex = "bar" },

        .{ .src = "div.setAttribute('foo', 'baz')", .ex = "undefined" },
        .{ .src = "div.hasAttribute('foo')", .ex = "true" },
        .{ .src = "div.getAttribute('foo')", .ex = "baz" },

        .{ .src = "div.removeAttribute('foo')", .ex = "undefined" },
        .{ .src = "div.hasAttribute('foo')", .ex = "false" },
        .{ .src = "div.getAttribute('foo')", .ex = "null" },
    };
    try checkCases(js_env, &attribute);
}

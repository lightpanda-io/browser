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

    // https://dom.spec.whatwg.org/#dom-element-toggleattribute
    pub fn _toggleAttribute(self: *parser.Element, qname: []const u8, force: ?bool) !bool {
        const exists = try parser.elementHasAttribute(self, qname);

        // If attribute is null, then:
        if (!exists) {
            // If force is not given or is true, create an attribute whose
            // local name is qualifiedName, value is the empty string and node
            // document is this’s node document, then append this attribute to
            // this, and then return true.
            if (force == null or force.?) {
                try parser.elementSetAttribute(self, qname, "");
                return true;
            }

            // Return false.
            return false;
        }

        // Otherwise, if force is not given or is false, remove an attribute
        // given qualifiedName and this, and then return false.
        if (force == null or !force.?) {
            try parser.elementRemoveAttribute(self, qname);
            return false;
        }

        // Return true.
        return true;
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
        .{ .src = "let a = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "a.getAttribute('id')", .ex = "content" },

        .{ .src = "a.hasAttribute('foo')", .ex = "false" },
        .{ .src = "a.getAttribute('foo')", .ex = "null" },

        .{ .src = "a.setAttribute('foo', 'bar')", .ex = "undefined" },
        .{ .src = "a.hasAttribute('foo')", .ex = "true" },
        .{ .src = "a.getAttribute('foo')", .ex = "bar" },

        .{ .src = "a.setAttribute('foo', 'baz')", .ex = "undefined" },
        .{ .src = "a.hasAttribute('foo')", .ex = "true" },
        .{ .src = "a.getAttribute('foo')", .ex = "baz" },

        .{ .src = "a.removeAttribute('foo')", .ex = "undefined" },
        .{ .src = "a.hasAttribute('foo')", .ex = "false" },
        .{ .src = "a.getAttribute('foo')", .ex = "null" },
    };
    try checkCases(js_env, &attribute);

    var toggleAttr = [_]Case{
        .{ .src = "let b = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "b.toggleAttribute('foo')", .ex = "true" },
        .{ .src = "b.hasAttribute('foo')", .ex = "true" },
        .{ .src = "b.getAttribute('foo')", .ex = "" },

        .{ .src = "b.toggleAttribute('foo')", .ex = "false" },
        .{ .src = "b.hasAttribute('foo')", .ex = "false" },
    };
    try checkCases(js_env, &toggleAttr);
}

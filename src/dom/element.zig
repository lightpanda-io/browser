const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("node.zig").Node;
const HTMLElem = @import("../html/elements.zig");
pub const Union = @import("../html/elements.zig").Union;

const DOMException = @import("exceptions.zig").DOMException;

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

    pub fn get_namespaceURI(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetNamespace(parser.elementToNode(self));
    }

    pub fn get_prefix(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetPrefix(parser.elementToNode(self));
    }

    pub fn get_localName(self: *parser.Element) ![]const u8 {
        return try parser.nodeLocalName(parser.elementToNode(self));
    }

    pub fn get_tagName(self: *parser.Element) ![]const u8 {
        return try parser.nodeName(parser.elementToNode(self));
    }

    pub fn get_id(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "id") orelse "";
    }

    pub fn set_id(self: *parser.Element, id: []const u8) !void {
        return try parser.elementSetAttribute(self, "id", id);
    }

    pub fn get_className(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "class") orelse "";
    }

    pub fn set_className(self: *parser.Element, class: []const u8) !void {
        return try parser.elementSetAttribute(self, "class", class);
    }

    pub fn get_slot(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "slot") orelse "";
    }

    pub fn set_slot(self: *parser.Element, slot: []const u8) !void {
        return try parser.elementSetAttribute(self, "slot", slot);
    }

    pub fn get_attributes(self: *parser.Element) !*parser.NamedNodeMap {
        return try parser.nodeGetAttributes(parser.elementToNode(self));
    }

    pub fn _hasAttributes(self: *parser.Element) !bool {
        return try parser.nodeHasAttributes(parser.elementToNode(self));
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
    var getters = [_]Case{
        .{ .src = "let g = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "g.namespaceURI", .ex = "http://www.w3.org/1999/xhtml" },
        .{ .src = "g.prefix", .ex = "null" },
        .{ .src = "g.localName", .ex = "div" },
        .{ .src = "g.tagName", .ex = "DIV" },
    };
    try checkCases(js_env, &getters);

    var gettersetters = [_]Case{
        .{ .src = "let gs = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "gs.id", .ex = "content" },
        .{ .src = "gs.id = 'foo'", .ex = "foo" },
        .{ .src = "gs.id", .ex = "foo" },
        .{ .src = "gs.id = 'content'", .ex = "content" },
        .{ .src = "gs.className", .ex = "" },
        .{ .src = "let gs2 = document.getElementById('para-empty')", .ex = "undefined" },
        .{ .src = "gs2.className", .ex = "ok empty" },
        .{ .src = "gs2.className = 'foo bar baz'", .ex = "foo bar baz" },
        .{ .src = "gs2.className", .ex = "foo bar baz" },
        .{ .src = "gs2.className = 'ok empty'", .ex = "ok empty" },
    };
    try checkCases(js_env, &gettersetters);

    var attribute = [_]Case{
        .{ .src = "let a = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "a.hasAttributes()", .ex = "true" },
        .{ .src = "a.attributes.length", .ex = "1" },

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

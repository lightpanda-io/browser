const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#attr
pub const Attr = struct {
    pub const Self = parser.Attribute;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn get_namespaceURI(self: *parser.Attribute) !?[]const u8 {
        return try parser.nodeGetNamespace(parser.attributeToNode(self));
    }

    pub fn get_prefix(self: *parser.Attribute) !?[]const u8 {
        return try parser.nodeGetPrefix(parser.attributeToNode(self));
    }

    pub fn get_localName(self: *parser.Attribute) ![]const u8 {
        return try parser.nodeLocalName(parser.attributeToNode(self));
    }

    pub fn get_name(self: *parser.Attribute) ![]const u8 {
        return try parser.attributeGetName(self);
    }

    pub fn get_value(self: *parser.Attribute) !?[]const u8 {
        return try parser.attributeGetValue(self);
    }

    pub fn set_value(self: *parser.Attribute, v: []const u8) !?[]const u8 {
        try parser.attributeSetValue(self, v);
        return v;
    }

    pub fn get_ownerElement(self: *parser.Attribute) !?*parser.Element {
        return try parser.attributeGetOwnerElement(self);
    }

    pub fn get_specified(_: *parser.Attribute) bool {
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
        .{ .src = "let a = document.createAttributeNS('foo', 'bar')", .ex = "undefined" },
        .{ .src = "a.namespaceURI", .ex = "foo" },
        .{ .src = "a.prefix", .ex = "null" },
        .{ .src = "a.localName", .ex = "bar" },
        .{ .src = "a.name", .ex = "bar" },
        .{ .src = "a.value", .ex = "" },
        // TODO: libdom has a bug here: the created attr has no parent, it
        // causes a panic w/ libdom when setting the value.
        //.{ .src = "a.value = 'nok'", .ex = "nok" },
        .{ .src = "a.ownerElement", .ex = "null" },
    };
    try checkCases(js_env, &getters);

    var attr = [_]Case{
        .{ .src = "let b = document.getElementById('link').getAttributeNode('class')", .ex = "undefined" },
        .{ .src = "b.name", .ex = "class" },
        .{ .src = "b.value", .ex = "ok" },
        .{ .src = "b.value = 'nok'", .ex = "nok" },
        .{ .src = "b.value", .ex = "nok" },
        .{ .src = "b.value = null", .ex = "null" },
        .{ .src = "b.value", .ex = "null" },
        .{ .src = "b.value = 'ok'", .ex = "ok" },
        .{ .src = "b.ownerElement.id", .ex = "link" },
    };
    try checkCases(js_env, &attr);
}

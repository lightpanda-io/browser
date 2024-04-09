const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#namednodemap
pub const NamedNodeMap = struct {
    pub const Self = parser.NamedNodeMap;
    pub const mem_guarantied = true;

    pub const Exception = DOMException;

    // TODO implement LegacyUnenumerableNamedProperties.
    // https://webidl.spec.whatwg.org/#LegacyUnenumerableNamedProperties

    pub fn get_length(self: *parser.NamedNodeMap) !u32 {
        return try parser.namedNodeMapGetLength(self);
    }

    pub fn _item(self: *parser.NamedNodeMap, index: u32) !?*parser.Attribute {
        return try parser.namedNodeMapItem(self, index);
    }

    pub fn _getNamedItem(self: *parser.NamedNodeMap, qname: []const u8) !?*parser.Attribute {
        return try parser.namedNodeMapGetNamedItem(self, qname);
    }

    pub fn _getNamedItemNS(
        self: *parser.NamedNodeMap,
        namespace: []const u8,
        localname: []const u8,
    ) !?*parser.Attribute {
        return try parser.namedNodeMapGetNamedItemNS(self, namespace, localname);
    }

    pub fn _setNamedItem(self: *parser.NamedNodeMap, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.namedNodeMapSetNamedItem(self, attr);
    }

    pub fn _setNamedItemNS(self: *parser.NamedNodeMap, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.namedNodeMapSetNamedItemNS(self, attr);
    }

    pub fn _removeNamedItem(self: *parser.NamedNodeMap, qname: []const u8) !*parser.Attribute {
        return try parser.namedNodeMapRemoveNamedItem(self, qname);
    }

    pub fn _removeNamedItemNS(
        self: *parser.NamedNodeMap,
        namespace: []const u8,
        localname: []const u8,
    ) !*parser.Attribute {
        return try parser.namedNodeMapRemoveNamedItemNS(self, namespace, localname);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var setItem = [_]Case{
        .{ .src = "let a = document.getElementById('content').attributes", .ex = "undefined" },
        .{ .src = "a.length", .ex = "1" },
        .{ .src = "a.item(0)", .ex = "[object Attr]" },
        .{ .src = "a.item(1)", .ex = "null" },
        .{ .src = "a.getNamedItem('id')", .ex = "[object Attr]" },
        .{ .src = "a.getNamedItem('foo')", .ex = "null" },
        .{ .src = "a.setNamedItem(a.getNamedItem('id'))", .ex = "[object Attr]" },
    };
    try checkCases(js_env, &setItem);
}

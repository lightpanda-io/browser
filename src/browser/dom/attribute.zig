// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#attr
pub const Attr = struct {
    pub const Self = parser.Attribute;
    pub const prototype = *Node;
    pub const subtype = "node";

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

const testing = @import("../../testing.zig");
test "Browser.DOM.Attribute" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let a = document.createAttributeNS('foo', 'bar')", "undefined" },
        .{ "a.namespaceURI", "foo" },
        .{ "a.prefix", "null" },
        .{ "a.localName", "bar" },
        .{ "a.name", "bar" },
        .{ "a.value", "" },
        // TODO: libdom has a bug here: the created attr has no parent, it
        // causes a panic w/ libdom when setting the value.
        //.{ "a.value = 'nok'", "nok" },
        .{ "a.ownerElement", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let b = document.getElementById('link').getAttributeNode('class')", "undefined" },
        .{ "b.name", "class" },
        .{ "b.value", "ok" },
        .{ "b.value = 'nok'", "nok" },
        .{ "b.value", "nok" },
        .{ "b.value = null", "null" },
        .{ "b.value", "null" },
        .{ "b.value = 'ok'", "ok" },
        .{ "b.ownerElement.id", "link" },
    }, .{});
}

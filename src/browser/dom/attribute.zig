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
const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#attr
pub const Attr = struct {
    pub const Self = parser.Attribute;
    pub const prototype = *Node;
    pub const subtype = .node;

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
        if (try parser.attributeGetOwnerElement(self)) |el| {
            // if possible, go through the element, as that triggers a
            // DOMAttrModified event (which MutationObserver cares about)
            const name = try parser.attributeGetName(self);
            try parser.elementSetAttribute(el, name, v);
        } else {
            try parser.attributeSetValue(self, v);
        }
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
test "Browser: DOM.Attribute" {
    try testing.htmlRunner("dom/attribute.html");
}

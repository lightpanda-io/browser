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

const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#namednodemap
pub const NamedNodeMap = struct {
    pub const Self = parser.NamedNodeMap;

    pub const Exception = DOMException;
    pub const Iterator = NamedNodeMapIterator;

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

    pub fn indexed_get(self: *parser.NamedNodeMap, index: u32, has_value: *bool) !*parser.Attribute {
        return (try _item(self, index)) orelse {
            has_value.* = false;
            return undefined;
        };
    }

    pub fn named_get(self: *parser.NamedNodeMap, name: []const u8, has_value: *bool) !*parser.Attribute {
        return (try _getNamedItem(self, name)) orelse {
            has_value.* = false;
            return undefined;
        };
    }

    pub fn _symbol_iterator(self: *parser.NamedNodeMap) NamedNodeMapIterator {
        return .{ .map = self };
    }
};

pub const NamedNodeMapIterator = struct {
    index: u32 = 0,
    map: *parser.NamedNodeMap,

    pub const Return = struct {
        done: bool,
        value: ?*parser.Attribute,
    };

    pub fn _next(self: *NamedNodeMapIterator) !Return {
        const e = try NamedNodeMap._item(self.map, self.index);
        if (e == null) {
            return .{
                .value = null,
                .done = true,
            };
        }

        self.index += 1;
        return .{
            .value = e,
            .done = false,
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.NamedNodeMap" {
    try testing.htmlRunner("dom/named_node_map.html");
}

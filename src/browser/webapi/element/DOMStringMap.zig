// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");

const Element = @import("../Element.zig");
const Page = @import("../../Page.zig");

const Allocator = std.mem.Allocator;

const DOMStringMap = @This();

_element: *Element,

fn getProperty(self: *DOMStringMap, name: []const u8, page: *Page) !?[]const u8 {
    const attr_name = try camelToKebab(page.call_arena, name);
    return try self._element.getAttribute(attr_name, page);
}

fn setProperty(self: *DOMStringMap, name: []const u8, value: []const u8, page: *Page) !void {
    const attr_name = try camelToKebab(page.call_arena, name);
    return self._element.setAttributeSafe(attr_name, value, page);
}

fn deleteProperty(self: *DOMStringMap, name: []const u8, page: *Page) !void {
    const attr_name = try camelToKebab(page.call_arena, name);
    try self._element.removeAttribute(attr_name, page);
}

// fooBar -> foo-bar
fn camelToKebab(arena: Allocator, camel: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(arena, 5 + camel.len * 2);
    result.appendSliceAssumeCapacity("data-");

    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                result.appendAssumeCapacity('-');
            }
            result.appendAssumeCapacity(std.ascii.toLower(c));
        } else {
            result.appendAssumeCapacity(c);
        }
    }

    return result.items;
}

// data-foo-bar -> fooBar
fn kebabToCamel(arena: Allocator, kebab: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, kebab, "data-")) {
        return null;
    }

    const data_part = kebab[5..]; // Skip "data-"
    if (data_part.len == 0) {
        return null;
    }

    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(arena, data_part.len);

    var capitalize_next = false;
    for (data_part) |c| {
        if (c == '-') {
            capitalize_next = true;
        } else if (capitalize_next) {
            result.appendAssumeCapacity(std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            result.appendAssumeCapacity(c);
        }
    }

    return result.items;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMStringMap);

    pub const Meta = struct {
        pub const name = "DOMStringMap";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"[]" = bridge.namedIndexed(getProperty, setProperty, deleteProperty, .{ .null_as_undefined = true });
};

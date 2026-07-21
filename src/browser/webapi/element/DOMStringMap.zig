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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Element = @import("../Element.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const DOMStringMap = @This();

_element: *Element,

fn getProperty(self: *DOMStringMap, name: String, frame: *Frame) !?String {
    const attr_name = try camelToKebab(frame.local_arena, name);
    return try self._element.getAttribute(attr_name, frame);
}

fn setProperty(self: *DOMStringMap, name: String, value: String, frame: *Frame) !void {
    const attr_name = try camelToKebab(frame.local_arena, name);
    return self._element.setAttributeSafe(attr_name, value, frame);
}

fn deleteProperty(self: *DOMStringMap, name: String, frame: *Frame) !void {
    const attr_name = try camelToKebab(frame.local_arena, name);
    try self._element.removeAttribute(attr_name, frame);
}

// fooBar -> data-foo-bar (with SSO optimization for short strings)
fn camelToKebab(arena: Allocator, camel: String) !String {
    const camel_str = camel.str();

    // Calculate output length
    var output_len: usize = 5; // "data-"
    for (camel_str, 0..) |c, i| {
        output_len += 1;
        if (std.ascii.isUpper(c) and i > 0) output_len += 1; // extra char for '-'
    }

    if (output_len <= 12) {
        // SSO path - no allocation!
        var content: [12]u8 = @splat(0);
        @memcpy(content[0..5], "data-");
        var idx: usize = 5;

        for (camel_str, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                if (i > 0) {
                    content[idx] = '-';
                    idx += 1;
                }
                content[idx] = std.ascii.toLower(c);
            } else {
                content[idx] = c;
            }
            idx += 1;
        }

        return .{ .len = @intCast(output_len), .payload = .{ .content = @bitCast(content) } };
    }

    // Fallback: allocate for longer strings
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(arena, output_len);
    result.appendSliceAssumeCapacity("data-");

    for (camel_str, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                result.appendAssumeCapacity('-');
            }
            result.appendAssumeCapacity(std.ascii.toLower(c));
        } else {
            result.appendAssumeCapacity(c);
        }
    }

    return try String.init(arena, result.items, .{});
}

// data-foo-bar -> fooBar. Returns null for non data-* attributes. Per spec,
// only a '-' followed by an ASCII lowercase letter is folded into an
// uppercase letter; any other '-' (e.g. trailing) is kept as-is, and the
// bare "data-" attribute maps to the empty name.
fn kebabToCamel(arena: Allocator, kebab: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, kebab, "data-")) {
        return null;
    }

    const data_part = kebab[5..]; // Skip "data-"

    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(arena, data_part.len);

    var i: usize = 0;
    while (i < data_part.len) : (i += 1) {
        const c = data_part[i];
        if (c == '-' and i + 1 < data_part.len and std.ascii.isLower(data_part[i + 1])) {
            result.appendAssumeCapacity(std.ascii.toUpper(data_part[i + 1]));
            i += 1;
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

    pub const @"[]" = bridge.namedIndexed(getProperty, setProperty, deleteProperty, getNames, null, .{ .null_as_undefined = true, .ce_reactions = true });

    // The supported property names are the camel-cased names of the
    // element's data-* attributes, in attribute order.
    fn getNames(self: *DOMStringMap, frame: *Frame) !js.Array {
        var names: std.ArrayList([]const u8) = .empty;
        for (try self._element._attributes.getNames(frame.local_arena)) |attr_name| {
            const camel = (try kebabToCamel(frame.local_arena, attr_name)) orelse continue;
            try names.append(frame.local_arena, camel);
        }

        var arr = frame.js.local.?.newArray(@intCast(names.items.len));
        for (names.items, 0..) |name, i| {
            _ = try arr.set(@intCast(i), name, .{});
        }
        return arr;
    }
};

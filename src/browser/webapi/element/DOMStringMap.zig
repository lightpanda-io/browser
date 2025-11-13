const std = @import("std");
const js = @import("../../js/js.zig");

const Element = @import("../Element.zig");
const Page = @import("../../Page.zig");

const Allocator = std.mem.Allocator;

const DOMStringMap = @This();

_element: *Element,

fn _getProperty(self: *DOMStringMap, name: []const u8, page: *Page) !?[]const u8 {
    const attr_name = try camelToKebab(page.call_arena, name);
    return try self._element.getAttribute(attr_name, page);
}

fn _setProperty(self: *DOMStringMap, name: []const u8, value: []const u8, page: *Page) !void {
    const attr_name = try camelToKebab(page.call_arena, name);
    return self._element.setAttributeSafe(attr_name, value, page);
}

fn _deleteProperty(self: *DOMStringMap, name: []const u8, page: *Page) !void {
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

    pub const @"[]" = bridge.namedIndexed(_getProperty, _setProperty, _deleteProperty, .{ .null_as_undefined = true });
};

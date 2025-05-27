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

const CSSParser = @import("./css_parser.zig").CSSParser;
const CSSValueAnalyzer = @import("./css_value_analyzer.zig").CSSValueAnalyzer;
const Page = @import("../page.zig").Page;

pub const Interfaces = .{
    CSSStyleDeclaration,
    CSSRule,
};

const CSSRule = struct {};

pub const CSSStyleDeclaration = struct {
    store: std.StringHashMapUnmanaged(Property),
    order: std.ArrayListUnmanaged([]const u8),

    pub const empty: CSSStyleDeclaration = .{
        .store = .empty,
        .order = .empty,
    };

    const Property = struct {
        value: []const u8,
        priority: bool,
    };

    pub fn get_cssFloat(self: *const CSSStyleDeclaration) []const u8 {
        return self._getPropertyValue("float");
    }

    pub fn set_cssFloat(self: *CSSStyleDeclaration, value: ?[]const u8, page: *Page) !void {
        const final_value = value orelse "";
        return self._setProperty("float", final_value, null, page);
    }

    pub fn get_cssText(self: *const CSSStyleDeclaration, page: *Page) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const writer = buffer.writer(page.call_arena);
        for (self.order.items) |name| {
            const prop = self.store.get(name).?;
            const escaped = try CSSValueAnalyzer.escapeCSSValue(page.call_arena, prop.value);
            try writer.print("{s}: {s}", .{ name, escaped });
            if (prop.priority) try writer.writeAll(" !important");
            try writer.writeAll("; ");
        }
        return buffer.items;
    }

    // TODO Propagate also upward to parent node
    pub fn set_cssText(self: *CSSStyleDeclaration, text: []const u8, page: *Page) !void {
        self.store.clearRetainingCapacity();
        self.order.clearRetainingCapacity();

        // call_arena is safe here, because _setProperty will dupe the name
        // using the page's longer-living arena.
        const declarations = try CSSParser.parseDeclarations(page.call_arena, text);

        for (declarations) |decl| {
            if (!CSSValueAnalyzer.isValidPropertyName(decl.name)) continue;
            const priority: ?[]const u8 = if (decl.is_important) "important" else null;
            try self._setProperty(decl.name, decl.value, priority, page);
        }
    }

    pub fn get_length(self: *const CSSStyleDeclaration) usize {
        return self.order.items.len;
    }

    pub fn get_parentRule() ?CSSRule {
        return null;
    }

    pub fn _getPropertyPriority(self: *const CSSStyleDeclaration, name: []const u8) []const u8 {
        return if (self.store.get(name)) |prop| (if (prop.priority) "important" else "") else "";
    }

    // TODO should handle properly shorthand properties and canonical forms
    pub fn _getPropertyValue(self: *const CSSStyleDeclaration, name: []const u8) []const u8 {
        if (self.store.get(name)) |prop| {
            return prop.value;
        }

        // default to everything being visible (unless it's been explicitly set)
        if (std.mem.eql(u8, name, "visibility")) {
            return "visible";
        }

        return "";
    }

    pub fn _item(self: *const CSSStyleDeclaration, index: usize) []const u8 {
        return if (index < self.order.items.len) self.order.items[index] else "";
    }

    pub fn _removeProperty(self: *CSSStyleDeclaration, name: []const u8) ![]const u8 {
        const prop = self.store.fetchRemove(name) orelse return "";
        for (self.order.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) {
                _ = self.order.orderedRemove(i);
                break;
            }
        }
        // safe to return, since it's in our page.arena
        return prop.value.value;
    }

    pub fn _setProperty(self: *CSSStyleDeclaration, name: []const u8, value: []const u8, priority: ?[]const u8, page: *Page) !void {
        const owned_value = try page.arena.dupe(u8, value);
        const is_important = priority != null and std.ascii.eqlIgnoreCase(priority.?, "important");

        const gop = try self.store.getOrPut(page.arena, name);
        if (!gop.found_existing) {
            const owned_name = try page.arena.dupe(u8, name);
            gop.key_ptr.* = owned_name;
            try self.order.append(page.arena, owned_name);
        }

        gop.value_ptr.* = .{ .value = owned_value, .priority = is_important };
    }

    pub fn named_get(self: *const CSSStyleDeclaration, name: []const u8, _: *bool) []const u8 {
        return self._getPropertyValue(name);
    }
};

const testing = @import("../../testing.zig");

test "CSSOM.CSSStyleDeclaration" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let style = document.getElementById('content').style", "undefined" },
        .{ "style.cssText = 'color: red; font-size: 12px; margin: 5px !important;'", "color: red; font-size: 12px; margin: 5px !important;" },
        .{ "style.length", "3" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.getPropertyValue('color')", "red" },
        .{ "style.getPropertyValue('font-size')", "12px" },
        .{ "style.getPropertyValue('unknown-property')", "" },

        .{ "style.getPropertyPriority('margin')", "important" },
        .{ "style.getPropertyPriority('color')", "" },
        .{ "style.getPropertyPriority('unknown-property')", "" },

        .{ "style.item(0)", "color" },
        .{ "style.item(1)", "font-size" },
        .{ "style.item(2)", "margin" },
        .{ "style.item(3)", "" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.setProperty('background-color', 'blue')", "undefined" },
        .{ "style.getPropertyValue('background-color')", "blue" },
        .{ "style.length", "4" },

        .{ "style.setProperty('color', 'green')", "undefined" },
        .{ "style.getPropertyValue('color')", "green" },
        .{ "style.length", "4" },
        .{ "style.color", "green" },

        .{ "style.setProperty('padding', '10px', 'important')", "undefined" },
        .{ "style.getPropertyValue('padding')", "10px" },
        .{ "style.getPropertyPriority('padding')", "important" },

        .{ "style.setProperty('border', '1px solid black', 'IMPORTANT')", "undefined" },
        .{ "style.getPropertyPriority('border')", "important" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.removeProperty('color')", "green" },
        .{ "style.getPropertyValue('color')", "" },
        .{ "style.length", "5" },

        .{ "style.removeProperty('unknown-property')", "" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.cssText.includes('font-size: 12px;')", "true" },
        .{ "style.cssText.includes('margin: 5px !important;')", "true" },
        .{ "style.cssText.includes('padding: 10px !important;')", "true" },
        .{ "style.cssText.includes('border: 1px solid black !important;')", "true" },

        .{ "style.cssText = 'color: purple; text-align: center;'", "color: purple; text-align: center;" },
        .{ "style.length", "2" },
        .{ "style.getPropertyValue('color')", "purple" },
        .{ "style.getPropertyValue('text-align')", "center" },
        .{ "style.getPropertyValue('font-size')", "" },

        .{ "style.setProperty('cont', 'Hello; world!')", "undefined" },
        .{ "style.getPropertyValue('cont')", "Hello; world!" },

        .{ "style.cssText = 'content: \"Hello; world!\"; background-image: url(\"test.png\");'", "content: \"Hello; world!\"; background-image: url(\"test.png\");" },
        .{ "style.getPropertyValue('content')", "\"Hello; world!\"" },
        .{ "style.getPropertyValue('background-image')", "url(\"test.png\")" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.cssFloat", "" },
        .{ "style.cssFloat = 'left'", "left" },
        .{ "style.cssFloat", "left" },
        .{ "style.getPropertyValue('float')", "left" },

        .{ "style.cssFloat = 'right'", "right" },
        .{ "style.cssFloat", "right" },

        .{ "style.cssFloat = null", "null" },
        .{ "style.cssFloat", "" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.setProperty('display', '')", "undefined" },
        .{ "style.getPropertyValue('display')", "" },

        .{ "style.cssText = '  color  :  purple  ;  margin  :  10px  ;  '", "  color  :  purple  ;  margin  :  10px  ;  " },
        .{ "style.getPropertyValue('color')", "purple" },
        .{ "style.getPropertyValue('margin')", "10px" },

        .{ "style.setProperty('border-bottom-left-radius', '5px')", "undefined" },
        .{ "style.getPropertyValue('border-bottom-left-radius')", "5px" },
    }, .{});

    try runner.testCases(&.{
        .{ "style.visibility", "visible" },
        .{ "style.getPropertyValue('visibility')", "visible" },
    }, .{});
}

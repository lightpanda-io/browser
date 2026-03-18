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
const log = @import("../../../log.zig");
const String = @import("../../../string.zig").String;

const CssParser = @import("../../css/Parser.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");

const CSSStyleDeclaration = @This();

_element: ?*Element = null,
_properties: std.DoublyLinkedList = .{},
_is_computed: bool = false,

pub const CascadeSpecificity = struct {
    inline_style: u16 = 0,
    ids: u16 = 0,
    classes: u16 = 0,
    tags: u16 = 0,

    pub fn compare(self: @This(), other: @This()) std.math.Order {
        if (self.inline_style != other.inline_style) return std.math.order(self.inline_style, other.inline_style);
        if (self.ids != other.ids) return std.math.order(self.ids, other.ids);
        if (self.classes != other.classes) return std.math.order(self.classes, other.classes);
        return std.math.order(self.tags, other.tags);
    }
};

pub fn init(element: ?*Element, is_computed: bool, page: *Page) !*CSSStyleDeclaration {
    const self = try page._factory.create(CSSStyleDeclaration{
        ._element = element,
        ._is_computed = is_computed,
    });

    // Parse the element's existing style attribute into _properties so that
    // subsequent JS reads and writes see all CSS properties, not just newly
    // added ones.  Computed styles have no inline attribute to parse.
    if (!is_computed) {
        if (element) |el| {
            if (el.getAttributeSafe(comptime .wrap("style"))) |attr_value| {
                var it = CssParser.parseDeclarationsList(attr_value);
                while (it.next()) |declaration| {
                    try self.applyDeclaration(declaration.name, declaration.value, declaration.important, page);
                }
            }
        }
    }

    return self;
}

pub fn length(self: *const CSSStyleDeclaration) u32 {
    return @intCast(self._properties.len());
}

pub fn item(self: *const CSSStyleDeclaration, index: u32) []const u8 {
    var i: u32 = 0;
    var node = self._properties.first;
    while (node) |n| {
        if (i == index) {
            const prop = Property.fromNodeLink(n);
            return prop._name.str();
        }
        i += 1;
        node = n.next;
    }
    return "";
}

pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, page: *Page) []const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse {
        // Only return default values for computed styles
        if (self._is_computed) {
            return getDefaultPropertyValue(self, normalized);
        }
        return "";
    };
    return prop._value.str();
}

pub fn getSpecifiedPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, page: *Page) []const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";
    return prop._value.str();
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, page: *Page) []const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";
    return if (prop._important) "important" else "";
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, page: *Page) !void {
    // Validate priority
    const priority = priority_ orelse "";
    const important = if (priority.len > 0) blk: {
        if (!std.ascii.eqlIgnoreCase(priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

    try self.setPropertyImpl(property_name, value, important, page);

    try self.syncStyleAttribute(page);
}

fn setPropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, page: *Page) !void {
    if (value.len == 0) {
        _ = try self.removePropertyImpl(property_name, page);
        return;
    }

    const normalized = normalizePropertyName(property_name, &page.buf);

    // Find existing property
    if (self.findProperty(normalized)) |existing| {
        existing._value = try String.init(page.arena, value, .{});
        existing._important = important;
        existing._cascade_specificity = .{};
        existing._cascade_source_order = 0;
        return;
    }

    // Create new property
    const prop = try page._factory.create(Property{
        ._node = .{},
        ._name = try String.init(page.arena, normalized, .{}),
        ._value = try String.init(page.arena, value, .{}),
        ._important = important,
        ._cascade_specificity = .{},
        ._cascade_source_order = 0,
    });
    self._properties.append(&prop._node);
}

fn setPropertyImplWithCascade(
    self: *CSSStyleDeclaration,
    property_name: []const u8,
    value: []const u8,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    if (value.len == 0) {
        _ = try self.removePropertyImpl(property_name, page);
        return;
    }

    const normalized = normalizePropertyName(property_name, &page.buf);
    if (self.findProperty(normalized)) |existing| {
        if (!shouldOverrideCascade(existing, important, specificity, source_order)) {
            return;
        }
        existing._value = try String.init(page.arena, value, .{});
        existing._important = important;
        existing._cascade_specificity = specificity;
        existing._cascade_source_order = source_order;
        return;
    }

    const prop = try page._factory.create(Property{
        ._node = .{},
        ._name = try String.init(page.arena, normalized, .{}),
        ._value = try String.init(page.arena, value, .{}),
        ._important = important,
        ._cascade_specificity = specificity,
        ._cascade_source_order = source_order,
    });
    self._properties.append(&prop._node);
}

fn shouldOverrideCascade(
    existing: *const Property,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
) bool {
    if (important != existing._important) {
        return important;
    }

    switch (specificity.compare(existing._cascade_specificity)) {
        .gt => return true,
        .lt => return false,
        .eq => {},
    }

    return source_order >= existing._cascade_source_order;
}

pub fn applyDeclarationsText(self: *CSSStyleDeclaration, text: []const u8, page: *Page) !void {
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.applyDeclaration(declaration.name, declaration.value, declaration.important, page);
    }
}

pub fn applyDeclarationsTextWithCascade(
    self: *CSSStyleDeclaration,
    text: []const u8,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.applyDeclarationWithCascade(
            declaration.name,
            declaration.value,
            declaration.important,
            specificity,
            source_order,
            page,
        );
    }
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, page: *Page) ![]const u8 {
    const result = try self.removePropertyImpl(property_name, page);
    try self.syncStyleAttribute(page);
    return result;
}

fn removePropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, page: *Page) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";

    // the value might not be on the heap (it could be inlined in the small string
    // optimization), so we need to dupe it.
    const old_value = try page.call_arena.dupe(u8, prop._value.str());
    self._properties.remove(&prop._node);
    page._factory.destroy(prop);
    return old_value;
}

// Serialize current properties back to the element's style attribute so that
// DOM serialization (outerHTML, getAttribute) reflects JS-modified styles.
fn syncStyleAttribute(self: *CSSStyleDeclaration, page: *Page) !void {
    const element = self._element orelse return;
    const css_text = try self.getCssText(page);
    try element.setAttributeSafe(comptime .wrap("style"), .wrap(css_text), page);
}

pub fn getFloat(self: *const CSSStyleDeclaration, page: *Page) []const u8 {
    return self.getPropertyValue("float", page);
}

pub fn setFloat(self: *CSSStyleDeclaration, value_: ?[]const u8, page: *Page) !void {
    try self.setPropertyImpl("float", value_ orelse "", false, page);
    try self.syncStyleAttribute(page);
}

pub fn getCssText(self: *const CSSStyleDeclaration, page: *Page) ![]const u8 {
    if (self._element == null) return "";

    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    try self.format(&buf.writer);
    return buf.written();
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, page: *Page) !void {
    if (self._element == null) return;

    // Clear existing properties
    var node = self._properties.first;
    while (node) |n| {
        const next = n.next;
        const prop = Property.fromNodeLink(n);
        self._properties.remove(n);
        page._factory.destroy(prop);
        node = next;
    }

    // Parse and set new properties
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.applyDeclaration(declaration.name, declaration.value, declaration.important, page);
    }
    try self.syncStyleAttribute(page);
}

fn applyDeclaration(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, page: *Page) !void {
    try self.setPropertyImpl(property_name, value, important, page);

    const normalized = normalizePropertyName(property_name, &page.buf);
    if (std.mem.eql(u8, normalized, "background")) {
        try self.expandBackgroundShorthand(value, important, page);
        return;
    }
    if (std.mem.eql(u8, normalized, "border")) {
        try self.expandBorderShorthand(value, important, page);
        return;
    }
    if (std.mem.eql(u8, normalized, "font")) {
        try self.expandFontShorthand(value, important, page);
    }
}

fn applyDeclarationWithCascade(
    self: *CSSStyleDeclaration,
    property_name: []const u8,
    value: []const u8,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    try self.setPropertyImplWithCascade(property_name, value, important, specificity, source_order, page);

    const normalized = normalizePropertyName(property_name, &page.buf);
    if (std.mem.eql(u8, normalized, "background")) {
        try self.expandBackgroundShorthandWithCascade(value, important, specificity, source_order, page);
        return;
    }
    if (std.mem.eql(u8, normalized, "border")) {
        try self.expandBorderShorthandWithCascade(value, important, specificity, source_order, page);
        return;
    }
    if (std.mem.eql(u8, normalized, "font")) {
        try self.expandFontShorthandWithCascade(value, important, specificity, source_order, page);
    }
}

fn expandBackgroundShorthand(self: *CSSStyleDeclaration, value: []const u8, important: bool, page: *Page) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    if (extractBackgroundColorToken(trimmed)) |color_token| {
        try self.setPropertyImpl("background-color", color_token, important, page);
    }

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var image_token: ?[]const u8 = null;
    var repeat_token: ?[]const u8 = null;
    var position_tokens = std.ArrayList([]const u8).empty;
    var size_tokens = std.ArrayList([]const u8).empty;
    var parsing_size = false;
    defer position_tokens.deinit(page.call_arena);
    defer size_tokens.deinit(page.call_arena);

    while (tokens.next()) |token| {
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "/")) {
            parsing_size = true;
            continue;
        }

        if (std.mem.indexOfScalar(u8, token, '/')) |slash| {
            const left = std.mem.trim(u8, token[0..slash], &std.ascii.whitespace);
            const right = std.mem.trim(u8, token[slash + 1 ..], &std.ascii.whitespace);
            if (left.len > 0 and isBackgroundPositionToken(left) and position_tokens.items.len < 2) {
                try position_tokens.append(page.call_arena, left);
            }
            if (right.len > 0 and isBackgroundSizeToken(right) and size_tokens.items.len < 2) {
                try size_tokens.append(page.call_arena, right);
                parsing_size = true;
            }
            continue;
        }

        if (image_token == null and isBackgroundImageToken(token)) {
            image_token = token;
            continue;
        }
        if (repeat_token == null and isBackgroundRepeatToken(token)) {
            repeat_token = token;
            continue;
        }
        if (parsing_size and isBackgroundSizeToken(token) and size_tokens.items.len < 2) {
            try size_tokens.append(page.call_arena, token);
            continue;
        }
        if (isBackgroundPositionToken(token) and position_tokens.items.len < 2) {
            try position_tokens.append(page.call_arena, token);
        }
    }

    if (image_token) |token| {
        try self.setPropertyImpl("background-image", token, important, page);
    }
    if (repeat_token) |token| {
        try self.setPropertyImpl("background-repeat", token, important, page);
    }
    if (position_tokens.items.len > 0) {
        const background_position = try std.mem.join(page.call_arena, " ", position_tokens.items);
        try self.setPropertyImpl("background-position", background_position, important, page);
    }
    if (size_tokens.items.len > 0) {
        const background_size = try std.mem.join(page.call_arena, " ", size_tokens.items);
        try self.setPropertyImpl("background-size", background_size, important, page);
    }
}

fn expandBackgroundShorthandWithCascade(
    self: *CSSStyleDeclaration,
    value: []const u8,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    if (extractBackgroundColorToken(trimmed)) |color_token| {
        try self.setPropertyImplWithCascade("background-color", color_token, important, specificity, source_order, page);
    }

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var image_token: ?[]const u8 = null;
    var repeat_token: ?[]const u8 = null;
    var position_tokens = std.ArrayList([]const u8).empty;
    var size_tokens = std.ArrayList([]const u8).empty;
    var parsing_size = false;
    defer position_tokens.deinit(page.call_arena);
    defer size_tokens.deinit(page.call_arena);

    while (tokens.next()) |token| {
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "/")) {
            parsing_size = true;
            continue;
        }

        if (std.mem.indexOfScalar(u8, token, '/')) |slash| {
            const left = std.mem.trim(u8, token[0..slash], &std.ascii.whitespace);
            const right = std.mem.trim(u8, token[slash + 1 ..], &std.ascii.whitespace);
            if (left.len > 0 and isBackgroundPositionToken(left) and position_tokens.items.len < 2) {
                try position_tokens.append(page.call_arena, left);
            }
            if (right.len > 0 and isBackgroundSizeToken(right) and size_tokens.items.len < 2) {
                try size_tokens.append(page.call_arena, right);
                parsing_size = true;
            }
            continue;
        }

        if (image_token == null and isBackgroundImageToken(token)) {
            image_token = token;
            continue;
        }
        if (repeat_token == null and isBackgroundRepeatToken(token)) {
            repeat_token = token;
            continue;
        }
        if (parsing_size and isBackgroundSizeToken(token) and size_tokens.items.len < 2) {
            try size_tokens.append(page.call_arena, token);
            continue;
        }
        if (!parsing_size and isBackgroundPositionToken(token) and position_tokens.items.len < 2) {
            try position_tokens.append(page.call_arena, token);
        }
    }

    if (image_token) |token| {
        try self.setPropertyImplWithCascade("background-image", token, important, specificity, source_order, page);
    }
    if (repeat_token) |token| {
        try self.setPropertyImplWithCascade("background-repeat", token, important, specificity, source_order, page);
    }
    if (position_tokens.items.len > 0) {
        const background_position = try std.mem.join(page.call_arena, " ", position_tokens.items);
        try self.setPropertyImplWithCascade("background-position", background_position, important, specificity, source_order, page);
    }
    if (size_tokens.items.len > 0) {
        const background_size = try std.mem.join(page.call_arena, " ", size_tokens.items);
        try self.setPropertyImplWithCascade("background-size", background_size, important, specificity, source_order, page);
    }
}

fn expandBorderShorthand(self: *CSSStyleDeclaration, value: []const u8, important: bool, page: *Page) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var width_token: ?[]const u8 = null;
    var style_token: ?[]const u8 = null;
    var color_token: ?[]const u8 = null;

    while (tokens.next()) |token| {
        if (token.len == 0) continue;

        if (style_token == null and isBorderStyleToken(token)) {
            style_token = token;
            continue;
        }
        if (width_token == null and isBorderWidthToken(token)) {
            width_token = token;
            continue;
        }
        if (color_token == null and isLikelyColorToken(token)) {
            color_token = token;
        }
    }

    if (width_token) |token| {
        try self.setPropertyImpl("border-width", token, important, page);
    }
    if (style_token) |token| {
        try self.setPropertyImpl("border-style", token, important, page);
    }
    if (color_token) |token| {
        try self.setPropertyImpl("border-color", token, important, page);
    }
}

fn expandBorderShorthandWithCascade(
    self: *CSSStyleDeclaration,
    value: []const u8,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var width_token: ?[]const u8 = null;
    var style_token: ?[]const u8 = null;
    var color_token: ?[]const u8 = null;
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        if (width_token == null and isBorderWidthToken(token)) {
            width_token = token;
            continue;
        }
        if (style_token == null and isBorderStyleToken(token)) {
            style_token = token;
            continue;
        }
        if (color_token == null and isLikelyColorToken(token)) {
            color_token = token;
        }
    }

    if (width_token) |token| {
        try self.setPropertyImplWithCascade("border-width", token, important, specificity, source_order, page);
    }
    if (style_token) |token| {
        try self.setPropertyImplWithCascade("border-style", token, important, specificity, source_order, page);
    }
    if (color_token) |token| {
        try self.setPropertyImplWithCascade("border-color", token, important, specificity, source_order, page);
    }
}

fn expandFontShorthand(self: *CSSStyleDeclaration, value: []const u8, important: bool, page: *Page) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var collected: std.ArrayList([]const u8) = .{};
    defer collected.deinit(page.call_arena);
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try collected.append(page.call_arena, token);
    }
    if (collected.items.len == 0) return;

    var style_token: ?[]const u8 = null;
    var weight_token: ?[]const u8 = null;
    var size_token: ?[]const u8 = null;
    var line_height_token: ?[]const u8 = null;
    var family_start: ?usize = null;

    for (collected.items, 0..) |token, index| {
        if (size_token == null) {
            if (fontShorthandSizeAndLineHeight(token)) |size_line| {
                size_token = size_line.size;
                line_height_token = size_line.line_height;
                family_start = index + 1;
                break;
            }
            if (style_token == null and isFontStyleToken(token)) {
                style_token = token;
                continue;
            }
            if (weight_token == null and isFontWeightToken(token)) {
                weight_token = token;
                continue;
            }
        }
    }

    if (size_token == null or family_start == null or family_start.? >= collected.items.len) {
        return;
    }

    const family = try std.mem.join(page.call_arena, " ", collected.items[family_start.?..]);
    if (family.len == 0) return;

    if (style_token) |token| {
        try self.setPropertyImpl("font-style", token, important, page);
    }
    if (weight_token) |token| {
        try self.setPropertyImpl("font-weight", token, important, page);
    }
    if (size_token) |token| {
        try self.setPropertyImpl("font-size", token, important, page);
    }
    if (line_height_token) |token| {
        try self.setPropertyImpl("line-height", token, important, page);
    }
    try self.setPropertyImpl("font-family", family, important, page);
}

fn expandFontShorthandWithCascade(
    self: *CSSStyleDeclaration,
    value: []const u8,
    important: bool,
    specificity: CascadeSpecificity,
    source_order: usize,
    page: *Page,
) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var tokens = tokenizeCssValue(trimmed, page.call_arena);
    var collected: std.ArrayList([]const u8) = .{};
    defer collected.deinit(page.call_arena);
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try collected.append(page.call_arena, token);
    }
    if (collected.items.len == 0) return;

    var style_token: ?[]const u8 = null;
    var weight_token: ?[]const u8 = null;
    var size_token: ?[]const u8 = null;
    var line_height_token: ?[]const u8 = null;
    var family_start: ?usize = null;

    for (collected.items, 0..) |token, index| {
        if (size_token == null) {
            if (fontShorthandSizeAndLineHeight(token)) |size_line| {
                size_token = size_line.size;
                line_height_token = size_line.line_height;
                family_start = index + 1;
                break;
            }
            if (style_token == null and isFontStyleToken(token)) {
                style_token = token;
                continue;
            }
            if (weight_token == null and isFontWeightToken(token)) {
                weight_token = token;
                continue;
            }
        }
    }

    if (size_token == null or family_start == null or family_start.? >= collected.items.len) {
        return;
    }

    const family = try std.mem.join(page.call_arena, " ", collected.items[family_start.?..]);
    if (family.len == 0) return;

    if (style_token) |token| {
        try self.setPropertyImplWithCascade("font-style", token, important, specificity, source_order, page);
    }
    if (weight_token) |token| {
        try self.setPropertyImplWithCascade("font-weight", token, important, specificity, source_order, page);
    }
    if (size_token) |token| {
        try self.setPropertyImplWithCascade("font-size", token, important, specificity, source_order, page);
    }
    if (line_height_token) |token| {
        try self.setPropertyImplWithCascade("line-height", token, important, specificity, source_order, page);
    }
    try self.setPropertyImplWithCascade("font-family", family, important, specificity, source_order, page);
}

pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer) !void {
    const node = self._properties.first orelse return;
    try Property.fromNodeLink(node).format(writer);

    var next = node.next;
    while (next) |n| {
        try writer.writeByte(' ');
        try Property.fromNodeLink(n).format(writer);
        next = n.next;
    }
}

fn findProperty(self: *const CSSStyleDeclaration, name: []const u8) ?*Property {
    var node = self._properties.first;
    while (node) |n| {
        const prop = Property.fromNodeLink(n);
        if (prop._name.eqlSlice(name)) {
            return prop;
        }
        node = n.next;
    }
    return null;
}

fn normalizePropertyName(name: []const u8, buf: []u8) []const u8 {
    if (name.len > buf.len) {
        log.info(.dom, "css.long.name", .{ .name = name });
        return name;
    }
    return std.ascii.lowerString(buf, name);
}

fn getDefaultPropertyValue(self: *const CSSStyleDeclaration, normalized_name: []const u8) []const u8 {
    if (std.mem.eql(u8, normalized_name, "visibility")) {
        return "visible";
    }
    if (std.mem.eql(u8, normalized_name, "opacity")) {
        return "1";
    }
    if (std.mem.eql(u8, normalized_name, "display")) {
        const element = self._element orelse return "";
        return getDefaultDisplay(element);
    }
    if (std.mem.eql(u8, normalized_name, "color")) {
        const element = self._element orelse return "";
        return getDefaultColor(element);
    }
    if (std.mem.eql(u8, normalized_name, "background-color")) {
        // transparent
        return "rgba(0, 0, 0, 0)";
    }
    if (std.mem.eql(u8, normalized_name, "line-height")) {
        return "normal";
    }
    if (std.mem.eql(u8, normalized_name, "letter-spacing")) {
        return "normal";
    }
    if (std.mem.eql(u8, normalized_name, "word-spacing")) {
        return "normal";
    }
    if (std.mem.eql(u8, normalized_name, "text-transform")) {
        return "none";
    }

    if (self._element) |element| {
        if (presentationalPropertyValue(element, normalized_name)) |value| {
            return value;
        }
    }

    return "";
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote => "inline",
                .button, .canvas, .iframe, .img, .input, .select, .textarea => "inline-block",
                .table => "table",
                .table_caption => "table-caption",
                .table_cell => "table-cell",
                .table_col => |table_col| if (std.ascii.eqlIgnoreCase(table_col._tag_name.str(), "colgroup")) "table-column-group" else "table-column",
                .table_row => "table-row",
                .table_section => |section| switch (section._tag) {
                    .thead => "table-header-group",
                    .tfoot => "table-footer-group",
                    else => "table-row-group",
                },
                .body, .div, .dl, .p, .heading, .form, .details, .dialog, .embed, .head, .html, .hr, .li, .link, .meta, .ol, .option, .script, .slot, .style, .template, .title, .ul, .media, .area, .base, .datalist, .directory, .fieldset, .legend, .map, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .source, .track => "block",
                .generic, .custom, .unknown, .data => blk: {
                    if (std.ascii.eqlIgnoreCase(element.getTagNameLower(), "center")) {
                        break :blk "block";
                    }
                    const tag = element.getTagNameLower();
                    if (isInlineTag(tag)) break :blk "inline";
                    break :blk "block";
                },
            };
        },
        .svg => return "inline",
    }
}

fn isInlineTag(tag_name: []const u8) bool {
    const inline_tags = [_][]const u8{
        "abbr",  "b",    "bdi",    "bdo",  "cite", "code", "dfn",
        "em",    "i",    "kbd",    "mark", "q",    "s",    "samp",
        "small", "span", "strong", "sub",  "sup",  "time", "u",
        "var",   "wbr",
    };

    for (inline_tags) |inline_tag| {
        if (std.mem.eql(u8, tag_name, inline_tag)) {
            return true;
        }
    }
    return false;
}

fn getDefaultColor(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor => "rgb(0, 0, 238)", // blue
                else => "rgb(0, 0, 0)",
            };
        },
        .svg => return "rgb(0, 0, 0)",
    }
}

fn presentationalPropertyValue(element: *const Element, normalized_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, normalized_name, "text-align")) {
        if (std.ascii.eqlIgnoreCase(element.getTagNameLower(), "center")) {
            return "center";
        }
        if (element.getAttributeSafe(comptime .wrap("align"))) |attr_align| {
            if (std.ascii.eqlIgnoreCase(attr_align, "left")) return "left";
            if (std.ascii.eqlIgnoreCase(attr_align, "right")) return "right";
            if (std.ascii.eqlIgnoreCase(attr_align, "center") or std.ascii.eqlIgnoreCase(attr_align, "middle")) return "center";
            if (std.ascii.eqlIgnoreCase(attr_align, "justify")) return "justify";
        }
    }

    if (std.mem.eql(u8, normalized_name, "vertical-align")) {
        if (element.getAttributeSafe(comptime .wrap("valign"))) |valign| {
            if (std.ascii.eqlIgnoreCase(valign, "top")) return "top";
            if (std.ascii.eqlIgnoreCase(valign, "middle") or std.ascii.eqlIgnoreCase(valign, "center")) return "middle";
            if (std.ascii.eqlIgnoreCase(valign, "bottom")) return "bottom";
        }
    }

    if (std.mem.eql(u8, normalized_name, "white-space")) {
        if (element.hasAttributeSafe(comptime .wrap("nowrap"))) {
            return "nowrap";
        }
    }

    if (std.mem.eql(u8, normalized_name, "width")) {
        if (element.getAttributeSafe(comptime .wrap("width"))) |width| {
            return std.mem.trim(u8, width, &std.ascii.whitespace);
        }
    }

    if (std.mem.eql(u8, normalized_name, "height")) {
        if (element.getAttributeSafe(comptime .wrap("height"))) |height| {
            return std.mem.trim(u8, height, &std.ascii.whitespace);
        }
    }

    return null;
}

const CssValueTokenizer = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *CssValueTokenizer) ?[]const u8 {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}
        if (self.index >= self.input.len) return null;

        const start = self.index;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (self.index < self.input.len) : (self.index += 1) {
            const c = self.input[self.index];
            if (quote != 0) {
                if (c == '\\' and self.index + 1 < self.input.len) {
                    self.index += 1;
                    continue;
                }
                if (c == quote) {
                    quote = 0;
                }
                continue;
            }

            switch (c) {
                '"', '\'' => quote = c,
                '(' => depth += 1,
                ')' => {
                    if (depth > 0) depth -= 1;
                },
                else => {},
            }

            if (depth == 0 and std.ascii.isWhitespace(c)) {
                break;
            }
        }

        const end = self.index;
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}
        return self.input[start..end];
    }
};

fn tokenizeCssValue(input: []const u8, _: std.mem.Allocator) CssValueTokenizer {
    return .{ .input = input };
}

fn extractBackgroundColorToken(value: []const u8) ?[]const u8 {
    if (isLikelyColorToken(value)) return value;

    var tokens = tokenizeCssValue(value, std.heap.page_allocator);
    while (tokens.next()) |token| {
        if (isLikelyColorToken(token)) {
            return token;
        }
    }
    return null;
}

fn isLikelyColorToken(token: []const u8) bool {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '#') return true;
    if (std.ascii.startsWithIgnoreCase(trimmed, "rgb(") or
        std.ascii.startsWithIgnoreCase(trimmed, "rgba(") or
        std.ascii.startsWithIgnoreCase(trimmed, "hsl(") or
        std.ascii.startsWithIgnoreCase(trimmed, "hsla("))
    {
        return true;
    }

    return asciiEqualsAnyIgnoreCase(trimmed, &.{
        "transparent",
        "black",
        "white",
        "red",
        "green",
        "blue",
        "yellow",
        "orange",
        "purple",
        "gray",
        "grey",
        "silver",
        "maroon",
        "navy",
        "teal",
        "aqua",
        "lime",
        "olive",
        "fuchsia",
        "currentcolor",
    });
}

fn isBackgroundImageToken(token: []const u8) bool {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return std.ascii.startsWithIgnoreCase(trimmed, "url(") or std.ascii.eqlIgnoreCase(trimmed, "none");
}

fn isBackgroundRepeatToken(token: []const u8) bool {
    return asciiEqualsAnyIgnoreCase(token, &.{
        "repeat",
        "repeat-x",
        "repeat-y",
        "no-repeat",
    });
}

fn isBackgroundPositionToken(token: []const u8) bool {
    if (likelyCssLengthToken(token)) return true;
    return asciiEqualsAnyIgnoreCase(token, &.{
        "left",
        "right",
        "top",
        "bottom",
        "center",
    });
}

fn isBackgroundSizeToken(token: []const u8) bool {
    if (likelyCssLengthToken(token)) return true;
    return asciiEqualsAnyIgnoreCase(token, &.{
        "auto",
        "contain",
        "cover",
    });
}

fn isBorderStyleToken(token: []const u8) bool {
    return asciiEqualsAnyIgnoreCase(token, &.{
        "none",
        "hidden",
        "dotted",
        "dashed",
        "solid",
        "double",
        "groove",
        "ridge",
        "inset",
        "outset",
    });
}

fn isBorderWidthToken(token: []const u8) bool {
    if (asciiEqualsAnyIgnoreCase(token, &.{ "thin", "medium", "thick" })) {
        return true;
    }
    return likelyCssLengthToken(token);
}

fn isFontStyleToken(token: []const u8) bool {
    return asciiEqualsAnyIgnoreCase(token, &.{ "normal", "italic", "oblique" });
}

fn isFontWeightToken(token: []const u8) bool {
    if (asciiEqualsAnyIgnoreCase(token, &.{ "normal", "bold", "bolder", "lighter" })) {
        return true;
    }
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    return std.fmt.parseInt(i32, trimmed, 10) catch 0 > 0;
}

const FontSizeLineHeight = struct {
    size: []const u8,
    line_height: ?[]const u8 = null,
};

fn fontShorthandSizeAndLineHeight(token: []const u8) ?FontSizeLineHeight {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const size = std.mem.trim(u8, trimmed[0..slash], &std.ascii.whitespace);
        const line_height = std.mem.trim(u8, trimmed[slash + 1 ..], &std.ascii.whitespace);
        if (likelyCssLengthToken(size) and line_height.len > 0) {
            return .{ .size = size, .line_height = line_height };
        }
        return null;
    }

    if (likelyCssLengthToken(trimmed)) {
        return .{ .size = trimmed };
    }
    return null;
}

fn likelyCssLengthToken(token: []const u8) bool {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "0")) return true;

    var index: usize = 0;
    if (trimmed[index] == '+' or trimmed[index] == '-') {
        index += 1;
    }

    var saw_digit = false;
    var saw_dot = false;
    while (index < trimmed.len) : (index += 1) {
        const c = trimmed[index];
        if (std.ascii.isDigit(c)) {
            saw_digit = true;
            continue;
        }
        if (c == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        break;
    }

    if (!saw_digit) return false;
    if (index >= trimmed.len) return true;

    const unit = trimmed[index..];
    return asciiEqualsAnyIgnoreCase(unit, &.{
        "px",
        "%",
        "em",
        "rem",
        "vw",
        "vh",
        "vmin",
        "vmax",
        "pt",
        "pc",
        "cm",
        "mm",
        "in",
        "ch",
        "ex",
    });
}

fn asciiEqualsAnyIgnoreCase(value: []const u8, candidates: []const []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) {
            return true;
        }
    }
    return false;
}

pub const Property = struct {
    _name: String,
    _value: String,
    _important: bool = false,
    _cascade_specificity: CascadeSpecificity = .{},
    _cascade_source_order: usize = 0,
    _node: std.DoublyLinkedList.Node,

    fn fromNodeLink(n: *std.DoublyLinkedList.Node) *Property {
        return @alignCast(@fieldParentPtr("_node", n));
    }

    pub fn format(self: *const Property, writer: *std.Io.Writer) !void {
        try self._name.format(writer);
        try writer.writeAll(": ");
        try self._value.format(writer);

        if (self._important) {
            try writer.writeAll(" !important");
        }
        try writer.writeByte(';');
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cssText = bridge.accessor(CSSStyleDeclaration.getCssText, CSSStyleDeclaration.setCssText, .{});
    pub const length = bridge.accessor(CSSStyleDeclaration.length, null, .{});
    pub const item = bridge.function(_item, .{});

    fn _item(self: *const CSSStyleDeclaration, index: i32) []const u8 {
        if (index < 0) {
            return "";
        }
        return self.item(@intCast(index));
    }

    pub const getPropertyValue = bridge.function(CSSStyleDeclaration.getPropertyValue, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleDeclaration.getPropertyPriority, .{});
    pub const setProperty = bridge.function(CSSStyleDeclaration.setProperty, .{});
    pub const removeProperty = bridge.function(CSSStyleDeclaration.removeProperty, .{});
    pub const cssFloat = bridge.accessor(CSSStyleDeclaration.getFloat, CSSStyleDeclaration.setFloat, .{});
};

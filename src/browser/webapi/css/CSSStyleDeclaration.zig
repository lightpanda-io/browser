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
                    try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, page);
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
        return;
    }

    // Create new property
    const prop = try page._factory.create(Property{
        ._node = .{},
        ._name = try String.init(page.arena, normalized, .{}),
        ._value = try String.init(page.arena, value, .{}),
        ._important = important,
    });
    self._properties.append(&prop._node);
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
        try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, page);
    }
    try self.syncStyleAttribute(page);
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

    return "";
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote => "inline",
                .body, .div, .dl, .p, .heading, .form, .button, .canvas, .dialog, .embed, .head, .html, .hr, .iframe, .img, .input, .li, .link, .meta, .ol, .option, .script, .select, .slot, .style, .template, .textarea, .title, .ul, .media, .area, .base, .datalist, .directory, .fieldset, .legend, .map, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .source, .table, .table_caption, .table_cell, .table_col, .table_row, .table_section, .track => "block",
                .generic, .custom, .unknown, .data => blk: {
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

pub const Property = struct {
    _name: String,
    _value: String,
    _important: bool = false,
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

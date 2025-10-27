const std = @import("std");
const log = @import("../../../log.zig");
const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");

const CSSStyleDeclaration = @This();

_element: ?*Element = null,
_properties: std.DoublyLinkedList = .{},

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

pub fn init(element: ?*Element, page: *Page) !*CSSStyleDeclaration {
    return page._factory.create(CSSStyleDeclaration{
        ._element = element,
    });
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

pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, page: *Page) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";
    return prop._value.str();
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, page: *Page) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";
    return if (prop._important) "important" else "";
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, page: *Page) !void {
    if (value.len == 0) {
        _ = try self.removeProperty(property_name, page);
        return;
    }

    const normalized = normalizePropertyName(property_name, &page.buf);
    const priority = priority_ orelse "";

    // Validate priority
    const important = if (priority.len > 0) blk: {
        if (!std.mem.eql(u8, priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

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
    const normalized = normalizePropertyName(property_name, &page.buf);
    const prop = self.findProperty(normalized) orelse return "";

    // the value might not be on the heap (it could be inlined in the small string
    // optimization), so we need to dupe it.
    const old_value = try page.call_arena.dupe(u8, prop._value.str());
    self._properties.remove(&prop._node);
    page._factory.destroy(prop);
    return old_value;
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
    // This is a simple parser - a full implementation would use a proper CSS parser
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |declaration| {
        const trimmed = std.mem.trim(u8, declaration, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            const name = std.mem.trim(u8, trimmed[0..colon_pos], &std.ascii.whitespace);
            const value_part = std.mem.trim(u8, trimmed[colon_pos + 1 ..], &std.ascii.whitespace);

            var value = value_part;
            var priority: ?[]const u8 = null;

            // Check for !important
            if (std.mem.lastIndexOfScalar(u8, value_part, '!')) |bang_pos| {
                const after_bang = std.mem.trim(u8, value_part[bang_pos + 1 ..], &std.ascii.whitespace);
                if (std.mem.eql(u8, after_bang, "important")) {
                    value = std.mem.trimRight(u8, value_part[0..bang_pos], &std.ascii.whitespace);
                    priority = "important";
                }
            }

            try self.setProperty(name, value, priority, page);
        }
    }
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
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
};

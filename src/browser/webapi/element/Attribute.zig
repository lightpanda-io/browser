const std = @import("std");
const js = @import("../../js/js.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

const Page = @import("../../Page.zig");
const String = @import("../../../string.zig").String;

pub fn registerTypes() []const type {
    return &.{
        Attribute,
        NamedNodeMap,
        NamedNodeMap.Iterator,
    };
}

pub const Attribute = @This();

_proto: *Node,
_name: []const u8,
_value: []const u8,
_element: ?*Element,

pub fn format(self: *const Attribute, writer: *std.Io.Writer) !void {
    return formatAttribute(self._name, self._value, writer);
}

pub fn className(_: *const Attribute) []const u8 {
    return "Attr";
}

pub fn getName(self: *const Attribute) []const u8 {
    return self._name;
}

pub fn getValue(self: *const Attribute) []const u8 {
    return self._value;
}

pub fn setValue(self: *Attribute, data_: ?[]const u8, page: *Page) !void {
    const data = data_ orelse "";
    const el = self._element orelse {
        self._value = try page.arena.dupe(u8, data);
        return;
    };
    // this takes ownership of the data
    try el.setAttribute(self._name, data, page);

    // not the most efficient, but we don't expect this to be called oftens
    self._value = (try el.getAttribute(self._name, page)) orelse "";
}

pub fn getNamespaceURI(_: *const Attribute) ?[]const u8 {
    return null;
}

pub fn getOwnerElement(self: *const Attribute) ?*Element {
    return self._element;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Attribute);

    pub const Meta = struct {
        pub const name = "Attr";
        // we _never_ hold a reference to this, so the JS layer doesn't need to
        // persist the value. It can pass it to QuickJS and let it fully manage it
        // (TODO: we probably _should_ hold a refernece, because calling getAttributeNode
        // on the same element + name should return the same instance)
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Attribute.getName, null, .{});
    pub const localName = bridge.accessor(Attribute.getName, null, .{});
    pub const value = bridge.accessor(Attribute.getValue, null, .{});
    pub const namespaceURI = bridge.accessor(Attribute.getNamespaceURI, null, .{});
    pub const ownerElement = bridge.accessor(Attribute.getOwnerElement, null, .{});
};

// This is what an Element references. It isn't exposed to JavaScript. In
// JavaScript, the element attribute list (el.attributes) is the NamedNodeMap
// which exposes Attributes. It isn't ideal that we have both.
// NamedNodeMap and Attribute are relatively fat and awkward to use. You can
// imagine a page will have tens of thousands of attributes, and it's very likely
// that page will _never_ load a single Attribute. It might get a string value
// from a string key, but it won't load the full Attribute. And, even if it does,
// it will almost certainly load realtively few.
// The main issue with Attribute is that it's a full Node -> EventTarget. It's
// _huge_ for something that's essentially just name=>value.
// That said, we need identity. el.getAttributeNode("id") should return the same
// Attribute value (the same JSValue) when called multiple time, and that gets
// more important when you look at the [hardly every used] el.removeAttributeNode
// and setAttributeNode.
// So, we maintain a lookup, page._attribute_lookup, to serve as an identity map
// from our internal Entry to a proper Attribute. This is lazily populated
// whenever an Attribute is created. Why not just have an ?*Attribute field
// in our Entry? Because that would require an extra 8 bytes for every single
// attribute in the DOM, and, again, we expect that to almost always be null.
pub const List = struct {
    _list: std.DoublyLinkedList = .{},

    pub fn get(self: *const List, name: []const u8, page: *Page) !?[]const u8 {
        const entry = (try self.getEntry(name, page)) orelse return null;
        return entry._value.str();
    }

    // meant for internal usage, where the name is known to be properly cased
    pub fn getSafe(self: *const List, name: []const u8) ?[]const u8 {
        const entry = self.getEntryWithNormalizedName(name) orelse return null;
        return entry._value.str();
    }

    pub fn getAttribute(self: *const List, name: []const u8, element: ?*Element, page: *Page) !?*Attribute {
        const entry = (try self.getEntry(name, page)) orelse return null;
        const gop = try page._attribute_lookup.getOrPut(page.arena, @intFromPtr(entry));
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }
        const attribute = try entry.toAttribute(element, page);
        gop.value_ptr.* = attribute;
        return attribute;
    }

    pub fn put(self: *List, name: []const u8, value: []const u8, element: *Element, page: *Page) !*Entry {
        const result = try self.getEntryAndNormalizedName(name, page);
        return self._put(result, value, element, page);
    }

    pub fn putSafe(self: *List, name: []const u8, value: []const u8, element: *Element, page: *Page) !*Entry {
        const entry = self.getEntryWithNormalizedName(name);
        return self._put(.{ .entry = entry, .normalized = name }, value, element, page);
    }

    fn _put(self: *List, result: NormalizeAndEntry, value: []const u8, element: *Element, page: *Page) !*Entry {
        const is_id = isIdForConnected(result.normalized, element);

        var entry: *Entry = undefined;
        if (result.entry) |e| {
            if (is_id) {
                _ = page.document._elements_by_id.remove(e._value.str());
            }
            e._value = try String.init(page.arena, value, .{});
            entry = e;
        } else {
            entry = try page._factory.create(Entry{
                ._node = .{},
                ._name = try String.init(page.arena, result.normalized, .{}),
                ._value = try String.init(page.arena, value, .{}),
            });
            self._list.append(&entry._node);
        }

        if (is_id) {
            try page.document._elements_by_id.put(page.arena, entry._value.str(), element);
        }
        page.attributeChange(element, result.normalized, value);
        return entry;
    }

    // Optimized for cloning. We know `name` is already normalized. We know there isn't duplicates.
    // We know the Element is detatched (and thus, don't need to check for `id`).
    pub fn putForCloned(self: *List, name: []const u8, value: []const u8, page: *Page) !void {
        const entry = try page._factory.create(Entry{
            ._node = .{},
            ._name = try String.init(page.arena, name, .{}),
            ._value = try String.init(page.arena, value, .{}),
        });
        self._list.append(&entry._node);
    }

    // not efficient, won't be called often (if ever!)
    pub fn putAttribute(self: *List, attribute: *Attribute, element: *Element, page: *Page) !?*Attribute {
        // we expect our caller to make sure this is true
        std.debug.assert(attribute._element == null);

        const existing_attribute = try self.getAttribute(attribute._name, element, page);
        if (existing_attribute) |ea| {
            try self.delete(ea._name, element, page);
        }

        const entry = try self.put(attribute._name, attribute._value, element, page);
        attribute._element = element;
        try page._attribute_lookup.put(page.arena, @intFromPtr(entry), attribute);
        return existing_attribute;
    }

    // called form our parser, names already lower-cased
    pub fn putNew(self: *List, name: []const u8, value: []const u8, page: *Page) !void {
        if (try self.getEntry(name, page) != null) {
            // When parsing, if there are dupicate names, it isn't valid, and
            // the first is kept
            return;
        }

        const entry = try page._factory.create(Entry{
            ._node = .{},
            ._name = try String.init(page.arena, name, .{}),
            ._value = try String.init(page.arena, value, .{}),
        });
        self._list.append(&entry._node);
    }

    pub fn delete(self: *List, name: []const u8, element: *Element, page: *Page) !void {
        const result = try self.getEntryAndNormalizedName(name, page);
        const entry = result.entry orelse return;

        const is_id = isIdForConnected(result.normalized, element);

        if (is_id) {
            _ = page.document._elements_by_id.remove(entry._value.str());
        }

        page.attributeRemove(element, result.normalized);
        _ = page._attribute_lookup.remove(@intFromPtr(entry));
        self._list.remove(&entry._node);
        page._factory.destroy(entry);
    }

    pub fn getNames(self: *const List, page: *Page) ![][]const u8 {
        var arr: std.ArrayList([]const u8) = .empty;
        var node = self._list.first;
        while (node) |n| {
            try arr.append(page.call_arena, Entry.fromNode(n)._name.str());
            node = n.next;
        }
        return arr.items;
    }

    pub fn iterator(self: *List) InnerIterator {
        return .{ ._node = self._list.first };
    }

    fn getEntry(self: *const List, name: []const u8, page: *Page) !?*Entry {
        const result = try self.getEntryAndNormalizedName(name, page);
        return result.entry;
    }

    // Dangerous, the returned normalized name is only valid until someone
    // else uses pages.buf.
    const NormalizeAndEntry = struct {
        normalized: []const u8,
        entry: ?*Entry,
    };
    fn getEntryAndNormalizedName(self: *const List, name: []const u8, page: *Page) !NormalizeAndEntry {
        const normalized = try normalizeNameForLookup(name, page);
        return .{
            .normalized = normalized,
            .entry = self.getEntryWithNormalizedName(normalized),
        };
    }

    fn getEntryWithNormalizedName(self: *const List, name: []const u8) ?*Entry {
        var node = self._list.first;
        while (node) |n| {
            var e = Entry.fromNode(n);
            if (e._name.eqlSlice(name)) {
                return e;
            }
            node = n.next;
        }
        return null;
    }

    pub const Entry = struct {
        _name: String,
        _value: String,
        _node: std.DoublyLinkedList.Node,

        fn fromNode(n: *std.DoublyLinkedList.Node) *Entry {
            return @alignCast(@fieldParentPtr("_node", n));
        }

        pub fn format(self: *const Entry, writer: *std.Io.Writer) !void {
            return formatAttribute(self._name.str(), self._value.str(), writer);
        }

        pub fn toAttribute(self: *const Entry, element: ?*Element, page: *Page) !*Attribute {
            return page._factory.node(Attribute{
                ._proto = undefined,
                ._element = element,
                // Cannot directly reference self._name.str() and self._value.str()
                // This attribute can outlive the list entry (the node can be
                // removed from the element's attribute, but still exist in the DOM)
                ._name = try page.dupeString(self._name.str()),
                ._value = try page.dupeString(self._value.str()),
            });
        }
    };
};

fn isIdForConnected(normalized_id: []const u8, element: *const Element) bool {
    return std.mem.eql(u8, normalized_id, "id") and element.asConstNode().isConnected();
}

pub fn normalizeNameForLookup(name: []const u8, page: *Page) ![]const u8 {
    if (!needsLowerCasing(name)) {
        return name;
    }
    if (name.len < page.buf.len) {
        return std.ascii.lowerString(&page.buf, name);
    }
    return std.ascii.allocLowerString(page.call_arena, name);
}

fn needsLowerCasing(name: []const u8) bool {
    var remaining = name;
    if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
        while (remaining.len > vector_len) {
            const chunk: @Vector(vector_len, u8) = remaining[0..vector_len].*;
            if (@reduce(.Min, chunk) <= 'Z') {
                return true;
            }
            remaining = remaining[vector_len..];
        }
    }

    for (remaining) |b| {
        if (std.ascii.isUpper(b)) {
            return true;
        }
    }
    return false;
}

pub const NamedNodeMap = struct {
    _list: *List,

    // Whenever the NamedNodeMap creates an Attribute, it needs to provide the
    // "ownerElement".
    _element: ?*Element = null,

    pub fn length(self: *const NamedNodeMap) u32 {
        return @intCast(self._list._list.len());
    }

    pub fn getAtIndex(self: *const NamedNodeMap, index: usize, page: *Page) !?*Attribute {
        var i: usize = 0;
        var node = self._list._list.first;
        while (node) |n| {
            if (i == index) {
                var entry = List.Entry.fromNode(n);
                const gop = try page._attribute_lookup.getOrPut(page.arena, @intFromPtr(entry));
                if (gop.found_existing) {
                    return gop.value_ptr.*;
                }
                const attribute = try entry.toAttribute(self._element, page);
                gop.value_ptr.* = attribute;
                return attribute;
            }
            node = n.next;
            i += 1;
        }
        return null;
    }

    pub fn getByName(self: *const NamedNodeMap, name: []const u8, page: *Page) !?*Attribute {
        return self._list.getAttribute(name, self._element, page);
    }

    pub fn iterator(self: *const NamedNodeMap, page: *Page) !*Iterator {
        return .init(.{ .list = self }, page);
    }

    pub const Iterator = GenericIterator(struct {
        index: usize = 0,
        list: *const NamedNodeMap,

        pub fn next(self: *@This(), page: *Page) !?*Attribute {
            const index = self.index;
            self.index = index + 1;
            return self.list.getAtIndex(index, page);
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NamedNodeMap);

        pub const Meta = struct {
            pub const name = "NamedNodeMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(NamedNodeMap.length, null, .{});
        pub const @"[int]" = bridge.indexed(NamedNodeMap.getAtIndex, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(NamedNodeMap.getByName, .{ .null_as_undefined = true });
        pub const getNamedItem = bridge.function(NamedNodeMap.getByName, .{});
        pub const item = bridge.function(_item, .{});
        fn _item(self: *const NamedNodeMap, index: i32, page: *Page) !?*Attribute {
            // the bridge.indexed handles this, so if we want
            //   list.item(-2) to return the same as list[-2] we need to
            // 1 - take an i32 for the index
            // 2 - return null if it's < 0
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index), page);
        }
        pub const symbol_iterator = bridge.iterator(NamedNodeMap.iterator, .{});
    };
};

// Not meant to be exposed. The "public" iterator is a NamedNodeMap, and it's a
// bit awkward. Having this for more straightforward key=>value is useful for
// the few internal places we need to iterate through the attributes (e.g. dump)
pub const InnerIterator = struct {
    _node: ?*std.DoublyLinkedList.Node = null,

    pub fn next(self: *InnerIterator) ?*List.Entry {
        const node = self._node orelse return null;
        self._node = node.next;
        return List.Entry.fromNode(node);
    }
};

fn formatAttribute(name: []const u8, value: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll(name);

    // Boolean attributes with empty values are serialized without a value
    if (value.len == 0 and boolean_attributes_lookup.has(name)) {
        return;
    }

    try writer.writeByte('=');
    if (value.len == 0) {
        return writer.writeAll("\"\"");
    }

    try writer.writeByte('"');
    const offset = std.mem.indexOfAny(u8, value, "`' &\"<>=") orelse {
        try writer.writeAll(value);
        return writer.writeByte('"');
    };

    try writeEscapedAttributeValue(value, offset, writer);
    return writer.writeByte('"');
}

const boolean_attributes = [_][]const u8{
    "checked",
    "disabled",
    "required",
    "readonly",
    "multiple",
    "selected",
    "autofocus",
    "autoplay",
    "controls",
    "loop",
    "muted",
    "hidden",
    "async",
    "defer",
    "novalidate",
    "formnovalidate",
    "ismap",
    "reversed",
    "default",
    "open",
};

const boolean_attributes_lookup = std.StaticStringMap(void).initComptime(blk: {
    var entries: [boolean_attributes.len]struct { []const u8, void } = undefined;
    for (boolean_attributes, 0..) |attr, i| {
        entries[i] = .{ attr, {} };
    }
    break :blk entries;
});

fn writeEscapedAttributeValue(value: []const u8, first_offset: usize, writer: *std.Io.Writer) !void {
    // Write everything before the first special character
    try writer.writeAll(value[0..first_offset]);
    try writer.writeAll(switch (value[first_offset]) {
        '&' => "&amp;",
        '"' => "&quot;",
        '<' => "&lt;",
        '>' => "&gt;",
        '=' => "=",
        ' ' => " ",
        '`' => "`",
        '\'' => "'",
        else => unreachable,
    });

    var remaining = value[first_offset + 1 ..];
    while (std.mem.indexOfAny(u8, remaining, "&\"<>")) |offset| {
        try writer.writeAll(remaining[0..offset]);
        try writer.writeAll(switch (remaining[offset]) {
            '&' => "&amp;",
            '"' => "&quot;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => unreachable,
        });
        remaining = remaining[offset + 1 ..];
    }

    if (remaining.len > 0) {
        try writer.writeAll(remaining);
    }
}

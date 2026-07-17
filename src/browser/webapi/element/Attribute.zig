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

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

const String = lp.String;
const Allocator = std.mem.Allocator;

const IS_DEBUG = @import("builtin").mode == .Debug;

pub fn registerTypes() []const type {
    return &.{
        Attribute,
        NamedNodeMap,
        NamedNodeMap.Iterator,
    };
}

pub const Attribute = @This();

_proto: *Node,
_name: String,
_value: String,
_element: ?*Element,

pub fn format(self: *const Attribute, writer: *std.Io.Writer) !void {
    return formatAttribute(self._name.str(), self._value.str(), writer);
}

pub fn getName(self: *const Attribute) String {
    return self._name;
}

pub fn getValue(self: *const Attribute) String {
    return self._value;
}

pub fn setValue(self: *Attribute, data_: ?String, frame: *Frame) !void {
    const data = data_ orelse String.empty;
    const el = self._element orelse {
        self._value = try data.dupe(frame.arena);
        return;
    };
    // this takes ownership of the data
    try el.setAttribute(self._name, data, frame);

    // not the most efficient, but we don't expect this to be called often
    self._value = (try el.getAttribute(self._name, frame)) orelse String.empty;
}

pub fn getNamespaceURI(_: *const Attribute) ?[]const u8 {
    return null;
}

pub fn getOwnerElement(self: *const Attribute) ?*Element {
    return self._element;
}

pub fn isEqualNode(self: *const Attribute, other: *const Attribute) bool {
    return self.getName().eql(other.getName()) and self.getValue().eql(other.getValue());
}

pub fn clone(self: *const Attribute, frame: *Frame) !*Attribute {
    return frame._factory.node(Attribute{
        ._proto = undefined,
        ._element = self._element,
        ._name = self._name,
        ._value = self._value,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Attribute);

    pub const Meta = struct {
        pub const name = "Attr";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Attribute.getName, null, .{});
    pub const localName = bridge.accessor(Attribute.getName, null, .{});
    pub const value = bridge.accessor(Attribute.getValue, Attribute.setValue, .{ .ce_reactions = true });
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
// it will almost certainly load relatively few.
// The main issue with Attribute is that it's a full Node -> EventTarget. It's
// _huge_ for something that's essentially just name=>value.
// That said, we need identity. el.getAttributeNode("id") should return the same
// Attribute value (the same JSValue) when called multiple time, and that gets
// more important when you look at the [hardly every used] el.removeAttributeNode
// and setAttributeNode.
// So, we maintain a lookup, frame._attribute_lookup, to serve as an identity map
// from our internal Entry to a proper Attribute. This is lazily populated
// whenever an Attribute is created. Why not just have an ?*Attribute field
// in our Entry? Because that would require an extra 8 bytes for every single
// attribute in the DOM, and, again, we expect that to almost always be null.
pub const List = struct {
    normalize: bool = true,
    _len: u16 = 0,
    _cap: u16 = 0,
    _entries: [*]Entry = @constCast(&empty_entries),

    const empty_entries: [0]Entry = .{};

    pub const Lookup = std.AutoHashMapUnmanaged(LookupKey, *Attribute);

    // for Frame._attribute_lookup which is our identity map for attributes
    pub const LookupKey = struct {
        list: *const List,
        // canonical (see canonicalizeName), so identity is the address
        name: [*]const u8,
    };

    pub fn entries(self: *const List) []const Entry {
        return self._entries[0..self._len];
    }

    pub fn isEmpty(self: *const List) bool {
        return self._len == 0;
    }

    pub fn length(self: *const List) usize {
        return self._len;
    }

    pub fn get(self: *const List, name: String, frame: *Frame) !?String {
        const entry = (try self.getEntry(name, frame)) orelse return null;
        return .wrap(entry.value());
    }

    pub fn eql(self: *const List, other: *const List) bool {
        if (self._len != other._len) {
            return false;
        }

        search: for (self.entries()) |*attr| {
            for (other.entries()) |*other_attr| {
                if (attr.eql(other_attr)) {
                    continue :search; // Found match.
                }
            }
            // Iterated over all `other` and no match.
            return false;
        }
        return true;
    }

    // meant for internal usage, where the name is known to be properly cased
    pub fn getSafe(self: *const List, name: String) ?[]const u8 {
        const entry = self.getEntryWithNormalizedName(name) orelse return null;
        return entry.value();
    }

    // meant for internal usage, where the name is known to be properly cased
    pub fn hasSafe(self: *const List, name: String) bool {
        return self.getEntryWithNormalizedName(name) != null;
    }

    pub fn getAttribute(self: *const List, name: String, element: ?*Element, frame: *Frame) !?*Attribute {
        const entry = (try self.getEntry(name, frame)) orelse return null;
        return self.getOrCreateAttribute(entry, element, frame);
    }

    // Identity map access: a given (list, name) always yields the same
    // *Attribute until the attribute is removed. The map must be the
    // element's frame's, not the caller's frame.
    pub fn getOrCreateAttribute(self: *const List, entry: *const Entry, element: ?*Element, frame: *Frame) !*Attribute {
        const owner = if (element) |el| el.ownerFrame(frame) else frame;
        const gop = try owner._attribute_lookup.getOrPut(owner.arena, .{ .list = self, .name = entry._name_ptr });
        if (!gop.found_existing) {
            gop.value_ptr.* = try entry.toAttribute(element, owner);
        }
        return gop.value_ptr.*;
    }

    pub fn put(self: *List, name: String, value: String, element: *Element, frame: *Frame) !*Entry {
        const result = try self.getEntryAndNormalizedName(name, frame);
        return self._put(result, value, element, frame);
    }

    pub fn putSafe(self: *List, name: String, value: String, element: *Element, frame: *Frame) !*Entry {
        const entry = self.getEntryWithNormalizedName(name);
        return self._put(.{ .entry = entry, .normalized = name }, value, element, frame);
    }

    // The returned *Entry is only valid until the next mutation of the list.
    fn _put(self: *List, result: NormalizeAndEntry, value: String, element: *Element, frame: *Frame) !*Entry {
        const owner = element.ownerFrame(frame);
        const is_id = shouldAddToIdMap(result.normalized, element);

        var entry: *Entry = undefined;
        var old_value: ?String = null;
        if (result.entry) |e| {
            // the old bytes are arena-owned or static; they outlive this update
            old_value = String.wrap(e.value());
            if (is_id) {
                owner.removeElementId(element, e.value());
            }
            e.setValue(try owner.dupeString(value.str()));
            entry = e;
        } else {
            try self.ensureUnusedCapacity(1, owner);
            entry = &self._entries[self._len];
            entry.* = .init(
                try canonicalizeName(result.normalized.str(), owner),
                try owner.dupeString(value.str()),
            );
            self._len += 1;
        }

        if (is_id) {
            const parent = element.asNode()._parent orelse {
                return entry;
            };
            try owner.addElementId(parent, element, entry.value());
        }
        owner.domChanged();
        owner.attributeChange(element, result.normalized, .wrap(entry.value()), old_value);
        return entry;
    }

    // Optimized for cloning. We know the names are already normalized and
    // unique. We know the Element is detached (and thus, don't need to check
    // for `id`).
    pub fn cloneFrom(self: *List, other: *const List, frame: *Frame) !void {
        try self.ensureTotalCapacity(other._len, frame);
        for (other.entries()) |*e| {
            const len = self._len;
            // re-canonicalize: `other` can belong to a different frame
            self._entries[len] = .init(
                try canonicalizeName(e.name(), frame),
                try frame.dupeString(e.value()),
            );
            self._len = len + 1;
        }
    }

    // not efficient, won't be called often (if ever!)
    pub fn putAttribute(self: *List, attribute: *Attribute, element: *Element, frame: *Frame) !?*Attribute {
        // we expect our caller to make sure this is true
        if (comptime IS_DEBUG) {
            std.debug.assert(attribute._element == null);
        }

        const existing_attribute = try self.getAttribute(attribute._name, element, frame);
        if (existing_attribute) |ea| {
            // Per DOM "replace an attribute": one handle-attribute-changes call
            // with (old, new), not a remove-then-add that would fire two
            // attributeChanged reactions. Detach the old wrapper; put() updates
            // the entry in place and fires the single reaction.
            ea._element = null;
        }

        const entry = try self.put(attribute._name, attribute._value, element, frame);
        attribute._element = element;
        const owner = element.ownerFrame(frame);
        try owner._attribute_lookup.put(owner.arena, .{ .list = self, .name = entry._name_ptr }, attribute);
        return existing_attribute;
    }

    // called form our parser, names already lower-cased
    pub fn putNew(self: *List, name: []const u8, value: []const u8, frame: *Frame) !void {
        if (try self.getEntry(.wrap(name), frame) != null) {
            // When parsing, if there are duplicate names, it isn't valid, and
            // the first is kept
            return;
        }
        const len = self._len;
        if (len == std.math.maxInt(u16) or name.len > std.math.maxInt(u32) or value.len > std.math.maxInt(u32)) {
            // Bad input. Drop rather than fail the parse
            return;
        }

        try self.ensureUnusedCapacity(1, frame);
        self._entries[len] = .init(
            try canonicalizeName(name, frame),
            try frame.dupeString(value),
        );
        self._len = len + 1;
    }

    pub fn delete(self: *List, name: String, element: *Element, frame: *Frame) !void {
        const result = try self.getEntryAndNormalizedName(name, frame);
        const entry = result.entry orelse return;

        const owner = element.ownerFrame(frame);
        const is_id = shouldAddToIdMap(result.normalized, element);
        const old_value = entry.value();

        if (is_id) {
            owner.removeElementId(element, old_value);
        }

        // remove this BEFORE triggering anything, incase that re-enters delete
        // or some other callback.
        _ = owner._attribute_lookup.remove(.{ .list = self, .name = entry._name_ptr });
        const index = (@intFromPtr(entry) - @intFromPtr(self._entries)) / @sizeOf(Entry);
        const list_entries = self._entries[0..self._len];
        std.mem.copyForwards(Entry, list_entries[index .. list_entries.len - 1], list_entries[index + 1 ..]);
        self._len -= 1;

        owner.domChanged();
        owner.attributeRemove(element, result.normalized, .wrap(old_value));
    }

    pub fn getNames(self: *const List, allocator: Allocator) ![][]const u8 {
        var arr: std.ArrayList([]const u8) = .empty;
        try arr.ensureTotalCapacity(allocator, self._len);
        for (self.entries()) |*e| {
            arr.appendAssumeCapacity(e.name());
        }
        return arr.items;
    }

    pub fn ensureTotalCapacity(self: *List, count: usize, frame: *Frame) !void {
        const cap: u16 = @intCast(@min(count, std.math.maxInt(u16)));
        return self.setCapacity(cap, frame);
    }

    fn ensureUnusedCapacity(self: *List, extra: u16, frame: *Frame) !void {
        const needed = @as(u32, self._len) + extra;
        if (needed <= self._cap) {
            return;
        }
        if (needed > std.math.maxInt(u16)) {
            return error.OutOfMemory;
        }
        // Lists are sized exactly at creation; dynamic additions are rare and
        // small, so grow slowly.
        return self.setCapacity(@intCast(@max(needed, @as(u32, self._cap) + 2)), frame);
    }

    fn setCapacity(self: *List, new_cap: u16, frame: *Frame) !void {
        if (new_cap <= self._cap) {
            return;
        }
        if (self._cap == 0) {
            self._entries = (try frame.arena.alloc(Entry, new_cap)).ptr;
        } else {
            self._entries = (try frame.arena.realloc(self._entries[0..self._cap], new_cap)).ptr;
        }
        self._cap = new_cap;
    }

    fn getEntry(self: *const List, name: String, frame: *Frame) !?*Entry {
        const result = try self.getEntryAndNormalizedName(name, frame);
        return result.entry;
    }

    // Dangerous, the returned normalized name is only valid until someone
    // else uses pages.buf.
    const NormalizeAndEntry = struct {
        entry: ?*Entry,
        normalized: String,
    };
    fn getEntryAndNormalizedName(self: *const List, name: String, frame: *Frame) !NormalizeAndEntry {
        const normalized =
            if (self.normalize) try normalizeNameForLookup(name, frame) else name;

        return .{
            .normalized = normalized,
            .entry = self.getEntryWithNormalizedName(normalized),
        };
    }

    fn getEntryWithNormalizedName(self: *const List, name: String) ?*Entry {
        const name_str = name.str();
        for (self._entries[0..self._len]) |*e| {
            if (std.mem.eql(u8, e.name(), name_str)) {
                return e;
            }
        }
        return null;
    }

    // Two []const u8 would be 32 bytes. Packed like this, it's 24.
    pub const Entry = struct {
        _name_ptr: [*]const u8,
        _value_ptr: [*]const u8,
        _name_len: u32,
        _value_len: u32,

        fn init(canonical_name: []const u8, value_: []const u8) Entry {
            return .{
                ._name_ptr = canonical_name.ptr,
                ._value_ptr = value_.ptr,
                ._name_len = @intCast(canonical_name.len),
                ._value_len = @intCast(value_.len),
            };
        }

        pub fn name(self: *const Entry) []const u8 {
            return self._name_ptr[0..self._name_len];
        }

        pub fn value(self: *const Entry) []const u8 {
            return self._value_ptr[0..self._value_len];
        }

        fn setValue(self: *Entry, value_: []const u8) void {
            self._value_ptr = value_.ptr;
            self._value_len = @intCast(value_.len);
        }

        /// Returns true if 2 entries are equal. Names can't be compared by
        /// pointer alone: the entries can belong to different frames.
        pub fn eql(self: *const Entry, other: *const Entry) bool {
            if (self._name_ptr != other._name_ptr and !std.mem.eql(u8, self.name(), other.name())) {
                return false;
            }
            return std.mem.eql(u8, self.value(), other.value());
        }

        pub fn format(self: *const Entry, writer: *std.Io.Writer) !void {
            return formatAttribute(self.name(), self.value(), writer);
        }

        pub fn toAttribute(self: *const Entry, element: ?*Element, frame: *Frame) !*Attribute {
            return frame._factory.node(Attribute{
                ._proto = undefined,
                ._element = element,
                // The entry's bytes outlive the entry itself, so the
                // Attribute can wrap them without duping.
                ._name = .wrap(self.name()),
                ._value = .wrap(self.value()),
            });
        }
    };
};

fn shouldAddToIdMap(normalized_name: String, element: *Element) bool {
    if (!normalized_name.eql(comptime .wrap("id"))) {
        return false;
    }

    const node = element.asNode();
    // Shadow tree elements are always added to their shadow root's map
    if (node.isInShadowTree()) {
        return true;
    }
    // Document tree elements only when connected
    return node.isConnected();
}

pub fn validateAttributeName(name: String) !void {
    const name_str = name.str();

    if (name_str.len == 0) {
        return error.InvalidCharacterError;
    }

    const first = name_str[0];
    if ((first >= '0' and first <= '9') or first == '-' or first == '.') {
        return error.InvalidCharacterError;
    }

    for (name_str) |c| {
        if (c == 0 or c == '/' or c == '=' or c == '>' or std.ascii.isWhitespace(c)) {
            return error.InvalidCharacterError;
        }

        const is_valid = std.ascii.isAlphanumeric(c) or
            c == '_' or c == '-' or c == '.' or c == ':';

        if (!is_valid) {
            return error.InvalidCharacterError;
        }
    }
}

// Every stored entry name either comes from the static String.intern or from
// the frame._attribute_names. Beyond avoiding extra dupes/allocations, this
// gives a stable pointer for the frame's lifetime, which List.LookupKey
// relies on for identity. The pointer is NOT comparable across frames (each
// frame has its own pool), which is why lookups byte-compare.
fn canonicalizeName(name: []const u8, frame: *Frame) ![]const u8 {
    if (String.intern(name)) |static| {
        return static;
    }
    const gop = try frame._attribute_names.getOrPut(frame.arena, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try frame.arena.dupe(u8, name);
    }
    return gop.key_ptr.*;
}

fn normalizeNameForLookup(name: String, frame: *Frame) !String {
    if (!needsLowerCasing(name.str())) {
        return name;
    }
    const normalized = if (name.len < frame.buf.len)
        std.ascii.lowerString(&frame.buf, name.str())
    else
        try std.ascii.allocLowerString(frame.local_arena, name.str());

    return .wrap(normalized);
}

pub fn needsLowerCasing(name: []const u8) bool {
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

pub fn normalizeNameForLookupAlloc(allocator: Allocator, name: String) !String {
    const normalized = try std.ascii.allocLowerString(allocator, name.str());
    return .wrap(normalized);
}

pub const NamedNodeMap = struct {
    // Whenever the NamedNodeMap creates an Attribute, it needs to provide the
    // "ownerElement". The attribute list is the element's.
    _element: *Element,

    fn list(self: *const NamedNodeMap) *List {
        return &self._element._attributes;
    }

    pub fn length(self: *const NamedNodeMap) u32 {
        return self.list()._len;
    }

    pub fn getAtIndex(self: *const NamedNodeMap, index: usize, frame: *Frame) !?*Attribute {
        const l = self.list();
        if (index >= l._len) {
            return null;
        }
        return l.getOrCreateAttribute(&l._entries[index], self._element, frame);
    }

    pub fn getByName(self: *const NamedNodeMap, name: String, frame: *Frame) !?*Attribute {
        return self.list().getAttribute(name, self._element, frame);
    }

    pub fn set(self: *const NamedNodeMap, attribute: *Attribute, frame: *Frame) !?*Attribute {
        attribute._element = null; // just a requirement of list.putAttribute, it'll re-set it.
        return self.list().putAttribute(attribute, self._element, frame);
    }

    pub fn removeByName(self: *const NamedNodeMap, name: String, frame: *Frame) !?*Attribute {
        // this 2-step process (get then delete) isn't efficient. But we don't
        // expect this to be called often, and this lets us keep delete straightforward.
        const attr = (try self.getByName(name, frame)) orelse return null;
        try self.list().delete(name, self._element, frame);
        return attr;
    }

    pub fn iterator(self: *const NamedNodeMap, frame: *Frame) !*Iterator {
        return .init(.{ .list = self }, frame);
    }

    pub const Iterator = GenericIterator(struct {
        index: usize = 0,
        list: *const NamedNodeMap,

        pub fn next(self: *@This(), frame: *Frame) !?*Attribute {
            const index = self.index;
            self.index = index + 1;
            return self.list.getAtIndex(index, frame);
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
        pub const @"[int]" = bridge.indexed(NamedNodeMap.getAtIndex, getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(NamedNodeMap.getByName, null, null, getNames, null, .{ .null_as_undefined = true });

        fn getIndexes(self: *const NamedNodeMap, frame: *Frame) !js.Array {
            const len = self.length();
            var arr = frame.js.local.?.newArray(len);
            for (0..len) |i| {
                _ = try arr.set(@intCast(i), i, .{});
            }
            return arr;
        }

        fn getNames(self: *const NamedNodeMap, frame: *Frame) !js.Array {
            const names = try self.list().getNames(frame.local_arena);
            var arr = frame.js.local.?.newArray(@intCast(names.len));
            for (names, 0..) |name, i| {
                _ = try arr.set(@intCast(i), name, .{});
            }
            return arr;
        }
        pub const getNamedItem = bridge.function(NamedNodeMap.getByName, .{});
        pub const setNamedItem = bridge.function(NamedNodeMap.set, .{ .ce_reactions = true });
        pub const removeNamedItem = bridge.function(NamedNodeMap.removeByName, .{ .ce_reactions = true });
        pub const item = bridge.function(_item, .{});
        fn _item(self: *const NamedNodeMap, index: i32, frame: *Frame) !?*Attribute {
            // the bridge.indexed handles this, so if we want
            //   list.item(-2) to return the same as list[-2] we need to
            // 1 - take an i32 for the index
            // 2 - return null if it's < 0
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index), frame);
        }
        pub const symbol_iterator = bridge.iterator(NamedNodeMap.iterator, .{});
    };
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

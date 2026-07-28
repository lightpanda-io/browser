// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const StringList = @This();

const Delimiter = enum { whitespace, comma };

_element: *Element,
_attribute_name: lp.String,
_delimiter: Delimiter,
_synced: bool = false,
// An absent attribute is an empty list, but an empty attribute is not: a
// comma-separated value parses "" as a single empty token.
_present: bool = false,
_snapshot: std.ArrayList(u8) = .empty,
_items: std.ArrayList([]const u8) = .empty,

pub const Kind = enum {
    required_extensions,
    system_language,

    fn attributeName(self: Kind) lp.String {
        return switch (self) {
            .required_extensions => .wrap("requiredExtensions"),
            .system_language => .wrap("systemLanguage"),
        };
    }

    fn delimiter(self: Kind) Delimiter {
        return switch (self) {
            .required_extensions => .whitespace,
            .system_language => .comma,
        };
    }
};

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *StringList);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*StringList {
    const key: Key = .{
        .element = element,
        .kind = kind,
    };
    const gop = try frame._svg_string_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_string_lists.remove(key);
        gop.value_ptr.* = try frame._factory.create(StringList{
            ._element = element,
            ._attribute_name = kind.attributeName(),
            ._delimiter = kind.delimiter(),
        });
    }
    return gop.value_ptr.*;
}

pub fn getLength(self: *StringList, frame: *Frame) !u32 {
    try self.sync(frame);
    return @intCast(self._items.items.len);
}

pub fn getNumberOfItems(self: *StringList, frame: *Frame) !u32 {
    return self.getLength(frame);
}

pub fn clear(self: *StringList, frame: *Frame) !void {
    try self.commit(&.{}, frame);
}

pub fn initialize(self: *StringList, item: []const u8, frame: *Frame) ![]const u8 {
    try self.commit(&.{item}, frame);
    return item;
}

pub fn getItem(self: *StringList, index: u32, frame: *Frame) ![]const u8 {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    return self._items.items[index];
}

pub fn insertItemBefore(self: *StringList, item: []const u8, index: u32, frame: *Frame) ![]const u8 {
    try self.sync(frame);
    const at = @min(@as(usize, index), self._items.items.len);
    const next = try frame.local_arena.alloc([]const u8, self._items.items.len + 1);
    @memcpy(next[0..at], self._items.items[0..at]);
    next[at] = item;
    @memcpy(next[at + 1 ..], self._items.items[at..]);
    try self.commit(next, frame);
    return item;
}

pub fn replaceItem(self: *StringList, item: []const u8, index: u32, frame: *Frame) ![]const u8 {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    const next = try frame.local_arena.dupe([]const u8, self._items.items);
    next[index] = item;
    try self.commit(next, frame);
    return item;
}

pub fn removeItem(self: *StringList, index: u32, frame: *Frame) ![]const u8 {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    const removed = try frame.local_arena.dupe(u8, self._items.items[index]);
    const next = try frame.local_arena.alloc([]const u8, self._items.items.len - 1);
    @memcpy(next[0..index], self._items.items[0..index]);
    @memcpy(next[index..], self._items.items[index + 1 ..]);
    try self.commit(next, frame);
    return removed;
}

pub fn appendItem(self: *StringList, item: []const u8, frame: *Frame) ![]const u8 {
    return self.insertItemBefore(item, std.math.maxInt(u32), frame);
}

fn sync(self: *StringList, frame: *Frame) !void {
    const raw = self._element.getAttributeSafe(self._attribute_name);
    if (self._synced and self._present == (raw != null) and
        std.mem.eql(u8, self._snapshot.items, raw orelse ""))
    {
        return;
    }
    return self.rebuild(raw, frame);
}

// The list is authoritative: an item keeps its identity even when it contains
// the delimiter, so we record where each one landed rather than reparsing our
// own serialization.
fn commit(self: *StringList, items: []const []const u8, frame: *Frame) !void {
    if (items.len == 0) {
        self._synced = false;
        self._element.removeAttributeSafe(self._attribute_name, frame);
        self._present = false;
        self._snapshot.clearRetainingCapacity();
        self._items.clearRetainingCapacity();
        self._synced = true;
        return;
    }

    const separator: []const u8 = if (self._delimiter == .comma) "," else " ";
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    const bounds = try frame.local_arena.alloc([2]usize, items.len);
    for (items, bounds, 0..) |item, *bound, i| {
        if (i != 0) try writer.writeAll(separator);
        const start = serialized.written().len;
        try writer.writeAll(item);
        bound.* = .{ start, serialized.written().len };
    }
    const bytes = serialized.written();

    self._synced = false;
    try self._element.setAttributeSafe(self._attribute_name, .wrap(bytes), frame);
    self._present = true;
    self._snapshot.clearRetainingCapacity();
    try self._snapshot.appendSlice(frame.arena, bytes);
    self._items.clearRetainingCapacity();
    for (bounds) |bound| {
        try self._items.append(frame.arena, self._snapshot.items[bound[0]..bound[1]]);
    }
    self._synced = true;
}

fn rebuild(self: *StringList, raw: ?[]const u8, frame: *Frame) !void {
    self._synced = false;
    self._present = raw != null;
    self._snapshot.clearRetainingCapacity();
    self._items.clearRetainingCapacity();

    if (raw) |value| {
        try self._snapshot.appendSlice(frame.arena, value);
        switch (self._delimiter) {
            .whitespace => {
                var iterator = std.mem.tokenizeAny(u8, self._snapshot.items, WHITESPACE);
                while (iterator.next()) |item| try self._items.append(frame.arena, item);
            },
            // A set of comma-separated tokens: every segment is a token, even
            // an empty one, and each is trimmed of surrounding whitespace.
            .comma => {
                var iterator = std.mem.splitScalar(u8, self._snapshot.items, ',');
                while (iterator.next()) |part| {
                    try self._items.append(frame.arena, std.mem.trim(u8, part, WHITESPACE));
                }
            },
        }
    }
    self._synced = true;
}

const WHITESPACE = " \t\r\n\x0c";

pub const JsApi = struct {
    pub const bridge = js.Bridge(StringList);

    pub const Meta = struct {
        pub const name = "SVGStringList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(StringList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(StringList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(StringList.clear, .{});
    pub const initialize = bridge.function(StringList.initialize, .{});
    pub const getItem = bridge.function(StringList.getItem, .{});
    pub const insertItemBefore = bridge.function(StringList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(StringList.replaceItem, .{});
    pub const removeItem = bridge.function(StringList.removeItem, .{});
    pub const appendItem = bridge.function(StringList.appendItem, .{});
};

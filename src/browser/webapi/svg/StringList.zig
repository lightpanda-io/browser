// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");

const StringList = @This();

pub const Delimiter = enum { whitespace, comma };

_element: *Element,
_attribute_name: lp.String,
_delimiter: Delimiter,
_items: std.ArrayList([]const u8) = .empty,
_snapshot: ?[]const u8 = null,

pub fn create(element: *Element, attribute_name: lp.String, delimiter: Delimiter, frame: *Frame) !*StringList {
    return frame._factory.create(StringList{
        ._element = element,
        ._attribute_name = attribute_name,
        ._delimiter = delimiter,
    });
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
    try self.validateItem(item);
    try self.commit(&.{item}, frame);
    return self._items.items[0];
}

pub fn getItem(self: *StringList, index: u32, frame: *Frame) ![]const u8 {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    return self._items.items[index];
}

pub fn insertItemBefore(self: *StringList, item: []const u8, index: u32, frame: *Frame) ![]const u8 {
    try self.validateItem(item);
    try self.sync(frame);
    const at = @min(@as(usize, index), self._items.items.len);
    const next = try frame.local_arena.alloc([]const u8, self._items.items.len + 1);
    @memcpy(next[0..at], self._items.items[0..at]);
    next[at] = item;
    @memcpy(next[at + 1 ..], self._items.items[at..]);
    try self.commit(next, frame);
    return self._items.items[at];
}

pub fn replaceItem(self: *StringList, item: []const u8, index: u32, frame: *Frame) ![]const u8 {
    try self.validateItem(item);
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    const next = try frame.local_arena.dupe([]const u8, self._items.items);
    next[index] = item;
    try self.commit(next, frame);
    return self._items.items[index];
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

fn validateItem(self: *const StringList, item: []const u8) !void {
    if (item.len == 0) return error.SyntaxError;
    for (item) |byte| {
        if (std.ascii.isWhitespace(byte) or (self._delimiter == .comma and byte == ',')) {
            return error.SyntaxError;
        }
    }
}

fn sync(self: *StringList, frame: *Frame) !void {
    const raw = self._element.getAttributeSafe(self._attribute_name) orelse "";
    if (self._snapshot) |snapshot| if (std.mem.eql(u8, snapshot, raw)) return;

    const snapshot = try frame.arena.dupe(u8, raw);
    var parsed = parse(snapshot, self._delimiter, frame.local_arena) catch |err| switch (err) {
        error.SyntaxError => std.ArrayList([]const u8).empty,
        else => return err,
    };
    try self._items.ensureTotalCapacity(frame.arena, parsed.items.len);
    self._items.clearRetainingCapacity();
    for (parsed.items) |item| self._items.appendAssumeCapacity(item);
    parsed.clearRetainingCapacity();
    self._snapshot = snapshot;
}

fn commit(self: *StringList, items: []const []const u8, frame: *Frame) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (items, 0..) |item, i| {
        try self.validateItem(item);
        if (i != 0) try writer.writeAll(if (self._delimiter == .comma) ", " else " ");
        try writer.writeAll(item);
    }

    const serialized_bytes = serialized.written();
    const snapshot = try frame.arena.dupe(u8, serialized_bytes);
    var parsed = try parse(snapshot, self._delimiter, frame.local_arena);
    try self._items.ensureTotalCapacity(frame.arena, parsed.items.len);
    try self._element.setAttributeSafe(self._attribute_name, .wrap(serialized_bytes), frame);
    self._items.clearRetainingCapacity();
    for (parsed.items) |item| self._items.appendAssumeCapacity(item);
    parsed.clearRetainingCapacity();
    self._snapshot = snapshot;
}

fn parse(raw: []const u8, delimiter: Delimiter, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var items: std.ArrayList([]const u8) = .empty;
    switch (delimiter) {
        .whitespace => {
            var iterator = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
            while (iterator.next()) |item| try items.append(allocator, item);
        },
        .comma => {
            if (std.mem.trim(u8, raw, " \t\r\n\x0c").len == 0) return items;
            var iterator = std.mem.splitScalar(u8, raw, ',');
            while (iterator.next()) |part| {
                const item = std.mem.trim(u8, part, " \t\r\n\x0c");
                if (item.len == 0) return error.SyntaxError;
                for (item) |byte| if (std.ascii.isWhitespace(byte)) return error.SyntaxError;
                try items.append(allocator, item);
            }
        },
    }
    return items;
}

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

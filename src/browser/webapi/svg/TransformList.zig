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
const Page = @import("../../Page.zig");
const DOMMatrixReadOnly = @import("../DOMMatrixReadOnly.zig");
const Element = @import("../Element.zig");
const Transform = @import("Transform.zig");

const TransformList = @This();

_element: *Element,
_attr_name: lp.String,
_read_only: bool,
_items: std.ArrayList(*Transform) = .empty,
_retired: std.ArrayList(*Transform) = .empty,
_snapshot: ?[]const u8 = null,

pub fn create(element: *Element, read_only: bool, frame: *Frame) !*TransformList {
    return createForAttribute(element, comptime .wrap("transform"), read_only, frame);
}

pub fn createForAttribute(element: *Element, attr_name: lp.String, read_only: bool, frame: *Frame) !*TransformList {
    const self = try frame._factory.create(TransformList{
        ._element = element,
        ._attr_name = attr_name,
        ._read_only = read_only,
    });
    try frame.registerSvgCollectionCleanup(.{
        .context = self,
        .callback = TransformList.cleanup,
    });
    return self;
}

fn cleanup(context: *anyopaque, page: *Page) void {
    const self: *TransformList = @ptrCast(@alignCast(context));
    for (self._items.items) |transform| {
        transform.detach(self);
        transform.releaseRef(page);
    }
    for (self._retired.items) |transform| transform.releaseRef(page);
    self._items.clearRetainingCapacity();
    self._retired.clearRetainingCapacity();
}

pub fn getLength(self: *TransformList, frame: *Frame) !u32 {
    try self.sync(frame);
    return @intCast(self._items.items.len);
}

pub fn getNumberOfItems(self: *TransformList, frame: *Frame) !u32 {
    return self.getLength(frame);
}

pub fn clear(self: *TransformList, frame: *Frame) !void {
    try self.requireMutable();
    try self.sync(frame);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    try self.setAttribute(&.{}, frame);
    self.retireAllAssumeCapacity();
}

pub fn initialize(self: *TransformList, item: *Transform, frame: *Frame) !*Transform {
    try self.requireMutable();
    try self.sync(frame);
    const prepared = try self.prepareItem(item, frame);
    errdefer prepared.releaseRef(frame._page);

    try self._items.ensureTotalCapacity(frame.arena, 1);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    try self.setAttribute(&.{prepared}, frame);
    self.retireAllAssumeCapacity();
    self._items.appendAssumeCapacity(prepared);
    self.attach(prepared);
    return prepared;
}

pub fn getItem(self: *TransformList, index: u32, frame: *Frame) !*Transform {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    return self._items.items[index];
}

pub fn insertItemBefore(self: *TransformList, item: *Transform, index: u32, frame: *Frame) !*Transform {
    try self.requireMutable();
    try self.sync(frame);
    const prepared = try self.prepareItem(item, frame);
    errdefer prepared.releaseRef(frame._page);
    const at = @min(@as(usize, index), self._items.items.len);
    const next = try frame.local_arena.alloc(*Transform, self._items.items.len + 1);
    @memcpy(next[0..at], self._items.items[0..at]);
    next[at] = prepared;
    @memcpy(next[at + 1 ..], self._items.items[at..]);

    try self._items.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    self._items.insertAssumeCapacity(at, prepared);
    self.attach(prepared);
    return prepared;
}

pub fn replaceItem(self: *TransformList, item: *Transform, index: u32, frame: *Frame) !*Transform {
    try self.requireMutable();
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    const prepared = try self.prepareItem(item, frame);
    errdefer prepared.releaseRef(frame._page);
    const next = try frame.local_arena.dupe(*Transform, self._items.items);
    next[index] = prepared;

    try self._retired.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    const replaced = self._items.items[index];
    replaced.detach(self);
    self._retired.appendAssumeCapacity(replaced);
    self._items.items[index] = prepared;
    self.attach(prepared);
    return prepared;
}

pub fn removeItem(self: *TransformList, index: u32, frame: *Frame) !*Transform {
    try self.requireMutable();
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    const next = try frame.local_arena.alloc(*Transform, self._items.items.len - 1);
    @memcpy(next[0..index], self._items.items[0..index]);
    @memcpy(next[index..], self._items.items[index + 1 ..]);

    try self._retired.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    const removed = self._items.orderedRemove(index);
    removed.detach(self);
    self._retired.appendAssumeCapacity(removed);
    return removed;
}

pub fn appendItem(self: *TransformList, item: *Transform, frame: *Frame) !*Transform {
    return self.insertItemBefore(item, std.math.maxInt(u32), frame);
}

pub fn consolidate(self: *TransformList, frame: *Frame) !?*Transform {
    try self.requireMutable();
    try self.sync(frame);
    if (self._items.items.len == 0) return null;

    var matrix = DOMMatrixReadOnly.identity();
    for (self._items.items) |item| matrix = DOMMatrixReadOnly.multiplyMatrix(matrix, item.getState().matrix);
    for (matrix) |value| if (!std.math.isFinite(value)) return error.TypeError;
    var values: [16]f64 = undefined;
    values[0] = matrix[0];
    values[1] = matrix[1];
    values[2] = matrix[4];
    values[3] = matrix[5];
    values[4] = matrix[12];
    values[5] = matrix[13];
    const consolidated = try Transform.fromParsed(.{
        .kind = .matrix,
        .matrix = matrix,
        .values = values,
        .count = 6,
        .is_2d = true,
    }, frame);
    consolidated.acquireRef();
    errdefer consolidated.releaseRef(frame._page);

    try self._items.ensureTotalCapacity(frame.arena, 1);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    try self.setAttribute(&.{consolidated}, frame);
    self.retireAllAssumeCapacity();
    self._items.appendAssumeCapacity(consolidated);
    self.attach(consolidated);
    return consolidated;
}

fn requireMutable(self: *const TransformList) !void {
    if (self._read_only) return error.NoModificationAllowed;
}

fn prepareItem(_: *TransformList, item: *Transform, frame: *Frame) !*Transform {
    const prepared = if (item.isAttached()) try item.clone(frame) else item;
    prepared.acquireRef();
    return prepared;
}

fn attach(self: *TransformList, transform: *Transform) void {
    transform.attach(.{
        .owner = self,
        .read_only = self._read_only,
        .mutate = TransformList.mutateTransform,
    });
}

fn mutateTransform(context: *anyopaque, transform: *Transform, state: Transform.State, frame: *Frame) anyerror!void {
    const self: *TransformList = @ptrCast(@alignCast(context));
    try self.sync(frame);
    if (!transform.isAttachedTo(self)) {
        transform.applyStateRaw(state);
        return;
    }
    const index = for (self._items.items, 0..) |candidate, i| {
        if (candidate == transform) break i;
    } else unreachable;
    try self.setAttributeWithOverride(index, state, frame);
    transform.applyStateRaw(state);
}

fn sync(self: *TransformList, frame: *Frame) !void {
    const raw = self._element.getAttributeSafe(self._attr_name) orelse "";
    if (self._snapshot) |snapshot| if (std.mem.eql(u8, snapshot, raw)) return;
    const snapshot = try frame.arena.dupe(u8, raw);
    var parsed = parse(raw, frame) catch |err| switch (err) {
        error.SyntaxError => std.ArrayList(*Transform).empty,
        else => return err,
    };
    errdefer for (parsed.items) |transform| transform.releaseRef(frame._page);

    try self._items.ensureTotalCapacity(frame.arena, parsed.items.len);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    self.retireAllAssumeCapacity();
    for (parsed.items) |transform| {
        self._items.appendAssumeCapacity(transform);
        self.attach(transform);
    }
    parsed.clearRetainingCapacity();
    self._snapshot = snapshot;
}

fn parse(raw: []const u8, frame: *Frame) !std.ArrayList(*Transform) {
    var parsed: std.ArrayList(*Transform) = .empty;
    errdefer for (parsed.items) |transform| transform.releaseRef(frame._page);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return parsed;

    var iterator = DOMMatrixReadOnly.TransformFunctionIterator{ .input = trimmed, .allow_comma = true };
    while (try iterator.next()) |function| {
        const value = try DOMMatrixReadOnly.parseTransformFunction(function, .svg);
        const transform = try Transform.fromParsed(value, frame);
        transform.acquireRef();
        parsed.append(frame.local_arena, transform) catch |err| {
            transform.releaseRef(frame._page);
            return err;
        };
    }
    return parsed;
}

fn retireAllAssumeCapacity(self: *TransformList) void {
    for (self._items.items) |transform| {
        transform.detach(self);
        self._retired.appendAssumeCapacity(transform);
    }
    self._items.clearRetainingCapacity();
}

fn setAttribute(self: *TransformList, items: []const *Transform, frame: *Frame) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (items, 0..) |transform, i| {
        if (i != 0) try writer.writeByte(' ');
        try Transform.writeState(transform.getState(), writer);
    }
    try self.commitAttribute(serialized.written(), frame);
}

fn setAttributeWithOverride(self: *TransformList, index: usize, state: Transform.State, frame: *Frame) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (self._items.items, 0..) |transform, i| {
        if (i != 0) try writer.writeByte(' ');
        try Transform.writeState(if (i == index) state else transform.getState(), writer);
    }
    try self.commitAttribute(serialized.written(), frame);
}

fn commitAttribute(self: *TransformList, serialized: []const u8, frame: *Frame) !void {
    const snapshot = try frame.arena.dupe(u8, serialized);
    try self._element.setAttributeSafe(self._attr_name, .wrap(serialized), frame);
    self._snapshot = snapshot;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TransformList);

    pub const Meta = struct {
        pub const name = "SVGTransformList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(TransformList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(TransformList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(TransformList.clear, .{});
    pub const initialize = bridge.function(TransformList.initialize, .{});
    pub const getItem = bridge.function(TransformList.getItem, .{});
    pub const insertItemBefore = bridge.function(TransformList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(TransformList.replaceItem, .{});
    pub const removeItem = bridge.function(TransformList.removeItem, .{});
    pub const appendItem = bridge.function(TransformList.appendItem, .{});
    pub const consolidate = bridge.function(TransformList.consolidate, .{});
};

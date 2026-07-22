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
const DOMPoint = @import("../DOMPoint.zig");
const DOMPointReadOnly = @import("../DOMPointReadOnly.zig");
const Element = @import("../Element.zig");

const PointList = @This();

_element: *Element,
_read_only: bool,
_items: std.ArrayList(*DOMPoint) = .empty,
_retired: std.ArrayList(*DOMPoint) = .empty,
_snapshot: ?[]const u8 = null,

pub fn create(element: *Element, read_only: bool, frame: *Frame) !*PointList {
    const self = try frame._factory.create(PointList{
        ._element = element,
        ._read_only = read_only,
    });
    try frame.registerSvgCollectionCleanup(.{
        .context = self,
        .callback = PointList.cleanup,
    });
    return self;
}

fn cleanup(context: *anyopaque, page: *Page) void {
    const self: *PointList = @ptrCast(@alignCast(context));
    for (self._items.items) |point| {
        point._proto.detach(self);
        point._proto.releaseRef(page);
    }
    for (self._retired.items) |point| {
        point._proto.releaseRef(page);
    }
    self._items.clearRetainingCapacity();
    self._retired.clearRetainingCapacity();
}

pub fn getLength(self: *PointList, frame: *Frame) !u32 {
    try self.sync(frame);
    return @intCast(self._items.items.len);
}

pub fn getNumberOfItems(self: *PointList, frame: *Frame) !u32 {
    return self.getLength(frame);
}

pub fn clear(self: *PointList, frame: *Frame) !void {
    try self.requireMutable();
    try self.sync(frame);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    try self.setAttribute(&.{}, frame);
    self.retireAllAssumeCapacity();
}

pub fn initialize(self: *PointList, item: *DOMPoint, frame: *Frame) !*DOMPoint {
    try self.requireMutable();
    try self.sync(frame);

    const prepared = try self.prepareItem(item, frame);
    errdefer prepared._proto.releaseRef(frame._page);

    try self._items.ensureTotalCapacity(frame.arena, 1);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    try self.setAttribute(&.{prepared}, frame);
    self.retireAllAssumeCapacity();
    self._items.appendAssumeCapacity(prepared);
    self.attach(prepared);
    return prepared;
}

pub fn getItem(self: *PointList, index: u32, frame: *Frame) !*DOMPoint {
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;
    return self._items.items[index];
}

pub fn insertItemBefore(self: *PointList, item: *DOMPoint, index: u32, frame: *Frame) !*DOMPoint {
    try self.requireMutable();
    try self.sync(frame);

    const prepared = try self.prepareItem(item, frame);
    errdefer prepared._proto.releaseRef(frame._page);
    const at = @min(@as(usize, index), self._items.items.len);
    const next = try frame.local_arena.alloc(*DOMPoint, self._items.items.len + 1);
    @memcpy(next[0..at], self._items.items[0..at]);
    next[at] = prepared;
    @memcpy(next[at + 1 ..], self._items.items[at..]);

    try self._items.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    self._items.insertAssumeCapacity(at, prepared);
    self.attach(prepared);
    return prepared;
}

pub fn replaceItem(self: *PointList, item: *DOMPoint, index: u32, frame: *Frame) !*DOMPoint {
    try self.requireMutable();
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;

    const prepared = try self.prepareItem(item, frame);
    errdefer prepared._proto.releaseRef(frame._page);
    const next = try frame.local_arena.dupe(*DOMPoint, self._items.items);
    next[index] = prepared;

    try self._retired.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    const replaced = self._items.items[index];
    replaced._proto.detach(self);
    self._retired.appendAssumeCapacity(replaced);
    self._items.items[index] = prepared;
    self.attach(prepared);
    return prepared;
}

pub fn removeItem(self: *PointList, index: u32, frame: *Frame) !*DOMPoint {
    try self.requireMutable();
    try self.sync(frame);
    if (index >= self._items.items.len) return error.IndexSizeError;

    const next = try frame.local_arena.alloc(*DOMPoint, self._items.items.len - 1);
    @memcpy(next[0..index], self._items.items[0..index]);
    @memcpy(next[index..], self._items.items[index + 1 ..]);

    try self._retired.ensureUnusedCapacity(frame.arena, 1);
    try self.setAttribute(next, frame);
    const removed = self._items.orderedRemove(index);
    removed._proto.detach(self);
    self._retired.appendAssumeCapacity(removed);
    return removed;
}

pub fn appendItem(self: *PointList, item: *DOMPoint, frame: *Frame) !*DOMPoint {
    return self.insertItemBefore(item, std.math.maxInt(u32), frame);
}

fn requireMutable(self: *const PointList) !void {
    if (self._read_only) return error.NoModificationAllowed;
}

fn prepareItem(_: *PointList, item: *DOMPoint, frame: *Frame) !*DOMPoint {
    if (!std.math.isFinite(item._proto._x) or !std.math.isFinite(item._proto._y)) return error.TypeError;
    const prepared = if (item._proto.isAttached())
        try DOMPoint.create(item._proto._x, item._proto._y, item._proto._z, item._proto._w, frame._page)
    else
        item;
    prepared._proto.acquireRef();
    return prepared;
}

fn attach(self: *PointList, point: *DOMPoint) void {
    point._proto.attach(.{
        .owner = self,
        .read_only = self._read_only,
        .mutate = PointList.mutatePoint,
    });
}

fn mutatePoint(
    context: *anyopaque,
    point: *DOMPointReadOnly,
    coordinate: DOMPointReadOnly.Coordinate,
    value: f64,
    frame: *Frame,
) anyerror!void {
    const self: *PointList = @ptrCast(@alignCast(context));
    try self.sync(frame);

    // An external attribute mutation detaches the old item during sync. The
    // caller still owns that DOMPoint identity, but it no longer mutates the list.
    if (!point.isAttachedTo(self)) {
        point.setCoordinateRaw(coordinate, value);
        return;
    }

    if (coordinate == .z or coordinate == .w) {
        point.setCoordinateRaw(coordinate, value);
        return;
    }
    if (!std.math.isFinite(value)) return error.TypeError;

    const index = for (self._items.items, 0..) |candidate, i| {
        if (candidate._proto == point) break i;
    } else unreachable;

    try self.setAttributeWithOverride(index, coordinate, value, frame);
    point.setCoordinateRaw(coordinate, value);
}

fn sync(self: *PointList, frame: *Frame) !void {
    const raw = self._element.getAttributeSafe(comptime .wrap("points")) orelse "";
    if (self._snapshot) |snapshot| {
        if (std.mem.eql(u8, snapshot, raw)) return;
    }

    const snapshot = try frame.arena.dupe(u8, raw);
    var parsed = parse(raw, frame) catch |err| switch (err) {
        error.SyntaxError => std.ArrayList(*DOMPoint).empty,
        else => return err,
    };
    errdefer for (parsed.items) |point| point._proto.releaseRef(frame._page);

    try self._items.ensureTotalCapacity(frame.arena, parsed.items.len);
    try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
    self.retireAllAssumeCapacity();
    for (parsed.items) |point| {
        self._items.appendAssumeCapacity(point);
        self.attach(point);
    }
    parsed.clearRetainingCapacity();
    self._snapshot = snapshot;
}

fn parse(raw: []const u8, frame: *Frame) !std.ArrayList(*DOMPoint) {
    var scanner = NumberScanner{ .input = raw };
    var parsed: std.ArrayList(*DOMPoint) = .empty;
    errdefer for (parsed.items) |point| point._proto.releaseRef(frame._page);

    while (try scanner.next()) |x| {
        const y = (try scanner.next()) orelse return error.SyntaxError;
        const point = try DOMPoint.create(x, y, 0, 1, frame._page);
        point._proto.acquireRef();
        parsed.append(frame.local_arena, point) catch |err| {
            point._proto.releaseRef(frame._page);
            return err;
        };
    }
    return parsed;
}

fn retireAllAssumeCapacity(self: *PointList) void {
    for (self._items.items) |point| {
        point._proto.detach(self);
        self._retired.appendAssumeCapacity(point);
    }
    self._items.clearRetainingCapacity();
}

fn setAttribute(self: *PointList, items: []const *DOMPoint, frame: *Frame) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (items, 0..) |point, i| {
        if (i != 0) try writer.writeByte(' ');
        try writer.print("{d},{d}", .{ point._proto._x, point._proto._y });
    }
    try self.commitAttribute(serialized.written(), frame);
}

fn setAttributeWithOverride(
    self: *PointList,
    index: usize,
    coordinate: DOMPointReadOnly.Coordinate,
    value: f64,
    frame: *Frame,
) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (self._items.items, 0..) |point, i| {
        if (i != 0) try writer.writeByte(' ');
        const x = if (i == index and coordinate == .x) value else point._proto._x;
        const y = if (i == index and coordinate == .y) value else point._proto._y;
        try writer.print("{d},{d}", .{ x, y });
    }
    try self.commitAttribute(serialized.written(), frame);
}

fn commitAttribute(self: *PointList, serialized: []const u8, frame: *Frame) !void {
    const snapshot = try frame.arena.dupe(u8, serialized);
    try self._element.setAttributeSafe(comptime .wrap("points"), .wrap(serialized), frame);
    self._snapshot = snapshot;
}

const NumberScanner = struct {
    input: []const u8,
    index: usize = 0,
    first: bool = true,

    fn next(self: *NumberScanner) !?f64 {
        var had_whitespace = false;
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) {
            had_whitespace = true;
            self.index += 1;
        }

        if (!self.first and self.index < self.input.len and self.input[self.index] == ',') {
            self.index += 1;
            while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
            if (self.index == self.input.len) return error.SyntaxError;
        } else if (!self.first and self.index < self.input.len and !had_whitespace and
            self.input[self.index] != '+' and self.input[self.index] != '-')
        {
            return error.SyntaxError;
        }

        if (self.index == self.input.len) return null;
        const start = self.index;
        if (self.input[self.index] == '+' or self.input[self.index] == '-') self.index += 1;

        var digits: usize = 0;
        while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) digits += 1;
        if (self.index < self.input.len and self.input[self.index] == '.') {
            self.index += 1;
            while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) digits += 1;
        }
        if (digits == 0) return error.SyntaxError;

        if (self.index < self.input.len and (self.input[self.index] == 'e' or self.input[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.input.len and (self.input[self.index] == '+' or self.input[self.index] == '-')) self.index += 1;
            const exponent_start = self.index;
            while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) self.index += 1;
            if (self.index == exponent_start) return error.SyntaxError;
        }

        const value = std.fmt.parseFloat(f64, self.input[start..self.index]) catch return error.SyntaxError;
        if (!std.math.isFinite(value)) return error.SyntaxError;
        self.first = false;
        return value;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(PointList);

    pub const Meta = struct {
        pub const name = "SVGPointList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(PointList.getLength, null, .{});
    pub const numberOfItems = bridge.accessor(PointList.getNumberOfItems, null, .{});
    pub const clear = bridge.function(PointList.clear, .{});
    pub const initialize = bridge.function(PointList.initialize, .{});
    pub const getItem = bridge.function(PointList.getItem, .{});
    pub const insertItemBefore = bridge.function(PointList.insertItemBefore, .{});
    pub const replaceItem = bridge.function(PointList.replaceItem, .{});
    pub const removeItem = bridge.function(PointList.removeItem, .{});
    pub const appendItem = bridge.function(PointList.appendItem, .{});
};

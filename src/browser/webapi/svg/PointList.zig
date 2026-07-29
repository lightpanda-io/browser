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
const Page = @import("../../Page.zig");
const DOMPoint = @import("../DOMPoint.zig");
const DOMPointReadOnly = @import("../DOMPointReadOnly.zig");
const Element = @import("../Element.zig");
const reflected_list = @import("reflected_list.zig");

const PointList = @This();

_frame: *Frame,
_element: *Element,
_read_only: bool,
_synced: bool = false,
_snapshot: std.ArrayList(u8) = .empty,
_items: std.ArrayList(*DOMPoint) = .empty,
_retired: std.ArrayList(*DOMPoint) = .empty,

const M = reflected_list.Mixin(PointList, DOMPoint, .{
    .attrName = attrName,
    .parse = parse,
    .writeItem = writeItem,
    .prepareItem = prepareItem,
    .attach = attach,
    .detachItem = detachItem,
    .releaseItem = releaseItem,
});

pub const Kind = enum { base, animated };

pub const Key = struct {
    element: *Element,
    kind: Kind,
};

pub const Lookup = std.AutoHashMapUnmanaged(Key, *PointList);

pub fn getOrCreate(element: *Element, kind: Kind, frame: *Frame) !*PointList {
    const key: Key = .{
        .element = element,
        .kind = kind,
    };
    const gop = try frame._svg_point_lists.getOrPut(frame.arena, key);
    if (!gop.found_existing) {
        errdefer _ = frame._svg_point_lists.remove(key);
        gop.value_ptr.* = try frame._factory.create(PointList{
            ._frame = frame,
            ._element = element,
            ._read_only = kind == .animated,
        });
    }
    return gop.value_ptr.*;
}

pub const deinit = M.deinit;
pub const getLength = M.getLength;
pub const getNumberOfItems = M.getNumberOfItems;
pub const clear = M.clear;
pub const initialize = M.initialize;
pub const getItem = M.getItem;
pub const insertItemBefore = M.insertItemBefore;
pub const replaceItem = M.replaceItem;
pub const removeItem = M.removeItem;
pub const appendItem = M.appendItem;

fn attrName(_: *const PointList) lp.String {
    return .wrap("points");
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
    point._proto.restrict();
    point._proto.attach(.{
        .owner = self,
        .mutate = PointList.mutatePoint,
    }, self._read_only);
}

fn detachItem(point: *DOMPoint, owner: *PointList) void {
    point._proto.detach(owner);
}

fn releaseItem(point: *DOMPoint, page: *Page) void {
    point._proto.releaseRef(page);
}

fn mutatePoint(
    context: *anyopaque,
    point: *DOMPointReadOnly,
    coordinate: DOMPointReadOnly.Coordinate,
    value: f64,
) anyerror!void {
    const self: *PointList = @ptrCast(@alignCast(context));
    const frame = self._frame;
    try M.sync(self, frame);

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

fn parse(raw: []const u8, frame: *Frame) !std.ArrayList(*DOMPoint) {
    var scanner = NumberScanner{ .input = raw };
    var parsed: std.ArrayList(*DOMPoint) = .empty;
    errdefer for (parsed.items) |point| point._proto.releaseRef(frame._page);

    while (try scanner.next()) |x| {
        // A trailing coordinate with no pair truncates the list; only a
        // malformed number invalidates the whole attribute.
        const y = (try scanner.next()) orelse break;
        const point = try DOMPoint.create(x, y, 0, 1, frame._page);
        point._proto.acquireRef();
        parsed.append(frame.local_arena, point) catch |err| {
            point._proto.releaseRef(frame._page);
            return err;
        };
    }
    return parsed;
}

fn writeItem(point: *DOMPoint, writer: *std.Io.Writer) !void {
    try writer.print("{d} {d}", .{ point._proto._x, point._proto._y });
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
        try writer.print("{d} {d}", .{ x, y });
    }
    try M.commitAttribute(self, serialized.written(), frame);
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

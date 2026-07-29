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
const DOMMatrixReadOnly = @import("../DOMMatrixReadOnly.zig");
const Element = @import("../Element.zig");
const Transform = @import("Transform.zig");
const reflected_list = @import("reflected_list.zig");

const TransformList = @This();

_frame: *Frame,
_attr_name: lp.String,
_read_only: bool,
_element: *Element,
_synced: bool = false,
_snapshot: std.ArrayList(u8) = .empty,
_items: std.ArrayList(*Transform) = .empty,
_retired: std.ArrayList(*Transform) = .empty,

const M = reflected_list.Mixin(TransformList, Transform, .{
    .attrName = attrName,
    .parse = parse,
    .writeItem = writeItem,
    .prepareItem = prepareItem,
    .attach = attach,
    .detachItem = detachItem,
    .releaseItem = releaseItem,
});

pub fn createForAttribute(element: *Element, attr_name: lp.String, read_only: bool, frame: *Frame) !*TransformList {
    return frame._factory.create(TransformList{
        ._frame = frame,
        ._element = element,
        ._attr_name = attr_name,
        ._read_only = read_only,
    });
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

pub fn consolidate(self: *TransformList, frame: *Frame) !?*Transform {
    try M.requireMutable(self);
    try M.sync(self, frame);
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

    try M.retireAll(self, frame);
    try self._items.ensureTotalCapacity(frame.arena, 1);
    try M.setAttribute(self, &.{consolidated}, frame);
    self._items.appendAssumeCapacity(consolidated);
    attach(self, consolidated);
    return consolidated;
}

fn attrName(self: *const TransformList) lp.String {
    return self._attr_name;
}

fn prepareItem(_: *TransformList, item: *Transform, frame: *Frame) !*Transform {
    const prepared = if (item.isAttached()) try item.clone(frame) else item;
    prepared.acquireRef();
    return prepared;
}

fn attach(self: *TransformList, transform: *Transform) void {
    transform.attach(.{
        .owner = self,
        .mutate = TransformList.mutateTransform,
    }, self._read_only);
}

fn detachItem(transform: *Transform, owner: *TransformList) void {
    transform.detach(owner);
}

fn releaseItem(transform: *Transform, page: *Page) void {
    transform.releaseRef(page);
}

fn mutateTransform(context: *anyopaque, transform: *Transform, state: Transform.State) anyerror!void {
    const self: *TransformList = @ptrCast(@alignCast(context));
    const frame = self._frame;
    try M.sync(self, frame);
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

fn writeItem(transform: *Transform, writer: *std.Io.Writer) !void {
    try Transform.writeState(transform.getState(), writer);
}

fn setAttributeWithOverride(self: *TransformList, index: usize, state: Transform.State, frame: *Frame) !void {
    var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
    const writer = &serialized.writer;
    for (self._items.items, 0..) |transform, i| {
        if (i != 0) try writer.writeByte(' ');
        try Transform.writeState(if (i == index) state else transform.getState(), writer);
    }
    try M.commitAttribute(self, serialized.written(), frame);
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

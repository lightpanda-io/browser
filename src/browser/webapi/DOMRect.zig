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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Factory = @import("../Factory.zig");

const RO = @import("DOMRectReadOnly.zig");

pub const Data = RO.Data;

const DOMRect = @This();

_proto: *RO,

pub fn init(x_: ?f64, y_: ?f64, width_: ?f64, height_: ?f64, exec: *const js.Execution) !*DOMRect {
    return create(.{
        .x = x_ orelse 0,
        .y = y_ orelse 0,
        .width = width_ orelse 0,
        .height = height_ orelse 0,
    }, exec._factory);
}

pub fn create(rect: Data, factory: *Factory) !*DOMRect {
    return factory.domRect(rect);
}

pub fn fromRect(other_: ?Data, exec: *const js.Execution) !*DOMRect {
    return create(other_ orelse .{}, exec._factory);
}

pub fn structuredSerialize(self: *const DOMRect, writer: *js.StructuredWriter) !void {
    try self._proto.structuredSerialize(writer);
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*DOMRect {
    return page.factory.domRect(try RO.readData(reader));
}

// DOMRect redeclares x/y/width/height as writable, so DOMRect.prototype needs its
// own read-write accessors distinct from the read-only ones on
// DOMRectReadOnly.prototype. The setters are the point; each accessor bundles a
// getter too, so we pair them with DOMRect-typed getters that read through
// `_proto`. top/right/bottom/left stay read-only and are inherited from the base.

pub fn getX(self: *const DOMRect) f64 {
    return self._proto._x;
}
pub fn getY(self: *const DOMRect) f64 {
    return self._proto._y;
}
pub fn getWidth(self: *const DOMRect) f64 {
    return self._proto._width;
}
pub fn getHeight(self: *const DOMRect) f64 {
    return self._proto._height;
}

pub fn setX(self: *DOMRect, v: f64) void {
    self._proto._x = v;
}
pub fn setY(self: *DOMRect, v: f64) void {
    self._proto._y = v;
}
pub fn setWidth(self: *DOMRect, v: f64) void {
    self._proto._width = v;
}
pub fn setHeight(self: *DOMRect, v: f64) void {
    self._proto._height = v;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMRect);

    pub const Meta = struct {
        pub const name = "DOMRect";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMRect.init, .{});
    pub const fromRect = bridge.function(DOMRect.fromRect, .{ .static = true });

    // Writable components (the read-only top/right/bottom/left are inherited
    // from DOMRectReadOnly.prototype).
    pub const x = bridge.accessor(DOMRect.getX, DOMRect.setX, .{});
    pub const y = bridge.accessor(DOMRect.getY, DOMRect.setY, .{});
    pub const width = bridge.accessor(DOMRect.getWidth, DOMRect.setWidth, .{});
    pub const height = bridge.accessor(DOMRect.getHeight, DOMRect.setHeight, .{});
};

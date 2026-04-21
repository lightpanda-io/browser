// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const DOMPoint = @This();

const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMMatrix = @import("DOMMatrix.zig");

_x: f64,
_y: f64,
_z: f64,
_w: f64,

pub fn init(x: ?f64, y: ?f64, z: ?f64, w: ?f64, page: *Page) !*DOMPoint {
    return page._factory.create(DOMPoint{
        ._x = x orelse 0,
        ._y = y orelse 0,
        ._z = z orelse 0,
        ._w = w orelse 1,
    });
}

pub fn fromPoint(x: ?f64, y: ?f64, z: ?f64, w: ?f64, page: *Page) !*DOMPoint {
    return init(x, y, z, w, page);
}

pub fn matrixTransform(self: *const DOMPoint, matrix: *const DOMMatrix, page: *Page) !*DOMPoint {
    const m = matrix._m;
    const x = self._x;
    const y = self._y;
    const z = self._z;
    const w = self._w;
    return page._factory.create(DOMPoint{
        ._x = m[0] * x + m[4] * y + m[8] * z + m[12] * w,
        ._y = m[1] * x + m[5] * y + m[9] * z + m[13] * w,
        ._z = m[2] * x + m[6] * y + m[10] * z + m[14] * w,
        ._w = m[3] * x + m[7] * y + m[11] * z + m[15] * w,
    });
}

pub fn getX(self: *const DOMPoint) f64 {
    return self._x;
}
pub fn getY(self: *const DOMPoint) f64 {
    return self._y;
}
pub fn getZ(self: *const DOMPoint) f64 {
    return self._z;
}
pub fn getW(self: *const DOMPoint) f64 {
    return self._w;
}

pub fn setX(self: *DOMPoint, value: f64) void {
    self._x = value;
}
pub fn setY(self: *DOMPoint, value: f64) void {
    self._y = value;
}
pub fn setZ(self: *DOMPoint, value: f64) void {
    self._z = value;
}
pub fn setW(self: *DOMPoint, value: f64) void {
    self._w = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMPoint);

    pub const Meta = struct {
        pub const name = "DOMPoint";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMPoint.init, .{});
    pub const fromPoint = bridge.function(DOMPoint.fromPoint, .{ .static = true });
    pub const matrixTransform = bridge.function(DOMPoint.matrixTransform, .{});
    pub const x = bridge.accessor(DOMPoint.getX, DOMPoint.setX, .{});
    pub const y = bridge.accessor(DOMPoint.getY, DOMPoint.setY, .{});
    pub const z = bridge.accessor(DOMPoint.getZ, DOMPoint.setZ, .{});
    pub const w = bridge.accessor(DOMPoint.getW, DOMPoint.setW, .{});
};

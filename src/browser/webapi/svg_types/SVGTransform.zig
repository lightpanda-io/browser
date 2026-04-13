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

const SVGTransform = @This();

const std = @import("std");
const js = @import("../../js/js.zig");

_type: u16,
_angle: f64,
_matrix: [6]f64,

pub fn getType(self: *const SVGTransform) u16 {
    return self._type;
}

pub fn getAngle(self: *const SVGTransform) f64 {
    return self._angle;
}

pub fn setMatrix(self: *SVGTransform, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self._type = 1; // SVG_TRANSFORM_MATRIX
    self._matrix = .{ a, b, c, d, e, f };
}

pub fn setTranslate(self: *SVGTransform, tx: f64, ty: f64) void {
    self._type = 2; // SVG_TRANSFORM_TRANSLATE
    self._matrix = .{ 1, 0, 0, 1, tx, ty };
}

pub fn setScale(self: *SVGTransform, sx: f64, sy: f64) void {
    self._type = 3; // SVG_TRANSFORM_SCALE
    self._matrix = .{ sx, 0, 0, sy, 0, 0 };
}

pub fn setRotate(self: *SVGTransform, angle: f64, cx: f64, cy: f64) void {
    self._type = 4; // SVG_TRANSFORM_ROTATE
    self._angle = angle;
    const rad = angle * std.math.pi / 180.0;
    const cos_a = @cos(rad);
    const sin_a = @sin(rad);
    self._matrix = .{ cos_a, sin_a, -sin_a, cos_a, cx - cos_a * cx + sin_a * cy, cy - sin_a * cx - cos_a * cy };
}

pub fn setSkewX(self: *SVGTransform, angle: f64) void {
    self._type = 5; // SVG_TRANSFORM_SKEWX
    self._angle = angle;
    const rad = angle * std.math.pi / 180.0;
    self._matrix = .{ 1, 0, @tan(rad), 1, 0, 0 };
}

pub fn setSkewY(self: *SVGTransform, angle: f64) void {
    self._type = 6; // SVG_TRANSFORM_SKEWY
    self._angle = angle;
    const rad = angle * std.math.pi / 180.0;
    self._matrix = .{ 1, @tan(rad), 0, 1, 0, 0 };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGTransform);

    pub const Meta = struct {
        pub const name = "SVGTransform";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_TRANSFORM_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_TRANSFORM_MATRIX = bridge.property(1, .{ .template = true });
    pub const SVG_TRANSFORM_TRANSLATE = bridge.property(2, .{ .template = true });
    pub const SVG_TRANSFORM_SCALE = bridge.property(3, .{ .template = true });
    pub const SVG_TRANSFORM_ROTATE = bridge.property(4, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWX = bridge.property(5, .{ .template = true });
    pub const SVG_TRANSFORM_SKEWY = bridge.property(6, .{ .template = true });

    pub const @"type" = bridge.accessor(SVGTransform.getType, null, .{});
    pub const angle = bridge.accessor(SVGTransform.getAngle, null, .{});
    pub const setMatrix = bridge.function(SVGTransform.setMatrix, .{});
    pub const setTranslate = bridge.function(SVGTransform.setTranslate, .{});
    pub const setScale = bridge.function(SVGTransform.setScale, .{});
    pub const setRotate = bridge.function(SVGTransform.setRotate, .{});
    pub const setSkewX = bridge.function(SVGTransform.setSkewX, .{});
    pub const setSkewY = bridge.function(SVGTransform.setSkewY, .{});
};

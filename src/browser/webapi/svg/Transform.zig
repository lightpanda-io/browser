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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const RO = @import("../DOMMatrixReadOnly.zig");

const Transform = @This();

pub const DOMMatrix2DInit = struct {
    a: ?f64 = null,
    b: ?f64 = null,
    c: ?f64 = null,
    d: ?f64 = null,
    e: ?f64 = null,
    f: ?f64 = null,
    m11: ?f64 = null,
    m12: ?f64 = null,
    m21: ?f64 = null,
    m22: ?f64 = null,
    m41: ?f64 = null,
    m42: ?f64 = null,
};

_type: u16 = 1,
_angle: f64 = 0,
_matrix: *DOMMatrix,

// The transform owns the matrix arena even when no JS wrapper currently
// references `matrix`. Forwarding the transform's bridge lifetime keeps the
// stable SameObject pointer valid across garbage collections.
pub fn acquireRef(self: *Transform) void {
    self._matrix._proto.acquireRef();
}

pub fn releaseRef(self: *Transform, page: *Page) void {
    self._matrix._proto.releaseRef(page);
}

pub fn detached(frame: *Frame) !*Transform {
    const matrix = try DOMMatrix.create(RO.identity(), true, frame._page);
    return frame._factory.create(Transform{ ._matrix = matrix });
}

pub fn fromMatrix(init: ?DOMMatrix2DInit, frame: *Frame) !*Transform {
    const parsed = try fixup2D(init orelse .{});
    const matrix = try DOMMatrix.create(parsed.m, true, frame._page);
    return frame._factory.create(Transform{ ._matrix = matrix });
}

pub fn getType(self: *const Transform) u16 {
    return self._type;
}

pub fn getMatrix(self: *Transform) *DOMMatrix {
    return self._matrix;
}

pub fn getAngle(self: *const Transform) f64 {
    return self._angle;
}

pub fn setMatrix(self: *Transform, init: ?DOMMatrix2DInit) !void {
    const parsed = try fixup2D(init orelse .{});
    self.replaceMatrix(parsed.m, true);
    self._type = 1;
    self._angle = 0;
}

pub fn setTranslate(self: *Transform, tx: f64, ty: f64) !void {
    try ensureFinite(&.{ tx, ty });
    self.replaceMatrix(RO.translationMatrix(tx, ty, 0), true);
    self._type = 2;
    self._angle = 0;
}

pub fn setScale(self: *Transform, sx: f64, sy: f64) !void {
    try ensureFinite(&.{ sx, sy });
    self.replaceMatrix(RO.scaleMatrix(sx, sy, 1), true);
    self._type = 3;
    self._angle = 0;
}

pub fn setRotate(self: *Transform, angle: f64, cx: f64, cy: f64) !void {
    try ensureFinite(&.{ angle, cx, cy });
    const radians = angle * std.math.pi / 180.0;
    var matrix = RO.translationMatrix(cx, cy, 0);
    matrix = RO.multiplyMatrix(matrix, RO.rotateZMatrix(radians));
    matrix = RO.multiplyMatrix(matrix, RO.translationMatrix(-cx, -cy, 0));
    self.replaceMatrix(matrix, true);
    self._type = 4;
    self._angle = angle;
}

pub fn setSkewX(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    self.replaceMatrix(RO.skewMatrix(angle * std.math.pi / 180.0, 0), true);
    self._type = 5;
    self._angle = angle;
}

pub fn setSkewY(self: *Transform, angle: f64) !void {
    try ensureFinite(&.{angle});
    self.replaceMatrix(RO.skewMatrix(0, angle * std.math.pi / 180.0), true);
    self._type = 6;
    self._angle = angle;
}

fn replaceMatrix(self: *Transform, matrix: [16]f64, is_2d: bool) void {
    self._matrix._proto._m = matrix;
    self._matrix._proto._is_2d = is_2d;
}

fn fixup2D(init: DOMMatrix2DInit) !RO.Parsed {
    return RO.fixupDict(.{
        .a = init.a,
        .b = init.b,
        .c = init.c,
        .d = init.d,
        .e = init.e,
        .f = init.f,
        .m11 = init.m11,
        .m12 = init.m12,
        .m21 = init.m21,
        .m22 = init.m22,
        .m41 = init.m41,
        .m42 = init.m42,
        .is2D = true,
    });
}

fn ensureFinite(values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.TypeError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Transform);

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

    pub const @"type" = bridge.accessor(Transform.getType, null, .{});
    pub const matrix = bridge.accessor(Transform.getMatrix, null, .{});
    pub const angle = bridge.accessor(Transform.getAngle, null, .{});
    pub const setMatrix = bridge.function(Transform.setMatrix, .{});
    pub const setTranslate = bridge.function(Transform.setTranslate, .{});
    pub const setScale = bridge.function(Transform.setScale, .{});
    pub const setRotate = bridge.function(Transform.setRotate, .{});
    pub const setSkewX = bridge.function(Transform.setSkewX, .{});
    pub const setSkewY = bridge.function(Transform.setSkewY, .{});
};

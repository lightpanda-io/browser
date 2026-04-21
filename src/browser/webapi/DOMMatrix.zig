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

const DOMMatrix = @This();

const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMPoint = @import("DOMPoint.zig");

_m: [16]f64,

fn identity() [16]f64 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

pub fn init(page: *Page) !*DOMMatrix {
    return page._factory.create(DOMMatrix{ ._m = identity() });
}

fn mul4x4(a: [16]f64, b: [16]f64) [16]f64 {
    var r: [16]f64 = undefined;
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            var s: f64 = 0;
            inline for (0..4) |k| {
                s += a[k * 4 + row] * b[col * 4 + k];
            }
            r[col * 4 + row] = s;
        }
    }
    return r;
}

fn translationMatrix(tx: f64, ty: f64, tz: f64) [16]f64 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1 };
}

fn scaleMatrix(sx: f64, sy: f64, sz: f64) [16]f64 {
    return .{ sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1 };
}

fn rotationZMatrix(degrees: f64) [16]f64 {
    const rad = degrees * std.math.pi / 180.0;
    const c = @cos(rad);
    const s = @sin(rad);
    return .{ c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

fn invert2d(m: [16]f64) [16]f64 {
    const det = m[0] * m[5] - m[1] * m[4];
    if (det == 0) return identity();
    const inv_det = 1.0 / det;
    var r = identity();
    r[0] = m[5] * inv_det;
    r[1] = -m[1] * inv_det;
    r[4] = -m[4] * inv_det;
    r[5] = m[0] * inv_det;
    r[12] = (m[4] * m[13] - m[5] * m[12]) * inv_det;
    r[13] = (m[1] * m[12] - m[0] * m[13]) * inv_det;
    return r;
}

// Accessors for m11..m44 (column-major: m11=0, m12=1, m13=2, m14=3, m21=4, ...)
pub fn getM11(self: *const DOMMatrix) f64 {
    return self._m[0];
}
pub fn getM12(self: *const DOMMatrix) f64 {
    return self._m[1];
}
pub fn getM13(self: *const DOMMatrix) f64 {
    return self._m[2];
}
pub fn getM14(self: *const DOMMatrix) f64 {
    return self._m[3];
}
pub fn getM21(self: *const DOMMatrix) f64 {
    return self._m[4];
}
pub fn getM22(self: *const DOMMatrix) f64 {
    return self._m[5];
}
pub fn getM23(self: *const DOMMatrix) f64 {
    return self._m[6];
}
pub fn getM24(self: *const DOMMatrix) f64 {
    return self._m[7];
}
pub fn getM31(self: *const DOMMatrix) f64 {
    return self._m[8];
}
pub fn getM32(self: *const DOMMatrix) f64 {
    return self._m[9];
}
pub fn getM33(self: *const DOMMatrix) f64 {
    return self._m[10];
}
pub fn getM34(self: *const DOMMatrix) f64 {
    return self._m[11];
}
pub fn getM41(self: *const DOMMatrix) f64 {
    return self._m[12];
}
pub fn getM42(self: *const DOMMatrix) f64 {
    return self._m[13];
}
pub fn getM43(self: *const DOMMatrix) f64 {
    return self._m[14];
}
pub fn getM44(self: *const DOMMatrix) f64 {
    return self._m[15];
}

pub fn setM11(self: *DOMMatrix, v: f64) void {
    self._m[0] = v;
}
pub fn setM12(self: *DOMMatrix, v: f64) void {
    self._m[1] = v;
}
pub fn setM13(self: *DOMMatrix, v: f64) void {
    self._m[2] = v;
}
pub fn setM14(self: *DOMMatrix, v: f64) void {
    self._m[3] = v;
}
pub fn setM21(self: *DOMMatrix, v: f64) void {
    self._m[4] = v;
}
pub fn setM22(self: *DOMMatrix, v: f64) void {
    self._m[5] = v;
}
pub fn setM23(self: *DOMMatrix, v: f64) void {
    self._m[6] = v;
}
pub fn setM24(self: *DOMMatrix, v: f64) void {
    self._m[7] = v;
}
pub fn setM31(self: *DOMMatrix, v: f64) void {
    self._m[8] = v;
}
pub fn setM32(self: *DOMMatrix, v: f64) void {
    self._m[9] = v;
}
pub fn setM33(self: *DOMMatrix, v: f64) void {
    self._m[10] = v;
}
pub fn setM34(self: *DOMMatrix, v: f64) void {
    self._m[11] = v;
}
pub fn setM41(self: *DOMMatrix, v: f64) void {
    self._m[12] = v;
}
pub fn setM42(self: *DOMMatrix, v: f64) void {
    self._m[13] = v;
}
pub fn setM43(self: *DOMMatrix, v: f64) void {
    self._m[14] = v;
}
pub fn setM44(self: *DOMMatrix, v: f64) void {
    self._m[15] = v;
}

// 2D aliases
pub fn getA(self: *const DOMMatrix) f64 {
    return self._m[0];
}
pub fn getB(self: *const DOMMatrix) f64 {
    return self._m[1];
}
pub fn getC(self: *const DOMMatrix) f64 {
    return self._m[4];
}
pub fn getD(self: *const DOMMatrix) f64 {
    return self._m[5];
}
pub fn getE(self: *const DOMMatrix) f64 {
    return self._m[12];
}
pub fn getF(self: *const DOMMatrix) f64 {
    return self._m[13];
}

pub fn setA(self: *DOMMatrix, v: f64) void {
    self._m[0] = v;
}
pub fn setB(self: *DOMMatrix, v: f64) void {
    self._m[1] = v;
}
pub fn setC(self: *DOMMatrix, v: f64) void {
    self._m[4] = v;
}
pub fn setD(self: *DOMMatrix, v: f64) void {
    self._m[5] = v;
}
pub fn setE(self: *DOMMatrix, v: f64) void {
    self._m[12] = v;
}
pub fn setF(self: *DOMMatrix, v: f64) void {
    self._m[13] = v;
}

pub fn getIs2D(self: *const DOMMatrix) bool {
    const m = self._m;
    return m[2] == 0 and m[3] == 0 and m[6] == 0 and m[7] == 0 and
        m[8] == 0 and m[9] == 0 and m[10] == 1 and m[11] == 0 and
        m[14] == 0 and m[15] == 1;
}

pub fn getIsIdentity(self: *const DOMMatrix) bool {
    return std.mem.eql(f64, &self._m, &identity());
}

// Immutable methods — return new DOMMatrix
pub fn multiply(self: *const DOMMatrix, other: *const DOMMatrix, page: *Page) !*DOMMatrix {
    return page._factory.create(DOMMatrix{ ._m = mul4x4(self._m, other._m) });
}

pub fn translate(self: *const DOMMatrix, tx: f64, ty: f64, tz: ?f64, page: *Page) !*DOMMatrix {
    return page._factory.create(DOMMatrix{ ._m = mul4x4(self._m, translationMatrix(tx, ty, tz orelse 0)) });
}

pub fn scale(self: *const DOMMatrix, sx: f64, sy: ?f64, sz: ?f64, page: *Page) !*DOMMatrix {
    return page._factory.create(DOMMatrix{ ._m = mul4x4(self._m, scaleMatrix(sx, sy orelse sx, sz orelse 1)) });
}

pub fn rotate(self: *const DOMMatrix, angle: f64, page: *Page) !*DOMMatrix {
    return page._factory.create(DOMMatrix{ ._m = mul4x4(self._m, rotationZMatrix(angle)) });
}

pub fn inverse(self: *const DOMMatrix, page: *Page) !*DOMMatrix {
    const m = if (self.getIs2D()) invert2d(self._m) else identity();
    return page._factory.create(DOMMatrix{ ._m = m });
}

pub fn transformPoint(self: *const DOMMatrix, x: ?f64, y: ?f64, z: ?f64, w: ?f64, page: *Page) !*DOMPoint {
    const px = x orelse 0;
    const py = y orelse 0;
    const pz = z orelse 0;
    const pw = w orelse 1;
    const m = self._m;
    return page._factory.create(DOMPoint{
        ._x = m[0] * px + m[4] * py + m[8] * pz + m[12] * pw,
        ._y = m[1] * px + m[5] * py + m[9] * pz + m[13] * pw,
        ._z = m[2] * px + m[6] * py + m[10] * pz + m[14] * pw,
        ._w = m[3] * px + m[7] * py + m[11] * pz + m[15] * pw,
    });
}

// Mutating methods — return self
pub fn multiplySelf(self: *DOMMatrix, other: *const DOMMatrix) *DOMMatrix {
    self._m = mul4x4(self._m, other._m);
    return self;
}

pub fn translateSelf(self: *DOMMatrix, tx: f64, ty: f64, tz: ?f64) *DOMMatrix {
    self._m = mul4x4(self._m, translationMatrix(tx, ty, tz orelse 0));
    return self;
}

pub fn scaleSelf(self: *DOMMatrix, sx: f64, sy: ?f64, sz: ?f64) *DOMMatrix {
    self._m = mul4x4(self._m, scaleMatrix(sx, sy orelse sx, sz orelse 1));
    return self;
}

pub fn rotateSelf(self: *DOMMatrix, angle: f64) *DOMMatrix {
    self._m = mul4x4(self._m, rotationZMatrix(angle));
    return self;
}

pub fn invertSelf(self: *DOMMatrix) *DOMMatrix {
    if (self.getIs2D()) {
        self._m = invert2d(self._m);
    } else {
        self._m = identity();
    }
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMMatrix);

    pub const Meta = struct {
        pub const name = "DOMMatrix";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMMatrix.init, .{});

    // 2D aliases
    pub const a = bridge.accessor(DOMMatrix.getA, DOMMatrix.setA, .{});
    pub const b = bridge.accessor(DOMMatrix.getB, DOMMatrix.setB, .{});
    pub const c = bridge.accessor(DOMMatrix.getC, DOMMatrix.setC, .{});
    pub const d = bridge.accessor(DOMMatrix.getD, DOMMatrix.setD, .{});
    pub const e = bridge.accessor(DOMMatrix.getE, DOMMatrix.setE, .{});
    pub const f = bridge.accessor(DOMMatrix.getF, DOMMatrix.setF, .{});

    // Full 4x4 accessors
    pub const m11 = bridge.accessor(DOMMatrix.getM11, DOMMatrix.setM11, .{});
    pub const m12 = bridge.accessor(DOMMatrix.getM12, DOMMatrix.setM12, .{});
    pub const m13 = bridge.accessor(DOMMatrix.getM13, DOMMatrix.setM13, .{});
    pub const m14 = bridge.accessor(DOMMatrix.getM14, DOMMatrix.setM14, .{});
    pub const m21 = bridge.accessor(DOMMatrix.getM21, DOMMatrix.setM21, .{});
    pub const m22 = bridge.accessor(DOMMatrix.getM22, DOMMatrix.setM22, .{});
    pub const m23 = bridge.accessor(DOMMatrix.getM23, DOMMatrix.setM23, .{});
    pub const m24 = bridge.accessor(DOMMatrix.getM24, DOMMatrix.setM24, .{});
    pub const m31 = bridge.accessor(DOMMatrix.getM31, DOMMatrix.setM31, .{});
    pub const m32 = bridge.accessor(DOMMatrix.getM32, DOMMatrix.setM32, .{});
    pub const m33 = bridge.accessor(DOMMatrix.getM33, DOMMatrix.setM33, .{});
    pub const m34 = bridge.accessor(DOMMatrix.getM34, DOMMatrix.setM34, .{});
    pub const m41 = bridge.accessor(DOMMatrix.getM41, DOMMatrix.setM41, .{});
    pub const m42 = bridge.accessor(DOMMatrix.getM42, DOMMatrix.setM42, .{});
    pub const m43 = bridge.accessor(DOMMatrix.getM43, DOMMatrix.setM43, .{});
    pub const m44 = bridge.accessor(DOMMatrix.getM44, DOMMatrix.setM44, .{});

    // Boolean properties
    pub const is2D = bridge.accessor(DOMMatrix.getIs2D, null, .{});
    pub const isIdentity = bridge.accessor(DOMMatrix.getIsIdentity, null, .{});

    // Immutable methods
    pub const multiply = bridge.function(DOMMatrix.multiply, .{});
    pub const translate = bridge.function(DOMMatrix.translate, .{});
    pub const scale = bridge.function(DOMMatrix.scale, .{});
    pub const rotate = bridge.function(DOMMatrix.rotate, .{});
    pub const inverse = bridge.function(DOMMatrix.inverse, .{});
    pub const transformPoint = bridge.function(DOMMatrix.transformPoint, .{});

    // Mutating methods
    pub const multiplySelf = bridge.function(DOMMatrix.multiplySelf, .{});
    pub const translateSelf = bridge.function(DOMMatrix.translateSelf, .{});
    pub const scaleSelf = bridge.function(DOMMatrix.scaleSelf, .{});
    pub const rotateSelf = bridge.function(DOMMatrix.rotateSelf, .{});
    pub const invertSelf = bridge.function(DOMMatrix.invertSelf, .{});
};

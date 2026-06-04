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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const RO = @import("DOMMatrixReadOnly.zig");

const DOMMatrix = @This();

_proto: *RO,

pub fn init(init_: ?js.Value, exec: *const js.Execution) !*DOMMatrix {
    const parsed = try RO.Parsed.init(init_, exec);
    return create(parsed.m, parsed.is_2d, exec.page);
}

// Builds the [DOMMatrixReadOnly, DOMMatrix] prototype chain on a single arena
// (owned by the base) and cross-links them, the same way File wraps Blob.
pub fn create(m: [16]f64, is_2d: bool, page: *Page) !*DOMMatrix {
    const proto = try RO.createBare(m, is_2d, page);
    errdefer proto.deinit(page);

    const self = try proto._arena.create(DOMMatrix);
    self.* = .{ ._proto = proto };
    proto._type = .{ .mutable = self };
    return self;
}

pub fn fromMatrix(other_: ?RO.DOMMatrixInit, page: *Page) !*DOMMatrix {
    const parsed = try RO.fixupDict(other_ orelse .{});
    return create(parsed.m, parsed.is_2d, page);
}

pub fn fromFloat32Array(array: js.TypedArray(f32), page: *Page) !*DOMMatrix {
    const parsed = try RO.floatsToParsed(f32, array.values);
    return create(parsed.m, parsed.is_2d, page);
}

pub fn fromFloat64Array(array: js.TypedArray(f64), page: *Page) !*DOMMatrix {
    const parsed = try RO.floatsToParsed(f64, array.values);
    return create(parsed.m, parsed.is_2d, page);
}

// The base already exposes read-only getters, but a redeclared accessor's
// getter must be typed to this (owner) struct, so we provide DOMMatrix-typed
// getters that read through `_proto`.

pub fn getA(self: *const DOMMatrix) f64 {
    return self._proto._m[0];
}
pub fn getB(self: *const DOMMatrix) f64 {
    return self._proto._m[1];
}
pub fn getC(self: *const DOMMatrix) f64 {
    return self._proto._m[4];
}
pub fn getD(self: *const DOMMatrix) f64 {
    return self._proto._m[5];
}
pub fn getE(self: *const DOMMatrix) f64 {
    return self._proto._m[12];
}
pub fn getF(self: *const DOMMatrix) f64 {
    return self._proto._m[13];
}

pub fn setA(self: *DOMMatrix, v: f64) void {
    self._proto._m[0] = v;
}
pub fn setB(self: *DOMMatrix, v: f64) void {
    self._proto._m[1] = v;
}
pub fn setC(self: *DOMMatrix, v: f64) void {
    self._proto._m[4] = v;
}
pub fn setD(self: *DOMMatrix, v: f64) void {
    self._proto._m[5] = v;
}
pub fn setE(self: *DOMMatrix, v: f64) void {
    self._proto._m[12] = v;
}
pub fn setF(self: *DOMMatrix, v: f64) void {
    self._proto._m[13] = v;
}

pub fn translateSelf(self: *DOMMatrix, tx_: ?f64, ty_: ?f64, tz_: ?f64) *DOMMatrix {
    const tz = tz_ orelse 0;
    const p = self._proto;
    p._m = RO.multiplyMatrix(p._m, RO.translationMatrix(tx_ orelse 0, ty_ orelse 0, tz));
    if (tz != 0) p._is_2d = false;
    return self;
}

pub fn scaleSelf(self: *DOMMatrix, sx_: ?f64, sy_: ?f64, sz_: ?f64, ox_: ?f64, oy_: ?f64, oz_: ?f64) *DOMMatrix {
    const sx = sx_ orelse 1;
    const sy = sy_ orelse sx;
    const sz = sz_ orelse 1;
    const ox = ox_ orelse 0;
    const oy = oy_ orelse 0;
    const oz = oz_ orelse 0;
    const p = self._proto;
    var m = RO.multiplyMatrix(p._m, RO.translationMatrix(ox, oy, oz));
    m = RO.multiplyMatrix(m, RO.scaleMatrix(sx, sy, sz));
    m = RO.multiplyMatrix(m, RO.translationMatrix(-ox, -oy, -oz));
    p._m = m;
    if (sz != 1 or oz != 0) p._is_2d = false;
    return self;
}

pub fn scale3dSelf(self: *DOMMatrix, scale_: ?f64, ox_: ?f64, oy_: ?f64, oz_: ?f64) *DOMMatrix {
    const s = scale_ orelse 1;
    const ox = ox_ orelse 0;
    const oy = oy_ orelse 0;
    const oz = oz_ orelse 0;
    const p = self._proto;
    var m = RO.multiplyMatrix(p._m, RO.translationMatrix(ox, oy, oz));
    m = RO.multiplyMatrix(m, RO.scaleMatrix(s, s, s));
    m = RO.multiplyMatrix(m, RO.translationMatrix(-ox, -oy, -oz));
    p._m = m;
    if (s != 1) p._is_2d = false;
    return self;
}

pub fn rotateSelf(self: *DOMMatrix, rx_: ?f64, ry_: ?f64, rz_: ?f64) *DOMMatrix {
    const p = self._proto;
    if (ry_ == null and rz_ == null) {
        p._m = RO.multiplyMatrix(p._m, RO.rotateZMatrix(RO.toRadians(rx_ orelse 0, .deg)));
    } else {
        p._m = RO.multiplyMatrix(p._m, RO.rotateXMatrix(RO.toRadians(rx_ orelse 0, .deg)));
        p._m = RO.multiplyMatrix(p._m, RO.rotateYMatrix(RO.toRadians(ry_ orelse 0, .deg)));
        p._m = RO.multiplyMatrix(p._m, RO.rotateZMatrix(RO.toRadians(rz_ orelse 0, .deg)));
        p._is_2d = false;
    }
    return self;
}

pub fn rotateFromVectorSelf(self: *DOMMatrix, x_: ?f64, y_: ?f64) *DOMMatrix {
    const x = x_ orelse 0;
    const y = y_ orelse 0;
    const rad = if (x == 0 and y == 0) 0 else std.math.atan2(y, x);
    const p = self._proto;
    p._m = RO.multiplyMatrix(p._m, RO.rotateZMatrix(rad));
    return self;
}

pub fn rotateAxisAngleSelf(self: *DOMMatrix, x_: ?f64, y_: ?f64, z_: ?f64, angle_: ?f64) *DOMMatrix {
    const p = self._proto;
    p._m = RO.multiplyMatrix(p._m, RO.axisAngleMatrix(x_ orelse 0, y_ orelse 0, z_ orelse 0, RO.toRadians(angle_ orelse 0, .deg)));
    if ((x_ orelse 0) != 0 or (y_ orelse 0) != 0) p._is_2d = false;
    return self;
}

pub fn skewXSelf(self: *DOMMatrix, sx_: ?f64) *DOMMatrix {
    const p = self._proto;
    p._m = RO.multiplyMatrix(p._m, RO.skewMatrix(RO.toRadians(sx_ orelse 0, .deg), 0));
    return self;
}

pub fn skewYSelf(self: *DOMMatrix, sy_: ?f64) *DOMMatrix {
    const p = self._proto;
    p._m = RO.multiplyMatrix(p._m, RO.skewMatrix(0, RO.toRadians(sy_ orelse 0, .deg)));
    return self;
}

pub fn multiplySelf(self: *DOMMatrix, other_: ?RO.DOMMatrixInit) !*DOMMatrix {
    const p = self._proto;
    const other = try RO.fixupDict(other_ orelse .{});
    p._m = RO.multiplyMatrix(p._m, other.m);
    p._is_2d = p._is_2d and other.is_2d;
    return self;
}

pub fn preMultiplySelf(self: *DOMMatrix, other_: ?RO.DOMMatrixInit) !*DOMMatrix {
    const p = self._proto;
    const other = try RO.fixupDict(other_ orelse .{});
    p._m = RO.multiplyMatrix(other.m, p._m);
    p._is_2d = p._is_2d and other.is_2d;
    return self;
}

pub fn invertSelf(self: *DOMMatrix) *DOMMatrix {
    const p = self._proto;
    if (RO.invertMatrix(p._m)) |v| {
        p._m = v;
    } else {
        p._m = .{std.math.nan(f64)} ** 16;
        p._is_2d = false;
    }
    return self;
}

pub fn setMatrixValue(self: *DOMMatrix, transform: []const u8) !*DOMMatrix {
    var m = RO.identity();
    var is_2d = true;
    try RO.parseTransformList(transform, &m, &is_2d);
    self._proto._m = m;
    self._proto._is_2d = is_2d;
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMMatrix);

    pub const Meta = struct {
        pub const name = "DOMMatrix";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMMatrix.init, .{ .dom_exception = true });

    pub const fromMatrix = bridge.function(DOMMatrix.fromMatrix, .{ .static = true });
    pub const fromFloat32Array = bridge.function(DOMMatrix.fromFloat32Array, .{ .static = true });
    pub const fromFloat64Array = bridge.function(DOMMatrix.fromFloat64Array, .{ .static = true });

    // Make the components writable (the read-only getters are reused from the
    // base; the setters are ours).
    pub const a = bridge.accessor(DOMMatrix.getA, DOMMatrix.setA, .{});
    pub const b = bridge.accessor(DOMMatrix.getB, DOMMatrix.setB, .{});
    pub const c = bridge.accessor(DOMMatrix.getC, DOMMatrix.setC, .{});
    pub const d = bridge.accessor(DOMMatrix.getD, DOMMatrix.setD, .{});
    pub const e = bridge.accessor(DOMMatrix.getE, DOMMatrix.setE, .{});
    pub const f = bridge.accessor(DOMMatrix.getF, DOMMatrix.setF, .{});

    pub const m11 = bridge.accessor(getM(0), setM(0), .{});
    pub const m12 = bridge.accessor(getM(1), setM(1), .{});
    pub const m13 = bridge.accessor(getM(2), setM(2), .{});
    pub const m14 = bridge.accessor(getM(3), setM(3), .{});
    pub const m21 = bridge.accessor(getM(4), setM(4), .{});
    pub const m22 = bridge.accessor(getM(5), setM(5), .{});
    pub const m23 = bridge.accessor(getM(6), setM(6), .{});
    pub const m24 = bridge.accessor(getM(7), setM(7), .{});
    pub const m31 = bridge.accessor(getM(8), setM(8), .{});
    pub const m32 = bridge.accessor(getM(9), setM(9), .{});
    pub const m33 = bridge.accessor(getM(10), setM(10), .{});
    pub const m34 = bridge.accessor(getM(11), setM(11), .{});
    pub const m41 = bridge.accessor(getM(12), setM(12), .{});
    pub const m42 = bridge.accessor(getM(13), setM(13), .{});
    pub const m43 = bridge.accessor(getM(14), setM(14), .{});
    pub const m44 = bridge.accessor(getM(15), setM(15), .{});

    pub const translateSelf = bridge.function(DOMMatrix.translateSelf, .{});
    pub const scaleSelf = bridge.function(DOMMatrix.scaleSelf, .{});
    pub const scale3dSelf = bridge.function(DOMMatrix.scale3dSelf, .{});
    pub const rotateSelf = bridge.function(DOMMatrix.rotateSelf, .{});
    pub const rotateFromVectorSelf = bridge.function(DOMMatrix.rotateFromVectorSelf, .{});
    pub const rotateAxisAngleSelf = bridge.function(DOMMatrix.rotateAxisAngleSelf, .{});
    pub const skewXSelf = bridge.function(DOMMatrix.skewXSelf, .{});
    pub const skewYSelf = bridge.function(DOMMatrix.skewYSelf, .{});
    pub const multiplySelf = bridge.function(DOMMatrix.multiplySelf, .{});
    pub const preMultiplySelf = bridge.function(DOMMatrix.preMultiplySelf, .{});
    pub const invertSelf = bridge.function(DOMMatrix.invertSelf, .{});
    // setMatrixValue parses a CSS transform string; Window-only.
    pub const setMatrixValue = bridge.function(DOMMatrix.setMatrixValue, .{ .dom_exception = true, .exposed = .window });

    fn getM(comptime idx: usize) fn (*const DOMMatrix) f64 {
        return struct {
            fn get(self: *const DOMMatrix) f64 {
                return self._proto._m[idx];
            }
        }.get;
    }

    fn setM(comptime idx: usize) fn (*DOMMatrix, f64) void {
        return struct {
            fn set(self: *DOMMatrix, v: f64) void {
                self._proto._m[idx] = v;
                // Assigning a z/w element a value other than its identity drops the
                // 2D flag. Setting it back to the identity value (0 for the
                // off-diagonal elements, 1 for m33/m44) preserves is2D. Note `-0`
                // compares equal to `0`, so it preserves it too, per spec.
                switch (idx) {
                    2, 3, 6, 7, 8, 9, 11, 14 => if (v != 0) {
                        self._proto._is_2d = false;
                    },
                    10, 15 => if (v != 1) {
                        self._proto._is_2d = false;
                    },
                    else => {},
                }
            }
        }.set;
    }
};

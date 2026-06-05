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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMMatrix = @import("DOMMatrix.zig");

const Allocator = std.mem.Allocator;

const DOMMatrixReadOnly = @This();

pub const _prototype_root = true;

_type: Type,
_rc: lp.RC(u8),
_arena: Allocator,

// Stored column-major, matching the spec's mAB naming where A is the column
// and B is the row:
//   _m[0.._4]   = m11, m12, m13, m14   (first column)
//   _m[4.._8]   = m21, m22, m23, m24
//   _m[8..12]   = m31, m32, m33, m34
//   _m[12..16]  = m41, m42, m43, m44
//
// A point (x, y, z, w) is transformed as:
//   out[row] = sum_col _m[col*4 + row] * in[col]
_m: [16]f64,
_is_2d: bool,

pub const Type = union(enum) {
    generic,
    mutable: *DOMMatrix,
};

pub fn init(init_: ?js.Value, exec: *const js.Execution) !*DOMMatrixReadOnly {
    const parsed = try Parsed.init(init_, exec);
    return createBare(parsed.m, parsed.is_2d, exec.page);
}

pub fn deinit(self: *DOMMatrixReadOnly, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *DOMMatrixReadOnly) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DOMMatrixReadOnly, page: *Page) void {
    self._rc.release(self, page);
}

pub fn createBare(m: [16]f64, is_2d: bool, page: *Page) !*DOMMatrixReadOnly {
    const arena = try page.getArena(.tiny, "DOMMatrix");
    errdefer page.releaseArena(arena);

    const self = try arena.create(DOMMatrixReadOnly);
    self.* = .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._m = m,
        ._is_2d = is_2d,
    };
    return self;
}

pub const DOMMatrixInit = struct {
    a: ?f64 = null,
    b: ?f64 = null,
    c: ?f64 = null,
    d: ?f64 = null,
    e: ?f64 = null,
    f: ?f64 = null,
    m11: ?f64 = null,
    m12: ?f64 = null,
    m13: ?f64 = null,
    m14: ?f64 = null,
    m21: ?f64 = null,
    m22: ?f64 = null,
    m23: ?f64 = null,
    m24: ?f64 = null,
    m31: ?f64 = null,
    m32: ?f64 = null,
    m33: ?f64 = null,
    m34: ?f64 = null,
    m41: ?f64 = null,
    m42: ?f64 = null,
    m43: ?f64 = null,
    m44: ?f64 = null,
    is2D: ?bool = null,
};

// Implements "validate and fixup a DOMMatrixInit dictionary".
pub fn fixupDict(d: DOMMatrixInit) !Parsed {
    if (aliasConflict(d.m11, d.a) or aliasConflict(d.m12, d.b) or
        aliasConflict(d.m21, d.c) or aliasConflict(d.m22, d.d) or
        aliasConflict(d.m41, d.e) or aliasConflict(d.m42, d.f))
    {
        return error.TypeError;
    }

    // An explicit is2D:true is incompatible with any 3D member being set.
    if (d.is2D) |is_2d| {
        if (is_2d and has3dMembers(d)) {
            return error.TypeError;
        }
    }

    const m: [16]f64 = .{
        d.m11 orelse d.a orelse 1, d.m12 orelse d.b orelse 0, d.m13 orelse 0, d.m14 orelse 0,
        d.m21 orelse d.c orelse 0, d.m22 orelse d.d orelse 1, d.m23 orelse 0, d.m24 orelse 0,
        d.m31 orelse 0,            d.m32 orelse 0,            d.m33 orelse 1, d.m34 orelse 0,
        d.m41 orelse d.e orelse 0, d.m42 orelse d.f orelse 0, d.m43 orelse 0, d.m44 orelse 1,
    };

    const is_2d = d.is2D orelse !has3dMembers(d);
    return .{ .m = m, .is_2d = is_2d };
}

// Builds a matrix from a 6- or 16-element float sequence (toFloat*Array order).
pub fn floatsToParsed(comptime T: type, values: []const T) !Parsed {
    var m = identity();
    if (values.len == 6) {
        m = .{
            values[0], values[1], 0, 0,
            values[2], values[3], 0, 0,
            0,         0,         1, 0,
            values[4], values[5], 0, 1,
        };
        return .{ .m = m, .is_2d = true };
    }

    if (values.len == 16) {
        for (0..16) |i| m[i] = values[i];
        return .{ .m = m, .is_2d = false };
    }

    return error.TypeError;
}

pub fn fromMatrix(other_: ?DOMMatrixInit, page: *Page) !*DOMMatrixReadOnly {
    const parsed = try fixupDict(other_ orelse .{});
    return createBare(parsed.m, parsed.is_2d, page);
}

pub fn fromFloat32Array(array: js.TypedArray(f32), page: *Page) !*DOMMatrixReadOnly {
    const parsed = try floatsToParsed(f32, array.values);
    return createBare(parsed.m, parsed.is_2d, page);
}

pub fn fromFloat64Array(array: js.TypedArray(f64), page: *Page) !*DOMMatrixReadOnly {
    const parsed = try floatsToParsed(f64, array.values);
    return createBare(parsed.m, parsed.is_2d, page);
}

pub fn identity() [16]f64 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

// Returns lhs * rhs (composition: applying the result is lhs(rhs(point))).
pub fn multiplyMatrix(lhs: [16]f64, rhs: [16]f64) [16]f64 {
    var out: [16]f64 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f64 = 0;
            for (0..4) |k| {
                sum += lhs[k * 4 + row] * rhs[col * 4 + k];
            }
            out[col * 4 + row] = sum;
        }
    }
    return out;
}

pub fn translationMatrix(tx: f64, ty: f64, tz: f64) [16]f64 {
    return .{
        1,  0,  0,  0,
        0,  1,  0,  0,
        0,  0,  1,  0,
        tx, ty, tz, 1,
    };
}

pub fn scaleMatrix(sx: f64, sy: f64, sz: f64) [16]f64 {
    return .{
        sx, 0,  0,  0,
        0,  sy, 0,  0,
        0,  0,  sz, 0,
        0,  0,  0,  1,
    };
}

pub fn rotateZMatrix(rad: f64) [16]f64 {
    const c = @cos(rad);
    const s = @sin(rad);
    return .{
        c,  s, 0, 0,
        -s, c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    };
}

pub fn rotateXMatrix(rad: f64) [16]f64 {
    const c = @cos(rad);
    const s = @sin(rad);
    return .{
        1, 0,  0, 0,
        0, c,  s, 0,
        0, -s, c, 0,
        0, 0,  0, 1,
    };
}

pub fn rotateYMatrix(rad: f64) [16]f64 {
    const c = @cos(rad);
    const s = @sin(rad);
    return .{
        c, 0, -s, 0,
        0, 1, 0,  0,
        s, 0, c,  0,
        0, 0, 0,  1,
    };
}

// Rotation by `rad` about the (possibly unnormalised) axis (x, y, z).
pub fn axisAngleMatrix(x_in: f64, y_in: f64, z_in: f64, rad: f64) [16]f64 {
    var x = x_in;
    var y = y_in;
    var z = z_in;
    const len = @sqrt(x * x + y * y + z * z);
    if (len == 0) {
        return identity();
    }

    x /= len;
    y /= len;
    z /= len;
    const c = @cos(rad);
    const s = @sin(rad);
    const t = 1 - c;
    return .{
        t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0,
        t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0,
        t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0,
        0,                 0,                 0,                 1,
    };
}

pub fn skewMatrix(ax_rad: f64, ay_rad: f64) [16]f64 {
    return .{
        1,            @tan(ay_rad), 0, 0,
        @tan(ax_rad), 1,            0, 0,
        0,            0,            1, 0,
        0,            0,            0, 1,
    };
}

// Inverse of a 4x4 matrix; returns null if non-invertible.
pub fn invertMatrix(m: [16]f64) ?[16]f64 {
    var inv: [16]f64 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    var det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (det == 0) {
        return null;
    }
    det = 1.0 / det;

    var out: [16]f64 = undefined;
    for (0..16) |i| {
        out[i] = inv[i] * det;
    }
    return out;
}

// Parses a CSS <transform-list> (e.g. "matrix(1,0,0,1,10,20) scale(2)") and
// accumulates it into `m`. "none"/empty leave the matrix as identity.
pub fn parseTransformList(input: []const u8, m: *[16]f64, is_2d: *bool) !void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) {
        return;
    }

    var i: usize = 0;
    while (i < trimmed.len) {
        // skip whitespace and separating commas
        while (i < trimmed.len and (std.ascii.isWhitespace(trimmed[i]) or trimmed[i] == ',')) : (i += 1) {}
        if (i >= trimmed.len) {
            break;
        }

        const name_start = i;
        while (i < trimmed.len and trimmed[i] != '(') : (i += 1) {}
        if (i >= trimmed.len) {
            return error.SyntaxError;
        }
        const name = std.mem.trim(u8, trimmed[name_start..i], " \t\r\n");

        i += 1; // consume '('
        const args_start = i;
        while (i < trimmed.len and trimmed[i] != ')') : (i += 1) {}
        if (i >= trimmed.len) {
            return error.SyntaxError;
        }
        const args = trimmed[args_start..i];
        i += 1; // consume ')'

        const func = try parseFunction(name, args, is_2d);
        m.* = multiplyMatrix(m.*, func);
    }
}

fn parseFunction(name: []const u8, args: []const u8, is_2d: *bool) ![16]f64 {
    var nums: [16]f64 = undefined;
    var units: [16]ParsedValue.Unit = undefined;
    var count: usize = 0;

    var it = std.mem.splitScalar(u8, args, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t\r\n");
        if (tok.len == 0) {
            continue;
        }
        if (count >= 16) {
            return error.SyntaxError;
        }
        const parsed = try ParsedValue.parse(tok);
        nums[count] = parsed.value;
        units[count] = parsed.unit;
        count += 1;
    }

    const Eql = std.mem.eql;
    if (Eql(u8, name, "matrix")) {
        if (count != 6) {
            return error.SyntaxError;
        }
        return .{
            nums[0], nums[1], 0, 0,
            nums[2], nums[3], 0, 0,
            0,       0,       1, 0,
            nums[4], nums[5], 0, 1,
        };
    }

    if (Eql(u8, name, "matrix3d")) {
        if (count != 16) {
            return error.SyntaxError;
        }
        is_2d.* = false;
        return nums;
    }

    if (Eql(u8, name, "translate")) {
        const tx = nums[0];
        const ty = if (count > 1) nums[1] else 0;
        return translationMatrix(tx, ty, 0);
    }

    if (Eql(u8, name, "translateX")) {
        return translationMatrix(nums[0], 0, 0);
    }

    if (Eql(u8, name, "translateY")) {
        return translationMatrix(0, nums[0], 0);
    }

    if (Eql(u8, name, "translateZ")) {
        is_2d.* = false;
        return translationMatrix(0, 0, nums[0]);
    }

    if (Eql(u8, name, "translate3d")) {
        is_2d.* = false;
        return translationMatrix(nums[0], nums[1], nums[2]);
    }

    if (Eql(u8, name, "scale")) {
        const sx = nums[0];
        const sy = if (count > 1) nums[1] else sx;
        return scaleMatrix(sx, sy, 1);
    }

    if (Eql(u8, name, "scaleX")) {
        return scaleMatrix(nums[0], 1, 1);
    }

    if (Eql(u8, name, "scaleY")) {
        return scaleMatrix(1, nums[0], 1);
    }

    if (Eql(u8, name, "scaleZ")) {
        is_2d.* = false;
        return scaleMatrix(1, 1, nums[0]);
    }

    if (Eql(u8, name, "scale3d")) {
        is_2d.* = false;
        return scaleMatrix(nums[0], nums[1], nums[2]);
    }
    if (Eql(u8, name, "rotate") or Eql(u8, name, "rotateZ")) {
        if (Eql(u8, name, "rotateZ")) is_2d.* = false;
        return rotateZMatrix(toRadians(nums[0], units[0]));
    }

    if (Eql(u8, name, "rotateX")) {
        is_2d.* = false;
        return rotateXMatrix(toRadians(nums[0], units[0]));
    }

    if (Eql(u8, name, "rotateY")) {
        is_2d.* = false;
        return rotateYMatrix(toRadians(nums[0], units[0]));
    }

    if (Eql(u8, name, "rotate3d")) {
        is_2d.* = false;
        if (count != 4) {
            return error.SyntaxError;
        }
        return axisAngleMatrix(nums[0], nums[1], nums[2], toRadians(nums[3], units[3]));
    }

    if (Eql(u8, name, "skew")) {
        const ax = toRadians(nums[0], units[0]);
        const ay = if (count > 1) toRadians(nums[1], units[1]) else 0;
        return skewMatrix(ax, ay);
    }

    if (Eql(u8, name, "skewX")) {
        return skewMatrix(toRadians(nums[0], units[0]), 0);
    }

    if (Eql(u8, name, "skewY")) {
        return skewMatrix(0, toRadians(nums[0], units[0]));
    }

    if (Eql(u8, name, "perspective")) {
        is_2d.* = false;
        var out = identity();
        if (nums[0] != 0) out[11] = -1.0 / nums[0];
        return out;
    }

    return error.SyntaxError;
}

pub fn toRadians(value: f64, unit: ParsedValue.Unit) f64 {
    return switch (unit) {
        .rad => value,
        .grad => value * std.math.pi / 200.0,
        .turn => value * std.math.tau,
        // bare numbers in rotate()/skew() are interpreted as degrees
        .deg, .none => value * std.math.pi / 180.0,
    };
}

pub fn getA(self: *const DOMMatrixReadOnly) f64 {
    return self._m[0];
}
pub fn getB(self: *const DOMMatrixReadOnly) f64 {
    return self._m[1];
}
pub fn getC(self: *const DOMMatrixReadOnly) f64 {
    return self._m[4];
}
pub fn getD(self: *const DOMMatrixReadOnly) f64 {
    return self._m[5];
}
pub fn getE(self: *const DOMMatrixReadOnly) f64 {
    return self._m[12];
}
pub fn getF(self: *const DOMMatrixReadOnly) f64 {
    return self._m[13];
}

pub fn getIs2D(self: *const DOMMatrixReadOnly) bool {
    return self._is_2d;
}

pub fn getIsIdentity(self: *const DOMMatrixReadOnly) bool {
    const id = identity();
    for (0..16) |i| {
        if (self._m[i] != id[i]) {
            return false;
        }
    }
    return true;
}

pub fn translate(self: *const DOMMatrixReadOnly, tx_: ?f64, ty_: ?f64, tz_: ?f64, page: *Page) !*DOMMatrix {
    const tz = tz_ orelse 0;
    return DOMMatrix.create(
        multiplyMatrix(self._m, translationMatrix(tx_ orelse 0, ty_ orelse 0, tz)),
        self._is_2d and tz == 0,
        page,
    );
}

pub fn scale(self: *const DOMMatrixReadOnly, sx_: ?f64, sy_: ?f64, sz_: ?f64, ox_: ?f64, oy_: ?f64, oz_: ?f64, page: *Page) !*DOMMatrix {
    const sx = sx_ orelse 1;
    const sy = sy_ orelse sx;
    const sz = sz_ orelse 1;
    const ox = ox_ orelse 0;
    const oy = oy_ orelse 0;
    const oz = oz_ orelse 0;
    var m = multiplyMatrix(self._m, translationMatrix(ox, oy, oz));
    m = multiplyMatrix(m, scaleMatrix(sx, sy, sz));
    m = multiplyMatrix(m, translationMatrix(-ox, -oy, -oz));
    return DOMMatrix.create(m, self._is_2d and sz == 1 and oz == 0, page);
}

pub fn scaleNonUniform(self: *const DOMMatrixReadOnly, sx_: ?f64, sy_: ?f64, page: *Page) !*DOMMatrix {
    const sx = sx_ orelse 1;
    const sy = sy_ orelse 1;
    return DOMMatrix.create(multiplyMatrix(self._m, scaleMatrix(sx, sy, 1)), self._is_2d, page);
}

pub fn scale3d(self: *const DOMMatrixReadOnly, scale_: ?f64, ox_: ?f64, oy_: ?f64, oz_: ?f64, page: *Page) !*DOMMatrix {
    const s = scale_ orelse 1;
    const ox = ox_ orelse 0;
    const oy = oy_ orelse 0;
    const oz = oz_ orelse 0;
    var m = multiplyMatrix(self._m, translationMatrix(ox, oy, oz));
    m = multiplyMatrix(m, scaleMatrix(s, s, s));
    m = multiplyMatrix(m, translationMatrix(-ox, -oy, -oz));
    return DOMMatrix.create(m, self._is_2d and s == 1, page);
}

pub fn rotate(self: *const DOMMatrixReadOnly, rx_: ?f64, ry_: ?f64, rz_: ?f64, page: *Page) !*DOMMatrix {
    var out = self._m;
    var is_2d = self._is_2d;
    // With a single argument, it is the Z rotation.
    if (ry_ == null and rz_ == null) {
        out = multiplyMatrix(out, rotateZMatrix(toRadians(rx_ orelse 0, .deg)));
    } else {
        out = multiplyMatrix(out, rotateXMatrix(toRadians(rx_ orelse 0, .deg)));
        out = multiplyMatrix(out, rotateYMatrix(toRadians(ry_ orelse 0, .deg)));
        out = multiplyMatrix(out, rotateZMatrix(toRadians(rz_ orelse 0, .deg)));
        is_2d = false;
    }
    return DOMMatrix.create(out, is_2d, page);
}

pub fn rotateFromVector(self: *const DOMMatrixReadOnly, x_: ?f64, y_: ?f64, page: *Page) !*DOMMatrix {
    const x = x_ orelse 0;
    const y = y_ orelse 0;
    const rad = if (x == 0 and y == 0) 0 else std.math.atan2(y, x);
    return DOMMatrix.create(multiplyMatrix(self._m, rotateZMatrix(rad)), self._is_2d, page);
}

pub fn rotateAxisAngle(self: *const DOMMatrixReadOnly, x_: ?f64, y_: ?f64, z_: ?f64, angle_: ?f64, page: *Page) !*DOMMatrix {
    return DOMMatrix.create(
        multiplyMatrix(self._m, axisAngleMatrix(x_ orelse 0, y_ orelse 0, z_ orelse 0, toRadians(angle_ orelse 0, .deg))),
        // Only a rotation purely about the z axis stays 2D.
        self._is_2d and (x_ orelse 0) == 0 and (y_ orelse 0) == 0,
        page,
    );
}

pub fn skewX(self: *const DOMMatrixReadOnly, sx_: ?f64, page: *Page) !*DOMMatrix {
    return DOMMatrix.create(multiplyMatrix(self._m, skewMatrix(toRadians(sx_ orelse 0, .deg), 0)), self._is_2d, page);
}

pub fn skewY(self: *const DOMMatrixReadOnly, sy_: ?f64, page: *Page) !*DOMMatrix {
    return DOMMatrix.create(multiplyMatrix(self._m, skewMatrix(0, toRadians(sy_ orelse 0, .deg))), self._is_2d, page);
}

pub fn multiply(self: *const DOMMatrixReadOnly, other_: ?DOMMatrixInit, page: *Page) !*DOMMatrix {
    const other = try fixupDict(other_ orelse .{});
    return DOMMatrix.create(multiplyMatrix(self._m, other.m), self._is_2d and other.is_2d, page);
}

pub fn flipX(self: *const DOMMatrixReadOnly, page: *Page) !*DOMMatrix {
    return DOMMatrix.create(multiplyMatrix(self._m, scaleMatrix(-1, 1, 1)), self._is_2d, page);
}

pub fn flipY(self: *const DOMMatrixReadOnly, page: *Page) !*DOMMatrix {
    return DOMMatrix.create(multiplyMatrix(self._m, scaleMatrix(1, -1, 1)), self._is_2d, page);
}

pub fn inverse(self: *const DOMMatrixReadOnly, page: *Page) !*DOMMatrix {
    if (invertMatrix(self._m)) |v| {
        return DOMMatrix.create(v, self._is_2d, page);
    }
    // Non-invertible matrices become all-NaN with is2D = false.
    return DOMMatrix.create(.{std.math.nan(f64)} ** 16, false, page);
}

pub fn toFloat32Array(self: *const DOMMatrixReadOnly, exec: *const js.Execution) !js.TypedArray(f32) {
    const out = try exec.call_arena.alloc(f32, 16);
    for (0..16) |i| {
        out[i] = @floatCast(self._m[i]);
    }
    return .{ .values = out };
}

pub fn toFloat64Array(self: *const DOMMatrixReadOnly, exec: *const js.Execution) !js.TypedArray(f64) {
    const out = try exec.call_arena.dupe(f64, &self._m);
    return .{ .values = out };
}

pub fn toString(self: *const DOMMatrixReadOnly, exec: *const js.Execution) ![]const u8 {
    const m = self._m;
    if (self._is_2d) {
        // Per the stringifier: throw if any serialized component is non-finite.
        for ([_]f64{ m[0], m[1], m[4], m[5], m[12], m[13] }) |v| {
            if (!std.math.isFinite(v)) {
                return error.InvalidStateError;
            }
        }
        return std.fmt.allocPrint(exec.call_arena, "matrix({d}, {d}, {d}, {d}, {d}, {d})", .{
            m[0], m[1], m[4], m[5], m[12], m[13],
        });
    }
    for (m) |v| {
        if (!std.math.isFinite(v)) {
            return error.InvalidStateError;
        }
    }
    return std.fmt.allocPrint(exec.call_arena, "matrix3d({d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d})", .{
        m[0],  m[1],  m[2],  m[3],
        m[4],  m[5],  m[6],  m[7],
        m[8],  m[9],  m[10], m[11],
        m[12], m[13], m[14], m[15],
    });
}

fn aliasConflict(x: ?f64, y: ?f64) bool {
    const a = x orelse return false;
    const b = y orelse return false;
    if (std.math.isNan(a) and std.math.isNan(b)) {
        return false;
    }
    return a != b;
}

// True when the dict specifies any 3D-only member away from its identity value.
fn has3dMembers(d: DOMMatrixInit) bool {
    return (d.m13 orelse 0) != 0 or (d.m14 orelse 0) != 0 or
        (d.m23 orelse 0) != 0 or (d.m24 orelse 0) != 0 or
        (d.m31 orelse 0) != 0 or (d.m32 orelse 0) != 0 or
        (d.m34 orelse 0) != 0 or (d.m43 orelse 0) != 0 or
        (d.m33 orelse 1) != 1 or (d.m44 orelse 1) != 1;
}

pub const Parsed = struct {
    m: [16]f64,
    is_2d: bool,

    pub fn init(init_: ?js.Value, exec: *const js.Execution) !Parsed {
        var m: [16]f64 = identity();
        var is_2d = true;

        if (init_) |in| {
            if (!in.isUndefined()) {
                if (in.isArray()) {
                    try sequenceToMatrix(in.toArray(), &m, &is_2d);
                } else {
                    // Per WebIDL the union is `(DOMString or sequence)`: a value
                    // that isn't a sequence is converted to a DOMString. So a
                    // string parses directly, and any other value (a number, null,
                    // or another matrix) is stringified first — which is how
                    // `new DOMMatrix(otherMatrix)` round-trips via its
                    // matrix()/matrix3d() serialization.
                    if (exec.js.global == .worker) {
                        return error.TypeError;
                    }
                    const str = try in.toStringSmart();
                    try parseTransformList(str, &m, &is_2d);
                }
            }
        }

        return .{ .m = m, .is_2d = is_2d };
    }
};

const ParsedValue = struct {
    value: f64,
    unit: Unit,

    const Unit = enum {
        none,
        deg,
        rad,
        grad,
        turn,
    };

    // Parses a single CSS dimension token: a number with an optional unit suffix.
    // Length units are ignored (we don't resolve layout), so the numeric part is
    // taken verbatim; angle units are recorded so they can be normalised.
    fn parse(tok: []const u8) !ParsedValue {
        var end: usize = 0;
        while (end < tok.len) : (end += 1) {
            const c = tok[end];
            if ((c >= '0' and c <= '9') or c == '.' or c == '+' or c == '-' or c == 'e' or c == 'E') {
                // 'e'/'E' is ambiguous with exponents; only treat as exponent when
                // followed by a digit/sign.
                if ((c == 'e' or c == 'E') and end > 0) {
                    if (end + 1 >= tok.len) break;
                    const nx = tok[end + 1];
                    if (!((nx >= '0' and nx <= '9') or nx == '+' or nx == '-')) break;
                }
                continue;
            }
            break;
        }
        if (end == 0) {
            return error.SyntaxError;
        }
        const value = try std.fmt.parseFloat(f64, tok[0..end]);
        const suffix = tok[end..];

        var unit: Unit = .none;
        if (std.ascii.eqlIgnoreCase(suffix, "deg")) {
            unit = .deg;
        } else if (std.ascii.eqlIgnoreCase(suffix, "rad")) {
            unit = .rad;
        } else if (std.ascii.eqlIgnoreCase(suffix, "grad")) {
            unit = .grad;
        } else if (std.ascii.eqlIgnoreCase(suffix, "turn")) {
            unit = .turn;
        }
        return .{ .value = value, .unit = unit };
    }
};

fn sequenceToMatrix(arr: js.Array, m: *[16]f64, is_2d: *bool) !void {
    const n = arr.len();
    if (n == 6) {
        // matrix(a, b, c, d, e, f)
        var v: [6]f64 = undefined;
        for (0..6) |i| {
            v[i] = try (try arr.get(@intCast(i))).toF64();
        }
        m.* = .{
            v[0], v[1], 0, 0,
            v[2], v[3], 0, 0,
            0,    0,    1, 0,
            v[4], v[5], 0, 1,
        };
        is_2d.* = true;
        return;
    }

    if (n == 16) {
        for (0..16) |i| {
            m[i] = try (try arr.get(@intCast(i))).toF64();
        }
        is_2d.* = false;
        return;
    }
    return error.TypeError;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMMatrixReadOnly);

    pub const Meta = struct {
        pub const name = "DOMMatrixReadOnly";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMMatrixReadOnly.init, .{ .dom_exception = true });

    pub const fromMatrix = bridge.function(DOMMatrixReadOnly.fromMatrix, .{ .static = true });
    pub const fromFloat32Array = bridge.function(DOMMatrixReadOnly.fromFloat32Array, .{ .static = true });
    pub const fromFloat64Array = bridge.function(DOMMatrixReadOnly.fromFloat64Array, .{ .static = true });

    pub const a = bridge.accessor(DOMMatrixReadOnly.getA, null, .{});
    pub const b = bridge.accessor(DOMMatrixReadOnly.getB, null, .{});
    pub const c = bridge.accessor(DOMMatrixReadOnly.getC, null, .{});
    pub const d = bridge.accessor(DOMMatrixReadOnly.getD, null, .{});
    pub const e = bridge.accessor(DOMMatrixReadOnly.getE, null, .{});
    pub const f = bridge.accessor(DOMMatrixReadOnly.getF, null, .{});

    pub const m11 = bridge.accessor(getM(0), null, .{});
    pub const m12 = bridge.accessor(getM(1), null, .{});
    pub const m13 = bridge.accessor(getM(2), null, .{});
    pub const m14 = bridge.accessor(getM(3), null, .{});
    pub const m21 = bridge.accessor(getM(4), null, .{});
    pub const m22 = bridge.accessor(getM(5), null, .{});
    pub const m23 = bridge.accessor(getM(6), null, .{});
    pub const m24 = bridge.accessor(getM(7), null, .{});
    pub const m31 = bridge.accessor(getM(8), null, .{});
    pub const m32 = bridge.accessor(getM(9), null, .{});
    pub const m33 = bridge.accessor(getM(10), null, .{});
    pub const m34 = bridge.accessor(getM(11), null, .{});
    pub const m41 = bridge.accessor(getM(12), null, .{});
    pub const m42 = bridge.accessor(getM(13), null, .{});
    pub const m43 = bridge.accessor(getM(14), null, .{});
    pub const m44 = bridge.accessor(getM(15), null, .{});

    pub const is2D = bridge.accessor(DOMMatrixReadOnly.getIs2D, null, .{});
    pub const isIdentity = bridge.accessor(DOMMatrixReadOnly.getIsIdentity, null, .{});

    pub const translate = bridge.function(DOMMatrixReadOnly.translate, .{});
    pub const scale = bridge.function(DOMMatrixReadOnly.scale, .{});
    pub const scaleNonUniform = bridge.function(DOMMatrixReadOnly.scaleNonUniform, .{});
    pub const scale3d = bridge.function(DOMMatrixReadOnly.scale3d, .{});
    pub const rotate = bridge.function(DOMMatrixReadOnly.rotate, .{});
    pub const rotateFromVector = bridge.function(DOMMatrixReadOnly.rotateFromVector, .{});
    pub const rotateAxisAngle = bridge.function(DOMMatrixReadOnly.rotateAxisAngle, .{});
    pub const skewX = bridge.function(DOMMatrixReadOnly.skewX, .{});
    pub const skewY = bridge.function(DOMMatrixReadOnly.skewY, .{});
    pub const multiply = bridge.function(DOMMatrixReadOnly.multiply, .{});
    pub const flipX = bridge.function(DOMMatrixReadOnly.flipX, .{});
    pub const flipY = bridge.function(DOMMatrixReadOnly.flipY, .{});
    pub const inverse = bridge.function(DOMMatrixReadOnly.inverse, .{});
    pub const toFloat32Array = bridge.function(DOMMatrixReadOnly.toFloat32Array, .{});
    pub const toFloat64Array = bridge.function(DOMMatrixReadOnly.toFloat64Array, .{});
    // The stringifier depends on CSS serialization and is Window-only.
    pub const toString = bridge.function(DOMMatrixReadOnly.toString, .{ .dom_exception = true, .exposed = .window });

    // m11..m44 getters are generated from the storage index.
    fn getM(comptime idx: usize) fn (*const DOMMatrixReadOnly) f64 {
        return struct {
            fn get(self: *const DOMMatrixReadOnly) f64 {
                return self._m[idx];
            }
        }.get;
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DOMMatrixReadOnly" {
    try testing.htmlRunner("dommatrix.html", .{});
}

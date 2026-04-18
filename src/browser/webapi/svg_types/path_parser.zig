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

const std = @import("std");

pub const BBox = struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,

    pub fn width(self: BBox) f64 {
        return self.max_x - self.min_x;
    }

    pub fn height(self: BBox) f64 {
        return self.max_y - self.min_y;
    }

    pub fn empty() BBox {
        return .{
            .min_x = std.math.inf(f64),
            .min_y = std.math.inf(f64),
            .max_x = -std.math.inf(f64),
            .max_y = -std.math.inf(f64),
        };
    }

    pub fn extend(self: *BBox, x: f64, y: f64) void {
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, x);
        self.max_y = @max(self.max_y, y);
    }

    pub fn merge(self: *BBox, other: BBox) void {
        self.min_x = @min(self.min_x, other.min_x);
        self.min_y = @min(self.min_y, other.min_y);
        self.max_x = @max(self.max_x, other.max_x);
        self.max_y = @max(self.max_y, other.max_y);
    }
};

const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    fn skipWsp(self: *Parser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',')
                self.pos += 1
            else
                break;
        }
    }

    fn parseNumber(self: *Parser) ?f64 {
        self.skipWsp();
        const start = self.pos;
        if (self.pos >= self.data.len) return null;
        if (self.data[self.pos] == '+' or self.data[self.pos] == '-') self.pos += 1;
        var has_digits = false;
        while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
            self.pos += 1;
            has_digits = true;
        }
        if (self.pos < self.data.len and self.data[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
                self.pos += 1;
                has_digits = true;
            }
        }
        if (!has_digits) {
            self.pos = start;
            return null;
        }
        if (self.pos < self.data.len and (self.data[self.pos] == 'e' or self.data[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.data.len and (self.data[self.pos] == '+' or self.data[self.pos] == '-'))
                self.pos += 1;
            while (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9')
                self.pos += 1;
        }
        return std.fmt.parseFloat(f64, self.data[start..self.pos]) catch null;
    }

    fn parseFlag(self: *Parser) ?f64 {
        self.skipWsp();
        if (self.pos < self.data.len and (self.data[self.pos] == '0' or self.data[self.pos] == '1')) {
            const v: f64 = if (self.data[self.pos] == '1') 1.0 else 0.0;
            self.pos += 1;
            return v;
        }
        return null;
    }
};

fn solveQuadratic(a: f64, b: f64, c: f64) [2]?f64 {
    const eps = 1e-12;
    if (@abs(a) < eps) {
        if (@abs(b) < eps) return .{ null, null };
        return .{ -c / b, null };
    }
    const disc = b * b - 4 * a * c;
    if (disc < 0) return .{ null, null };
    const sq = @sqrt(disc);
    return .{ (-b + sq) / (2 * a), (-b - sq) / (2 * a) };
}

fn evalCubic(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const it = 1 - t;
    return it * it * it * p0 + 3 * it * it * t * p1 + 3 * it * t * t * p2 + t * t * t * p3;
}

fn cubicBBox(bbox: *BBox, p0x: f64, p0y: f64, p1x: f64, p1y: f64, p2x: f64, p2y: f64, p3x: f64, p3y: f64) void {
    bbox.extend(p0x, p0y);
    bbox.extend(p3x, p3y);
    const px = [4]f64{ p0x, p1x, p2x, p3x };
    const py = [4]f64{ p0y, p1y, p2y, p3y };
    const arrs = [2][4]f64{ px, py };
    for (arrs, 0..) |p, axis| {
        const a = -p[0] + 3 * p[1] - 3 * p[2] + p[3];
        const b_coeff = 2 * (p[0] - 2 * p[1] + p[2]);
        const c_coeff = p[1] - p[0];
        const roots = solveQuadratic(a, b_coeff, c_coeff);
        for (roots) |mr| {
            if (mr) |t| {
                if (t > 0 and t < 1) {
                    const val = evalCubic(p[0], p[1], p[2], p[3], t);
                    if (axis == 0) bbox.extend(val, bbox.min_y) else bbox.extend(bbox.min_x, val);
                }
            }
        }
    }
}

fn quadBBox(bbox: *BBox, p0x: f64, p0y: f64, p1x: f64, p1y: f64, p2x: f64, p2y: f64) void {
    bbox.extend(p0x, p0y);
    bbox.extend(p2x, p2y);
    const px = [3]f64{ p0x, p1x, p2x };
    const py = [3]f64{ p0y, p1y, p2y };
    const arrs = [2][3]f64{ px, py };
    for (arrs, 0..) |p, axis| {
        const denom = p[0] - 2 * p[1] + p[2];
        if (@abs(denom) > 1e-12) {
            const t = (p[0] - p[1]) / denom;
            if (t > 0 and t < 1) {
                const it = 1 - t;
                const val = it * it * p[0] + 2 * it * t * p[1] + t * t * p[2];
                if (axis == 0) bbox.extend(val, bbox.min_y) else bbox.extend(bbox.min_x, val);
            }
        }
    }
}

fn arcBBox(bbox: *BBox, x1: f64, y1: f64, rx_in: f64, ry_in: f64, phi_deg: f64, fa: f64, fs: f64, x2: f64, y2: f64) void {
    bbox.extend(x1, y1);
    bbox.extend(x2, y2);
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx < 1e-12 or ry < 1e-12) return;

    const phi = phi_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    const dx = (x1 - x2) / 2.0;
    const dy = (y1 - y2) / 2.0;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
        const sl = @sqrt(lam);
        rx *= sl;
        ry *= sl;
    }

    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const x1p2 = x1p * x1p;
    const y1p2 = y1p * y1p;
    var num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
    if (num < 0) num = 0;
    const den = rx2 * y1p2 + ry2 * x1p2;
    if (den < 1e-12) return;
    var sq = @sqrt(num / den);
    if ((fa != 0) == (fs != 0)) sq = -sq;
    const cxp = sq * rx * y1p / ry;
    const cyp = -sq * ry * x1p / rx;
    const ccx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0;
    const ccy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0;

    const theta1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
    var dtheta = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - theta1;
    if (fs != 0 and dtheta < 0) dtheta += 2.0 * std.math.pi;
    if (fs == 0 and dtheta > 0) dtheta -= 2.0 * std.math.pi;

    // Check cardinal angle extrema
    const half_pi = std.math.pi / 2.0;
    const base_angles = [4]f64{ 0, half_pi, std.math.pi, -half_pi };
    for (base_angles) |base| {
        var k: i32 = -4;
        while (k <= 4) : (k += 1) {
            const candidate = base + @as(f64, @floatFromInt(k)) * std.math.pi;
            var rel = candidate - theta1;
            if (dtheta > 0) {
                while (rel < 0) rel += 2.0 * std.math.pi;
                if (rel > 0 and rel < dtheta) {
                    bbox.extend(
                        ccx + rx * @cos(candidate) * cos_phi - ry * @sin(candidate) * sin_phi,
                        ccy + rx * @cos(candidate) * sin_phi + ry * @sin(candidate) * cos_phi,
                    );
                }
            } else {
                while (rel > 0) rel -= 2.0 * std.math.pi;
                if (rel < 0 and rel > dtheta) {
                    bbox.extend(
                        ccx + rx * @cos(candidate) * cos_phi - ry * @sin(candidate) * sin_phi,
                        ccy + rx * @cos(candidate) * sin_phi + ry * @sin(candidate) * cos_phi,
                    );
                }
            }
        }
    }
}

pub fn computeBBox(path_data: []const u8) ?BBox {
    if (path_data.len == 0) return null;
    var p = Parser{ .data = path_data };
    var bbox = BBox.empty();
    var cx: f64 = 0;
    var cy: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var last_ctrl_x: f64 = 0;
    var last_ctrl_y: f64 = 0;
    var last_cmd: u8 = 0;
    var has_points = false;

    while (true) {
        p.skipWsp();
        if (p.pos >= p.data.len) break;
        var cmd = p.data[p.pos];
        const is_cmd = (cmd >= 'A' and cmd <= 'Z') or (cmd >= 'a' and cmd <= 'z');
        if (is_cmd) {
            p.pos += 1;
        } else {
            cmd = if (last_cmd == 'M') 'L' else if (last_cmd == 'm') 'l' else last_cmd;
            if (cmd == 0) break;
        }

        const rel = cmd >= 'a' and cmd <= 'z';
        const upper = if (rel) cmd - 32 else cmd;

        var first_iter = true;
        while (first_iter or p.pos < p.data.len) {
            first_iter = false;
            switch (upper) {
                'M' => {
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    cx = if (rel) cx + nx else nx;
                    cy = if (rel) cy + ny else ny;
                    sx = cx;
                    sy = cy;
                    bbox.extend(cx, cy);
                    has_points = true;
                    last_cmd = if (rel) 'm' else 'M';
                },
                'L' => {
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    cx = if (rel) cx + nx else nx;
                    cy = if (rel) cy + ny else ny;
                    bbox.extend(cx, cy);
                    has_points = true;
                    last_cmd = cmd;
                },
                'H' => {
                    const nx = p.parseNumber() orelse break;
                    cx = if (rel) cx + nx else nx;
                    bbox.extend(cx, cy);
                    has_points = true;
                    last_cmd = cmd;
                },
                'V' => {
                    const ny = p.parseNumber() orelse break;
                    cy = if (rel) cy + ny else ny;
                    bbox.extend(cx, cy);
                    has_points = true;
                    last_cmd = cmd;
                },
                'Z' => {
                    cx = sx;
                    cy = sy;
                    last_cmd = cmd;
                    break;
                },
                'C' => {
                    const x1 = p.parseNumber() orelse break;
                    const y1 = p.parseNumber() orelse break;
                    const x2 = p.parseNumber() orelse break;
                    const y2 = p.parseNumber() orelse break;
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    const ax1 = if (rel) cx + x1 else x1;
                    const ay1 = if (rel) cy + y1 else y1;
                    const ax2 = if (rel) cx + x2 else x2;
                    const ay2 = if (rel) cy + y2 else y2;
                    const ax = if (rel) cx + nx else nx;
                    const ay = if (rel) cy + ny else ny;
                    cubicBBox(&bbox, cx, cy, ax1, ay1, ax2, ay2, ax, ay);
                    last_ctrl_x = ax2;
                    last_ctrl_y = ay2;
                    cx = ax;
                    cy = ay;
                    has_points = true;
                    last_cmd = cmd;
                },
                'S' => {
                    const x2 = p.parseNumber() orelse break;
                    const y2 = p.parseNumber() orelse break;
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    const pu = if (last_cmd >= 'a' and last_cmd <= 'z') last_cmd - 32 else last_cmd;
                    const r1x = if (pu == 'C' or pu == 'S') 2 * cx - last_ctrl_x else cx;
                    const r1y = if (pu == 'C' or pu == 'S') 2 * cy - last_ctrl_y else cy;
                    const ax2 = if (rel) cx + x2 else x2;
                    const ay2 = if (rel) cy + y2 else y2;
                    const ax = if (rel) cx + nx else nx;
                    const ay = if (rel) cy + ny else ny;
                    cubicBBox(&bbox, cx, cy, r1x, r1y, ax2, ay2, ax, ay);
                    last_ctrl_x = ax2;
                    last_ctrl_y = ay2;
                    cx = ax;
                    cy = ay;
                    has_points = true;
                    last_cmd = cmd;
                },
                'Q' => {
                    const x1 = p.parseNumber() orelse break;
                    const y1 = p.parseNumber() orelse break;
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    const ax1 = if (rel) cx + x1 else x1;
                    const ay1 = if (rel) cy + y1 else y1;
                    const ax = if (rel) cx + nx else nx;
                    const ay = if (rel) cy + ny else ny;
                    quadBBox(&bbox, cx, cy, ax1, ay1, ax, ay);
                    last_ctrl_x = ax1;
                    last_ctrl_y = ay1;
                    cx = ax;
                    cy = ay;
                    has_points = true;
                    last_cmd = cmd;
                },
                'T' => {
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    const pu = if (last_cmd >= 'a' and last_cmd <= 'z') last_cmd - 32 else last_cmd;
                    const r1x = if (pu == 'Q' or pu == 'T') 2 * cx - last_ctrl_x else cx;
                    const r1y = if (pu == 'Q' or pu == 'T') 2 * cy - last_ctrl_y else cy;
                    const ax = if (rel) cx + nx else nx;
                    const ay = if (rel) cy + ny else ny;
                    quadBBox(&bbox, cx, cy, r1x, r1y, ax, ay);
                    last_ctrl_x = r1x;
                    last_ctrl_y = r1y;
                    cx = ax;
                    cy = ay;
                    has_points = true;
                    last_cmd = cmd;
                },
                'A' => {
                    const arx = p.parseNumber() orelse break;
                    const ary = p.parseNumber() orelse break;
                    const rot = p.parseNumber() orelse break;
                    const la = p.parseFlag() orelse break;
                    const sw = p.parseFlag() orelse break;
                    const nx = p.parseNumber() orelse break;
                    const ny = p.parseNumber() orelse break;
                    const ax = if (rel) cx + nx else nx;
                    const ay = if (rel) cy + ny else ny;
                    arcBBox(&bbox, cx, cy, arx, ary, rot, la, sw, ax, ay);
                    cx = ax;
                    cy = ay;
                    has_points = true;
                    last_cmd = cmd;
                },
                else => break,
            }
        }
    }

    return if (has_points) bbox else null;
}

test "rect path" {
    const bbox = computeBBox("M10,20 L30,20 L30,40 L10,40 Z").?;
    try std.testing.expectApproxEqAbs(@as(f64, 10), bbox.min_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bbox.min_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 30), bbox.max_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 40), bbox.max_y, 0.01);
}

test "relative commands" {
    const bbox = computeBBox("M10,20 l20,0 l0,20 l-20,0 z").?;
    try std.testing.expectApproxEqAbs(@as(f64, 10), bbox.min_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bbox.min_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 30), bbox.max_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 40), bbox.max_y, 0.01);
}

test "cubic bezier" {
    const bbox = computeBBox("M0,0 C0,100 100,100 100,0").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), bbox.min_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bbox.min_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100), bbox.max_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 75), bbox.max_y, 0.01);
}

test "empty path" {
    try std.testing.expect(computeBBox("") == null);
}

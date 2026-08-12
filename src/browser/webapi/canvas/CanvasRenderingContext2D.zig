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

const color = @import("../../color.zig");

const Canvas = @import("../element/html/Canvas.zig");
const ImageData = @import("../ImageData.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const TextMetrics = @import("TextMetrics.zig");

const Execution = js.Execution;

/// Fingerprint-grade 2D canvas context. Drawing commands update a stable seed
/// used by getImageData / HTMLCanvasElement.toDataURL — no real GPU raster.
const CanvasRenderingContext2D = @This();

_canvas: *Canvas,
_fill_style: color.RGBA = color.RGBA.Named.black,
/// FNV-1a running hash of drawing ops for stable fingerprints.
/// Initialized from browser fingerprint profile when the 2d context is created.
_fp_seed: u64 = 0xcbf29ce484222325,
_dirty: bool = false,
_font: [96]u8 = "10px sans-serif".* ++ .{0} ** 81,
_font_len: u8 = 15,

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn fingerprintSeed(self: *const CanvasRenderingContext2D) u64 {
    return self._fp_seed;
}

fn mix(self: *CanvasRenderingContext2D, v: u64) void {
    self._dirty = true;
    self.mixSeed(v);
}

fn mixSeed(self: *CanvasRenderingContext2D, v: u64) void {
    self._fp_seed ^= v;
    self._fp_seed *%= 0x100000001b3;
}

fn mixF(self: *CanvasRenderingContext2D, f: f64) void {
    self.mix(@as(u64, @bitCast(f)));
}

fn mixSeedF(self: *CanvasRenderingContext2D, f: f64) void {
    self.mixSeed(@as(u64, @bitCast(f)));
}

fn mixBytes(self: *CanvasRenderingContext2D, bytes: []const u8) void {
    for (bytes) |b| {
        self._fp_seed ^= b;
        self._fp_seed *%= 0x100000001b3;
    }
}

fn mixColor(self: *CanvasRenderingContext2D) void {
    self.mix(@as(u32, self._fill_style.r) |
        (@as(u32, self._fill_style.g) << 8) |
        (@as(u32, self._fill_style.b) << 16) |
        (@as(u32, self._fill_style.a) << 24));
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(exec.local_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._font[0..self._font_len];
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8) void {
    const n = @min(value.len, self._font.len);
    @memcpy(self._font[0..n], value[0..n]);
    self._font_len = @intCast(n);
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    maybe_height: ?u32,
    maybe_settings: ?ImageData.ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            return ImageData.init(width, height, maybe_settings, exec);
        },
        .image_data => |image_data| {
            return ImageData.init(image_data._width, image_data._height, null, exec);
        },
    }
}

pub fn putImageData(self: *CanvasRenderingContext2D, data: *ImageData, dx: f64, dy: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {
    self.mix(data._width);
    self.mix(data._height);
    self.mixF(dx);
    self.mixF(dy);
}

pub fn drawImage(self: *CanvasRenderingContext2D, image: js.Value, dx: f64, dy: f64, dw: ?f64, dh: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {
    // Seed the fingerprint without inventing getImageData pixels — the source
    // may be fully transparent and scanners catch opaque noise after drawImage.
    _ = image;
    self.mixSeedF(dx);
    self.mixSeedF(dy);
    if (dw) |v| self.mixSeedF(v);
    if (dh) |v| self.mixSeedF(v);
}

pub fn getImageData(
    self: *const CanvasRenderingContext2D,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    exec: *Execution,
) !*ImageData {
    if (sw <= 0 or sh <= 0) {
        return error.IndexSizeError;
    }
    const image = try ImageData.init(@intCast(sw), @intCast(sh), null, exec);
    // Undrawn canvas: transparent black (spec). After drawing: stable fingerprint pixels.
    if (!self._dirty) return image;
    const seed = self._fp_seed ^ (@as(u64, @bitCast(@as(i64, sx))) *% 0x9e3779b97f4a7c15) ^ (@as(u64, @bitCast(@as(i64, sy))) *% 0xbf58476d1ce4e5b9);
    const local = exec.js.local.?;
    Canvas.fillFingerprintPixels(image._data.local(local).slice(), seed, @intCast(sw));
    return image;
}

pub fn createLinearGradient(self: *CanvasRenderingContext2D, x0: f64, y0: f64, x1: f64, y1: f64, exec: *Execution) !*CanvasGradient {
    var seed: u64 = self._fp_seed ^ 0x4c494e45;
    seed = fnvMix(seed, @as(u64, @bitCast(x0)));
    seed = fnvMix(seed, @as(u64, @bitCast(y0)));
    seed = fnvMix(seed, @as(u64, @bitCast(x1)));
    seed = fnvMix(seed, @as(u64, @bitCast(y1)));
    return exec._factory.create(CanvasGradient{ ._kind = .linear, ._seed = seed });
}

pub fn createRadialGradient(self: *CanvasRenderingContext2D, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64, exec: *Execution) !*CanvasGradient {
    var seed: u64 = self._fp_seed ^ 0x52414449;
    seed = fnvMix(seed, @as(u64, @bitCast(x0)));
    seed = fnvMix(seed, @as(u64, @bitCast(y0)));
    seed = fnvMix(seed, @as(u64, @bitCast(r0)));
    seed = fnvMix(seed, @as(u64, @bitCast(x1)));
    seed = fnvMix(seed, @as(u64, @bitCast(y1)));
    seed = fnvMix(seed, @as(u64, @bitCast(r1)));
    return exec._factory.create(CanvasGradient{ ._kind = .radial, ._seed = seed });
}

pub fn measureText(self: *const CanvasRenderingContext2D, text: []const u8, exec: *Execution) !*TextMetrics {
    const font = self.getFont();
    const size = parseFontSize(font);
    const family_factor = fontFamilyFactor(font);
    // Per-character advance with font-dependent spacing so font probes diverge.
    var width: f64 = 0;
    for (text) |c| {
        const base: f64 = if (c < 128) char_widths[c] else 0.6;
        width += base * size * family_factor;
    }
    const ascent = size * 0.8 * family_factor;
    const descent = size * 0.2 * family_factor;
    return exec._factory.create(TextMetrics{
        ._width = width,
        ._actual_bounding_box_left = 0,
        ._actual_bounding_box_right = width,
        ._font_bounding_box_ascent = ascent,
        ._font_bounding_box_descent = descent,
        ._actual_bounding_box_ascent = ascent * 0.95,
        ._actual_bounding_box_descent = descent,
        ._em_height_ascent = ascent,
        ._em_height_descent = descent,
        ._hanging_baseline = ascent * 0.8,
        ._alphabetic_baseline = 0,
        ._ideographic_baseline = -descent * 0.5,
    });
}

// Approximate advance widths as fraction of em for ASCII (mono-ish fallback).
const char_widths: [128]f64 = blk: {
    var w: [128]f64 = .{0.5} ** 128;
    // Digits / caps a bit wider; i/l/t narrower — enough to fingerprint.
    for ('A'..('Z' + 1)) |c| w[c] = 0.66;
    for ('a'..('z' + 1)) |c| w[c] = 0.56;
    w['i'] = 0.28;
    w['l'] = 0.28;
    w['t'] = 0.35;
    w['f'] = 0.35;
    w['m'] = 0.85;
    w['w'] = 0.85;
    w['W'] = 0.9;
    w['M'] = 0.9;
    w[' '] = 0.3;
    break :blk w;
};

fn parseFontSize(font: []const u8) f64 {
    // Scan for first number before "px"
    var i: usize = 0;
    while (i < font.len) : (i += 1) {
        if (font[i] >= '0' and font[i] <= '9') {
            var n: f64 = 0;
            while (i < font.len and font[i] >= '0' and font[i] <= '9') : (i += 1) {
                n = n * 10 + @as(f64, @floatFromInt(font[i] - '0'));
            }
            if (i < font.len and font[i] == '.') {
                i += 1;
                var place: f64 = 0.1;
                while (i < font.len and font[i] >= '0' and font[i] <= '9') : (i += 1) {
                    n += @as(f64, @floatFromInt(font[i] - '0')) * place;
                    place *= 0.1;
                }
            }
            return if (n > 0) n else 10;
        }
    }
    return 10;
}

fn fontFamilyFactor(font: []const u8) f64 {
    // Lowercased substring checks for common OS fonts used by fingerprint scripts.
    var lower_buf: [96]u8 = undefined;
    const n = @min(font.len, lower_buf.len);
    for (font[0..n], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..n];

    // Windows core
    if (std.mem.indexOf(u8, lower, "arial") != null) return 1.00;
    if (std.mem.indexOf(u8, lower, "calibri") != null) return 0.97;
    if (std.mem.indexOf(u8, lower, "segoe") != null) return 0.99;
    if (std.mem.indexOf(u8, lower, "tahoma") != null) return 0.96;
    if (std.mem.indexOf(u8, lower, "verdana") != null) return 1.05;
    if (std.mem.indexOf(u8, lower, "times") != null) return 0.94;
    if (std.mem.indexOf(u8, lower, "georgia") != null) return 0.98;
    if (std.mem.indexOf(u8, lower, "courier") != null) return 0.90;
    if (std.mem.indexOf(u8, lower, "consolas") != null) return 0.91;
    if (std.mem.indexOf(u8, lower, "comic") != null) return 1.08;
    if (std.mem.indexOf(u8, lower, "impact") != null) return 0.88;
    // macOS
    if (std.mem.indexOf(u8, lower, "helvetica") != null) return 0.99;
    if (std.mem.indexOf(u8, lower, "menlo") != null) return 0.92;
    if (std.mem.indexOf(u8, lower, "monaco") != null) return 0.93;
    if (std.mem.indexOf(u8, lower, "geneva") != null) return 0.98;
    // Linux
    if (std.mem.indexOf(u8, lower, "dejavu") != null) return 1.01;
    if (std.mem.indexOf(u8, lower, "liberation") != null) return 1.00;
    if (std.mem.indexOf(u8, lower, "ubuntu") != null) return 0.98;
    if (std.mem.indexOf(u8, lower, "noto") != null) return 1.02;
    if (std.mem.indexOf(u8, lower, "serif") != null) return 0.95;
    if (std.mem.indexOf(u8, lower, "mono") != null) return 0.90;
    return 1.0; // sans-serif default
}

fn fnvMix(h: u64, v: u64) u64 {
    var x = h ^ v;
    x *%= 0x100000001b3;
    return x;
}

pub fn save(_: *CanvasRenderingContext2D) void {}
pub fn restore(_: *CanvasRenderingContext2D) void {}
pub fn scale(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
}
pub fn rotate(self: *CanvasRenderingContext2D, a: f64) void {
    self.mixF(a);
}
pub fn translate(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
}
pub fn transform(self: *CanvasRenderingContext2D, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self.mixF(a);
    self.mixF(b);
    self.mixF(c);
    self.mixF(d);
    self.mixF(e);
    self.mixF(f);
}
pub fn setTransform(self: *CanvasRenderingContext2D, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self.transform(a, b, c, d, e, f);
}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.mixBytes(value);
}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(1);
}
pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixColor();
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(2);
}
pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(3);
}
pub fn beginPath(_: *CanvasRenderingContext2D) void {}
pub fn closePath(_: *CanvasRenderingContext2D) void {}
pub fn moveTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
}
pub fn lineTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
}
pub fn quadraticCurveTo(self: *CanvasRenderingContext2D, cpx: f64, cpy: f64, x: f64, y: f64) void {
    self.mixF(cpx);
    self.mixF(cpy);
    self.mixF(x);
    self.mixF(y);
}
pub fn bezierCurveTo(self: *CanvasRenderingContext2D, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) void {
    self.mixF(cp1x);
    self.mixF(cp1y);
    self.mixF(cp2x);
    self.mixF(cp2y);
    self.mixF(x);
    self.mixF(y);
}
pub fn arc(self: *CanvasRenderingContext2D, x: f64, y: f64, r: f64, a0: f64, a1: f64, _: ?bool) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(r);
    self.mixF(a0);
    self.mixF(a1);
}
pub fn arcTo(self: *CanvasRenderingContext2D, x1: f64, y1: f64, x2: f64, y2: f64, r: f64) void {
    self.mixF(x1);
    self.mixF(y1);
    self.mixF(x2);
    self.mixF(y2);
    self.mixF(r);
}
pub fn rect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
}
pub fn fill(self: *CanvasRenderingContext2D) void {
    self.mixColor();
    self.mix(4);
}
pub fn stroke(self: *CanvasRenderingContext2D) void {
    self.mix(5);
}
pub fn clip(_: *CanvasRenderingContext2D) void {}
pub fn fillText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self.mixColor();
    self.mixBytes(text);
    self.mixBytes(self.getFont());
    self.mixF(x);
    self.mixF(y);
    if (max_width) |mw| self.mixF(mw);
    self.mix(6);
}
pub fn strokeText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self.mixBytes(text);
    self.mixBytes(self.getFont());
    self.mixF(x);
    self.mixF(y);
    if (max_width) |mw| self.mixF(mw);
    self.mix(7);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const globalAlpha = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const globalCompositeOperation = bridge.property("source-over", .{ .template = false, .readonly = false });
    pub const strokeStyle = bridge.property("#000000", .{ .template = false, .readonly = false });
    pub const lineWidth = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.property("start", .{ .template = false, .readonly = false });
    pub const textBaseline = bridge.property("alphabetic", .{ .template = false, .readonly = false });

    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{});
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});

    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{ .noop = true });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{ .noop = true });
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{});
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{});
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{});
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{});
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{});
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{ .noop = true });
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{ .noop = true });
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{});
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{});
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{});
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

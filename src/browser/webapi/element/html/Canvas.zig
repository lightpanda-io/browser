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

const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const base64 = @import("../../encoding/base64.zig");

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const webgl = @import("../../canvas/WebGLRenderingContext.zig");
const WebGLRenderingContext = webgl.WebGLRenderingContext;
const WebGL2RenderingContext = webgl.WebGL2RenderingContext;
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");

const Execution = js.Execution;

const Canvas = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_cached: ?DrawingContext = null,

pub fn asElement(self: *Canvas) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
};

pub fn getContext(self: *Canvas, context_type: []const u8, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
            .webgl2 => std.mem.eql(u8, context_type, "webgl2"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            // CloakBrowser-style: canvas noise seed from fingerprint profile.
            const noise = frame._session.browser.app.config.fingerprint_profile.noise_seed;
            const ctx = try frame._factory.create(CanvasRenderingContext2D{
                ._canvas = self,
                ._fp_seed = noise,
            });
            break :blk .{ .@"2d" = ctx };
        }

        // Fingerprint-grade WebGL stub. Methods scanners need (getParameter,
        // getExtension, getSupportedExtensions) return plausible GPU strings.
        // Common draw/resource calls are no-ops so partial consumers don't
        // cascade TypeError; full WebGL apps still won't render frames.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            const noise = frame._session.browser.app.config.fingerprint_profile.noise_seed;
            const ctx = try frame._factory.create(WebGLRenderingContext{
                ._canvas = .{ .canvas = self },
                ._fp_seed = noise,
            });
            break :blk .{ .webgl = ctx };
        }

        if (std.mem.eql(u8, context_type, "webgl2")) {
            const noise = frame._session.browser.app.config.fingerprint_profile.noise_seed;
            const ctx = try frame._factory.create(WebGL2RenderingContext{
                ._canvas = .{ .canvas = self },
                ._fp_seed = noise,
            });
            break :blk .{ .webgl2 = ctx };
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// The bound 2D context, if the page ever asked for one.
pub fn context2d(self: *Canvas) ?*CanvasRenderingContext2D {
    const cached = self._cached orelse return null;
    return switch (cached) {
        .@"2d" => |ctx| ctx,
        .webgl, .webgl2 => null,
    };
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

/// Stable data-URL fingerprint. Encodes a small deterministic PNG derived from
/// the fingerprint seed, canvas size, and 2d context drawing seed.
///
/// Only image/png is produced; other mime types still get a PNG data URL
/// (browsers fall back similarly when an encoder is missing).
///
/// With --no-stealth and no --fingerprint there is no fingerprint profile and we
/// keep upstream's honest "data:," — Lightpanda has no rasterizer and does not
/// pretend to have one unless asked to look like Chrome.
pub fn toDataURL(self: *Canvas, _: ?[]const u8, _: ?f64, exec: *Execution) ![]const u8 {
    const fp = exec.session.browser.app.config.fingerprint_profile;
    if (fp.seed == 0) {
        return exec.local_arena.dupe(u8, "data:,");
    }

    const width = self.getWidth();
    const height = self.getHeight();
    var seed: u64 = fp.noise_seed;
    seed = fnv(seed, width);
    seed = fnv(seed, height);
    if (self._cached) |cached| {
        switch (cached) {
            .@"2d" => |ctx| seed ^= ctx.fingerprintSeed(),
            // Separate arms: the two WebGL contexts are distinct types, so a
            // shared capture would not compile.
            .webgl => |ctx| seed ^= ctx.fingerprintSeed(),
            .webgl2 => |ctx| seed ^= ctx.fingerprintSeed(),
        }
    }

    const png = try buildFingerprintPng(exec.local_arena, width, height, seed);
    const encoded = try base64.encode(exec.local_arena, .{ .raw = png });
    return std.fmt.allocPrint(exec.local_arena, "data:image/png;base64,{s}", .{encoded});
}

fn fnv(h: u64, v: u64) u64 {
    var x = h ^ v;
    x *%= 0x100000001b3;
    return x;
}

/// The one seeded pixel generator for every fingerprint surface: 2d
/// getImageData, WebGL readPixels and the toDataURL PNG body. Deterministic in
/// (seed, x, y) so a probe hashes the same every load, per-pixel varying so it
/// doesn't read as a flat/blank buffer, and opaque like a real rasterizer would produce.
pub fn fillFingerprintPixels(pixels: []u8, seed: u64, width: u32) void {
    var rng = if (seed == 0) 0x9e3779b97f4a7c15 else seed;
    const w: usize = if (width == 0) 1 else width;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        const p = i / 4;
        const px = rng ^ (@as(u64, p % w) *% 0x9e3779b97f4a7c15) ^ (@as(u64, p / w) *% 0xbf58476d1ce4e5b9);
        pixels[i] = @truncate(px);
        pixels[i + 1] = @truncate(px >> 8);
        pixels[i + 2] = @truncate(px >> 16);
        pixels[i + 3] = 255;
    }
}

/// Build a valid PNG: IHDR + zlib-stored IDAT of seed-derived pixels + IEND.
/// Caps at 32×32 so fingerprint encoding stays cheap.
fn buildFingerprintPng(allocator: std.mem.Allocator, width: u32, height: u32, seed: u64) ![]u8 {
    const w: u32 = @min(@max(width, 1), 32);
    const h: u32 = @min(@max(height, 1), 32);
    // Filter byte + RGBA per row
    const raw_len = @as(usize, h) * (@as(usize, w) * 4 + 1);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    const stride = @as(usize, w) * 4;
    const pixels = try allocator.alloc(u8, @as(usize, h) * stride);
    defer allocator.free(pixels);
    fillFingerprintPixels(pixels, seed, w);

    var offset: usize = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        raw[offset] = 0; // filter None
        offset += 1;
        @memcpy(raw[offset..][0..stride], pixels[y * stride ..][0..stride]);
        offset += stride;
    }

    // zlib stream with a single stored (uncompressed) block — no flate dependency.
    // Header (CMF/FLG) + block header + raw + Adler-32.
    const zlib_len = 2 + 5 + raw_len + 4;
    const zlib_buf = try allocator.alloc(u8, zlib_len);
    defer allocator.free(zlib_buf);
    zlib_buf[0] = 0x78; // CMF: deflate, 32k window
    zlib_buf[1] = 0x01; // FLG: check bits, no dict, fastest
    zlib_buf[2] = 0x01; // BFINAL=1, BTYPE=00 (stored)
    std.mem.writeInt(u16, zlib_buf[3..5], @intCast(raw_len), .little);
    std.mem.writeInt(u16, zlib_buf[5..7], @intCast(~@as(u16, @intCast(raw_len))), .little);
    @memcpy(zlib_buf[7 .. 7 + raw_len], raw);
    std.mem.writeInt(u32, zlib_buf[7 + raw_len ..][0..4], adler32(raw), .big);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(allocator, &out, "IHDR", &ihdr);
    try writeChunk(allocator, &out, "IDAT", zlib_buf);
    try writeChunk(allocator, &out, "IEND", &[_]u8{});

    return out.toOwnedSlice(allocator);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeChunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, data);

    var crc = std.hash.crc.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(allocator, &crc_buf);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{ .ce_reactions = true });
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

const testing = @import("../../../../testing.zig");

const PngDims = struct { w: u32, h: u32 };

// Walks the chunk stream, verifying every CRC. Returns the IHDR dimensions.
fn assertValidPng(png: []const u8) !PngDims {
    try testing.expectEqualSlices(u8, &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 }, png[0..8]);

    var dims: PngDims = .{ .w = 0, .h = 0 };
    var seen_ihdr = false;
    var seen_idat = false;
    var seen_iend = false;

    var i: usize = 8;
    while (i + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        const tag = png[i + 4 ..][0..4];
        const data = png[i + 8 ..][0..len];

        var crc = std.hash.crc.Crc32.init();
        crc.update(tag);
        crc.update(data);
        try testing.expectEqual(crc.final(), std.mem.readInt(u32, png[i + 8 + len ..][0..4], .big));

        if (std.mem.eql(u8, tag, "IHDR")) {
            seen_ihdr = true;
            try testing.expectEqual(@as(usize, 13), len);
            dims = .{
                .w = std.mem.readInt(u32, data[0..4], .big),
                .h = std.mem.readInt(u32, data[4..8], .big),
            };
            try testing.expectEqual(@as(u8, 8), data[8]); // bit depth
            try testing.expectEqual(@as(u8, 6), data[9]); // RGBA
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            seen_idat = true;
            try testing.expect(len > 0);
            try testing.expectEqual(@as(u8, 0x78), data[0]); // zlib CMF
            try testing.expectEqual(@as(usize, 0), (@as(usize, data[0]) * 256 + data[1]) % 31);
        } else if (std.mem.eql(u8, tag, "IEND")) {
            seen_iend = true;
        }
        i += 12 + len;
    }

    try testing.expectEqual(png.len, i);
    try testing.expect(seen_ihdr and seen_idat and seen_iend);
    return dims;
}

test "Canvas: fingerprint PNG is valid and seed-stable" {
    const a = testing.allocator;

    const p1 = try buildFingerprintPng(a, 200, 50, 0xdeadbeef);
    defer a.free(p1);
    const p2 = try buildFingerprintPng(a, 200, 50, 0xdeadbeef);
    defer a.free(p2);
    const p3 = try buildFingerprintPng(a, 200, 50, 0xfeedface);
    defer a.free(p3);

    // Structurally decodable, clamped to the 32x32 encode cap.
    const dims = try assertValidPng(p1);
    try testing.expectEqual(@as(u32, 32), dims.w);
    try testing.expectEqual(@as(u32, 32), dims.h);
    _ = try assertValidPng(p3);

    // Same seed + size => byte-identical. Different seed => different image.
    try testing.expectEqualSlices(u8, p1, p2);
    try testing.expect(!std.mem.eql(u8, p1, p3));

    // Size participates in the image too.
    const small = try buildFingerprintPng(a, 8, 4, 0xdeadbeef);
    defer a.free(small);
    const small_dims = try assertValidPng(small);
    try testing.expectEqual(@as(u32, 8), small_dims.w);
    try testing.expectEqual(@as(u32, 4), small_dims.h);
}

test "Canvas: fingerprint pixels are stable, seeded and non-uniform" {
    var a: [16 * 16 * 4]u8 = undefined;
    var b: [16 * 16 * 4]u8 = undefined;
    var c: [16 * 16 * 4]u8 = undefined;
    fillFingerprintPixels(&a, 424242, 16);
    fillFingerprintPixels(&b, 424242, 16);
    fillFingerprintPixels(&c, 424243, 16);

    // Same seed => byte-identical (a fingerprint that moves is itself a tell).
    try testing.expect(std.mem.eql(u8, &a, &b));
    try testing.expect(!std.mem.eql(u8, &a, &c));

    // Not a flat buffer, and opaque like a real render.
    var varied = false;
    var i: usize = 4;
    while (i < a.len) : (i += 4) {
        if (!std.mem.eql(u8, a[i .. i + 4], a[0..4])) {
            varied = true;
        }
        try testing.expectEqual(255, a[i + 3]);
    }
    try testing.expect(varied);
    try testing.expectEqual(255, a[3]);
}

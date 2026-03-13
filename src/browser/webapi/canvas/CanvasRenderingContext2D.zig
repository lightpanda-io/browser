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

const js = @import("../../js/js.zig");

const color = @import("../../color.zig");
const Page = @import("../../Page.zig");

const ImageData = @import("../ImageData.zig");
const CanvasSurface = @import("CanvasSurface.zig");
const CanvasPath = @import("CanvasPath.zig");
const Canvas = @import("../element/html/Canvas.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");
const Image = @import("../element/html/Image.zig");

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,
_stroke_style: color.RGBA = color.RGBA.Named.black,
_font_value: []const u8 = "10px sans-serif",
_text_align_value: []const u8 = "start",
_text_baseline_value: []const u8 = "alphabetic",
_text_style: CanvasSurface.TextStyle = .{},
_allocator: std.mem.Allocator,
_path: CanvasPath = .{},
_surface: *CanvasSurface,

pub fn getFillStyle(self: *const CanvasRenderingContext2D, page: *Page) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(page.call_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    // Prefer the same fill_style if fails.
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getStrokeStyle(self: *const CanvasRenderingContext2D, page: *Page) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(page.call_arena);
    try self._stroke_style.format(&w.writer);
    return w.written();
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: []const u8) void {
    self._stroke_style = color.RGBA.parse(value) catch self._stroke_style;
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._font_value;
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8) void {
    const parsed = parseCanvasFontShorthand(value) orelse return;
    self._font_value = self._allocator.dupe(u8, value) catch return;
    self._text_style.font_size_px = parsed.font_size_px;
    self._text_style.font_family = self._allocator.dupe(u8, parsed.font_family) catch parsed.font_family;
    self._text_style.font_weight = parsed.font_weight;
    self._text_style.italic = parsed.italic;
}

pub fn getTextAlign(self: *const CanvasRenderingContext2D) []const u8 {
    return self._text_align_value;
}

pub fn setTextAlign(self: *CanvasRenderingContext2D, value: []const u8) void {
    const normalized = normalizeTextAlign(value) orelse return;
    self._text_style.@"align" = normalized.value;
    self._text_align_value = normalized.stored;
}

pub fn getTextBaseline(self: *const CanvasRenderingContext2D) []const u8 {
    return self._text_baseline_value;
}

pub fn setTextBaseline(self: *CanvasRenderingContext2D, value: []const u8) void {
    const normalized = normalizeTextBaseline(value) orelse return;
    self._text_style.baseline = normalized.baseline;
    self._text_baseline_value = normalized.stored;
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

const DrawImageSource = union(enum) {
    canvas: *Canvas,
    offscreen_canvas: *OffscreenCanvas,
    image: *Image,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    /// If `ImageData` variant preferred, this is null.
    maybe_height: ?u32,
    /// Can be used if width and height provided.
    maybe_settings: ?ImageData.ConstructorSettings,
    page: *Page,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            return ImageData.constructor(width, height, maybe_settings, page);
        },
        .image_data => |image_data| {
            return ImageData.constructor(image_data._width, image_data._height, null, page);
        },
    }
}

pub fn getImageData(
    self: *const CanvasRenderingContext2D,
    sx: f64,
    sy: f64,
    sw: f64,
    sh: f64,
    page: *Page,
) !*ImageData {
    return self._surface.getImageData(sx, sy, sw, sh, page);
}

pub fn putImageData(
    self: *const CanvasRenderingContext2D,
    image_data: *ImageData,
    dx: f64,
    dy: f64,
    dirty_x: ?f64,
    dirty_y: ?f64,
    dirty_width: ?f64,
    dirty_height: ?f64,
    page: *Page,
) !void {
    try self._surface.putImageData(image_data, dx, dy, dirty_x, dirty_y, dirty_width, dirty_height, page);
}

pub fn drawImage(
    self: *CanvasRenderingContext2D,
    source: DrawImageSource,
    dx: f64,
    dy: f64,
    arg3: ?f64,
    arg4: ?f64,
    arg5: ?f64,
    arg6: ?f64,
    arg7: ?f64,
    arg8: ?f64,
    page: *Page,
) !void {
    const resolved_source = (try sourceSurface(source, page)) orelse return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    var sw: f64 = @floatFromInt(resolved_source.width);
    var sh: f64 = @floatFromInt(resolved_source.height);
    var dw: f64 = sw;
    var dh: f64 = sh;

    if (arg3 == null and arg4 == null and arg5 == null and arg6 == null and arg7 == null and arg8 == null) {
        // drawImage(image, dx, dy)
    } else if (arg3 != null and arg4 != null and arg5 == null and arg6 == null and arg7 == null and arg8 == null) {
        // drawImage(image, dx, dy, dWidth, dHeight)
        dw = arg3.?;
        dh = arg4.?;
    } else if (arg3 != null and arg4 != null and arg5 != null and arg6 != null and arg7 != null and arg8 != null) {
        // drawImage(image, sx, sy, sWidth, sHeight, dx, dy, dWidth, dHeight)
        sx = dx;
        sy = dy;
        sw = arg3.?;
        sh = arg4.?;
        dw = arg7.?;
        dh = arg8.?;
        try self._surface.drawSurface(page.arena, resolved_source.surface, sx, sy, sw, sh, arg5.?, arg6.?, dw, dh);
        return;
    } else {
        return error.TypeError;
    }

    try self._surface.drawSurface(page.arena, resolved_source.surface, sx, sy, sw, sh, dx, dy, dw, dh);
}
pub fn save(_: *CanvasRenderingContext2D) void {}
pub fn restore(_: *CanvasRenderingContext2D) void {}
pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self._surface.clearRect(x, y, width, height);
}
pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self._surface.fillRect(self._fill_style, x, y, width, height);
}
pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self._surface.strokeRect(self._stroke_style, x, y, width, height);
}
pub fn beginPath(self: *CanvasRenderingContext2D) void {
    self._path.beginPath();
}
pub fn closePath(self: *CanvasRenderingContext2D) void {
    self._path.closePath();
}
pub fn moveTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self._path.moveTo(self._allocator, x, y) catch {};
}
pub fn lineTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self._path.lineTo(self._allocator, x, y) catch {};
}
pub fn quadraticCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn bezierCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn arc(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn arcTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn rect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self._path.rect(self._allocator, x, y, width, height) catch {};
}
pub fn fill(self: *CanvasRenderingContext2D) void {
    self._path.fill(self._allocator, self._surface, self._fill_style) catch {};
}
pub fn stroke(self: *CanvasRenderingContext2D) void {
    self._path.stroke(self._surface, self._stroke_style);
}
pub fn clip(_: *CanvasRenderingContext2D) void {}
pub fn fillText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self._surface.fillText(self._allocator, text, x, y, max_width, self._text_style, self._fill_style);
}
pub fn strokeText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self._surface.strokeText(self._allocator, text, x, y, max_width, self._text_style, self._stroke_style);
}

const SourceSurface = struct {
    surface: *const CanvasSurface,
    width: u32,
    height: u32,
};

fn sourceSurface(source: DrawImageSource, page: *Page) !?SourceSurface {
    return switch (source) {
        .canvas => |canvas| blk: {
            const surface = canvas.getSurface() orelse break :blk null;
            break :blk .{
                .surface = surface,
                .width = canvas.getWidth(),
                .height = canvas.getHeight(),
            };
        },
        .offscreen_canvas => |canvas| blk: {
            const surface = canvas.getSurface() orelse break :blk null;
            break :blk .{
                .surface = surface,
                .width = canvas.getWidth(),
                .height = canvas.getHeight(),
            };
        },
        .image => |image| blk: {
            const surface = image.getCanvasSurface(page) orelse break :blk null;
            break :blk .{
                .surface = surface,
                .width = image.getNaturalWidth(page),
                .height = image.getNaturalHeight(page),
            };
        },
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const globalAlpha = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const globalCompositeOperation = bridge.property("source-over", .{ .template = false, .readonly = false });
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const lineWidth = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.accessor(CanvasRenderingContext2D.getTextAlign, CanvasRenderingContext2D.setTextAlign, .{});
    pub const textBaseline = bridge.accessor(CanvasRenderingContext2D.getTextBaseline, CanvasRenderingContext2D.setTextBaseline, .{});

    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{ .dom_exception = true });

    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{ .dom_exception = true });
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{ .dom_exception = true });
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{});
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{ .noop = true });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{ .noop = true });
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .noop = true });
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .noop = true });
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .noop = true });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{});
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{ .noop = true });
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});
};

const ParsedCanvasFont = struct {
    font_size_px: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
};

const NormalizedTextAlign = struct {
    value: CanvasSurface.TextAlign,
    stored: []const u8,
};

const NormalizedTextBaseline = struct {
    baseline: CanvasSurface.TextBaseline,
    stored: []const u8,
};

fn parseCanvasFontShorthand(value: []const u8) ?ParsedCanvasFont {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    var font_size_px: ?i32 = null;
    var font_weight: i32 = 400;
    var italic = false;
    var family_start: usize = 0;

    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (tokens.next()) |token| {
        if (std.mem.endsWith(u8, token, "px")) {
            const raw = token[0 .. token.len - 2];
            font_size_px = @intFromFloat(std.fmt.parseFloat(f64, raw) catch return null);
            family_start = @intFromPtr(token.ptr) - @intFromPtr(trimmed.ptr) + token.len;
            break;
        }
        if (std.ascii.eqlIgnoreCase(token, "italic") or std.ascii.eqlIgnoreCase(token, "oblique")) {
            italic = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "bold")) {
            font_weight = 700;
            continue;
        }
        if (std.fmt.parseInt(i32, token, 10)) |parsed_weight| {
            font_weight = std.math.clamp(parsed_weight, 100, 900);
            continue;
        } else |_| {}
    }

    const size = font_size_px orelse return null;
    const family = std.mem.trim(u8, trimmed[family_start..], &std.ascii.whitespace);
    if (family.len == 0) return null;
    return .{
        .font_size_px = size,
        .font_family = family,
        .font_weight = font_weight,
        .italic = italic,
    };
}

fn normalizeTextAlign(value: []const u8) ?NormalizedTextAlign {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "left") or std.ascii.eqlIgnoreCase(trimmed, "start")) {
        return .{ .value = .left, .stored = "start" };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "center")) {
        return .{ .value = .center, .stored = "center" };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "right") or std.ascii.eqlIgnoreCase(trimmed, "end")) {
        return .{ .value = .right, .stored = "end" };
    }
    return null;
}

fn normalizeTextBaseline(value: []const u8) ?NormalizedTextBaseline {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "top") or std.ascii.eqlIgnoreCase(trimmed, "hanging")) {
        return .{ .baseline = .top, .stored = "top" };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "middle")) {
        return .{ .baseline = .middle, .stored = "middle" };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "bottom") or std.ascii.eqlIgnoreCase(trimmed, "ideographic")) {
        return .{ .baseline = .bottom, .stored = "bottom" };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "alphabetic")) {
        return .{ .baseline = .alphabetic, .stored = "alphabetic" };
    }
    return null;
}

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

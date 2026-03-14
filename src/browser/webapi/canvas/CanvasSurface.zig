const std = @import("std");
const builtin = @import("builtin");

const color = @import("../../color.zig");
const Page = @import("../../Page.zig");

const ImageData = @import("../ImageData.zig");

const CanvasSurface = @This();

const win = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("wingdi.h");
}) else struct {};

pub const TextAlign = enum {
    left,
    center,
    right,
};

pub const TextBaseline = enum {
    top,
    middle,
    alphabetic,
    bottom,
};

pub const TextStyle = struct {
    font_size_px: i32 = 10,
    font_family: []const u8 = "sans-serif",
    font_weight: i32 = 400,
    italic: bool = false,
    @"align": TextAlign = .left,
    baseline: TextBaseline = .alphabetic,
};

pub const TextMetricsData = struct {
    width: f64,
    actual_bounding_box_ascent: f64,
    actual_bounding_box_descent: f64,
};

width: u32,
height: u32,
pixels: []u8,

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*CanvasSurface {
    const self = try allocator.create(CanvasSurface);
    self.* = .{
        .width = 0,
        .height = 0,
        .pixels = &.{},
    };
    try self.resize(allocator, width, height);
    return self;
}

pub fn clone(self: *const CanvasSurface, allocator: std.mem.Allocator) !*CanvasSurface {
    const copy = try allocator.create(CanvasSurface);
    copy.* = .{
        .width = self.width,
        .height = self.height,
        .pixels = try allocator.dupe(u8, self.pixels),
    };
    return copy;
}

pub fn resize(self: *CanvasSurface, allocator: std.mem.Allocator, width: u32, height: u32) !void {
    const next_len = try pixelLen(width, height);
    self.width = width;
    self.height = height;

    if (self.pixels.len == next_len) {
        @memset(self.pixels, 0);
        return;
    }

    self.pixels = if (next_len == 0)
        &.{}
    else
        try allocator.alloc(u8, next_len);
    if (self.pixels.len > 0) {
        @memset(self.pixels, 0);
    }
}

pub fn copyPixels(self: *const CanvasSurface, allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, self.pixels);
}

pub fn fillRect(self: *CanvasSurface, fill: color.RGBA, x: f64, y: f64, width: f64, height: f64) void {
    const rect = self.clipRect(x, y, width, height) orelse return;
    var row: i32 = rect.y;
    while (row < rect.y + rect.height) : (row += 1) {
        var col: i32 = rect.x;
        while (col < rect.x + rect.width) : (col += 1) {
            self.writePixel(@intCast(col), @intCast(row), fill);
        }
    }
}

pub fn clearRect(self: *CanvasSurface, x: f64, y: f64, width: f64, height: f64) void {
    const rect = self.clipRect(x, y, width, height) orelse return;
    var row: i32 = rect.y;
    while (row < rect.y + rect.height) : (row += 1) {
        var col: i32 = rect.x;
        while (col < rect.x + rect.width) : (col += 1) {
            const index = self.pixelIndex(@intCast(col), @intCast(row));
            @memset(self.pixels[index .. index + 4], 0);
        }
    }
}

pub fn strokeRect(self: *CanvasSurface, stroke: color.RGBA, x: f64, y: f64, width: f64, height: f64) void {
    const rect = self.clipRect(x, y, width, height) orelse return;
    if (rect.width <= 0 or rect.height <= 0) return;

    const left = rect.x;
    const top = rect.y;
    const right = rect.x + rect.width - 1;
    const bottom = rect.y + rect.height - 1;

    var col: i32 = left;
    while (col <= right) : (col += 1) {
        self.writePixel(@intCast(col), @intCast(top), stroke);
        self.writePixel(@intCast(col), @intCast(bottom), stroke);
    }

    var row: i32 = top;
    while (row <= bottom) : (row += 1) {
        self.writePixel(@intCast(left), @intCast(row), stroke);
        self.writePixel(@intCast(right), @intCast(row), stroke);
    }
}

pub fn drawLine(self: *CanvasSurface, stroke: color.RGBA, x0: f64, y0: f64, x1: f64, y1: f64) void {
    const start_x = coordinateFromFloat(x0) orelse return;
    const start_y = coordinateFromFloat(y0) orelse return;
    const end_x = coordinateFromFloat(x1) orelse return;
    const end_y = coordinateFromFloat(y1) orelse return;

    var x: i32 = start_x;
    var y: i32 = start_y;
    const delta_x: i32 = if (end_x >= start_x) end_x - start_x else start_x - end_x;
    const delta_y: i32 = -if (end_y >= start_y) end_y - start_y else start_y - end_y;
    const step_x: i32 = if (start_x < end_x) 1 else -1;
    const step_y: i32 = if (start_y < end_y) 1 else -1;
    var err = delta_x + delta_y;

    while (true) {
        if (x >= 0 and y >= 0) {
            self.writePixel(@intCast(x), @intCast(y), stroke);
        }
        if (x == end_x and y == end_y) {
            break;
        }
        const doubled_err = err * 2;
        if (doubled_err >= delta_y) {
            err += delta_y;
            x += step_x;
        }
        if (doubled_err <= delta_x) {
            err += delta_x;
            y += step_y;
        }
    }
}

pub fn fillTriangle(
    self: *CanvasSurface,
    fill: color.RGBA,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    cx: f64,
    cy: f64,
) void {
    if (!std.math.isFinite(ax) or !std.math.isFinite(ay) or !std.math.isFinite(bx) or !std.math.isFinite(by) or !std.math.isFinite(cx) or !std.math.isFinite(cy)) {
        return;
    }
    if (self.width == 0 or self.height == 0) return;

    const min_x_f = @min(ax, @min(bx, cx));
    const min_y_f = @min(ay, @min(by, cy));
    const max_x_f = @max(ax, @max(bx, cx));
    const max_y_f = @max(ay, @max(by, cy));

    var min_x = std.math.lossyCast(i32, @floor(min_x_f));
    var min_y = std.math.lossyCast(i32, @floor(min_y_f));
    var max_x = std.math.lossyCast(i32, @ceil(max_x_f));
    var max_y = std.math.lossyCast(i32, @ceil(max_y_f));

    min_x = std.math.clamp(min_x, 0, @as(i32, @intCast(self.width)));
    min_y = std.math.clamp(min_y, 0, @as(i32, @intCast(self.height)));
    max_x = std.math.clamp(max_x, 0, @as(i32, @intCast(self.width)));
    max_y = std.math.clamp(max_y, 0, @as(i32, @intCast(self.height)));
    if (min_x >= max_x or min_y >= max_y) return;

    const area = edgeFunction(ax, ay, bx, by, cx, cy);
    if (std.math.approxEqAbs(f64, area, 0, 0.000001)) return;

    var y: i32 = min_y;
    while (y < max_y) : (y += 1) {
        var x: i32 = min_x;
        while (x < max_x) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const w0 = edgeFunction(bx, by, cx, cy, px, py);
            const w1 = edgeFunction(cx, cy, ax, ay, px, py);
            const w2 = edgeFunction(ax, ay, bx, by, px, py);

            if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0)) {
                self.writePixel(@intCast(x), @intCast(y), fill);
            }
        }
    }
}

pub fn setPixel(self: *CanvasSurface, x: u32, y: u32, rgba: color.RGBA) void {
    self.writePixel(x, y, rgba);
}

pub fn getImageData(
    self: *const CanvasSurface,
    sx: f64,
    sy: f64,
    sw: f64,
    sh: f64,
    page: *Page,
) !*ImageData {
    const width = dimensionFromFloat(sw) orelse return error.IndexSizeError;
    const height = dimensionFromFloat(sh) orelse return error.IndexSizeError;
    if (width == 0 or height == 0) return error.IndexSizeError;

    const image_data = try ImageData.constructor(width, height, null, page);
    const bytes = try image_data.bytes(page);
    @memset(bytes, 0);

    const start_x = coordinateFromFloat(sx) orelse 0;
    const start_y = coordinateFromFloat(sy) orelse 0;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const src_x = start_x + @as(i32, @intCast(col));
            const src_y = start_y + @as(i32, @intCast(row));
            if (src_x < 0 or src_y < 0) continue;
            if (@as(u32, @intCast(src_x)) >= self.width or @as(u32, @intCast(src_y)) >= self.height) continue;

            const src_index = self.pixelIndex(@intCast(src_x), @intCast(src_y));
            const dst_index = (@as(usize, row) * width + col) * 4;
            @memcpy(bytes[dst_index .. dst_index + 4], self.pixels[src_index .. src_index + 4]);
        }
    }

    return image_data;
}

pub fn putImageData(
    self: *CanvasSurface,
    image_data: *ImageData,
    dx: f64,
    dy: f64,
    dirty_x: ?f64,
    dirty_y: ?f64,
    dirty_width: ?f64,
    dirty_height: ?f64,
    page: *Page,
) !void {
    const source = try image_data.bytes(page);
    const source_width = image_data._width;
    const source_height = image_data._height;

    var src_x = coordinateFromFloat(dirty_x orelse 0) orelse 0;
    var src_y = coordinateFromFloat(dirty_y orelse 0) orelse 0;
    const copy_width = dimensionFromFloat(dirty_width orelse @as(f64, @floatFromInt(source_width))) orelse source_width;
    const copy_height = dimensionFromFloat(dirty_height orelse @as(f64, @floatFromInt(source_height))) orelse source_height;

    if (dirty_width != null and dirty_width.? < 0) {
        src_x += @as(i32, @intCast(copy_width));
    }
    if (dirty_height != null and dirty_height.? < 0) {
        src_y += @as(i32, @intCast(copy_height));
    }

    if (copy_width == 0 or copy_height == 0) return;

    const dest_x = coordinateFromFloat(dx) orelse 0;
    const dest_y = coordinateFromFloat(dy) orelse 0;

    var row: u32 = 0;
    while (row < copy_height) : (row += 1) {
        var col: u32 = 0;
        while (col < copy_width) : (col += 1) {
            const source_col = src_x + @as(i32, @intCast(col));
            const source_row = src_y + @as(i32, @intCast(row));
            if (source_col < 0 or source_row < 0) continue;
            if (@as(u32, @intCast(source_col)) >= source_width or @as(u32, @intCast(source_row)) >= source_height) continue;

            const target_col = dest_x + @as(i32, @intCast(col));
            const target_row = dest_y + @as(i32, @intCast(row));
            if (target_col < 0 or target_row < 0) continue;
            if (@as(u32, @intCast(target_col)) >= self.width or @as(u32, @intCast(target_row)) >= self.height) continue;

            const source_index = (@as(usize, @intCast(source_row)) * source_width + @as(u32, @intCast(source_col))) * 4;
            const target_index = self.pixelIndex(@intCast(target_col), @intCast(target_row));
            @memcpy(self.pixels[target_index .. target_index + 4], source[source_index .. source_index + 4]);
        }
    }
}

pub fn drawSurface(
    self: *CanvasSurface,
    allocator: std.mem.Allocator,
    source: *const CanvasSurface,
    sx: f64,
    sy: f64,
    sw: f64,
    sh: f64,
    dx: f64,
    dy: f64,
    dw: f64,
    dh: f64,
) !void {
    const src_rect = normalizedDrawRect(sx, sy, sw, sh) orelse return;
    const dst_rect = normalizedDrawRect(dx, dy, dw, dh) orelse return;
    if (src_rect.width <= 0 or src_rect.height <= 0 or dst_rect.width <= 0 or dst_rect.height <= 0) return;

    var source_pixels = source.pixels;
    const needs_copy = self == source or (self.pixels.ptr == source.pixels.ptr and self.pixels.len == source.pixels.len);
    if (needs_copy) {
        source_pixels = try allocator.dupe(u8, source.pixels);
        defer allocator.free(source_pixels);
    }

    var row: i32 = 0;
    while (row < dst_rect.height) : (row += 1) {
        const target_row = dst_rect.y + row;
        if (target_row < 0 or target_row >= @as(i32, @intCast(self.height))) continue;

        const source_row = src_rect.y + @divTrunc(row * src_rect.height, dst_rect.height);
        if (source_row < 0 or source_row >= @as(i32, @intCast(source.height))) continue;

        var col: i32 = 0;
        while (col < dst_rect.width) : (col += 1) {
            const target_col = dst_rect.x + col;
            if (target_col < 0 or target_col >= @as(i32, @intCast(self.width))) continue;

            const source_col = src_rect.x + @divTrunc(col * src_rect.width, dst_rect.width);
            if (source_col < 0 or source_col >= @as(i32, @intCast(source.width))) continue;

            const source_index = (@as(usize, @intCast(source_row)) * source.width + @as(u32, @intCast(source_col))) * 4;
            const target_index = self.pixelIndex(@intCast(target_col), @intCast(target_row));
            @memcpy(self.pixels[target_index .. target_index + 4], source_pixels[source_index .. source_index + 4]);
        }
    }
}

pub fn fillText(
    self: *CanvasSurface,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f64,
    y: f64,
    max_width: ?f64,
    style: TextStyle,
    fill: color.RGBA,
) void {
    if (builtin.os.tag != .windows) return;
    self.drawTextWin32(allocator, text, x, y, max_width, style, fill, false);
}

pub fn strokeText(
    self: *CanvasSurface,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f64,
    y: f64,
    max_width: ?f64,
    style: TextStyle,
    stroke: color.RGBA,
) void {
    if (builtin.os.tag != .windows) return;
    self.drawTextWin32(allocator, text, x, y, max_width, style, stroke, true);
}

pub fn measureText(
    self: *const CanvasSurface,
    allocator: std.mem.Allocator,
    text: []const u8,
    style: TextStyle,
) TextMetricsData {
    _ = self;
    if (builtin.os.tag == .windows) {
        if (measureTextWin32(allocator, text, style)) |metrics| {
            return metrics;
        }
    }

    const fallback_size = @as(f64, @floatFromInt(@max(@as(i32, 1), style.font_size_px)));
    return .{
        .width = @as(f64, @floatFromInt(text.len)) * (fallback_size * 0.5),
        .actual_bounding_box_ascent = fallback_size * 0.8,
        .actual_bounding_box_descent = fallback_size * 0.2,
    };
}

fn pixelLen(width: u32, height: u32) !usize {
    var size, const overflow_a = @mulWithOverflow(width, height);
    if (overflow_a == 1) return error.Overflow;
    size, const overflow_b = @mulWithOverflow(size, 4);
    if (overflow_b == 1) return error.Overflow;
    return size;
}

fn coordinateFromFloat(value: f64) ?i32 {
    if (!std.math.isFinite(value)) return null;
    return std.math.lossyCast(i32, @floor(value));
}

fn dimensionFromFloat(value: f64) ?u32 {
    if (!std.math.isFinite(value)) return null;
    const floored = @floor(value);
    if (floored < 0) return @intFromFloat(-floored);
    return std.math.lossyCast(u32, floored);
}

const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const DrawRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn normalizedRect(x: f64, y: f64, width: f64, height: f64) ?Rect {
    const origin_x = coordinateFromFloat(x) orelse return null;
    const origin_y = coordinateFromFloat(y) orelse return null;
    var rect_width = coordinateFromFloat(width) orelse return null;
    var rect_height = coordinateFromFloat(height) orelse return null;

    var rect_x = origin_x;
    var rect_y = origin_y;
    if (rect_width < 0) {
        rect_x += rect_width;
        rect_width = -rect_width;
    }
    if (rect_height < 0) {
        rect_y += rect_height;
        rect_height = -rect_height;
    }

    return .{
        .x = rect_x,
        .y = rect_y,
        .width = rect_width,
        .height = rect_height,
    };
}

fn normalizedDrawRect(x: f64, y: f64, width: f64, height: f64) ?DrawRect {
    const origin_x = coordinateFromFloat(x) orelse return null;
    const origin_y = coordinateFromFloat(y) orelse return null;
    var rect_width = coordinateFromFloat(width) orelse return null;
    var rect_height = coordinateFromFloat(height) orelse return null;

    if (rect_width == 0 or rect_height == 0) return null;

    var rect_x = origin_x;
    var rect_y = origin_y;
    if (rect_width < 0) {
        rect_x += rect_width;
        rect_width = -rect_width;
    }
    if (rect_height < 0) {
        rect_y += rect_height;
        rect_height = -rect_height;
    }

    return .{
        .x = rect_x,
        .y = rect_y,
        .width = rect_width,
        .height = rect_height,
    };
}

fn clipRect(self: *const CanvasSurface, x: f64, y: f64, width: f64, height: f64) ?Rect {
    var rect = normalizedRect(x, y, width, height) orelse return null;
    if (rect.width <= 0 or rect.height <= 0) return null;

    const max_x = @as(i32, @intCast(self.width));
    const max_y = @as(i32, @intCast(self.height));
    const left = std.math.clamp(rect.x, 0, max_x);
    const top = std.math.clamp(rect.y, 0, max_y);
    const right = std.math.clamp(rect.x + rect.width, 0, max_x);
    const bottom = std.math.clamp(rect.y + rect.height, 0, max_y);
    rect.x = left;
    rect.y = top;
    rect.width = right - left;
    rect.height = bottom - top;

    if (rect.width <= 0 or rect.height <= 0) return null;
    return rect;
}

fn pixelIndex(self: *const CanvasSurface, x: u32, y: u32) usize {
    return (@as(usize, y) * self.width + x) * 4;
}

fn edgeFunction(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

fn writePixel(self: *CanvasSurface, x: u32, y: u32, rgba: color.RGBA) void {
    if (x >= self.width or y >= self.height) return;
    const index = self.pixelIndex(x, y);
    self.pixels[index + 0] = rgba.r;
    self.pixels[index + 1] = rgba.g;
    self.pixels[index + 2] = rgba.b;
    self.pixels[index + 3] = rgba.a;
}

fn measureTextWin32(
    allocator: std.mem.Allocator,
    text: []const u8,
    style: TextStyle,
) ?TextMetricsData {
    if (text.len == 0) {
        const fallback_size = @as(f64, @floatFromInt(@max(@as(i32, 1), style.font_size_px)));
        return .{
            .width = 0,
            .actual_bounding_box_ascent = fallback_size * 0.8,
            .actual_bounding_box_descent = fallback_size * 0.2,
        };
    }

    const wide_text = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return null;
    defer allocator.free(wide_text);
    if (wide_text.len == 0) return null;

    const hdc = win.CreateCompatibleDC(null);
    if (hdc == null) return null;
    defer _ = win.DeleteDC(hdc);

    const font_spec = resolveCanvasFontSpec(style.font_family);
    const wide_face = std.unicode.utf8ToUtf16LeAllocZ(allocator, font_spec.face_name) catch return null;
    defer allocator.free(wide_face);

    const font = win.CreateFontW(
        -@as(i32, @intCast(@max(@as(i32, 1), style.font_size_px))),
        0,
        0,
        0,
        measuredFontWeight(style.font_weight),
        @intFromBool(style.italic),
        0,
        0,
        win.DEFAULT_CHARSET,
        win.OUT_DEFAULT_PRECIS,
        win.CLIP_DEFAULT_PRECIS,
        win.CLEARTYPE_QUALITY,
        font_spec.pitch_family,
        wide_face.ptr,
    );
    if (font == null) return null;
    defer _ = win.DeleteObject(font);

    const old_font = win.SelectObject(hdc, font);
    defer _ = win.SelectObject(hdc, old_font);

    var text_size: win.SIZE = undefined;
    if (win.GetTextExtentPoint32W(hdc, wide_text.ptr, @intCast(wide_text.len), &text_size) == 0) {
        return null;
    }

    var metrics: win.TEXTMETRICW = undefined;
    if (win.GetTextMetricsW(hdc, &metrics) == 0) {
        return null;
    }

    return .{
        .width = @floatFromInt(text_size.cx),
        .actual_bounding_box_ascent = @floatFromInt(metrics.tmAscent),
        .actual_bounding_box_descent = @floatFromInt(metrics.tmDescent),
    };
}

fn drawTextWin32(
    self: *CanvasSurface,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f64,
    y: f64,
    max_width: ?f64,
    style: TextStyle,
    rgba: color.RGBA,
    is_stroke: bool,
) void {
    _ = max_width;
    if (text.len == 0 or self.width == 0 or self.height == 0) return;

    const wide_text = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return;
    defer allocator.free(wide_text);
    if (wide_text.len == 0) return;

    const hdc = win.CreateCompatibleDC(null);
    if (hdc == null) return;
    defer _ = win.DeleteDC(hdc);

    var bmi: win.BITMAPINFO = std.mem.zeroes(win.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @as(i32, @intCast(self.width));
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(self.height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = win.BI_RGB;

    var bits: ?*anyopaque = null;
    const dib = win.CreateDIBSection(hdc, &bmi, win.DIB_RGB_COLORS, &bits, null, 0);
    if (dib == null or bits == null) return;
    defer _ = win.DeleteObject(dib);

    const old_bitmap = win.SelectObject(hdc, dib);
    defer _ = win.SelectObject(hdc, old_bitmap);

    const dib_pixels = @as([*]u8, @ptrCast(bits.?))[0 .. @as(usize, self.width) * self.height * 4];
    @memset(dib_pixels, 0);

    const font_spec = resolveCanvasFontSpec(style.font_family);
    const wide_face = std.unicode.utf8ToUtf16LeAllocZ(allocator, font_spec.face_name) catch return;
    defer allocator.free(wide_face);

    const font = win.CreateFontW(
        -@as(i32, @intCast(@max(@as(i32, 1), style.font_size_px))),
        0,
        0,
        0,
        measuredFontWeight(style.font_weight),
        @intFromBool(style.italic),
        0,
        0,
        win.DEFAULT_CHARSET,
        win.OUT_DEFAULT_PRECIS,
        win.CLIP_DEFAULT_PRECIS,
        win.CLEARTYPE_QUALITY,
        font_spec.pitch_family,
        wide_face.ptr,
    );
    if (font == null) return;
    defer _ = win.DeleteObject(font);

    const old_font = win.SelectObject(hdc, font);
    defer _ = win.SelectObject(hdc, old_font);

    _ = win.SetBkMode(hdc, win.TRANSPARENT);
    _ = win.SetTextColor(hdc, win.RGB(255, 255, 255));

    var text_size: win.SIZE = undefined;
    if (win.GetTextExtentPoint32W(hdc, wide_text.ptr, @intCast(wide_text.len), &text_size) == 0) {
        return;
    }

    var metrics: win.TEXTMETRICW = undefined;
    if (win.GetTextMetricsW(hdc, &metrics) == 0) {
        return;
    }

    const draw_x = resolveAlignedTextX(coordinateFromFloat(x) orelse 0, text_size.cx, style.@"align");
    const draw_y = resolveBaselineTextY(coordinateFromFloat(y) orelse 0, text_size.cy, metrics.tmAscent, style.baseline);

    if (is_stroke) {
        const offsets = [_][2]i32{
            .{ -1, 0 },  .{ 1, 0 },  .{ 0, -1 }, .{ 0, 1 },
            .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 },
        };
        for (offsets) |offset| {
            _ = win.TextOutW(hdc, draw_x + offset[0], draw_y + offset[1], wide_text.ptr, @intCast(wide_text.len));
        }
    } else {
        _ = win.TextOutW(hdc, draw_x, draw_y, wide_text.ptr, @intCast(wide_text.len));
    }

    const bounds_left = std.math.clamp(draw_x - 2, 0, @as(i32, @intCast(self.width)));
    const bounds_top = std.math.clamp(draw_y - 2, 0, @as(i32, @intCast(self.height)));
    const bounds_right = std.math.clamp(draw_x + text_size.cx + 2, 0, @as(i32, @intCast(self.width)));
    const bounds_bottom = std.math.clamp(draw_y + text_size.cy + 2, 0, @as(i32, @intCast(self.height)));

    var row: i32 = bounds_top;
    while (row < bounds_bottom) : (row += 1) {
        var col: i32 = bounds_left;
        while (col < bounds_right) : (col += 1) {
            const dib_index = (@as(usize, @intCast(row)) * self.width + @as(u32, @intCast(col))) * 4;
            const coverage = @max(dib_pixels[dib_index + 0], @max(dib_pixels[dib_index + 1], dib_pixels[dib_index + 2]));
            if (coverage == 0) continue;
            const alpha = @as(u8, @intCast((@as(u16, coverage) * @as(u16, rgba.a) + 127) / 255));
            self.blendPixel(@intCast(col), @intCast(row), .{
                .r = rgba.r,
                .g = rgba.g,
                .b = rgba.b,
                .a = alpha,
            });
        }
    }
}

fn blendPixel(self: *CanvasSurface, x: u32, y: u32, rgba: color.RGBA) void {
    if (x >= self.width or y >= self.height) return;
    const index = self.pixelIndex(x, y);
    const dst_r = self.pixels[index + 0];
    const dst_g = self.pixels[index + 1];
    const dst_b = self.pixels[index + 2];
    const dst_a = self.pixels[index + 3];

    const src_a: u16 = rgba.a;
    const inv_src_a: u16 = 255 - src_a;
    const out_a_u16 = src_a + ((@as(u16, dst_a) * inv_src_a + 127) / 255);
    const out_a: u8 = @intCast(std.math.clamp(out_a_u16, 0, 255));

    self.pixels[index + 0] = @intCast((@as(u16, rgba.r) * src_a + @as(u16, dst_r) * inv_src_a + 127) / 255);
    self.pixels[index + 1] = @intCast((@as(u16, rgba.g) * src_a + @as(u16, dst_g) * inv_src_a + 127) / 255);
    self.pixels[index + 2] = @intCast((@as(u16, rgba.b) * src_a + @as(u16, dst_b) * inv_src_a + 127) / 255);
    self.pixels[index + 3] = out_a;
}

const CanvasFontSpec = struct {
    face_name: []const u8,
    pitch_family: win.DWORD,
};

fn resolveCanvasFontSpec(font_family_value: []const u8) CanvasFontSpec {
    var preferred_specific: []const u8 = "";
    var generic_spec: ?CanvasFontSpec = null;

    var families = std.mem.splitScalar(u8, font_family_value, ',');
    while (families.next()) |raw_family| {
        const family = trimCanvasFontFamily(raw_family);
        if (family.len == 0) continue;
        if (genericCanvasFontSpec(family)) |spec| {
            if (generic_spec == null) generic_spec = spec;
            continue;
        }
        if (preferred_specific.len == 0) preferred_specific = family;
    }

    if (preferred_specific.len > 0) {
        return .{
            .face_name = preferred_specific,
            .pitch_family = if (generic_spec) |spec| spec.pitch_family else @as(win.DWORD, win.DEFAULT_PITCH | win.FF_DONTCARE),
        };
    }
    if (generic_spec) |spec| return spec;
    return .{
        .face_name = "Segoe UI",
        .pitch_family = @as(win.DWORD, win.DEFAULT_PITCH | win.FF_SWISS),
    };
}

fn trimCanvasFontFamily(raw_family: []const u8) []const u8 {
    var family = std.mem.trim(u8, raw_family, &std.ascii.whitespace);
    if (family.len >= 2 and ((family[0] == '"' and family[family.len - 1] == '"') or (family[0] == '\'' and family[family.len - 1] == '\''))) {
        family = family[1 .. family.len - 1];
    }
    return std.mem.trim(u8, family, &std.ascii.whitespace);
}

fn genericCanvasFontSpec(family: []const u8) ?CanvasFontSpec {
    if (std.ascii.eqlIgnoreCase(family, "serif")) {
        return .{ .face_name = "Times New Roman", .pitch_family = @as(win.DWORD, win.VARIABLE_PITCH | win.FF_ROMAN) };
    }
    if (std.ascii.eqlIgnoreCase(family, "sans-serif")) {
        return .{ .face_name = "Segoe UI", .pitch_family = @as(win.DWORD, win.VARIABLE_PITCH | win.FF_SWISS) };
    }
    if (std.ascii.eqlIgnoreCase(family, "monospace")) {
        return .{ .face_name = "Consolas", .pitch_family = @as(win.DWORD, win.FIXED_PITCH | win.FF_MODERN) };
    }
    if (std.ascii.eqlIgnoreCase(family, "cursive")) {
        return .{ .face_name = "Comic Sans MS", .pitch_family = @as(win.DWORD, win.VARIABLE_PITCH | win.FF_SCRIPT) };
    }
    if (std.ascii.eqlIgnoreCase(family, "fantasy")) {
        return .{ .face_name = "Impact", .pitch_family = @as(win.DWORD, win.VARIABLE_PITCH | win.FF_DECORATIVE) };
    }
    return null;
}

fn measuredFontWeight(font_weight: i32) i32 {
    return std.math.clamp(font_weight, 100, 900);
}

fn resolveAlignedTextX(x: i32, width: i32, text_align: TextAlign) i32 {
    return switch (text_align) {
        .left => x,
        .center => x - @divTrunc(width, 2),
        .right => x - width,
    };
}

fn resolveBaselineTextY(y: i32, text_height: i32, ascent: i32, baseline: TextBaseline) i32 {
    return switch (baseline) {
        .top => y,
        .middle => y - @divTrunc(text_height, 2),
        .alphabetic => y - ascent,
        .bottom => y - text_height,
    };
}

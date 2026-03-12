const std = @import("std");

const color = @import("../../color.zig");
const Page = @import("../../Page.zig");

const ImageData = @import("../ImageData.zig");

const CanvasSurface = @This();

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

fn writePixel(self: *CanvasSurface, x: u32, y: u32, rgba: color.RGBA) void {
    if (x >= self.width or y >= self.height) return;
    const index = self.pixelIndex(x, y);
    self.pixels[index + 0] = rgba.r;
    self.pixels[index + 1] = rgba.g;
    self.pixels[index + 2] = rgba.b;
    self.pixels[index + 3] = rgba.a;
}

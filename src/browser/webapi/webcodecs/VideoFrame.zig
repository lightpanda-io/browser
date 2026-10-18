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

// https://w3c.github.io/webcodecs/#videoframe-interface
//
// Frames come from buffers, other frames, or canvases. Our canvases don't
// rasterize, so a canvas-made frame holds the same transparent black that
// getImageData() returns for it. Conversion from YUV to RGB isn't supported.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const common = @import("common.zig");

const Element = @import("../Element.zig");
const DOMRectReadOnly = @import("../DOMRectReadOnly.zig");
const OffscreenCanvas = @import("../canvas/OffscreenCanvas.zig");
const VideoColorSpace = @import("VideoColorSpace.zig");

const Execution = js.Execution;

const VideoFrame = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
// null once closed ([[Detached]]), like _format
_resource: ?*Resource,
_format: ?PixelFormat,
_coded_width: u32,
_coded_height: u32,
_visible: Rect,
_display_width: u32,
_display_height: u32,
_rotation: f64,
_flip: bool,
_timestamp: i64,
_duration: ?u64,
_color_space: VideoColorSpace.Value,

pub const PixelFormat = enum {
    I420,
    I420P10,
    I420P12,
    I420A,
    I420AP10,
    I420AP12,
    I422,
    I422P10,
    I422P12,
    I422A,
    I422AP10,
    I422AP12,
    I444,
    I444P10,
    I444P12,
    I444A,
    I444AP10,
    I444AP12,
    NV12,
    RGBA,
    RGBX,
    BGRA,
    BGRX,

    pub const Plane = struct {
        // bytes per sample times samples per position (2 for NV12's UV)
        sample_bytes: u32,
        // sub-sampling factors
        width: u32,
        height: u32,
    };

    pub fn planes(self: PixelFormat) []const Plane {
        return switch (self) {
            .NV12 => &.{ .{ .sample_bytes = 1, .width = 1, .height = 1 }, .{ .sample_bytes = 2, .width = 2, .height = 2 } },
            .RGBA, .RGBX, .BGRA, .BGRX => &.{.{ .sample_bytes = 4, .width = 1, .height = 1 }},
            inline else => |f| comptime yuvPlanes(@tagName(f)),
        };
    }

    fn yuvPlanes(comptime name: []const u8) []const Plane {
        const bytes: u32 = if (std.mem.endsWith(u8, name, "P10") or std.mem.endsWith(u8, name, "P12")) 2 else 1;
        // I4[20|22|44]...: the third digit picks the chroma sub-sampling
        const chroma: Plane = switch (name[3]) {
            '0' => .{ .sample_bytes = bytes, .width = 2, .height = 2 },
            '2' => .{ .sample_bytes = bytes, .width = 2, .height = 1 },
            '4' => .{ .sample_bytes = bytes, .width = 1, .height = 1 },
            else => unreachable,
        };
        const luma: Plane = .{ .sample_bytes = bytes, .width = 1, .height = 1 };
        const alpha = name.len > 4 and name[4] == 'A';
        return if (alpha) &.{ luma, chroma, chroma, luma } else &.{ luma, chroma, chroma };
    }

    // The format without its alpha plane/channel.
    pub fn opaqueFormat(self: PixelFormat) PixelFormat {
        return switch (self) {
            .I420A => .I420,
            .I420AP10 => .I420P10,
            .I420AP12 => .I420P12,
            .I422A => .I422,
            .I422AP10 => .I422P10,
            .I422AP12 => .I422P12,
            .I444A => .I444,
            .I444AP10 => .I444P10,
            .I444AP12 => .I444P12,
            .RGBA => .RGBX,
            .BGRA => .BGRX,
            else => self,
        };
    }

    pub fn isRgb(self: PixelFormat) bool {
        return switch (self) {
            .RGBA, .RGBX, .BGRA, .BGRX => true,
            else => false,
        };
    }
};

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn ceilDiv(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}

// The pixels, shared by a frame, its clones and the frames made from it.
// Planes are tightly packed, one after the other, in `format`'s layout.
const Resource = struct {
    refs: u32,
    arena: *lp.Arena,
    format: PixelFormat,
    width: u32,
    height: u32,
    data: []u8,

    fn create(format: PixelFormat, width: u32, height: u32, page: *Page) !*Resource {
        var size: u64 = 0;
        for (format.planes()) |plane| {
            size += planeStride(plane, width) * ceilDiv(height, plane.height);
        }
        const arena = try page.getPinnedArena(@as(usize, @intCast(size)) + 128, "VideoFrame.resource");
        errdefer arena.release();

        const self = try arena.create(Resource);
        self.* = .{
            .refs = 1,
            .arena = arena,
            .format = format,
            .width = width,
            .height = height,
            .data = try arena.alloc(u8, @intCast(size)),
        };
        @memset(self.data, 0);
        arena.report();
        return self;
    }

    fn planeStride(plane: PixelFormat.Plane, width: u32) u64 {
        return ceilDiv(width, plane.width) * plane.sample_bytes;
    }

    fn stride(self: *const Resource, index: usize) u64 {
        return planeStride(self.format.planes()[index], self.width);
    }

    fn offset(self: *const Resource, index: usize) u64 {
        var result: u64 = 0;
        for (self.format.planes()[0..index]) |plane| {
            result += planeStride(plane, self.width) * ceilDiv(self.height, plane.height);
        }
        return result;
    }

    fn acquire(self: *Resource) *Resource {
        self.refs += 1;
        return self;
    }

    fn release(self: *Resource) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.arena.release();
        }
    }
};

const RectInit = struct {
    height: f64 = 0,
    width: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
};

const PlaneLayoutInit = struct {
    offset: js.EnforceRange(u32),
    stride: js.EnforceRange(u32),
};

const PlaneLayout = struct {
    offset: u32,
    stride: u32,
};

// VideoFrameBufferInit
const BufferInit = struct {
    codedHeight: js.EnforceRange(u32),
    codedWidth: js.EnforceRange(u32),
    colorSpace: ?VideoColorSpace.Init = null,
    displayHeight: ?js.EnforceRange(u32) = null,
    displayWidth: ?js.EnforceRange(u32) = null,
    duration: ?js.EnforceRange(u64) = null,
    flip: bool = false,
    format: []const u8,
    layout: ?[]const PlaneLayoutInit = null,
    rotation: f64 = 0,
    timestamp: js.EnforceRange(i64),
    transfer: []const js.Value = &.{},
    visibleRect: ?RectInit = null,
};

// VideoFrameInit
const ImageInit = struct {
    alpha: []const u8 = "keep",
    displayHeight: ?js.EnforceRange(u32) = null,
    displayWidth: ?js.EnforceRange(u32) = null,
    duration: ?js.EnforceRange(u64) = null,
    flip: bool = false,
    rotation: f64 = 0,
    timestamp: ?js.EnforceRange(i64) = null,
    visibleRect: ?RectInit = null,
};

fn constructor(source: js.Value, init_: ?js.Value, exec: *const Execution) !*VideoFrame {
    if (source.isArrayBuffer() or source.isArrayBufferView()) {
        const data = try source.toZig(js.AllowSharedBufferSource);
        const init = (try (init_ orelse return error.TypeError).toZig(?BufferInit)) orelse return error.TypeError;
        return fromBuffer(data.bytes, init, exec.page);
    }

    const init: ImageInit = blk: {
        const value = init_ orelse break :blk .{};
        break :blk (try value.toZig(?ImageInit)) orelse .{};
    };

    if (source.toZig(*VideoFrame)) |other| {
        return fromFrame(other, init, exec.page);
    } else |_| {}

    const width: u32, const height: u32 = blk: {
        if (source.toZig(*OffscreenCanvas)) |canvas| {
            break :blk .{ canvas.getWidth(), canvas.getHeight() };
        } else |_| {}
        if (source.toZig(*Element.Html.Canvas)) |canvas| {
            break :blk .{ canvas.getWidth(), canvas.getHeight() };
        } else |_| {}
        // Images and videos have no pixel data for us to take: we don't
        // decode either. "Check the usability of the image argument" fails.
        if (source.toZig(*Element)) |_| {
            return error.InvalidStateError;
        } else |_| {}
        return error.TypeError;
    };
    return fromCanvas(width, height, init, exec.page);
}

fn parseFormat(value: []const u8) !PixelFormat {
    return std.meta.stringToEnum(PixelFormat, value) orelse error.TypeError;
}

// "Parse Rotation": the nearest multiple of 90 (ties up), in [0, 360).
fn parseRotation(rotation: f64) !f64 {
    if (std.math.isFinite(rotation) == false) {
        return error.TypeError;
    }
    // @mod is exact (fmod), whatever the magnitude; the subtraction form isn't.
    const aligned = @floor(@mod(rotation, 360) / 90 + 0.5) * 90;
    return @mod(aligned, 360);
}

fn addRotations(base: f64, base_flip: bool, rotation: f64) f64 {
    const combined = if (base_flip) base - rotation else base + rotation;
    return @mod(combined, 360);
}

// The checks shared by "Parse Visible Rect" and the init validations.
fn parseRect(init: RectInit, coded_width: u32, coded_height: u32, format: ?PixelFormat) !Rect {
    const rect: Rect = .{
        .x = try rectMember(init.x),
        .y = try rectMember(init.y),
        .width = try rectMember(init.width),
        .height = try rectMember(init.height),
    };
    if (rect.width == 0 or rect.height == 0) return error.TypeError;
    if (@as(u64, rect.x) + rect.width > coded_width) return error.TypeError;
    if (@as(u64, rect.y) + rect.height > coded_height) return error.TypeError;
    if (format) |f| {
        // "Verify Rect Offset Alignment"
        for (f.planes()) |plane| {
            if (rect.x % plane.width != 0 or rect.y % plane.height != 0) return error.TypeError;
        }
    }
    return rect;
}

// A DOMRectInit member is an unrestricted double: anything that isn't a
// non-negative value within the coded size (so a u32) is a TypeError. The
// range is checked before converting, which @intFromFloat can't survive.
fn rectMember(value: f64) !u32 {
    if (std.math.isFinite(value) == false or value < 0 or value > std.math.maxInt(u32)) {
        return error.TypeError;
    }
    return @intFromFloat(value);
}

const DisplaySize = struct { width: u32, height: u32 };

fn explicitDisplaySize(width: ?js.EnforceRange(u32), height: ?js.EnforceRange(u32)) !?DisplaySize {
    if ((width == null) != (height == null)) {
        return error.TypeError;
    }
    const w = (width orelse return null).value;
    const h = height.?.value;
    if (w == 0 or h == 0) {
        return error.TypeError;
    }
    return .{ .width = w, .height = h };
}

fn fromBuffer(data: []const u8, init: BufferInit, page: *Page) !*VideoFrame {
    const format = try parseFormat(init.format);
    const coded_width = init.codedWidth.value;
    const coded_height = init.codedHeight.value;
    const timestamp = init.timestamp.value;
    const duration = if (init.duration) |d| d.value else null;
    const display = try explicitDisplaySize(init.displayWidth, init.displayHeight);
    const rotation = try parseRotation(init.rotation);
    const color_space: VideoColorSpace.Value = if (init.colorSpace) |cs| try cs.toValue() else defaultColorSpace(format);

    if (coded_width == 0 or coded_height == 0) {
        return error.TypeError;
    }
    const visible: Rect = if (init.visibleRect) |r|
        try parseRect(r, coded_width, coded_height, format)
    else
        .{ .x = 0, .y = 0, .width = coded_width, .height = coded_height };

    // Like Chrome, `data` (and `layout`) describes the whole coded frame; the
    // visible rectangle is cropped out of it and becomes the new coded size.
    const planes = format.planes();
    const source_layout = try computeLayout(.{ .x = 0, .y = 0, .width = coded_width, .height = coded_height }, format, init.layout);
    if (data.len < source_layout.allocation_size) {
        return error.TypeError;
    }

    const transfer: common.Transfer = .{ .buffers = init.transfer };
    try transfer.check();

    const resource = try Resource.create(format, visible.width, visible.height, page);

    for (planes, 0..) |plane, i| {
        const source = source_layout.planes[i];
        const row_bytes = Resource.planeStride(plane, visible.width);
        const rows = ceilDiv(visible.height, plane.height);
        var src: u64 = source.offset + (visible.y / plane.height) * source.stride + (visible.x / plane.width) * plane.sample_bytes;
        var dst = resource.offset(i);
        for (0..rows) |_| {
            @memcpy(resource.data[@intCast(dst)..][0..@intCast(row_bytes)], data[@intCast(src)..][0..@intCast(row_bytes)]);
            src += source.stride;
            dst += row_bytes;
        }
    }

    const self = try create(resource, page);
    errdefer self.deinit(page);
    self.* = .{
        ._arena = self._arena,
        ._resource = resource,
        ._format = format,
        ._coded_width = visible.width,
        ._coded_height = visible.height,
        ._visible = .{ .x = 0, .y = 0, .width = visible.width, .height = visible.height },
        ._rotation = rotation,
        ._flip = init.flip,
        ._display_width = undefined,
        ._display_height = undefined,
        ._timestamp = timestamp,
        ._duration = duration,
        ._color_space = color_space,
    };
    if (display) |d| {
        self._display_width = d.width;
        self._display_height = d.height;
    } else if (rotation == 0 or rotation == 180) {
        self._display_width = visible.width;
        self._display_height = visible.height;
    } else {
        self._display_width = visible.height;
        self._display_height = visible.width;
    }

    try transfer.detach();
    return self;
}

// "Pick Color Space" without an override.
fn defaultColorSpace(format: PixelFormat) VideoColorSpace.Value {
    if (format.isRgb()) {
        // sRGB
        return .{ .primaries = .bt709, .transfer = .@"iec61966-2-1", .matrix = .rgb, .fullRange = true };
    }
    // REC709
    return .{ .primaries = .bt709, .transfer = .bt709, .matrix = .bt709, .fullRange = false };
}

fn parseAlpha(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "keep")) return true;
    if (std.mem.eql(u8, value, "discard")) return false;
    return error.TypeError;
}

// "Initialize Frame From Other Frame"
fn fromFrame(other: *const VideoFrame, init: ImageInit, page: *Page) !*VideoFrame {
    const other_format = other._format orelse return error.InvalidStateError;
    const resource = other._resource.?;
    const keep_alpha = try parseAlpha(init.alpha);
    const format = if (keep_alpha) other_format else other_format.opaqueFormat();
    const timestamp = if (init.timestamp) |t| t.value else other._timestamp;
    const duration = if (init.duration) |d| d.value else other._duration;

    const self = try create(resource.acquire(), page);
    errdefer self.deinit(page);
    self.* = .{
        ._arena = self._arena,
        ._resource = resource,
        ._format = format,
        ._coded_width = other._coded_width,
        ._coded_height = other._coded_height,
        ._visible = other._visible,
        ._rotation = other._rotation,
        ._flip = other._flip,
        ._display_width = other._display_width,
        ._display_height = other._display_height,
        ._timestamp = timestamp,
        ._duration = duration,
        ._color_space = other._color_space,
    };
    try self.initOrientation(init, format, other._visible, other._rotation, other._flip, other._display_width, other._display_height);
    return self;
}

// HTMLCanvasElement / OffscreenCanvas
// Chrome's media::limits: a canvas larger than this has no bitmap there, so
// "Check the usability of the image argument" fails. Ours would happily be
// that large, and the frame would allocate width * height * 4 bytes.
const max_canvas_dimension = 32767;
const max_canvas_pixels = 1 << 28;

fn fromCanvas(width: u32, height: u32, init: ImageInit, page: *Page) !*VideoFrame {
    if (width == 0 or height == 0) {
        return error.InvalidStateError;
    }
    if (width > max_canvas_dimension or height > max_canvas_dimension or @as(u64, width) * height > max_canvas_pixels) {
        return error.InvalidStateError;
    }
    const timestamp = (init.timestamp orelse return error.TypeError).value;
    const duration = if (init.duration) |d| d.value else null;
    const keep_alpha = try parseAlpha(init.alpha);
    const format: PixelFormat = if (keep_alpha) .RGBA else .RGBX;

    const resource = try Resource.create(.RGBA, width, height, page);

    const self = try create(resource, page);
    errdefer self.deinit(page);
    const visible: Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
    self.* = .{
        ._arena = self._arena,
        ._resource = resource,
        ._format = format,
        ._coded_width = width,
        ._coded_height = height,
        ._visible = visible,
        ._rotation = 0,
        ._flip = false,
        ._display_width = width,
        ._display_height = height,
        ._timestamp = timestamp,
        ._duration = duration,
        ._color_space = .{},
    };
    try self.initOrientation(init, format, visible, 0, false, width, height);
    return self;
}

// "Initialize Visible Rect, Orientation, and Display Size", plus the bits of
// "Validate VideoFrameInit" it doesn't already cover.
fn initOrientation(self: *VideoFrame, init: ImageInit, format: PixelFormat, default_visible: Rect, base_rotation: f64, base_flip: bool, default_display_width: u32, default_display_height: u32) !void {
    const display = try explicitDisplaySize(init.displayWidth, init.displayHeight);
    if (init.visibleRect) |r| {
        self._visible = try parseRect(r, self._coded_width, self._coded_height, format);
    }
    const rotation = try parseRotation(init.rotation);
    self._rotation = addRotations(base_rotation, base_flip, rotation);
    self._flip = base_flip != init.flip;

    if (display) |d| {
        self._display_width = d.width;
        self._display_height = d.height;
        return;
    }

    const default_w: f64 = @floatFromInt(default_visible.width);
    const default_h: f64 = @floatFromInt(default_visible.height);
    const width_scale, const height_scale = if (base_rotation == 0 or base_rotation == 180)
        .{ @as(f64, @floatFromInt(default_display_width)) / default_w, @as(f64, @floatFromInt(default_display_height)) / default_h }
    else
        .{ @as(f64, @floatFromInt(default_display_height)) / default_w, @as(f64, @floatFromInt(default_display_width)) / default_h };

    const display_width = @round(@as(f64, @floatFromInt(self._visible.width)) * width_scale);
    const display_height = @round(@as(f64, @floatFromInt(self._visible.height)) * height_scale);
    if (display_width == 0 or display_height == 0) {
        return error.TypeError;
    }
    const w = std.math.cast(u32, @as(u64, @intFromFloat(display_width))) orelse return error.TypeError;
    const h = std.math.cast(u32, @as(u64, @intFromFloat(display_height))) orelse return error.TypeError;
    if (rotation == 0 or rotation == 180) {
        self._display_width = w;
        self._display_height = h;
    } else {
        self._display_width = h;
        self._display_height = w;
    }
}

// Allocates the frame, which takes over the caller's reference to `resource`
// (released here on failure). The caller fills in every other field.
fn create(resource: *Resource, page: *Page) !*VideoFrame {
    errdefer resource.release();
    const arena = try page.getPinnedArena(.tiny, "VideoFrame");
    errdefer arena.release();
    const self = try arena.create(VideoFrame);
    self._arena = arena;
    self._rc = .{};
    self._resource = resource;
    return self;
}

pub fn deinit(self: *VideoFrame, _: *Page) void {
    if (self._resource) |resource| {
        resource.release();
    }
    self._arena.release();
}

pub fn acquireRef(self: *VideoFrame) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *VideoFrame, page: *Page) void {
    self._rc.release(self, page);
}

pub fn isClosed(self: *const VideoFrame) bool {
    return self._format == null;
}

fn getFormat(self: *const VideoFrame) ?[]const u8 {
    const format = self._format orelse return null;
    return @tagName(format);
}

fn getCodedWidth(self: *const VideoFrame) u32 {
    return self._coded_width;
}

fn getCodedHeight(self: *const VideoFrame) u32 {
    return self._coded_height;
}

fn getCodedRect(self: *const VideoFrame, exec: *const Execution) !?*DOMRectReadOnly {
    if (self.isClosed()) return null;
    return try DOMRectReadOnly.init(0, 0, @floatFromInt(self._coded_width), @floatFromInt(self._coded_height), exec);
}

fn getVisibleRect(self: *const VideoFrame, exec: *const Execution) !?*DOMRectReadOnly {
    if (self.isClosed()) return null;
    const v = self._visible;
    return try DOMRectReadOnly.init(@floatFromInt(v.x), @floatFromInt(v.y), @floatFromInt(v.width), @floatFromInt(v.height), exec);
}

fn getRotation(self: *const VideoFrame) f64 {
    return self._rotation;
}

fn getFlip(self: *const VideoFrame) bool {
    return self._flip;
}

fn getDisplayWidth(self: *const VideoFrame) u32 {
    return self._display_width;
}

fn getDisplayHeight(self: *const VideoFrame) u32 {
    return self._display_height;
}

fn getTimestamp(self: *const VideoFrame) i64 {
    return self._timestamp;
}

fn getDuration(self: *const VideoFrame) ?u64 {
    return self._duration;
}

fn getColorSpace(self: *const VideoFrame, exec: *const Execution) !*VideoColorSpace {
    return VideoColorSpace.create(self._color_space, exec.page);
}

// VideoFrameMetadata has no members of its own, and we support none from
// the registry: it's always an empty dictionary.
fn metadata(self: *const VideoFrame) !struct {} {
    if (self.isClosed()) return error.InvalidStateError;
    return .{};
}

const max_planes = 4;

// A "combined buffer layout"
const ComputedLayout = struct {
    allocation_size: u32,
    planes: [max_planes]ComputedPlane,
};

const ComputedPlane = struct {
    // where the plane goes in the destination
    offset: u64,
    stride: u64,
    // the part of the source plane copied
    source_top: u64,
    source_height: u64,
    source_left_bytes: u64,
    source_width_bytes: u64,
};

// "Compute Layout and Allocation Size"
fn computeLayout(rect: Rect, format: PixelFormat, layout: ?[]const PlaneLayoutInit) !ComputedLayout {
    const planes = format.planes();
    if (layout) |l| {
        if (l.len != planes.len) return error.TypeError;
    }

    var result: [max_planes]ComputedPlane = undefined;
    var ends: [max_planes]u64 = undefined;
    var min_size: u64 = 0;
    for (planes, 0..) |plane, i| {
        var computed: ComputedPlane = .{
            .source_top = ceilDiv(rect.y, plane.height),
            .source_height = ceilDiv(rect.height, plane.height),
            .source_left_bytes = (rect.x / plane.width) * plane.sample_bytes,
            .source_width_bytes = ceilDiv(rect.width, plane.width) * plane.sample_bytes,
            .offset = undefined,
            .stride = undefined,
        };
        if (layout) |l| {
            const stride = l[i].stride.value;
            if (stride < computed.source_width_bytes) return error.TypeError;
            computed.offset = l[i].offset.value;
            computed.stride = stride;
        } else {
            computed.offset = min_size;
            computed.stride = computed.source_width_bytes;
        }

        const plane_size = computed.stride * computed.source_height;
        const plane_end = plane_size + computed.offset;
        if (plane_size > std.math.maxInt(u32) or plane_end > std.math.maxInt(u32)) {
            return error.TypeError;
        }
        ends[i] = plane_end;
        min_size = @max(min_size, plane_end);

        for (result[0..i], 0..) |earlier, j| {
            if (plane_end <= earlier.offset or ends[j] <= computed.offset) continue;
            return error.TypeError;
        }
        result[i] = computed;
    }
    return .{ .allocation_size = @intCast(min_size), .planes = result };
}

const CopyToOptions = struct {
    colorSpace: ?[]const u8 = null,
    format: ?[]const u8 = null,
    layout: ?[]const PlaneLayoutInit = null,
    rect: ?RectInit = null,
};

// "Parse VideoFrameCopyToOptions"
fn parseCopyOptions(self: *const VideoFrame, options: CopyToOptions) !struct { format: PixelFormat, layout: ComputedLayout } {
    const source_format = self._format orelse return error.InvalidStateError;
    const format: PixelFormat = if (options.format) |f| blk: {
        const requested = try parseFormat(f);
        if (requested.isRgb() == false) return error.NotSupported;
        break :blk requested;
    } else source_format;

    if (options.colorSpace) |cs| {
        if (std.mem.eql(u8, cs, "srgb") == false and std.mem.eql(u8, cs, "display-p3") == false) {
            return error.TypeError;
        }
    }

    const rect = if (options.rect) |r|
        try parseRect(r, self._coded_width, self._coded_height, source_format)
    else
        self._visible;

    return .{ .format = format, .layout = try computeLayout(rect, format, options.layout) };
}

fn allocationSize(self: *const VideoFrame, options_: ?CopyToOptions) !u32 {
    const parsed = try self.parseCopyOptions(options_ orelse .{});
    return parsed.layout.allocation_size;
}

fn copyTo(self: *const VideoFrame, destination: js.AllowSharedBufferSource, options_: ?CopyToOptions, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const layouts = self.copyInto(destination.bytes, options_ orelse .{}) catch |err| {
        return local.rejectPromise(switch (err) {
            error.TypeError => .{ .type_error = "" },
            else => .{ .dom_exception = .{ .err = err } },
        });
    };
    return local.resolvePromise(layouts.slice());
}

const Layouts = struct {
    items: [max_planes]PlaneLayout,
    len: usize,

    fn slice(self: *const Layouts) []const PlaneLayout {
        return self.items[0..self.len];
    }
};

fn copyInto(self: *const VideoFrame, dest: []u8, options: CopyToOptions) !Layouts {
    const parsed = try self.parseCopyOptions(options);
    if (dest.len < parsed.layout.allocation_size) {
        return error.TypeError;
    }

    const source_format = self._format.?;
    const resource = self._resource.?;

    if (parsed.format != source_format) {
        // Only between the RGB formats: a channel shuffle.
        if (source_format.isRgb() == false) return error.NotSupported;
        if (options.colorSpace) |cs| {
            if (std.mem.eql(u8, cs, "srgb") == false) return error.NotSupported;
        }
    }

    var layouts: Layouts = .{ .items = undefined, .len = 0 };
    for (parsed.format.planes(), 0..) |_, i| {
        const computed = parsed.layout.planes[i];
        const source_stride = resource.stride(i);
        var src = resource.offset(i) + computed.source_top * source_stride + computed.source_left_bytes;
        var dst = computed.offset;
        for (0..computed.source_height) |_| {
            const out = dest[@intCast(dst)..][0..@intCast(computed.source_width_bytes)];
            const in = resource.data[@intCast(src)..][0..@intCast(computed.source_width_bytes)];
            if (parsed.format == source_format) {
                @memcpy(out, in);
            } else {
                convertRgbRow(source_format, parsed.format, in, out);
            }
            src += source_stride;
            dst += computed.stride;
        }
        // The spec says the row bytes, but Chrome (and WPT) give the
        // destination's stride, which is what a caller needs to read it back.
        layouts.items[i] = .{ .offset = @intCast(computed.offset), .stride = @intCast(computed.stride) };
        layouts.len += 1;
    }
    return layouts;
}

fn convertRgbRow(from: PixelFormat, to: PixelFormat, in: []const u8, out: []u8) void {
    const from_bgr = from == .BGRA or from == .BGRX;
    const to_bgr = to == .BGRA or to == .BGRX;
    const opaque_source = from == .RGBX or from == .BGRX;
    const opaque_dest = to == .RGBX or to == .BGRX;
    var i: usize = 0;
    while (i + 4 <= in.len) : (i += 4) {
        const px = in[i..][0..4];
        const r, const b = if (from_bgr) .{ px[2], px[0] } else .{ px[0], px[2] };
        out[i + 0] = if (to_bgr) b else r;
        out[i + 1] = px[1];
        out[i + 2] = if (to_bgr) r else b;
        out[i + 3] = if (opaque_source or opaque_dest) 255 else px[3];
    }
}

fn clone(self: *const VideoFrame, exec: *const Execution) !*VideoFrame {
    if (self.isClosed()) {
        return error.InvalidStateError;
    }
    const resource = self._resource.?;
    const copy = try create(resource.acquire(), exec.page);
    const arena = copy._arena;
    copy.* = self.*;
    copy._rc = .{};
    copy._arena = arena;
    return copy;
}

// "Close VideoFrame". The timestamp and duration survive.
pub fn close(self: *VideoFrame) void {
    if (self._resource) |resource| {
        resource.release();
        self._resource = null;
    }
    self._format = null;
    self._coded_width = 0;
    self._coded_height = 0;
    self._visible = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    self._rotation = 0;
    self._display_width = 0;
    self._display_height = 0;
    self._flip = false;
    self._color_space = .{};
}

pub fn structuredSerialize(self: *const VideoFrame, writer: *js.StructuredWriter) !void {
    const format = self._format orelse return error.DataClone;
    const resource = self._resource.?;
    writer.writeUint32(@backingInt(resource.format));
    writer.writeUint32(resource.width);
    writer.writeUint32(resource.height);
    writer.writeBytes(resource.data);
    writer.writeUint32(@backingInt(format));
    writer.writeUint32(self._coded_width);
    writer.writeUint32(self._coded_height);
    writer.writeUint32(self._visible.x);
    writer.writeUint32(self._visible.y);
    writer.writeUint32(self._visible.width);
    writer.writeUint32(self._visible.height);
    writer.writeUint32(self._display_width);
    writer.writeUint32(self._display_height);
    writer.writeUint32(@intFromFloat(self._rotation));
    writer.writeUint32(@intFromBool(self._flip));
    writer.writeUint64(@bitCast(self._timestamp));
    writer.writeUint32(@intFromBool(self._duration != null));
    writer.writeUint64(self._duration orelse 0);
    const cs = self._color_space;
    writer.writeUint32(if (cs.primaries) |v| @as(u32, @backingInt(v)) + 1 else 0);
    writer.writeUint32(if (cs.transfer) |v| @as(u32, @backingInt(v)) + 1 else 0);
    writer.writeUint32(if (cs.matrix) |v| @as(u32, @backingInt(v)) + 1 else 0);
    writer.writeUint32(if (cs.fullRange) |v| @as(u32, @intFromBool(v)) + 1 else 0);
}

fn readOptionalEnum(comptime E: type, reader: *js.StructuredReader) !?E {
    const v = try reader.readUint32();
    if (v == 0) return null;
    return std.enums.fromInt(E, v - 1) orelse error.DataClone;
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*VideoFrame {
    const resource_format = std.enums.fromInt(PixelFormat, try reader.readUint32()) orelse return error.DataClone;
    const width = try reader.readUint32();
    const height = try reader.readUint32();
    const data = try reader.readBytes();
    const format = std.enums.fromInt(PixelFormat, try reader.readUint32()) orelse return error.DataClone;
    const coded_width = try reader.readUint32();
    const coded_height = try reader.readUint32();
    const visible: Rect = .{
        .x = try reader.readUint32(),
        .y = try reader.readUint32(),
        .width = try reader.readUint32(),
        .height = try reader.readUint32(),
    };
    const display_width = try reader.readUint32();
    const display_height = try reader.readUint32();
    const rotation: f64 = @floatFromInt(try reader.readUint32());
    const flip = try reader.readUint32() != 0;
    const timestamp: i64 = @bitCast(try reader.readUint64());
    const has_duration = try reader.readUint32() != 0;
    const duration = try reader.readUint64();
    const color_space: VideoColorSpace.Value = .{
        .primaries = try readOptionalEnum(VideoColorSpace.Primaries, reader),
        .transfer = try readOptionalEnum(VideoColorSpace.Transfer, reader),
        .matrix = try readOptionalEnum(VideoColorSpace.Matrix, reader),
        .fullRange = blk: {
            const v = try reader.readUint32();
            break :blk if (v == 0) null else v == 2;
        },
    };

    const resource = try Resource.create(resource_format, width, height, page);
    if (data.len != resource.data.len) {
        resource.release();
        return error.DataClone;
    }
    @memcpy(resource.data, data);

    const self = try create(resource, page);
    self.* = .{
        ._arena = self._arena,
        ._resource = resource,
        ._format = format,
        ._coded_width = coded_width,
        ._coded_height = coded_height,
        ._visible = visible,
        ._display_width = display_width,
        ._display_height = display_height,
        ._rotation = rotation,
        ._flip = flip,
        ._timestamp = timestamp,
        ._duration = if (has_duration) duration else null,
        ._color_space = color_space,
    };
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VideoFrame);

    pub const Meta = struct {
        pub const name = "VideoFrame";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(VideoFrame.constructor, .{});
    pub const format = bridge.accessor(VideoFrame.getFormat, null, .{});
    pub const codedWidth = bridge.accessor(VideoFrame.getCodedWidth, null, .{});
    pub const codedHeight = bridge.accessor(VideoFrame.getCodedHeight, null, .{});
    pub const codedRect = bridge.accessor(VideoFrame.getCodedRect, null, .{});
    pub const visibleRect = bridge.accessor(VideoFrame.getVisibleRect, null, .{});
    pub const rotation = bridge.accessor(VideoFrame.getRotation, null, .{});
    pub const flip = bridge.accessor(VideoFrame.getFlip, null, .{});
    pub const displayWidth = bridge.accessor(VideoFrame.getDisplayWidth, null, .{});
    pub const displayHeight = bridge.accessor(VideoFrame.getDisplayHeight, null, .{});
    pub const duration = bridge.accessor(VideoFrame.getDuration, null, .{});
    pub const timestamp = bridge.accessor(VideoFrame.getTimestamp, null, .{});
    pub const colorSpace = bridge.accessor(VideoFrame.getColorSpace, null, .{});
    pub const metadata = bridge.function(VideoFrame.metadata, .{});
    pub const allocationSize = bridge.function(VideoFrame.allocationSize, .{});
    pub const copyTo = bridge.function(VideoFrame.copyTo, .{});
    pub const clone = bridge.function(VideoFrame.clone, .{});
    pub const close = bridge.function(VideoFrame.close, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: VideoFrame" {
    try testing.htmlRunner("webcodecs/video_frame.html", .{});
}

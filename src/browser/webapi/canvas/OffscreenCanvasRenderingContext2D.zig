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

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `OffscreenCanvas#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvasRenderingContext2D
const OffscreenCanvasRenderingContext2D = @This();
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,

pub fn getFillStyle(self: *const OffscreenCanvasRenderingContext2D, page: *Page) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(page.call_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *OffscreenCanvasRenderingContext2D,
    value: []const u8,
) !void {
    // Prefer the same fill_style if fails.
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getGlobalAlpha(_: *const OffscreenCanvasRenderingContext2D) f64 {
    return 1.0;
}

pub fn getGlobalCompositeOperation(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "source-over";
}

pub fn getStrokeStyle(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "#000000";
}

pub fn getLineWidth(_: *const OffscreenCanvasRenderingContext2D) f64 {
    return 1.0;
}

pub fn getLineCap(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "butt";
}

pub fn getLineJoin(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "miter";
}

pub fn getMiterLimit(_: *const OffscreenCanvasRenderingContext2D) f64 {
    return 10.0;
}

pub fn getFont(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "10px sans-serif";
}

pub fn getTextAlign(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "start";
}

pub fn getTextBaseline(_: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return "alphabetic";
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const OffscreenCanvasRenderingContext2D,
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

pub fn putImageData(_: *const OffscreenCanvasRenderingContext2D, _: *ImageData, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn save(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn restore(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn scale(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *OffscreenCanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn setGlobalAlpha(_: *OffscreenCanvasRenderingContext2D, _: f64) void {}
pub fn setGlobalCompositeOperation(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setStrokeStyle(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setLineWidth(_: *OffscreenCanvasRenderingContext2D, _: f64) void {}
pub fn setLineCap(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setLineJoin(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setMiterLimit(_: *OffscreenCanvasRenderingContext2D, _: f64) void {}
pub fn clearRect(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fillRect(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn strokeRect(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn beginPath(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn closePath(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn moveTo(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn lineTo(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn quadraticCurveTo(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn bezierCurveTo(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn arc(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn arcTo(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn rect(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fill(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn stroke(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn clip(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn setFont(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setTextAlign(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn setTextBaseline(_: *OffscreenCanvasRenderingContext2D, _: []const u8) void {}
pub fn fillText(_: *OffscreenCanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *OffscreenCanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "OffscreenCanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const createImageData = bridge.function(OffscreenCanvasRenderingContext2D.createImageData, .{ .dom_exception = true });
    pub const putImageData = bridge.function(OffscreenCanvasRenderingContext2D.putImageData, .{});

    pub const save = bridge.function(OffscreenCanvasRenderingContext2D.save, .{});
    pub const restore = bridge.function(OffscreenCanvasRenderingContext2D.restore, .{});

    pub const scale = bridge.function(OffscreenCanvasRenderingContext2D.scale, .{});
    pub const rotate = bridge.function(OffscreenCanvasRenderingContext2D.rotate, .{});
    pub const translate = bridge.function(OffscreenCanvasRenderingContext2D.translate, .{});
    pub const transform = bridge.function(OffscreenCanvasRenderingContext2D.transform, .{});
    pub const setTransform = bridge.function(OffscreenCanvasRenderingContext2D.setTransform, .{});
    pub const resetTransform = bridge.function(OffscreenCanvasRenderingContext2D.resetTransform, .{});

    pub const globalAlpha = bridge.accessor(OffscreenCanvasRenderingContext2D.getGlobalAlpha, OffscreenCanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const globalCompositeOperation = bridge.accessor(OffscreenCanvasRenderingContext2D.getGlobalCompositeOperation, OffscreenCanvasRenderingContext2D.setGlobalCompositeOperation, .{});

    pub const fillStyle = bridge.accessor(OffscreenCanvasRenderingContext2D.getFillStyle, OffscreenCanvasRenderingContext2D.setFillStyle, .{});
    pub const strokeStyle = bridge.accessor(OffscreenCanvasRenderingContext2D.getStrokeStyle, OffscreenCanvasRenderingContext2D.setStrokeStyle, .{});

    pub const lineWidth = bridge.accessor(OffscreenCanvasRenderingContext2D.getLineWidth, OffscreenCanvasRenderingContext2D.setLineWidth, .{});
    pub const lineCap = bridge.accessor(OffscreenCanvasRenderingContext2D.getLineCap, OffscreenCanvasRenderingContext2D.setLineCap, .{});
    pub const lineJoin = bridge.accessor(OffscreenCanvasRenderingContext2D.getLineJoin, OffscreenCanvasRenderingContext2D.setLineJoin, .{});
    pub const miterLimit = bridge.accessor(OffscreenCanvasRenderingContext2D.getMiterLimit, OffscreenCanvasRenderingContext2D.setMiterLimit, .{});

    pub const clearRect = bridge.function(OffscreenCanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(OffscreenCanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(OffscreenCanvasRenderingContext2D.strokeRect, .{});

    pub const beginPath = bridge.function(OffscreenCanvasRenderingContext2D.beginPath, .{});
    pub const closePath = bridge.function(OffscreenCanvasRenderingContext2D.closePath, .{});
    pub const moveTo = bridge.function(OffscreenCanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(OffscreenCanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(OffscreenCanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const bezierCurveTo = bridge.function(OffscreenCanvasRenderingContext2D.bezierCurveTo, .{});
    pub const arc = bridge.function(OffscreenCanvasRenderingContext2D.arc, .{});
    pub const arcTo = bridge.function(OffscreenCanvasRenderingContext2D.arcTo, .{});
    pub const rect = bridge.function(OffscreenCanvasRenderingContext2D.rect, .{});

    pub const fill = bridge.function(OffscreenCanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(OffscreenCanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(OffscreenCanvasRenderingContext2D.clip, .{});

    pub const font = bridge.accessor(OffscreenCanvasRenderingContext2D.getFont, OffscreenCanvasRenderingContext2D.setFont, .{});
    pub const textAlign = bridge.accessor(OffscreenCanvasRenderingContext2D.getTextAlign, OffscreenCanvasRenderingContext2D.setTextAlign, .{});
    pub const textBaseline = bridge.accessor(OffscreenCanvasRenderingContext2D.getTextBaseline, OffscreenCanvasRenderingContext2D.setTextBaseline, .{});
    pub const fillText = bridge.function(OffscreenCanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(OffscreenCanvasRenderingContext2D.strokeText, .{});
};

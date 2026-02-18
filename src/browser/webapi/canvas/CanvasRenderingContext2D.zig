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
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,

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

pub fn getGlobalAlpha(_: *const CanvasRenderingContext2D) f64 {
    return 1.0;
}

pub fn getGlobalCompositeOperation(_: *const CanvasRenderingContext2D) []const u8 {
    return "source-over";
}

pub fn getStrokeStyle(_: *const CanvasRenderingContext2D) []const u8 {
    return "#000000";
}

pub fn getLineWidth(_: *const CanvasRenderingContext2D) f64 {
    return 1.0;
}

pub fn getLineCap(_: *const CanvasRenderingContext2D) []const u8 {
    return "butt";
}

pub fn getLineJoin(_: *const CanvasRenderingContext2D) []const u8 {
    return "miter";
}

pub fn getMiterLimit(_: *const CanvasRenderingContext2D) f64 {
    return 10.0;
}

pub fn getFont(_: *const CanvasRenderingContext2D) []const u8 {
    return "10px sans-serif";
}

pub fn getTextAlign(_: *const CanvasRenderingContext2D) []const u8 {
    return "start";
}

pub fn getTextBaseline(_: *const CanvasRenderingContext2D) []const u8 {
    return "alphabetic";
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
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

pub fn putImageData(_: *const CanvasRenderingContext2D, _: *ImageData, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn save(_: *CanvasRenderingContext2D) void {}
pub fn restore(_: *CanvasRenderingContext2D) void {}
pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn setGlobalAlpha(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn setGlobalCompositeOperation(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setStrokeStyle(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setLineWidth(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn setLineCap(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setLineJoin(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setMiterLimit(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn clearRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fillRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn strokeRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn beginPath(_: *CanvasRenderingContext2D) void {}
pub fn closePath(_: *CanvasRenderingContext2D) void {}
pub fn moveTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn lineTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn quadraticCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn bezierCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn arc(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn arcTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn rect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fill(_: *CanvasRenderingContext2D) void {}
pub fn stroke(_: *CanvasRenderingContext2D) void {}
pub fn clip(_: *CanvasRenderingContext2D) void {}
pub fn setFont(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setTextAlign(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn setTextBaseline(_: *CanvasRenderingContext2D, _: []const u8) void {}
pub fn fillText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{ .dom_exception = true });
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});

    pub const save = bridge.function(CanvasRenderingContext2D.save, .{});
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{});

    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{});
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{});
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{});
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{});
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{});
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{});

    pub const globalAlpha = bridge.accessor(CanvasRenderingContext2D.getGlobalAlpha, CanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const globalCompositeOperation = bridge.accessor(CanvasRenderingContext2D.getGlobalCompositeOperation, CanvasRenderingContext2D.setGlobalCompositeOperation, .{});

    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});

    pub const lineWidth = bridge.accessor(CanvasRenderingContext2D.getLineWidth, CanvasRenderingContext2D.setLineWidth, .{});
    pub const lineCap = bridge.accessor(CanvasRenderingContext2D.getLineCap, CanvasRenderingContext2D.setLineCap, .{});
    pub const lineJoin = bridge.accessor(CanvasRenderingContext2D.getLineJoin, CanvasRenderingContext2D.setLineJoin, .{});
    pub const miterLimit = bridge.accessor(CanvasRenderingContext2D.getMiterLimit, CanvasRenderingContext2D.setMiterLimit, .{});

    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});

    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{});
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{});
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{});
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{});
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});

    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{});

    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const textAlign = bridge.accessor(CanvasRenderingContext2D.getTextAlign, CanvasRenderingContext2D.setTextAlign, .{});
    pub const textBaseline = bridge.accessor(CanvasRenderingContext2D.getTextBaseline, CanvasRenderingContext2D.setTextBaseline, .{});
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

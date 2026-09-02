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

const Canvas = @import("../element/html/Canvas.zig");
const ImageData = @import("../ImageData.zig");
const context2d = @import("context2d.zig");
const TextMetrics = @import("TextMetrics.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const CanvasPattern = @import("CanvasPattern.zig");

const Execution = js.Execution;

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Reference to the parent canvas element.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/canvas
_canvas: *Canvas,
_state: context2d.State = .{},

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, exec: *const Execution) !context2d.StyleOutput {
    return self._state.getStyle(.fill, exec);
}

pub fn setFillStyle(self: *CanvasRenderingContext2D, value: context2d.StyleInput) void {
    self._state.setStyle(.fill, value);
}

pub fn getStrokeStyle(self: *const CanvasRenderingContext2D, exec: *const Execution) !context2d.StyleOutput {
    return self._state.getStyle(.stroke, exec);
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: context2d.StyleInput) void {
    self._state.setStyle(.stroke, value);
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

pub fn putImageData(_: *const CanvasRenderingContext2D, _: *ImageData, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

// CanvasImageSource (HTMLImageElement, HTMLCanvasElement, ImageBitmap, ...) is
// just taken as a js.Value for now since we don't use it, and that's much easier.
pub fn drawImage(_: *const CanvasRenderingContext2D, _: js.Value, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn getImageData(
    _: *const CanvasRenderingContext2D,
    _: i32, // sx
    _: i32, // sy
    sw: i32,
    sh: i32,
    exec: *Execution,
) !*ImageData {
    if (sw <= 0 or sh <= 0) {
        return error.IndexSizeError;
    }
    return ImageData.init(@intCast(sw), @intCast(sh), null, exec);
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._state.font();
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8, exec: *const Execution) !void {
    return self._state.setFont(value, exec);
}

pub fn measureText(self: *const CanvasRenderingContext2D, text: []const u8, exec: *const Execution) !*TextMetrics {
    return self._state.measureText(text, exec);
}

pub fn setLineDash(self: *CanvasRenderingContext2D, segments: []const f64, exec: *const Execution) !void {
    return self._state.setLineDash(segments, exec);
}

pub fn getLineDash(self: *const CanvasRenderingContext2D) []const f64 {
    return self._state.lineDash();
}

pub fn roundRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: ?js.Value) void {}
pub fn ellipse(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn isPointInPath(_: *const CanvasRenderingContext2D, _: js.Value, _: ?js.Value, _: ?js.Value, _: ?js.Value) bool {
    return false;
}
pub fn isPointInStroke(_: *const CanvasRenderingContext2D, _: js.Value, _: ?js.Value, _: ?js.Value) bool {
    return false;
}

pub fn createLinearGradient(_: *const CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createRadialGradient(_: *const CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createConicGradient(_: *const CanvasRenderingContext2D, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createPattern(_: *const CanvasRenderingContext2D, _: js.Value, repetition_: ?[]const u8, exec: *const Execution) !*CanvasPattern {
    const repetition = repetition_ orelse "repeat";
    const known = [_][]const u8{ "", "repeat", "repeat-x", "repeat-y", "no-repeat" };
    for (known) |k| {
        if (std.mem.eql(u8, repetition, k)) return CanvasPattern.init(k, exec);
    }
    return error.SyntaxError;
}

pub fn save(_: *CanvasRenderingContext2D) void {}
pub fn restore(_: *CanvasRenderingContext2D) void {}
pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
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
pub fn fillText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});
    pub const setLineDash = bridge.function(CanvasRenderingContext2D.setLineDash, .{});
    pub const getLineDash = bridge.function(CanvasRenderingContext2D.getLineDash, .{});
    pub const lineDashOffset = bridge.property(0.0, .{ .template = false, .readonly = false });
    pub const roundRect = bridge.function(CanvasRenderingContext2D.roundRect, .{ .noop = true });
    pub const ellipse = bridge.function(CanvasRenderingContext2D.ellipse, .{ .noop = true });
    pub const isPointInPath = bridge.function(CanvasRenderingContext2D.isPointInPath, .{});
    pub const isPointInStroke = bridge.function(CanvasRenderingContext2D.isPointInStroke, .{});
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{});
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{});
    pub const createConicGradient = bridge.function(CanvasRenderingContext2D.createConicGradient, .{});
    pub const createPattern = bridge.function(CanvasRenderingContext2D.createPattern, .{});
    pub const shadowBlur = bridge.property(0.0, .{ .template = false, .readonly = false });
    pub const shadowColor = bridge.property("rgba(0, 0, 0, 0)", .{ .template = false, .readonly = false });
    pub const shadowOffsetX = bridge.property(0.0, .{ .template = false, .readonly = false });
    pub const shadowOffsetY = bridge.property(0.0, .{ .template = false, .readonly = false });
    pub const filter = bridge.property("none", .{ .template = false, .readonly = false });
    pub const imageSmoothingEnabled = bridge.property(true, .{ .template = false, .readonly = false });
    pub const imageSmoothingQuality = bridge.property("low", .{ .template = false, .readonly = false });
    pub const direction = bridge.property("ltr", .{ .template = false, .readonly = false });
    pub const letterSpacing = bridge.property("0px", .{ .template = false, .readonly = false });
    pub const wordSpacing = bridge.property("0px", .{ .template = false, .readonly = false });
    pub const fontKerning = bridge.property("auto", .{ .template = false, .readonly = false });
    pub const globalAlpha = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const globalCompositeOperation = bridge.property("source-over", .{ .template = false, .readonly = false });
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const lineWidth = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.property("start", .{ .template = false, .readonly = false });
    pub const textBaseline = bridge.property("alphabetic", .{ .template = false, .readonly = false });

    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});

    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{ .noop = true });
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{ .noop = true });
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{ .noop = true });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{ .noop = true });
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .noop = true });
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .noop = true });
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .noop = true });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{ .noop = true });
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{ .noop = true });
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{ .noop = true });
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{ .noop = true });
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{ .noop = true });
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{ .noop = true });
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{ .noop = true });
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{ .noop = true });
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{ .noop = true });
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{ .noop = true });
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{ .noop = true });
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{ .noop = true });
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{ .noop = true });
};

const testing = @import("../../../testing.zig");
test {
    _ = context2d;
}

test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

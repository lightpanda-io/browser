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

const ImageData = @import("../ImageData.zig");
const context2d = @import("context2d.zig");
const TextMetrics = @import("TextMetrics.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const CanvasPattern = @import("CanvasPattern.zig");

const Execution = js.Execution;

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `OffscreenCanvas#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvasRenderingContext2D
const OffscreenCanvasRenderingContext2D = @This();
_state: context2d.State = .{},

pub fn getFillStyle(self: *const OffscreenCanvasRenderingContext2D, exec: *const Execution) !context2d.StyleOutput {
    return self._state.getStyle(.fill, exec);
}

pub fn setFillStyle(self: *OffscreenCanvasRenderingContext2D, value: context2d.StyleInput) void {
    self._state.setStyle(.fill, value);
}

pub fn getStrokeStyle(self: *const OffscreenCanvasRenderingContext2D, exec: *const Execution) !context2d.StyleOutput {
    return self._state.getStyle(.stroke, exec);
}

pub fn setStrokeStyle(self: *OffscreenCanvasRenderingContext2D, value: context2d.StyleInput) void {
    self._state.setStyle(.stroke, value);
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

pub fn putImageData(_: *const OffscreenCanvasRenderingContext2D, _: *ImageData, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn getImageData(
    _: *const OffscreenCanvasRenderingContext2D,
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

pub fn getFont(self: *const OffscreenCanvasRenderingContext2D) []const u8 {
    return self._state.font();
}

pub fn setFont(self: *OffscreenCanvasRenderingContext2D, value: []const u8, exec: *const Execution) !void {
    return self._state.setFont(value, exec);
}

pub fn measureText(self: *const OffscreenCanvasRenderingContext2D, text: []const u8, exec: *const Execution) !*TextMetrics {
    return self._state.measureText(text, exec);
}

pub fn setLineDash(self: *OffscreenCanvasRenderingContext2D, segments: []const f64, exec: *const Execution) !void {
    return self._state.setLineDash(segments, exec);
}

pub fn getLineDash(self: *const OffscreenCanvasRenderingContext2D) []const f64 {
    return self._state.lineDash();
}

pub fn roundRect(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: ?js.Value) void {}
pub fn ellipse(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn isPointInPath(_: *const OffscreenCanvasRenderingContext2D, _: js.Value, _: ?js.Value, _: ?js.Value, _: ?js.Value) bool {
    return false;
}
pub fn isPointInStroke(_: *const OffscreenCanvasRenderingContext2D, _: js.Value, _: ?js.Value, _: ?js.Value) bool {
    return false;
}

pub fn createLinearGradient(_: *const OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createRadialGradient(_: *const OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createConicGradient(_: *const OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, exec: *const Execution) !*CanvasGradient {
    return CanvasGradient.init(exec);
}

pub fn createPattern(_: *const OffscreenCanvasRenderingContext2D, _: js.Value, repetition_: ?[]const u8, exec: *const Execution) !*CanvasPattern {
    const repetition = repetition_ orelse "repeat";
    const known = [_][]const u8{ "", "repeat", "repeat-x", "repeat-y", "no-repeat" };
    for (known) |k| {
        if (std.mem.eql(u8, repetition, k)) return CanvasPattern.init(k, exec);
    }
    return error.SyntaxError;
}

pub fn save(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn restore(_: *OffscreenCanvasRenderingContext2D) void {}
pub fn scale(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *OffscreenCanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *OffscreenCanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *OffscreenCanvasRenderingContext2D) void {}
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
pub fn fillText(_: *OffscreenCanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *OffscreenCanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "OffscreenCanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const font = bridge.accessor(OffscreenCanvasRenderingContext2D.getFont, OffscreenCanvasRenderingContext2D.setFont, .{});
    pub const measureText = bridge.function(OffscreenCanvasRenderingContext2D.measureText, .{});
    pub const setLineDash = bridge.function(OffscreenCanvasRenderingContext2D.setLineDash, .{});
    pub const getLineDash = bridge.function(OffscreenCanvasRenderingContext2D.getLineDash, .{});
    pub const lineDashOffset = bridge.property(0.0, .{ .template = false, .readonly = false });
    pub const roundRect = bridge.function(OffscreenCanvasRenderingContext2D.roundRect, .{ .noop = true });
    pub const ellipse = bridge.function(OffscreenCanvasRenderingContext2D.ellipse, .{ .noop = true });
    pub const isPointInPath = bridge.function(OffscreenCanvasRenderingContext2D.isPointInPath, .{});
    pub const isPointInStroke = bridge.function(OffscreenCanvasRenderingContext2D.isPointInStroke, .{});
    pub const createLinearGradient = bridge.function(OffscreenCanvasRenderingContext2D.createLinearGradient, .{});
    pub const createRadialGradient = bridge.function(OffscreenCanvasRenderingContext2D.createRadialGradient, .{});
    pub const createConicGradient = bridge.function(OffscreenCanvasRenderingContext2D.createConicGradient, .{});
    pub const createPattern = bridge.function(OffscreenCanvasRenderingContext2D.createPattern, .{});
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
    pub const strokeStyle = bridge.accessor(OffscreenCanvasRenderingContext2D.getStrokeStyle, OffscreenCanvasRenderingContext2D.setStrokeStyle, .{});
    pub const lineWidth = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.property("start", .{ .template = false, .readonly = false });
    pub const textBaseline = bridge.property("alphabetic", .{ .template = false, .readonly = false });

    pub const fillStyle = bridge.accessor(OffscreenCanvasRenderingContext2D.getFillStyle, OffscreenCanvasRenderingContext2D.setFillStyle, .{});
    pub const createImageData = bridge.function(OffscreenCanvasRenderingContext2D.createImageData, .{});

    pub const putImageData = bridge.function(OffscreenCanvasRenderingContext2D.putImageData, .{ .noop = true });
    pub const getImageData = bridge.function(OffscreenCanvasRenderingContext2D.getImageData, .{});
    pub const save = bridge.function(OffscreenCanvasRenderingContext2D.save, .{ .noop = true });
    pub const restore = bridge.function(OffscreenCanvasRenderingContext2D.restore, .{ .noop = true });
    pub const scale = bridge.function(OffscreenCanvasRenderingContext2D.scale, .{ .noop = true });
    pub const rotate = bridge.function(OffscreenCanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const translate = bridge.function(OffscreenCanvasRenderingContext2D.translate, .{ .noop = true });
    pub const transform = bridge.function(OffscreenCanvasRenderingContext2D.transform, .{ .noop = true });
    pub const setTransform = bridge.function(OffscreenCanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const resetTransform = bridge.function(OffscreenCanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const clearRect = bridge.function(OffscreenCanvasRenderingContext2D.clearRect, .{ .noop = true });
    pub const fillRect = bridge.function(OffscreenCanvasRenderingContext2D.fillRect, .{ .noop = true });
    pub const strokeRect = bridge.function(OffscreenCanvasRenderingContext2D.strokeRect, .{ .noop = true });
    pub const beginPath = bridge.function(OffscreenCanvasRenderingContext2D.beginPath, .{ .noop = true });
    pub const closePath = bridge.function(OffscreenCanvasRenderingContext2D.closePath, .{ .noop = true });
    pub const moveTo = bridge.function(OffscreenCanvasRenderingContext2D.moveTo, .{ .noop = true });
    pub const lineTo = bridge.function(OffscreenCanvasRenderingContext2D.lineTo, .{ .noop = true });
    pub const quadraticCurveTo = bridge.function(OffscreenCanvasRenderingContext2D.quadraticCurveTo, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(OffscreenCanvasRenderingContext2D.bezierCurveTo, .{ .noop = true });
    pub const arc = bridge.function(OffscreenCanvasRenderingContext2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(OffscreenCanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const rect = bridge.function(OffscreenCanvasRenderingContext2D.rect, .{ .noop = true });
    pub const fill = bridge.function(OffscreenCanvasRenderingContext2D.fill, .{ .noop = true });
    pub const stroke = bridge.function(OffscreenCanvasRenderingContext2D.stroke, .{ .noop = true });
    pub const clip = bridge.function(OffscreenCanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(OffscreenCanvasRenderingContext2D.fillText, .{ .noop = true });
    pub const strokeText = bridge.function(OffscreenCanvasRenderingContext2D.strokeText, .{ .noop = true });
};

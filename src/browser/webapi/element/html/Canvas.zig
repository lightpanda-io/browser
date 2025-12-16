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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

pub fn registerTypes() []const type {
    return &.{
        Canvas,
        RenderingContext2D,
    };
}

const Canvas = @This();
_proto: *HtmlElement,

pub const RenderingContext2D = struct {
    pub fn save(_: *RenderingContext2D) void {}
    pub fn restore(_: *RenderingContext2D) void {}

    pub fn scale(_: *RenderingContext2D, _: f64, _: f64) void {}
    pub fn rotate(_: *RenderingContext2D, _: f64) void {}
    pub fn translate(_: *RenderingContext2D, _: f64, _: f64) void {}
    pub fn transform(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn setTransform(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn resetTransform(_: *RenderingContext2D) void {}

    pub fn getGlobalAlpha(_: *const RenderingContext2D) f64 {
        return 1.0;
    }
    pub fn setGlobalAlpha(_: *RenderingContext2D, _: f64) void {}
    pub fn getGlobalCompositeOperation(_: *const RenderingContext2D) []const u8 {
        return "source-over";
    }
    pub fn setGlobalCompositeOperation(_: *RenderingContext2D, _: []const u8) void {}

    pub fn getFillStyle(_: *const RenderingContext2D) []const u8 {
        return "#000000";
    }
    pub fn setFillStyle(_: *RenderingContext2D, _: []const u8) void {}
    pub fn getStrokeStyle(_: *const RenderingContext2D) []const u8 {
        return "#000000";
    }
    pub fn setStrokeStyle(_: *RenderingContext2D, _: []const u8) void {}

    pub fn getLineWidth(_: *const RenderingContext2D) f64 {
        return 1.0;
    }
    pub fn setLineWidth(_: *RenderingContext2D, _: f64) void {}
    pub fn getLineCap(_: *const RenderingContext2D) []const u8 {
        return "butt";
    }
    pub fn setLineCap(_: *RenderingContext2D, _: []const u8) void {}
    pub fn getLineJoin(_: *const RenderingContext2D) []const u8 {
        return "miter";
    }
    pub fn setLineJoin(_: *RenderingContext2D, _: []const u8) void {}
    pub fn getMiterLimit(_: *const RenderingContext2D) f64 {
        return 10.0;
    }
    pub fn setMiterLimit(_: *RenderingContext2D, _: f64) void {}

    pub fn clearRect(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn fillRect(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn strokeRect(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}

    pub fn beginPath(_: *RenderingContext2D) void {}
    pub fn closePath(_: *RenderingContext2D) void {}
    pub fn moveTo(_: *RenderingContext2D, _: f64, _: f64) void {}
    pub fn lineTo(_: *RenderingContext2D, _: f64, _: f64) void {}
    pub fn quadraticCurveTo(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn bezierCurveTo(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn arc(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
    pub fn arcTo(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn rect(_: *RenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}

    pub fn fill(_: *RenderingContext2D) void {}
    pub fn stroke(_: *RenderingContext2D) void {}
    pub fn clip(_: *RenderingContext2D) void {}

    pub fn getFont(_: *const RenderingContext2D) []const u8 {
        return "10px sans-serif";
    }
    pub fn setFont(_: *RenderingContext2D, _: []const u8) void {}
    pub fn getTextAlign(_: *const RenderingContext2D) []const u8 {
        return "start";
    }
    pub fn setTextAlign(_: *RenderingContext2D, _: []const u8) void {}
    pub fn getTextBaseline(_: *const RenderingContext2D) []const u8 {
        return "alphabetic";
    }
    pub fn setTextBaseline(_: *RenderingContext2D, _: []const u8) void {}
    pub fn fillText(_: *RenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
    pub fn strokeText(_: *RenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RenderingContext2D);

        pub const Meta = struct {
            pub const name = "CanvasRenderingContext2D";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const save = bridge.function(RenderingContext2D.save, .{});
        pub const restore = bridge.function(RenderingContext2D.restore, .{});

        pub const scale = bridge.function(RenderingContext2D.scale, .{});
        pub const rotate = bridge.function(RenderingContext2D.rotate, .{});
        pub const translate = bridge.function(RenderingContext2D.translate, .{});
        pub const transform = bridge.function(RenderingContext2D.transform, .{});
        pub const setTransform = bridge.function(RenderingContext2D.setTransform, .{});
        pub const resetTransform = bridge.function(RenderingContext2D.resetTransform, .{});

        pub const globalAlpha = bridge.accessor(RenderingContext2D.getGlobalAlpha, RenderingContext2D.setGlobalAlpha, .{});
        pub const globalCompositeOperation = bridge.accessor(RenderingContext2D.getGlobalCompositeOperation, RenderingContext2D.setGlobalCompositeOperation, .{});

        pub const fillStyle = bridge.accessor(RenderingContext2D.getFillStyle, RenderingContext2D.setFillStyle, .{});
        pub const strokeStyle = bridge.accessor(RenderingContext2D.getStrokeStyle, RenderingContext2D.setStrokeStyle, .{});

        pub const lineWidth = bridge.accessor(RenderingContext2D.getLineWidth, RenderingContext2D.setLineWidth, .{});
        pub const lineCap = bridge.accessor(RenderingContext2D.getLineCap, RenderingContext2D.setLineCap, .{});
        pub const lineJoin = bridge.accessor(RenderingContext2D.getLineJoin, RenderingContext2D.setLineJoin, .{});
        pub const miterLimit = bridge.accessor(RenderingContext2D.getMiterLimit, RenderingContext2D.setMiterLimit, .{});

        pub const clearRect = bridge.function(RenderingContext2D.clearRect, .{});
        pub const fillRect = bridge.function(RenderingContext2D.fillRect, .{});
        pub const strokeRect = bridge.function(RenderingContext2D.strokeRect, .{});

        pub const beginPath = bridge.function(RenderingContext2D.beginPath, .{});
        pub const closePath = bridge.function(RenderingContext2D.closePath, .{});
        pub const moveTo = bridge.function(RenderingContext2D.moveTo, .{});
        pub const lineTo = bridge.function(RenderingContext2D.lineTo, .{});
        pub const quadraticCurveTo = bridge.function(RenderingContext2D.quadraticCurveTo, .{});
        pub const bezierCurveTo = bridge.function(RenderingContext2D.bezierCurveTo, .{});
        pub const arc = bridge.function(RenderingContext2D.arc, .{});
        pub const arcTo = bridge.function(RenderingContext2D.arcTo, .{});
        pub const rect = bridge.function(RenderingContext2D.rect, .{});

        pub const fill = bridge.function(RenderingContext2D.fill, .{});
        pub const stroke = bridge.function(RenderingContext2D.stroke, .{});
        pub const clip = bridge.function(RenderingContext2D.clip, .{});

        pub const font = bridge.accessor(RenderingContext2D.getFont, RenderingContext2D.setFont, .{});
        pub const textAlign = bridge.accessor(RenderingContext2D.getTextAlign, RenderingContext2D.setTextAlign, .{});
        pub const textBaseline = bridge.accessor(RenderingContext2D.getTextBaseline, RenderingContext2D.setTextBaseline, .{});
        pub const fillText = bridge.function(RenderingContext2D.fillText, .{});
        pub const strokeText = bridge.function(RenderingContext2D.strokeText, .{});
    };
};

pub fn asElement(self: *Canvas) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe("width") orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe("width", str, page);
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe("height") orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe("height", str, page);
}

pub fn getContext(self: *Canvas, context_type: []const u8, page: *Page) !?*RenderingContext2D {
    _ = self;

    if (!std.mem.eql(u8, context_type, "2d")) {
        return null;
    }

    const ctx = try page.arena.create(RenderingContext2D);
    ctx.* = .{};
    return ctx;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{});
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{});
    pub const getContext = bridge.function(Canvas.getContext, .{});
};

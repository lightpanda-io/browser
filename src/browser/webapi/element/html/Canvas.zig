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
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");

const Execution = js.Execution;

const Canvas = @This();
_proto: *HtmlElement,
_cached: ?DrawingContext = null,

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
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
};

pub fn getContext(self: *Canvas, context_type: []const u8, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            const ctx = try frame._factory.create(CanvasRenderingContext2D{ ._canvas = self });
            break :blk .{ .@"2d" = ctx };
        }

        // We only stub a tiny slice of the WebGL API (getParameter,
        // getExtension, getSupportedExtensions). Real WebGL consumers like
        // Three.js immediately call createTexture/createBuffer/etc. and
        // throw `TypeError: e.createTexture is not a function`. Pretending
        // WebGL works until the first non-stubbed call is the worst of both
        // worlds: pages that have an error boundary above the WebGL widget
        // catch the throw, reset, re-render, and loop forever.
        // Spec-correct signal for "no WebGL" is null, so apps that check
        // (Three.js does) can degrade gracefully.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            return null;
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
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
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

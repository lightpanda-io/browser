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

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const CanvasSurface = @import("../../canvas/CanvasSurface.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");

const Canvas = @This();
_proto: *HtmlElement,
_surface: ?*CanvasSurface = null,
_context_2d: ?*CanvasRenderingContext2D = null,
_webgl_context: ?*WebGLRenderingContext = null,

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

pub fn setWidth(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), page);
    if (self._surface) |surface| {
        try surface.resize(page.arena, self.getWidth(), self.getHeight());
    }
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), page);
    if (self._surface) |surface| {
        try surface.resize(page.arena, self.getWidth(), self.getHeight());
    }
}

/// Since there's no base class rendering contextes inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
};

fn ensureSurface(self: *Canvas, page: *Page) !*CanvasSurface {
    if (self._surface) |surface| return surface;
    const surface = try CanvasSurface.init(page.arena, self.getWidth(), self.getHeight());
    self._surface = surface;
    return surface;
}

pub fn getSurface(self: *const Canvas) ?*const CanvasSurface {
    return self._surface;
}

pub fn getContext(self: *Canvas, context_type: []const u8, page: *Page) !?DrawingContext {
    if (std.mem.eql(u8, context_type, "2d")) {
        if (self._webgl_context != null) return null;
        if (self._context_2d) |ctx| {
            return .{ .@"2d" = ctx };
        }
        const ctx = try page._factory.create(CanvasRenderingContext2D{
            ._surface = try self.ensureSurface(page),
        });
        self._context_2d = ctx;
        return .{ .@"2d" = ctx };
    }

    if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
        if (self._context_2d != null) return null;
        if (self._webgl_context) |ctx| {
            return .{ .webgl = ctx };
        }
        const ctx = try page._factory.create(WebGLRenderingContext{});
        self._webgl_context = ctx;
        return .{ .webgl = ctx };
    }

    return null;
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, page: *Page) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    const offscreen = try OffscreenCanvas.constructor(width, height, page);
    if (self._surface) |surface| {
        offscreen._surface = try surface.clone(page.arena);
    }
    return offscreen;
}

pub fn attributeChange(element: *Element, name: @import("../../../../string.zig").String, _: @import("../../../../string.zig").String, page: *Page) !void {
    const canvas = element.as(Element.Html.Canvas);
    if (name.eql(comptime .wrap("width")) or name.eql(comptime .wrap("height"))) {
        if (canvas._surface) |surface| {
            try surface.resize(page.arena, canvas.getWidth(), canvas.getHeight());
        }
    }
}

pub fn attributeRemove(element: *Element, name: @import("../../../../string.zig").String, page: *Page) !void {
    const canvas = element.as(Element.Html.Canvas);
    if (name.eql(comptime .wrap("width")) or name.eql(comptime .wrap("height"))) {
        if (canvas._surface) |surface| {
            try surface.resize(page.arena, canvas.getWidth(), canvas.getHeight());
        }
    }
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

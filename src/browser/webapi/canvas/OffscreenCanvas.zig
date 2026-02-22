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

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Blob = @import("../Blob.zig");
const OffscreenCanvasRenderingContext2D = @import("OffscreenCanvasRenderingContext2D.zig");

/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
const OffscreenCanvas = @This();

pub const _prototype_root = true;

_width: u32,
_height: u32,

/// Since there's no base class rendering contextes inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *OffscreenCanvasRenderingContext2D,
};

pub fn constructor(width: u32, height: u32, page: *Page) !*OffscreenCanvas {
    return page._factory.create(OffscreenCanvas{
        ._width = width,
        ._height = height,
    });
}

pub fn getWidth(self: *const OffscreenCanvas) u32 {
    return self._width;
}

pub fn setWidth(self: *OffscreenCanvas, value: u32) void {
    self._width = value;
}

pub fn getHeight(self: *const OffscreenCanvas) u32 {
    return self._height;
}

pub fn setHeight(self: *OffscreenCanvas, value: u32) void {
    self._height = value;
}

pub fn getContext(_: *OffscreenCanvas, context_type: []const u8, page: *Page) !?DrawingContext {
    if (std.mem.eql(u8, context_type, "2d")) {
        const ctx = try page._factory.create(OffscreenCanvasRenderingContext2D{});
        return .{ .@"2d" = ctx };
    }

    return null;
}

/// Returns a Promise that resolves to a Blob containing the image.
/// Since we have no actual rendering, this returns an empty blob.
pub fn convertToBlob(_: *OffscreenCanvas, page: *Page) !js.Promise {
    const blob = try Blob.init(null, null, page);
    return page.js.local.?.resolvePromise(blob);
}

/// Returns an ImageBitmap with the rendered content (stub).
pub fn transferToImageBitmap(_: *OffscreenCanvas) ?void {
    // ImageBitmap not implemented yet, return null
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvas);

    pub const Meta = struct {
        pub const name = "OffscreenCanvas";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OffscreenCanvas.constructor, .{});
    pub const width = bridge.accessor(OffscreenCanvas.getWidth, OffscreenCanvas.setWidth, .{});
    pub const height = bridge.accessor(OffscreenCanvas.getHeight, OffscreenCanvas.setHeight, .{});
    pub const getContext = bridge.function(OffscreenCanvas.getContext, .{});
    pub const convertToBlob = bridge.function(OffscreenCanvas.convertToBlob, .{});
    pub const transferToImageBitmap = bridge.function(OffscreenCanvas.transferToImageBitmap, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: OffscreenCanvas" {
    try testing.htmlRunner("canvas/offscreen_canvas.html", .{});
}

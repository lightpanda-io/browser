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

const Blob = @import("../Blob.zig");
const ImageBitmap = @import("ImageBitmap.zig");
const OffscreenCanvasRenderingContext2D = @import("OffscreenCanvasRenderingContext2D.zig");
const webgl = @import("WebGLRenderingContext.zig");
const WebGLRenderingContext = webgl.WebGLRenderingContext;
const WebGL2RenderingContext = webgl.WebGL2RenderingContext;

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
const OffscreenCanvas = @This();

pub const _prototype_root = true;

_width: u32,
_height: u32,

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *OffscreenCanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
    webgl2: *WebGL2RenderingContext,
};

pub fn constructor(width: u32, height: u32, exec: *Execution) !*OffscreenCanvas {
    return exec._factory.create(OffscreenCanvas{
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

pub fn getContext(self: *OffscreenCanvas, context_type: []const u8, exec: *Execution) !?DrawingContext {
    if (std.mem.eql(u8, context_type, "2d")) {
        const ctx = try exec._factory.create(OffscreenCanvasRenderingContext2D{});
        return .{ .@"2d" = ctx };
    }

    // Same fingerprint-grade WebGL stub the main-thread canvas hands out, and
    // seeded identically. A worker that answered null here reported no GPU
    // while the document reported a full vendor/renderer, and that
    // disagreement is itself the bot signal — real browsers never contradict
    // themselves across threads.
    const noise = exec.session.browser.app.config.fingerprint_profile.noise_seed;

    if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
        const ctx = try exec._factory.create(WebGLRenderingContext{
            ._canvas = .{ .offscreen = self },
            ._fp_seed = noise,
        });
        return .{ .webgl = ctx };
    }

    if (std.mem.eql(u8, context_type, "webgl2")) {
        const ctx = try exec._factory.create(WebGL2RenderingContext{
            ._canvas = .{ .offscreen = self },
            ._fp_seed = noise,
        });
        return .{ .webgl2 = ctx };
    }

    return null;
}

/// Returns a Promise that resolves to a Blob containing the image.
/// Since we have no actual rendering, this returns an empty blob.
pub fn convertToBlob(_: *OffscreenCanvas, exec: *Execution) !js.Promise {
    const blob = try Blob.init(null, null, exec);
    return exec.js.local.?.resolvePromise(blob);
}

/// Returns an ImageBitmap sized like the canvas. There are no pixels to carry
/// over, but consumers throw on a null return.
pub fn transferToImageBitmap(self: *OffscreenCanvas, exec: *Execution) !*ImageBitmap {
    return ImageBitmap.init(self._width, self._height, exec);
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

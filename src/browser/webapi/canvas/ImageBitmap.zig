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

const js = @import("../../js/js.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageBitmap
///
/// Lightpanda has no rasterizer, so a bitmap carries dimensions but no pixels.
/// That is enough for the common case: libraries call createImageBitmap to hand
/// the result to drawImage (a no-op here) or to read width/height off it, and
/// they break outright if the call rejects or resolves to null.
const ImageBitmap = @This();

_width: u32,
_height: u32,

pub fn init(width: u32, height: u32, exec: *const Execution) !*ImageBitmap {
    return exec._factory.create(ImageBitmap{
        ._width = width,
        ._height = height,
    });
}

/// https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#dom-createimagebitmap
///
/// The optional crop rectangle (sx, sy, sw, sh) sets the result's size when
/// given; otherwise the source's own width/height are used. Reading those off
/// the JS object keeps every source type (Blob, ImageData, OffscreenCanvas,
/// <canvas>, <img>, ...) on one path, in both windows and workers.
pub fn create(source: js.Value, sx: ?js.Value, sy: ?js.Value, sw: ?js.Value, sh: ?js.Value, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (!source.isObject()) {
        return local.rejectPromise(.{ .type_error = "createImageBitmap: unsupported source" });
    }

    // The crop offsets don't change the result's size. The two-argument form
    // passes an options dictionary where sx sits, so every trailing argument is
    // taken loosely: anything that isn't a number is ignored.
    _ = sx;
    _ = sy;

    const width, const height = blk: {
        if (intOf(sw)) |w| {
            if (intOf(sh)) |h| {
                break :blk .{ w, h };
            }
        }
        break :blk .{ dimension(source, "width"), dimension(source, "height") };
    };

    return local.resolvePromise(try init(width, height, exec));
}

fn intOf(value_: ?js.Value) ?u32 {
    const value = value_ orelse return null;
    return @abs(value.toZig(i32) catch return null);
}

fn dimension(source: js.Value, name: []const u8) u32 {
    const value = source.toObject().get(name) catch return 0;
    return value.toZig(u32) catch 0;
}

pub fn getWidth(self: *const ImageBitmap) u32 {
    return self._width;
}

pub fn getHeight(self: *const ImageBitmap) u32 {
    return self._height;
}

/// Releases the (non-existent) pixel data. Per spec the dimensions read back
/// as 0 afterwards.
pub fn close(self: *ImageBitmap) void {
    self._width = 0;
    self._height = 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageBitmap);

    pub const Meta = struct {
        pub const name = "ImageBitmap";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(ImageBitmap.getWidth, null, .{});
    pub const height = bridge.accessor(ImageBitmap.getHeight, null, .{});
    pub const close = bridge.function(ImageBitmap.close, .{});
};

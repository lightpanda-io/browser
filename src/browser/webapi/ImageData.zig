// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const String = @import("../../string.zig").String;
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const color = @import("../color.zig");
const Page = @import("../Page.zig");

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageData/ImageData
const ImageData = @This();
_width: u32,
_height: u32,
_data: js.ArrayBufferRef(.Uint8Clamped),

pub const ConstructorSettings = struct {
    /// Specifies the color space of the image data.
    /// Can be set to "srgb" for the sRGB color space or "display-p3" for the display-p3 color space.
    colorSpace: String = .wrap("srgb"),
    /// Specifies the pixel format.
    /// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/createImageData#pixelformat
    pixelFormat: String = .wrap("rgba-unorm8"),
};

/// This has many constructors:
///
/// ```js
/// new ImageData(width, height)
/// new ImageData(width, height, settings)
///
/// new ImageData(dataArray, width)
/// new ImageData(dataArray, width, height)
/// new ImageData(dataArray, width, height, settings)
/// ```
///
/// We currently support only the first 2.
pub fn constructor(
    width: u32,
    height: u32,
    maybe_settings: ?ConstructorSettings,
    page: *Page,
) !*ImageData {
    if (width == 0 or height == 0) {
        return error.IndexSizeError;
    }

    const settings: ConstructorSettings = maybe_settings orelse .{};
    if (settings.colorSpace.eql(comptime .wrap("srgb")) == false) {
        return error.TypeError;
    }
    if (settings.pixelFormat.eql(comptime .wrap("rgba-unorm8")) == false) {
        return error.TypeError;
    }

    const size = width * height * 4;
    return page._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._data = page.js.createTypedArray(.Uint8Clamped, size),
    });
}

pub fn getWidth(self: *const ImageData) u32 {
    return self._width;
}

pub fn getHeight(self: *const ImageData) u32 {
    return self._height;
}

pub fn getPixelFormat(_: *const ImageData) String {
    return comptime .wrap("rgba-unorm8");
}

pub fn getColorSpace(_: *const ImageData) String {
    return comptime .wrap("srgb");
}

pub fn getData(self: *const ImageData) js.ArrayBufferRef(.Uint8Clamped) {
    return self._data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageData);

    pub const Meta = struct {
        pub const name = "ImageData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ImageData.constructor, .{ .dom_exception = true });

    pub const width = bridge.accessor(ImageData.getWidth, null, .{});
    pub const height = bridge.accessor(ImageData.getHeight, null, .{});
    pub const pixelFormat = bridge.accessor(ImageData.getPixelFormat, null, .{});
    pub const colorSpace = bridge.accessor(ImageData.getColorSpace, null, .{});
    pub const data = bridge.accessor(ImageData.getData, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ImageData" {
    try testing.htmlRunner("image_data.html", .{});
}

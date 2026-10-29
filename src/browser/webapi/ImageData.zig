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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const String = lp.String;
const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageData/ImageData
const ImageData = @This();

_rc: lp.RC = .{},
_width: u32,
_height: u32,
_data: js.ArrayBufferRef(.uint8_clamped).Global,

pub const ConstructorSettings = struct {
    /// Specifies the color space of the image data.
    /// Can be set to "srgb" for the sRGB color space or "display-p3" for the display-p3 color space.
    colorSpace: String = .wrap("srgb"),
    /// Specifies the pixel format.
    /// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/createImageData#pixelformat
    pixelFormat: String = .wrap("rgba-unorm8"),
};

pub fn init(width: u32, height: u32, maybe_settings: ?ConstructorSettings, exec: *Execution) !*ImageData {
    try validateDimension(width);
    try validateDimension(height);
    try validateSettings(maybe_settings);

    var size, var overflown = @mulWithOverflow(width, height);
    if (overflown == 1) {
        return error.IndexSizeError;
    }

    size, overflown = @mulWithOverflow(size, 4);
    if (overflown == 1) {
        return error.IndexSizeError;
    }

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._data = try exec.js.local.?.createTypedArray(.uint8_clamped, size).persist(),
    });
}

// The ImageData wraps the caller's array, not a copy: `imageData.data`
// is the same object that was passed in.
fn initWithData(
    data: js.Value,
    width: u32,
    height_: ?js.Value,
    settings: ?ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    try validateSettings(settings);

    const array = js.ArrayBufferRef(.uint8_clamped){ .local = data.local, .handle = data.handle };
    const length = array.slice().len;
    if (length == 0 or length % 4 != 0) {
        return error.InvalidStateError;
    }
    try validateDimension(width);

    const pixels = length / 4;
    if (pixels % width != 0) {
        return error.IndexSizeError;
    }
    const height = pixels / width;
    if (height_) |v| {
        if (!v.isUndefined() and try v.toU32() != height) {
            return error.IndexSizeError;
        }
    }
    try validateDimension(height);

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = @intCast(height),
        ._data = try array.persist(),
    });
}

fn validateSettings(settings_: ?ConstructorSettings) !void {
    const settings = settings_ orelse return;
    if (settings.colorSpace.eql(comptime .wrap("srgb")) == false) {
        return error.TypeError;
    }
    if (settings.pixelFormat.eql(comptime .wrap("rgba-unorm8")) == false) {
        return error.TypeError;
    }
}

fn validateDimension(value: usize) !void {
    // Though arguments are unsigned long, these are capped to max. i32 on Chrome.
    // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/html/canvas/image_data.cc#L61
    if (value == 0 or value > std.math.maxInt(i32)) {
        return error.IndexSizeError;
    }
}

pub fn deinit(self: *ImageData, page: *Page) void {
    self._data.release();
    page.factory.destroy(self);
}

pub fn releaseRef(self: *ImageData, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *ImageData) void {
    self._rc.acquire();
}

pub fn structuredSerialize(self: *const ImageData, writer: *js.StructuredWriter) !void {
    writer.writeUint32(self._width);
    writer.writeUint32(self._height);
    writer.writeBytes(self._data.local(writer.local).slice());
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*ImageData {
    const width = try reader.readUint32();
    const height = try reader.readUint32();
    const bytes = try reader.readBytes();

    const data = reader.local.createTypedArray(.uint8_clamped, bytes.len);
    @memcpy(data.slice(), bytes);

    return page.factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._data = try data.persist(),
    });
}

pub fn getWidth(self: *const ImageData) u32 {
    return self._width;
}

pub fn getHeight(self: *const ImageData) u32 {
    return self._height;
}

pub fn getData(self: *const ImageData) js.ArrayBufferRef(.uint8_clamped).Global {
    return self._data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageData);

    pub const Meta = struct {
        pub const name = "ImageData";
        pub var class_id: bridge.ClassId = undefined;
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
    pub const constructor = bridge.constructor(struct {
        fn wrap(first: js.Value, second: u32, third: ?js.Value, fourth: ?ConstructorSettings, exec: *Execution) !*ImageData {
            if (first.isUint8ClampedArray()) {
                return initWithData(first, second, third, fourth, exec);
            }
            if (first.isFloat16Array()) {
                // Float16Array data needs the "rgba-float16" pixel format, which
                // we don't support. Other typed arrays aren't ImageDataArrays, so
                // they take the (sw, sh) overload.
                return error.TypeError;
            }

            const settings: ?ConstructorSettings = if (third) |v| blk: {
                if (v.isNullOrUndefined()) break :blk null;
                break :blk try v.toZig(ConstructorSettings);
            } else null;
            return init(try first.toU32(), second, settings, exec);
        }
    }.wrap, .{});

    pub const colorSpace = bridge.property("srgb", .{ .template = false, .readonly = true });
    pub const pixelFormat = bridge.property("rgba-unorm8", .{ .template = false, .readonly = true });

    pub const data = bridge.accessor(ImageData.getData, null, .{});
    pub const width = bridge.accessor(ImageData.getWidth, null, .{});
    pub const height = bridge.accessor(ImageData.getHeight, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ImageData" {
    try testing.htmlRunner("image_data.html", .{});
}

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

const TextMetrics = @This();

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

_width: f64,
_actual_bounding_box_left: f64,
_actual_bounding_box_right: f64,
_actual_bounding_box_ascent: f64,
_actual_bounding_box_descent: f64,
_font_bounding_box_ascent: f64,
_font_bounding_box_descent: f64,
_em_height_ascent: f64,
_em_height_descent: f64,

pub fn init(width: f64, font_size: f64, page: *Page) !*TextMetrics {
    return page._factory.create(TextMetrics{
        ._width = width,
        ._actual_bounding_box_left = 0,
        ._actual_bounding_box_right = width,
        ._actual_bounding_box_ascent = font_size * 0.8,
        ._actual_bounding_box_descent = font_size * 0.2,
        ._font_bounding_box_ascent = font_size * 0.8,
        ._font_bounding_box_descent = font_size * 0.2,
        ._em_height_ascent = font_size * 0.8,
        ._em_height_descent = font_size * 0.2,
    });
}

pub fn getWidth(self: *const TextMetrics) f64 {
    return self._width;
}
pub fn getActualBoundingBoxLeft(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_left;
}
pub fn getActualBoundingBoxRight(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_right;
}
pub fn getActualBoundingBoxAscent(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_ascent;
}
pub fn getActualBoundingBoxDescent(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_descent;
}
pub fn getFontBoundingBoxAscent(self: *const TextMetrics) f64 {
    return self._font_bounding_box_ascent;
}
pub fn getFontBoundingBoxDescent(self: *const TextMetrics) f64 {
    return self._font_bounding_box_descent;
}
pub fn getAlphabeticBaseline(_: *const TextMetrics) f64 {
    return 0;
}
pub fn getEmHeightAscent(self: *const TextMetrics) f64 {
    return self._em_height_ascent;
}
pub fn getEmHeightDescent(self: *const TextMetrics) f64 {
    return self._em_height_descent;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextMetrics);

    pub const Meta = struct {
        pub const name = "TextMetrics";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(TextMetrics.getWidth, null, .{});
    pub const actualBoundingBoxLeft = bridge.accessor(TextMetrics.getActualBoundingBoxLeft, null, .{});
    pub const actualBoundingBoxRight = bridge.accessor(TextMetrics.getActualBoundingBoxRight, null, .{});
    pub const actualBoundingBoxAscent = bridge.accessor(TextMetrics.getActualBoundingBoxAscent, null, .{});
    pub const actualBoundingBoxDescent = bridge.accessor(TextMetrics.getActualBoundingBoxDescent, null, .{});
    pub const fontBoundingBoxAscent = bridge.accessor(TextMetrics.getFontBoundingBoxAscent, null, .{});
    pub const fontBoundingBoxDescent = bridge.accessor(TextMetrics.getFontBoundingBoxDescent, null, .{});
    pub const alphabeticBaseline = bridge.accessor(TextMetrics.getAlphabeticBaseline, null, .{});
    pub const emHeightAscent = bridge.accessor(TextMetrics.getEmHeightAscent, null, .{});
    pub const emHeightDescent = bridge.accessor(TextMetrics.getEmHeightDescent, null, .{});
};

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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const TextMetrics = @This();

_width: f64,
_actual_bounding_box_ascent: f64,
_actual_bounding_box_descent: f64,

pub fn init(
    width: f64,
    actual_bounding_box_ascent: f64,
    actual_bounding_box_descent: f64,
    page: *Page,
) !*TextMetrics {
    return page._factory.create(TextMetrics{
        ._width = width,
        ._actual_bounding_box_ascent = actual_bounding_box_ascent,
        ._actual_bounding_box_descent = actual_bounding_box_descent,
    });
}

pub fn getWidth(self: *const TextMetrics) f64 {
    return self._width;
}

pub fn getActualBoundingBoxAscent(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_ascent;
}

pub fn getActualBoundingBoxDescent(self: *const TextMetrics) f64 {
    return self._actual_bounding_box_descent;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextMetrics);

    pub const Meta = struct {
        pub const name = "TextMetrics";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(TextMetrics.getWidth, null, .{});
    pub const actualBoundingBoxAscent = bridge.accessor(TextMetrics.getActualBoundingBoxAscent, null, .{});
    pub const actualBoundingBoxDescent = bridge.accessor(TextMetrics.getActualBoundingBoxDescent, null, .{});
};

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

const SVGAnimatedAngle = @This();

const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;
const SVGAngle = @import("SVGAngle.zig");

_element: *Element,
_attr_name: String,

pub fn getBaseVal(self: *const SVGAnimatedAngle, page: *Page) !*SVGAngle {
    const attr = self._element.getAttributeSafe(self._attr_name) orelse "";
    const value = std.fmt.parseFloat(f64, attr) catch 0;
    return page._factory.create(SVGAngle{
        ._value = value,
        ._unit_type = 2, // SVG_ANGLETYPE_DEG
        ._element = @constCast(self._element),
        ._attr_name = self._attr_name,
    });
}

pub fn getAnimVal(self: *const SVGAnimatedAngle, page: *Page) !*SVGAngle {
    return self.getBaseVal(page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGAnimatedAngle);

    pub const Meta = struct {
        pub const name = "SVGAnimatedAngle";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(SVGAnimatedAngle.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(SVGAnimatedAngle.getAnimVal, null, .{});
};

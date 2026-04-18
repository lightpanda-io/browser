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

const SVGAnimatedLength = @This();

const js = @import("../../js/js.zig");
const Element = @import("../Element.zig");
const String = @import("../../../string.zig").String;
const SVGLength = @import("SVGLength.zig");

_base_val: SVGLength = .{ ._value = 0, ._unit_type = 1, ._element = null, ._attr_name = String.empty },

pub fn init(element: *Element, attr_name: String) SVGAnimatedLength {
    return .{ ._base_val = .{ ._value = 0, ._unit_type = 1, ._element = element, ._attr_name = attr_name } };
}

pub fn getBaseVal(self: *SVGAnimatedLength) *SVGLength {
    return &self._base_val;
}

pub fn getAnimVal(self: *SVGAnimatedLength) *SVGLength {
    return &self._base_val;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SVGAnimatedLength);

    pub const Meta = struct {
        pub const name = "SVGAnimatedLength";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const baseVal = bridge.accessor(SVGAnimatedLength.getBaseVal, null, .{});
    pub const animVal = bridge.accessor(SVGAnimatedLength.getAnimVal, null, .{});
};

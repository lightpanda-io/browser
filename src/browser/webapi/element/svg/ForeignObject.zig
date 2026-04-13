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

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const String = @import("../../../../string.zig").String;
const SVGAnimatedLength = @import("../../svg_types/SVGAnimatedLength.zig");

const ForeignObject = @This();
_proto: *GraphicsElement,
_x: SVGAnimatedLength = .{},
_y: SVGAnimatedLength = .{},
_width: SVGAnimatedLength = .{},
_height: SVGAnimatedLength = .{},

pub fn asSvg(self: *ForeignObject) *Svg {
    return self._proto._proto;
}

pub fn asElement(self: *ForeignObject) *Element {
    return self.asSvg()._proto;
}

pub fn asNode(self: *ForeignObject) *Node {
    return self.asElement().asNode();
}

pub fn getX(self: *ForeignObject) *SVGAnimatedLength {
    if (self._x._base_val._element == null) self._x = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("x"));
    return &self._x;
}

pub fn getY(self: *ForeignObject) *SVGAnimatedLength {
    if (self._y._base_val._element == null) self._y = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("y"));
    return &self._y;
}

pub fn getWidth(self: *ForeignObject) *SVGAnimatedLength {
    if (self._width._base_val._element == null) self._width = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("width"));
    return &self._width;
}

pub fn getHeight(self: *ForeignObject) *SVGAnimatedLength {
    if (self._height._base_val._element == null) self._height = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("height"));
    return &self._height;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ForeignObject);

    pub const Meta = struct {
        pub const name = "SVGForeignObjectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(ForeignObject.getX, null, .{});
    pub const y = bridge.accessor(ForeignObject.getY, null, .{});
    pub const width = bridge.accessor(ForeignObject.getWidth, null, .{});
    pub const height = bridge.accessor(ForeignObject.getHeight, null, .{});
};

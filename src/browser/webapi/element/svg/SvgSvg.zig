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

const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const String = @import("../../../../string.zig").String;
const SVGNumber = @import("../../svg_types/SVGNumber.zig");
const SVGLength = @import("../../svg_types/SVGLength.zig");
const SVGAngle = @import("../../svg_types/SVGAngle.zig");
const SVGAnimatedLength = @import("../../svg_types/SVGAnimatedLength.zig");
const DOMRect = @import("../../DOMRect.zig");
const DOMPoint = @import("../../DOMPoint.zig");
const DOMMatrix = @import("../../DOMMatrix.zig");
const SVGAnimatedRect = @import("../../svg_types/SVGAnimatedRect.zig");

const SvgSvg = @This();
_proto: *GraphicsElement,
_x: SVGAnimatedLength = .{},
_y: SVGAnimatedLength = .{},
_width: SVGAnimatedLength = .{},
_height: SVGAnimatedLength = .{},
_viewBox: SVGAnimatedRect = .{},

pub fn asSvg(self: *SvgSvg) *Svg {
    return self._proto._proto;
}

pub fn asElement(self: *SvgSvg) *Element {
    return self.asSvg()._proto;
}

pub fn asNode(self: *SvgSvg) *Node {
    return self.asElement().asNode();
}

pub fn getX(self: *SvgSvg) *SVGAnimatedLength {
    if (self._x._base_val._element == null) self._x = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("x"));
    return &self._x;
}

pub fn getY(self: *SvgSvg) *SVGAnimatedLength {
    if (self._y._base_val._element == null) self._y = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("y"));
    return &self._y;
}

pub fn getWidth(self: *SvgSvg) *SVGAnimatedLength {
    if (self._width._base_val._element == null) self._width = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("width"));
    return &self._width;
}

pub fn getHeight(self: *SvgSvg) *SVGAnimatedLength {
    if (self._height._base_val._element == null) self._height = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("height"));
    return &self._height;
}

pub fn createSVGNumber(_: *SvgSvg, page: *Page) !*SVGNumber {
    return page._factory.create(SVGNumber{ ._element = null, ._attr_name = String.wrap("") });
}

pub fn createSVGLength(_: *SvgSvg, page: *Page) !*SVGLength {
    return page._factory.create(SVGLength{ ._value = 0, ._unit_type = 1, ._element = null, ._attr_name = String.wrap("") });
}

pub fn createSVGAngle(_: *SvgSvg, page: *Page) !*SVGAngle {
    return page._factory.create(SVGAngle{ ._value = 0, ._unit_type = 1, ._element = null, ._attr_name = String.wrap("") });
}

pub fn pauseAnimations(_: *SvgSvg) void {}

pub fn createSVGPoint(_: *SvgSvg, page: *Page) !*DOMPoint {
    return DOMPoint.init(null, null, null, null, page);
}

pub fn createSVGMatrix(_: *SvgSvg, page: *Page) !*DOMMatrix {
    return DOMMatrix.init(page);
}

pub fn createSVGRect(_: *SvgSvg, page: *Page) !*DOMRect {
    return DOMRect.init(0, 0, 0, 0, page);
}
pub fn unpauseAnimations(_: *SvgSvg) void {}
pub fn animationsPaused(_: *const SvgSvg) bool {
    return false;
}
pub fn getCurrentTime(_: *const SvgSvg) f64 {
    return 0;
}
pub fn setCurrentTime(_: *SvgSvg, _: f64) void {}

pub fn getViewBox(self: *SvgSvg) *SVGAnimatedRect {
    if (self._viewBox._element == null) {
        self._viewBox._element = self.asElement();
        self._viewBox._attr_name = comptime String.wrap("viewBox");
    }
    return &self._viewBox;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SvgSvg);

    pub const Meta = struct {
        pub const name = "SVGSVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(SvgSvg.getX, null, .{});
    pub const y = bridge.accessor(SvgSvg.getY, null, .{});
    pub const width = bridge.accessor(SvgSvg.getWidth, null, .{});
    pub const height = bridge.accessor(SvgSvg.getHeight, null, .{});
    pub const createSVGNumber = bridge.function(SvgSvg.createSVGNumber, .{});
    pub const createSVGLength = bridge.function(SvgSvg.createSVGLength, .{});
    pub const createSVGAngle = bridge.function(SvgSvg.createSVGAngle, .{});
    pub const createSVGPoint = bridge.function(SvgSvg.createSVGPoint, .{});
    pub const createSVGMatrix = bridge.function(SvgSvg.createSVGMatrix, .{});
    pub const createSVGRect = bridge.function(SvgSvg.createSVGRect, .{});
    pub const viewBox = bridge.accessor(SvgSvg.getViewBox, null, .{});
    pub const pauseAnimations = bridge.function(SvgSvg.pauseAnimations, .{});
    pub const unpauseAnimations = bridge.function(SvgSvg.unpauseAnimations, .{});
    pub const animationsPaused = bridge.function(SvgSvg.animationsPaused, .{});
    pub const getCurrentTime = bridge.function(SvgSvg.getCurrentTime, .{});
    pub const setCurrentTime = bridge.function(SvgSvg.setCurrentTime, .{});
};

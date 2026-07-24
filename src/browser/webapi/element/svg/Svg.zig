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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const DOMRect = @import("../../DOMRect.zig");
const DOMPoint = @import("../../DOMPoint.zig");
const DOMMatrix = @import("../../DOMMatrix.zig");
const SvgNumber = @import("../../svg/Number.zig");
const SvgLength = @import("../../svg/Length.zig");
const SvgAngle = @import("../../svg/Angle.zig");
const SvgTransform = @import("../../svg/Transform.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedPreserveAspectRatio = @import("../../svg/AnimatedPreserveAspectRatio.zig");

const Graphics = @import("Graphics.zig");

const Svg = @This();
_proto: *Graphics,

pub fn asElement(self: *Svg) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}

pub fn getElementById(self: *Svg, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }

    var tw = TreeWalker.Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn getX(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .x, frame);
}

pub fn getY(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .y, frame);
}

pub fn getWidth(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .width, frame);
}

pub fn getHeight(self: *Svg, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .height, frame);
}

pub fn getPreserveAspectRatio(self: *Svg, frame: *Frame) !*AnimatedPreserveAspectRatio {
    return AnimatedPreserveAspectRatio.getOrCreate(self.asElement(), frame);
}

pub fn createSVGPoint(_: *Svg, frame: *Frame) !*DOMPoint {
    return DOMPoint.create(0, 0, 0, 1, frame._page);
}

pub fn createSVGMatrix(_: *Svg, frame: *Frame) !*DOMMatrix {
    const identity: [16]f64 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    return DOMMatrix.create(identity, true, frame._page);
}

pub fn createSVGRect(_: *Svg, frame: *Frame) !*DOMRect {
    return DOMRect.create(.{}, frame._factory);
}

pub fn createSVGNumber(_: *Svg, frame: *Frame) !*SvgNumber {
    return frame._factory.create(SvgNumber{});
}

pub fn createSVGLength(_: *Svg, frame: *Frame) !*SvgLength {
    return SvgLength.detached(frame);
}

pub fn createSVGAngle(_: *Svg, frame: *Frame) !*SvgAngle {
    return SvgAngle.detached(frame);
}

pub fn createSVGTransform(_: *Svg, frame: *Frame) !*SvgTransform {
    return SvgTransform.detached(frame);
}

pub fn createSVGTransformFromMatrix(_: *Svg, init: ?SvgTransform.DOMMatrix2DInit, frame: *Frame) !*SvgTransform {
    return SvgTransform.fromMatrix(init, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGSVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getElementById = bridge.function(Svg.getElementById, .{});

    pub const x = bridge.accessor(Svg.getX, null, .{});
    pub const y = bridge.accessor(Svg.getY, null, .{});
    pub const width = bridge.accessor(Svg.getWidth, null, .{});
    pub const height = bridge.accessor(Svg.getHeight, null, .{});
    pub const preserveAspectRatio = bridge.accessor(Svg.getPreserveAspectRatio, null, .{});

    pub const createSVGPoint = bridge.function(Svg.createSVGPoint, .{});
    pub const createSVGMatrix = bridge.function(Svg.createSVGMatrix, .{});
    pub const createSVGRect = bridge.function(Svg.createSVGRect, .{});
    pub const createSVGNumber = bridge.function(Svg.createSVGNumber, .{});
    pub const createSVGLength = bridge.function(Svg.createSVGLength, .{});
    pub const createSVGAngle = bridge.function(Svg.createSVGAngle, .{});
    pub const createSVGTransform = bridge.function(Svg.createSVGTransform, .{});
    pub const createSVGTransformFromMatrix = bridge.function(Svg.createSVGTransformFromMatrix, .{});
};

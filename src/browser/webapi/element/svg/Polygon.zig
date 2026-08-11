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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Geometry = @import("Geometry.zig");
const PointList = @import("../../svg/PointList.zig");

const Polygon = @This();

pub const Proto = Geometry;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Geometry else void = undefined,

pub fn asElement(self: *Polygon) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Polygon) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Polygon);

    pub const Meta = struct {
        pub const name = "SVGPolygonElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const points = bridge.accessor(Polygon.getPoints, null, .{});
    pub const animatedPoints = bridge.accessor(Polygon.getAnimatedPoints, null, .{});
};

pub fn getPoints(self: *Polygon, frame: *Frame) !*PointList {
    return PointList.getOrCreate(self.asElement(), .base, frame);
}

pub fn getAnimatedPoints(self: *Polygon, frame: *Frame) !*PointList {
    return PointList.getOrCreate(self.asElement(), .animated, frame);
}

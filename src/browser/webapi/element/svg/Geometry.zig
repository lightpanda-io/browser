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

const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Graphics = @import("Graphics.zig");
pub const Rect = @import("Rect.zig");
pub const Circle = @import("Circle.zig");
pub const Ellipse = @import("Ellipse.zig");
pub const Line = @import("Line.zig");
pub const Path = @import("Path.zig");
pub const Polygon = @import("Polygon.zig");
pub const Polyline = @import("Polyline.zig");

const Geometry = @This();
_proto: *Graphics,
_type: Type,

pub const Type = union(enum) {
    rect: *Rect,
    circle: *Circle,
    ellipse: *Ellipse,
    line: *Line,
    path: *Path,
    polygon: *Polygon,
    polyline: *Polyline,
};

pub fn is(self: *Geometry, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn asElement(self: *Geometry) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Geometry) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Geometry);

    pub const Meta = struct {
        pub const name = "SVGGeometryElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

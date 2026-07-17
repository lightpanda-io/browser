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
const SvgElement = @import("../Svg.zig");

pub const Svg = @import("Svg.zig");
pub const G = @import("G.zig");
pub const A = @import("A.zig");
pub const Use = @import("Use.zig");
pub const Image = @import("Image.zig");
pub const Defs = @import("Defs.zig");
pub const Geometry = @import("Geometry.zig");

const Graphics = @This();
_proto: *SvgElement,
_type: Type,

pub const Type = union(enum) {
    svg: *Svg,
    g: *G,
    a: *A,
    use: *Use,
    image: *Image,
    defs: *Defs,
    geometry: *Geometry,
};

pub fn is(self: *Graphics, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    if (self._type == .geometry) {
        return self._type.geometry.is(T);
    }
    return null;
}

pub fn asElement(self: *Graphics) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Graphics) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Graphics);

    pub const Meta = struct {
        pub const name = "SVGGraphicsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

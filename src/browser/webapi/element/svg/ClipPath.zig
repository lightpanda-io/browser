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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");

const Svg = @import("../Svg.zig");

const ClipPath = @This();
_proto: *Svg,

pub fn asElement(self: *ClipPath) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *ClipPath) *Node {
    return self.asElement().asNode();
}

fn getClipPathUnits(self: *ClipPath, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .clip_path_units, frame);
}

fn getTransform(self: *ClipPath, frame: *Frame) !*AnimatedTransformList {
    return AnimatedTransformList.getOrCreate(self.asElement(), .transform, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ClipPath);
    pub const Meta = struct {
        pub const name = "SVGClipPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const clipPathUnits = bridge.accessor(ClipPath.getClipPathUnits, null, .{});
    pub const transform = bridge.accessor(ClipPath.getTransform, null, .{});
};

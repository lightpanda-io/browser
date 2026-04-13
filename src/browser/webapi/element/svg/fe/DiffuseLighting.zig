// Copyright (C) 2023-2025  Lightpanda Selecy SAS
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const js = @import("../../../../js/js.zig");
const Node = @import("../../../Node.zig");
const Element = @import("../../../Element.zig");
const Svg = @import("../../Svg.zig");

const DiffuseLighting = @This();
_proto: *Svg,

pub fn asElement(self: *DiffuseLighting) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *DiffuseLighting) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DiffuseLighting);
    pub const Meta = struct {
        pub const name = "SVGFEDiffuseLightingElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

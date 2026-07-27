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
const AnimatedLength = @import("../../svg/AnimatedLength.zig");

const Svg = @import("../Svg.zig");

const Marker = @This();
_proto: *Svg,

pub fn asElement(self: *Marker) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Marker) *Node {
    return self.asElement().asNode();
}

fn getRefX(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_ref_x, frame);
}
fn getRefY(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_ref_y, frame);
}
fn getMarkerWidth(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_width, frame);
}
fn getMarkerHeight(self: *Marker, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .marker_height, frame);
}
fn getMarkerUnits(self: *Marker, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .marker_units, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marker);
    pub const Meta = struct {
        pub const name = "SVGMarkerElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const SVG_MARKERUNITS_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_MARKERUNITS_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_MARKERUNITS_STROKEWIDTH = bridge.property(2, .{ .template = true });
    pub const refX = bridge.accessor(Marker.getRefX, null, .{});
    pub const refY = bridge.accessor(Marker.getRefY, null, .{});
    pub const markerWidth = bridge.accessor(Marker.getMarkerWidth, null, .{});
    pub const markerHeight = bridge.accessor(Marker.getMarkerHeight, null, .{});
    pub const markerUnits = bridge.accessor(Marker.getMarkerUnits, null, .{});
};

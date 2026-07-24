// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");

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
    pub const SVG_UNIT_TYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_UNIT_TYPE_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_UNIT_TYPE_OBJECTBOUNDINGBOX = bridge.property(2, .{ .template = true });
    pub const clipPathUnits = bridge.accessor(ClipPath.getClipPathUnits, null, .{});
    pub const transform = bridge.accessor(ClipPath.getTransform, null, .{});
};

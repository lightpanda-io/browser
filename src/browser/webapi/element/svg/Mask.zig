// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");

const Mask = @This();
_proto: *Svg,

pub fn asElement(self: *Mask) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Mask) *Node {
    return self.asElement().asNode();
}

fn getX(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_x, frame);
}
fn getY(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_y, frame);
}
fn getWidth(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_width, frame);
}
fn getHeight(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_height, frame);
}
fn getMaskUnits(self: *Mask, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .mask_units, frame);
}
fn getMaskContentUnits(self: *Mask, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .mask_content_units, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Mask);
    pub const Meta = struct {
        pub const name = "SVGMaskElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const SVG_UNIT_TYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_UNIT_TYPE_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_UNIT_TYPE_OBJECTBOUNDINGBOX = bridge.property(2, .{ .template = true });
    pub const x = bridge.accessor(Mask.getX, null, .{});
    pub const y = bridge.accessor(Mask.getY, null, .{});
    pub const width = bridge.accessor(Mask.getWidth, null, .{});
    pub const height = bridge.accessor(Mask.getHeight, null, .{});
    pub const maskUnits = bridge.accessor(Mask.getMaskUnits, null, .{});
    pub const maskContentUnits = bridge.accessor(Mask.getMaskContentUnits, null, .{});
};

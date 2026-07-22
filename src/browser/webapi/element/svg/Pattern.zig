// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");

const Pattern = @This();
_proto: *Svg,

pub fn asElement(self: *Pattern) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Pattern) *Node {
    return self.asElement().asNode();
}

fn getX(self: *Pattern, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .pattern_x, frame);
}
fn getY(self: *Pattern, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .pattern_y, frame);
}
fn getWidth(self: *Pattern, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .pattern_width, frame);
}
fn getHeight(self: *Pattern, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .pattern_height, frame);
}
fn getPatternUnits(self: *Pattern, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .pattern_units, frame);
}
fn getPatternContentUnits(self: *Pattern, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .pattern_content_units, frame);
}
fn getPatternTransform(self: *Pattern, frame: *Frame) !*AnimatedTransformList {
    return AnimatedTransformList.getOrCreate(self.asElement(), .pattern_transform, frame);
}
fn getHref(self: *Pattern, frame: *Frame) !*AnimatedString {
    return AnimatedString.getOrCreate(self.asElement(), .href, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Pattern);
    pub const Meta = struct {
        pub const name = "SVGPatternElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const SVG_UNIT_TYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_UNIT_TYPE_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_UNIT_TYPE_OBJECTBOUNDINGBOX = bridge.property(2, .{ .template = true });
    pub const x = bridge.accessor(Pattern.getX, null, .{});
    pub const y = bridge.accessor(Pattern.getY, null, .{});
    pub const width = bridge.accessor(Pattern.getWidth, null, .{});
    pub const height = bridge.accessor(Pattern.getHeight, null, .{});
    pub const patternUnits = bridge.accessor(Pattern.getPatternUnits, null, .{});
    pub const patternContentUnits = bridge.accessor(Pattern.getPatternContentUnits, null, .{});
    pub const patternTransform = bridge.accessor(Pattern.getPatternTransform, null, .{});
    pub const href = bridge.accessor(Pattern.getHref, null, .{});
};

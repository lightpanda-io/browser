// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");

pub const LinearGradient = @import("LinearGradient.zig");
pub const RadialGradient = @import("RadialGradient.zig");

const GradientElement = @This();
_proto: *Svg,
_type: Type,

pub const Type = union(enum) {
    linear: *LinearGradient,
    radial: *RadialGradient,
};

pub fn is(self: *GradientElement, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) {
                return @field(self._type, field.name);
            }
        }
    }
    return null;
}

pub fn asElement(self: *GradientElement) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *GradientElement) *Node {
    return self.asElement().asNode();
}

fn getGradientUnits(self: *GradientElement, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .gradient_units, frame);
}

fn getSpreadMethod(self: *GradientElement, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .spread_method, frame);
}

fn getGradientTransform(self: *GradientElement, frame: *Frame) !*AnimatedTransformList {
    return AnimatedTransformList.getOrCreate(self.asElement(), .gradient_transform, frame);
}

fn getHref(self: *GradientElement, frame: *Frame) !*AnimatedString {
    return AnimatedString.getOrCreate(self.asElement(), .href, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GradientElement);
    pub const Meta = struct {
        pub const name = "SVGGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const SVG_UNIT_TYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_UNIT_TYPE_USERSPACEONUSE = bridge.property(1, .{ .template = true });
    pub const SVG_UNIT_TYPE_OBJECTBOUNDINGBOX = bridge.property(2, .{ .template = true });
    pub const SVG_SPREADMETHOD_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_SPREADMETHOD_PAD = bridge.property(1, .{ .template = true });
    pub const SVG_SPREADMETHOD_REFLECT = bridge.property(2, .{ .template = true });
    pub const SVG_SPREADMETHOD_REPEAT = bridge.property(3, .{ .template = true });

    pub const gradientUnits = bridge.accessor(GradientElement.getGradientUnits, null, .{});
    pub const spreadMethod = bridge.accessor(GradientElement.getSpreadMethod, null, .{});
    pub const gradientTransform = bridge.accessor(GradientElement.getGradientTransform, null, .{});
    pub const href = bridge.accessor(GradientElement.getHref, null, .{});
};

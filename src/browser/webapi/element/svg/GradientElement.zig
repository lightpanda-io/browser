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

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");
const AnimatedTransformList = @import("../../svg/AnimatedTransformList.zig");

const Svg = @import("../Svg.zig");

pub const LinearGradient = @import("LinearGradient.zig");
pub const RadialGradient = @import("RadialGradient.zig");

const GradientElement = @This();

pub const Proto = Svg;
_type: Type,
_proto_canary: if (lp.IS_DEBUG) *Svg else void = undefined,

pub const Type = enum(u8) {
    linear,
    radial,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .linear => LinearGradient,
        .radial => RadialGradient,
    };
}

pub fn subtype(self: *const GradientElement, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, GradientElement);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *GradientElement, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn asElement(self: *GradientElement) *Element {
    return Factory.protoOf(self).asElement();
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

    pub const SVG_SPREADMETHOD_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const SVG_SPREADMETHOD_PAD = bridge.property(1, .{ .template = true });
    pub const SVG_SPREADMETHOD_REFLECT = bridge.property(2, .{ .template = true });
    pub const SVG_SPREADMETHOD_REPEAT = bridge.property(3, .{ .template = true });

    pub const gradientUnits = bridge.accessor(GradientElement.getGradientUnits, null, .{});
    pub const spreadMethod = bridge.accessor(GradientElement.getSpreadMethod, null, .{});
    pub const gradientTransform = bridge.accessor(GradientElement.getGradientTransform, null, .{});
    pub const href = bridge.accessor(GradientElement.getHref, null, .{});
};

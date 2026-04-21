// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GradientElement = @import("GradientElement.zig");
const String = @import("../../../../string.zig").String;

const RadialGradient = @This();

_proto: *GradientElement,

pub fn asSvg(self: *RadialGradient) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *RadialGradient) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *RadialGradient) *Node {
    return self.asElement().asNode();
}

fn getFloatAttr(element: *const Element, comptime name: []const u8) f64 {
    const val = element.getAttributeSafe(comptime String.wrap(name)) orelse return 0;
    // Find end of numeric part (handles units like px, cm, in, etc.)
    var end: usize = 0;
    while (end < val.len) : (end += 1) {
        const c = val[end];
        if (c >= '0' and c <= '9' or c == '.' or ((c == '-' or c == '+') and end == 0)) continue;
        if ((c == 'e' or c == 'E') and end > 0 and end + 1 < val.len and
            (val[end + 1] >= '0' and val[end + 1] <= '9' or val[end + 1] == '-' or val[end + 1] == '+')) {
            end += 1;
            continue;
        }
        break;
    }
    if (end == 0) return 0;
    return std.fmt.parseFloat(f64, val[0..end]) catch 0;
}

pub fn get_cx(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "cx");
}
pub fn get_cy(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "cy");
}
pub fn get_r(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "r");
}
pub fn get_fx(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "fx");
}
pub fn get_fy(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "fy");
}
pub fn get_fr(self: *RadialGradient) f64 {
    return getFloatAttr(self.asElement(), "fr");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RadialGradient);
    pub const Meta = struct {
        pub const name = "SVGRadialGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const cx = bridge.accessor(RadialGradient.get_cx, null, .{});
    pub const cy = bridge.accessor(RadialGradient.get_cy, null, .{});
    pub const r = bridge.accessor(RadialGradient.get_r, null, .{});
    pub const fx = bridge.accessor(RadialGradient.get_fx, null, .{});
    pub const fy = bridge.accessor(RadialGradient.get_fy, null, .{});
    pub const fr = bridge.accessor(RadialGradient.get_fr, null, .{});
};

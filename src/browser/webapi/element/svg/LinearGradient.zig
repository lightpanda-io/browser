// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GradientElement = @import("GradientElement.zig");
const String = @import("../../../../string.zig").String;

const LinearGradient = @This();

_proto: *GradientElement,

pub fn asSvg(self: *LinearGradient) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *LinearGradient) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *LinearGradient) *Node {
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

pub fn get_x1(self: *LinearGradient) f64 {
    return getFloatAttr(self.asElement(), "x1");
}
pub fn get_y1(self: *LinearGradient) f64 {
    return getFloatAttr(self.asElement(), "y1");
}
pub fn get_x2(self: *LinearGradient) f64 {
    return getFloatAttr(self.asElement(), "x2");
}
pub fn get_y2(self: *LinearGradient) f64 {
    return getFloatAttr(self.asElement(), "y2");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(LinearGradient);
    pub const Meta = struct {
        pub const name = "SVGLinearGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x1 = bridge.accessor(LinearGradient.get_x1, null, .{});
    pub const y1 = bridge.accessor(LinearGradient.get_y1, null, .{});
    pub const x2 = bridge.accessor(LinearGradient.get_x2, null, .{});
    pub const y2 = bridge.accessor(LinearGradient.get_y2, null, .{});
};

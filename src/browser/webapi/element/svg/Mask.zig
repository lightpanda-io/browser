// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const Mask = @This();

_proto: *Svg,

pub fn asElement(self: *Mask) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Mask) *Node {
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

pub fn get_x(self: *Mask) f64 {
    return getFloatAttr(self.asElement(), "x");
}
pub fn get_y(self: *Mask) f64 {
    return getFloatAttr(self.asElement(), "y");
}
pub fn get_width(self: *Mask) f64 {
    return getFloatAttr(self.asElement(), "width");
}
pub fn get_height(self: *Mask) f64 {
    return getFloatAttr(self.asElement(), "height");
}
pub fn get_maskUnits(self: *Mask) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("maskUnits")) orelse "";
}
pub fn get_maskContentUnits(self: *Mask) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("maskContentUnits")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Mask);
    pub const Meta = struct {
        pub const name = "SVGMaskElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(Mask.get_x, null, .{});
    pub const y = bridge.accessor(Mask.get_y, null, .{});
    pub const width = bridge.accessor(Mask.get_width, null, .{});
    pub const height = bridge.accessor(Mask.get_height, null, .{});
    pub const maskUnits = bridge.accessor(Mask.get_maskUnits, null, .{});
    pub const maskContentUnits = bridge.accessor(Mask.get_maskContentUnits, null, .{});
};

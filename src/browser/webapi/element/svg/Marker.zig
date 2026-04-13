// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const Marker = @This();

_proto: *Svg,

pub fn asElement(self: *Marker) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Marker) *Node {
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

pub fn get_refX(self: *Marker) f64 {
    return getFloatAttr(self.asElement(), "refX");
}
pub fn get_refY(self: *Marker) f64 {
    return getFloatAttr(self.asElement(), "refY");
}
pub fn get_markerWidth(self: *Marker) f64 {
    return getFloatAttr(self.asElement(), "markerWidth");
}
pub fn get_markerHeight(self: *Marker) f64 {
    return getFloatAttr(self.asElement(), "markerHeight");
}
pub fn get_markerUnits(self: *Marker) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("markerUnits")) orelse "";
}
pub fn get_orient(self: *Marker) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("orient")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marker);
    pub const Meta = struct {
        pub const name = "SVGMarkerElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const refX = bridge.accessor(Marker.get_refX, null, .{});
    pub const refY = bridge.accessor(Marker.get_refY, null, .{});
    pub const markerWidth = bridge.accessor(Marker.get_markerWidth, null, .{});
    pub const markerHeight = bridge.accessor(Marker.get_markerHeight, null, .{});
    pub const markerUnits = bridge.accessor(Marker.get_markerUnits, null, .{});
    pub const orient = bridge.accessor(Marker.get_orient, null, .{});
};

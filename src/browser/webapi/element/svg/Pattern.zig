// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const Pattern = @This();

_proto: *Svg,

pub fn asElement(self: *Pattern) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Pattern) *Node {
    return self.asElement().asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(if (name.len <= 12) comptime String.wrap(name) else String.wrap(name)) orelse "";
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

pub fn get_x(self: *Pattern) f64 {
    return getFloatAttr(self.asElement(), "x");
}
pub fn get_y(self: *Pattern) f64 {
    return getFloatAttr(self.asElement(), "y");
}
pub fn get_width(self: *Pattern) f64 {
    return getFloatAttr(self.asElement(), "width");
}
pub fn get_height(self: *Pattern) f64 {
    return getFloatAttr(self.asElement(), "height");
}
pub fn get_patternUnits(self: *Pattern) []const u8 {
    return getStringAttr(self.asElement(), "patternUnits");
}
pub fn get_patternContentUnits(self: *Pattern) []const u8 {
    return getStringAttr(self.asElement(), "patternContentUnits");
}
pub fn get_href(self: *Pattern) []const u8 {
    return getStringAttr(self.asElement(), "href");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Pattern);
    pub const Meta = struct {
        pub const name = "SVGPatternElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(Pattern.get_x, null, .{});
    pub const y = bridge.accessor(Pattern.get_y, null, .{});
    pub const width = bridge.accessor(Pattern.get_width, null, .{});
    pub const height = bridge.accessor(Pattern.get_height, null, .{});
    pub const patternUnits = bridge.accessor(Pattern.get_patternUnits, null, .{});
    pub const patternContentUnits = bridge.accessor(Pattern.get_patternContentUnits, null, .{});
    pub const href = bridge.accessor(Pattern.get_href, null, .{});
};

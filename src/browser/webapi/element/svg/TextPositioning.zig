// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// SVGTextPositioningElement - 7-level chain:
// EventTarget → Node → Element → Svg → GraphicsElement → TextContent → TextPositioning
// NOTE: Factory.zig must handle 7-level chains for this element.

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const TextContent = @import("TextContent.zig");
const String = @import("../../../../string.zig").String;

const TextPositioning = @This();

_proto: *TextContent,

pub fn asTextContent(self: *TextPositioning) *TextContent {
    return self._proto;
}
pub fn asSvg(self: *TextPositioning) *Svg {
    return self._proto.asSvg();
}
pub fn asElement(self: *TextPositioning) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextPositioning) *Node {
    return self._proto.asNode();
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

pub fn get_x(self: *TextPositioning) f64 {
    return getFloatAttr(self.asElement(), "x");
}
pub fn get_y(self: *TextPositioning) f64 {
    return getFloatAttr(self.asElement(), "y");
}
pub fn get_dx(self: *TextPositioning) f64 {
    return getFloatAttr(self.asElement(), "dx");
}
pub fn get_dy(self: *TextPositioning) f64 {
    return getFloatAttr(self.asElement(), "dy");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextPositioning);
    pub const Meta = struct {
        pub const name = "SVGTextPositioningElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(TextPositioning.get_x, null, .{});
    pub const y = bridge.accessor(TextPositioning.get_y, null, .{});
    pub const dx = bridge.accessor(TextPositioning.get_dx, null, .{});
    pub const dy = bridge.accessor(TextPositioning.get_dy, null, .{});
};

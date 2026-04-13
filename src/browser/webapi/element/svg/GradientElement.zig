// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const GradientElement = @This();

_proto: *Svg,

pub fn asElement(self: *GradientElement) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *GradientElement) *Node {
    return self.asElement().asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(if (name.len <= 12) comptime String.wrap(name) else String.wrap(name)) orelse "";
}

pub fn get_gradientUnits(self: *GradientElement) []const u8 {
    return getStringAttr(self.asElement(), "gradientUnits");
}
pub fn get_spreadMethod(self: *GradientElement) []const u8 {
    return getStringAttr(self.asElement(), "spreadMethod");
}
pub fn get_href(self: *GradientElement) []const u8 {
    return getStringAttr(self.asElement(), "href");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GradientElement);
    pub const Meta = struct {
        pub const name = "SVGGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const gradientUnits = bridge.accessor(GradientElement.get_gradientUnits, null, .{});
    pub const spreadMethod = bridge.accessor(GradientElement.get_spreadMethod, null, .{});
    pub const href = bridge.accessor(GradientElement.get_href, null, .{});
};

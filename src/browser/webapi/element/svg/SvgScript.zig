// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const SvgScript = @This();

_proto: *Svg,

pub fn asElement(self: *SvgScript) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *SvgScript) *Node {
    return self.asElement().asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_type(self: *SvgScript) []const u8 {
    return getStringAttr(self.asElement(), "type");
}
pub fn get_crossOrigin(self: *SvgScript) []const u8 {
    return getStringAttr(self.asElement(), "crossorigin");
}
pub fn get_href(self: *SvgScript) []const u8 {
    return getStringAttr(self.asElement(), "href");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SvgScript);
    pub const Meta = struct {
        pub const name = "SVGScriptElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"type" = bridge.accessor(SvgScript.get_type, null, .{});
    pub const crossOrigin = bridge.accessor(SvgScript.get_crossOrigin, null, .{});
    pub const href = bridge.accessor(SvgScript.get_href, null, .{});
};

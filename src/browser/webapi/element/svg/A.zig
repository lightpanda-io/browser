// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const String = @import("../../../../string.zig").String;

const A = @This();

_proto: *GraphicsElement,

pub fn asSvg(self: *A) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *A) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *A) *Node {
    return self.asElement().asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_href(self: *A) []const u8 {
    return getStringAttr(self.asElement(), "href");
}
pub fn get_target(self: *A) []const u8 {
    return getStringAttr(self.asElement(), "target");
}
pub fn get_download(self: *A) []const u8 {
    return getStringAttr(self.asElement(), "download");
}
pub fn get_rel(self: *A) []const u8 {
    return getStringAttr(self.asElement(), "rel");
}
pub fn get_hreflang(self: *A) []const u8 {
    return getStringAttr(self.asElement(), "hreflang");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(A);
    pub const Meta = struct {
        pub const name = "SVGAElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    // getBBox inherited from GraphicsElement via prototype chain
    pub const href = bridge.accessor(A.get_href, null, .{});
    pub const target = bridge.accessor(A.get_target, null, .{});
    pub const download = bridge.accessor(A.get_download, null, .{});
    pub const rel = bridge.accessor(A.get_rel, null, .{});
    pub const hreflang = bridge.accessor(A.get_hreflang, null, .{});
};

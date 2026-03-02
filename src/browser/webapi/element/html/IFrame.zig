// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const log = @import("../../../../log.zig");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Window = @import("../../Window.zig");
const Document = @import("../../Document.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const URL = @import("../../URL.zig");

const IFrame = @This();
_proto: *HtmlElement,
_src: []const u8 = "",
_executed: bool = false,
_content_window: ?*Window = null,

pub fn asElement(self: *IFrame) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *IFrame) *Node {
    return self.asElement().asNode();
}

pub fn getContentWindow(self: *const IFrame) ?*Window {
    return self._content_window;
}

pub fn getContentDocument(self: *const IFrame) ?*Document {
    const window = self._content_window orelse return null;
    return window._document;
}

pub fn getSrc(self: *const IFrame, page: *Page) ![:0]const u8 {
    if (self._src.len == 0) return "";
    return try URL.resolve(page.call_arena, page.base(), self._src, .{ .encode = true });
}

pub fn setSrc(self: *IFrame, src: []const u8, page: *Page) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(src), page);
    self._src = element.getAttributeSafe(comptime .wrap("src")) orelse unreachable;
    if (element.asNode().isConnected()) {
        try page.iframeAddedCallback(self);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IFrame);

    pub const Meta = struct {
        pub const name = "HTMLIFrameElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const src = bridge.accessor(IFrame.getSrc, IFrame.setSrc, .{});
    pub const contentWindow = bridge.accessor(IFrame.getContentWindow, null, .{});
    pub const contentDocument = bridge.accessor(IFrame.getContentDocument, null, .{});
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Page) !void {
        const self = node.as(IFrame);
        const element = self.asElement();
        self._src = element.getAttributeSafe(comptime .wrap("src")) orelse "";
    }
};

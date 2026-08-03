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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Window = @import("../../Window.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const String = lp.String;
const IFrame = @This();

pub const Proto = HtmlElement;
_proto: *HtmlElement,
_src: []const u8 = "",
_executed: bool = false,
// setSrc lets the reflected attribute update state, then reports navigation errors itself.
_setting_src: bool = false,
_window: ?*Window = null,

pub fn asElement(self: *IFrame) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *IFrame) *Node {
    return self.asElement().asNode();
}

pub fn getContentWindow(self: *const IFrame, frame: *Frame) ?Window.Access {
    const frame_window = self._window orelse return null;
    return Window.Access.init(frame.window, frame_window);
}

pub fn getContentDocument(self: *const IFrame) ?*Document {
    const window = self._window orelse return null;
    return window._document;
}

// loading=lazy iframes are still but don't delay the page's "load" event
pub fn isLazyLoading(self: *IFrame) bool {
    const loading = self.asElement().getAttributeSafe(comptime .wrap("loading")) orelse return false;
    return std.ascii.eqlIgnoreCase(loading, "lazy");
}

pub fn getSrc(self: *IFrame, frame: *Frame) ![]const u8 {
    if (self._src.len == 0) return "";
    return self.asNode().resolveURLReflect(self._src, frame, .{});
}

pub fn setSrc(self: *IFrame, src: []const u8, frame: *Frame) !void {
    const was_setting_src = self._setting_src;
    self._setting_src = true;
    defer self._setting_src = was_setting_src;

    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(src), frame);
    if (!was_setting_src) {
        try self.navigateForSrcChange(frame);
    }
}

fn srcAttributeChanged(self: *IFrame, frame: *Frame) !void {
    self._src = self.asElement().getAttributeSafe(comptime .wrap("src")) orelse "";
    self._executed = false;
    if (!self._setting_src) {
        try self.navigateForSrcChange(frame);
    }
}

fn srcAttributeRemoved(self: *IFrame, frame: *Frame) !void {
    const was_blank = self._src.len == 0;
    self._src = "";
    if (was_blank and self.asNode().isConnected()) {
        return;
    }

    self._executed = false;
    if (!was_blank) {
        try self.navigateForSrcChange(frame);
    }
}

fn navigateForSrcChange(self: *IFrame, frame: *Frame) !void {
    if (self.asNode().isConnected()) {
        // Unlike script, an iframe is reloaded every time src is set,
        // even if it is set to the same URL.
        try frame.iframeAddedCallback(self);
    }
}

pub fn getName(self: *IFrame) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *IFrame, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub fn getSandbox(self: *IFrame, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.sandbox, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IFrame);

    pub const Meta = struct {
        pub const name = "HTMLIFrameElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const src = bridge.accessor(IFrame.getSrc, IFrame.setSrc, .{ .ce_reactions = true });
    pub const name = bridge.accessor(IFrame.getName, IFrame.setName, .{ .ce_reactions = true });
    pub const contentWindow = bridge.accessor(IFrame.getContentWindow, null, .{});
    pub const contentDocument = bridge.accessor(IFrame.getContentDocument, null, .{});
    pub const sandbox = bridge.accessor(IFrame.getSandbox, null, .{ .null_as_undefined = true });
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Frame) !void {
        const self = node.as(IFrame);
        const element = self.asElement();
        self._src = element.getAttributeSafe(comptime .wrap("src")) orelse "";
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }

        try element.as(IFrame).srcAttributeChanged(frame);
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }

        try element.as(IFrame).srcAttributeRemoved(frame);
    }
};

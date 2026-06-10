// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Element = @import("../../Element.zig");
const DocumentFragment = @import("../../DocumentFragment.zig");

const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Template = @This();

_proto: *HtmlElement,
_content: *DocumentFragment,

pub fn asElement(self: *Template) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const Template) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Template) *Node {
    return self.asElement().asNode();
}

pub fn getContent(self: *Template) *DocumentFragment {
    return self._content;
}

pub fn setInnerHTML(self: *Template, html: []const u8, frame: *Frame) !void {
    return self._content.setInnerHTML(html, frame);
}

pub fn getShadowRootMode(self: *const Template) []const u8 {
    const value = self.asConstElement().getAttributeSafe(.wrap("shadowrootmode")) orelse return "";

    if (std.ascii.eqlIgnoreCase(value, "open")) {
        return "open";
    }

    if (std.ascii.eqlIgnoreCase(value, "closed")) {
        return "closed";
    }

    return "";
}

pub fn setShadowRootMode(self: *Template, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("shadowrootmode"), .wrap(value), frame);
}

fn getBoolAttribute(self: *const Template, name: String) bool {
    return self.asConstElement().getAttributeSafe(name) != null;
}

fn setBoolAttribute(self: *Template, name: String, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(name, .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(name, frame);
    }
}

pub fn getOuterHTML(self: *Template, writer: *std.Io.Writer, frame: *Frame) !void {
    const dump = @import("../../../dump.zig");
    const el = self.asElement();

    try el.format(writer);
    try dump.children(self._content.asNode(), .{ .shadow = .skip }, writer, frame);
    try writer.writeAll("</");
    try writer.writeAll(el.getTagNameDump());
    try writer.writeByte('>');
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Template);

    pub const Meta = struct {
        pub const name = "HTMLTemplateElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const content = bridge.accessor(Template.getContent, null, .{});
    pub const innerHTML = bridge.accessor(_getInnerHTML, Template.setInnerHTML, .{ .ce_reactions = true });
    pub const outerHTML = bridge.accessor(_getOuterHTML, null, .{});
    pub const shadowRootMode = bridge.accessor(Template.getShadowRootMode, Template.setShadowRootMode, .{ .ce_reactions = true });
    pub const shadowRootDelegatesFocus = bridge.accessor(_getShadowRootDelegatesFocus, _setShadowRootDelegatesFocus, .{ .ce_reactions = true });
    pub const shadowRootClonable = bridge.accessor(_getShadowRootClonable, _setShadowRootClonable, .{ .ce_reactions = true });
    pub const shadowRootSerializable = bridge.accessor(_getShadowRootSerializable, _setShadowRootSerializable, .{ .ce_reactions = true });

    fn _getShadowRootDelegatesFocus(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootdelegatesfocus"));
    }
    fn _setShadowRootDelegatesFocus(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootdelegatesfocus"), value, frame);
    }
    fn _getShadowRootClonable(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootclonable"));
    }
    fn _setShadowRootClonable(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootclonable"), value, frame);
    }
    fn _getShadowRootSerializable(self: *const Template) bool {
        return self.getBoolAttribute(.wrap("shadowrootserializable"));
    }
    fn _setShadowRootSerializable(self: *Template, value: bool, frame: *Frame) !void {
        try self.setBoolAttribute(.wrap("shadowrootserializable"), value, frame);
    }

    fn _getInnerHTML(self: *Template, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self._content.getInnerHTML(&buf.writer, frame);
        return buf.written();
    }

    fn _getOuterHTML(self: *Template, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self.getOuterHTML(&buf.writer, frame);
        return buf.written();
    }
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Template);
        // Create the template content DocumentFragment
        self._content = try DocumentFragment.init(frame);
    }

    // Per the HTML spec's cloning steps for <template>, a deep clone must
    // also copy the content fragment (the element itself has no childNodes,
    // so the generic deep-clone loop won't do it).
    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, frame: *Frame) !void {
        if (!deep) {
            return;
        }
        const source = source_element.as(Template);
        const clone = cloned_element.as(Template);
        const clone_content = clone._content.asNode();
        var child_it = source._content.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                try frame.appendNode(clone_content, cloned_child, .{ .child_already_connected = true });
            }
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Template" {
    try testing.htmlRunner("element/html/template.html", .{});
}

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

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");

const TextArea = @This();

_proto: *HtmlElement,
_default_value: ?[]const u8 = null,
_value: ?[]const u8 = null,

pub fn asElement(self: *TextArea) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const TextArea) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *TextArea) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *const TextArea) []const u8 {
    return self._value orelse self._default_value orelse "";
}

pub fn setValue(self: *TextArea, value: []const u8, page: *Page) !void {
    const owned = try page.arena.dupe(u8, value);
    self._value = owned;
}

pub fn getDefaultValue(self: *const TextArea) []const u8 {
    return self._default_value orelse "";
}

pub fn getDisabled(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe("disabled") != null;
}

pub fn setDisabled(self: *TextArea, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe("disabled", "", page);
    } else {
        try self.asElement().removeAttribute("disabled", page);
    }
}

pub fn getForm(self: *TextArea, page: *Page) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe("form")) |form_id| {
        if (page.document.getElementById(form_id)) |form_element| {
            return form_element.is(Form);
        }
        // form attribute present but invalid - no form owner
        return null;
    }

    // No form attribute - traverse ancestors looking for a <form>
    var node = element.asNode()._parent;
    while (node) |n| {
        if (n.is(Element.Html.Form)) |form| {
            return form;
        }
        node = n._parent;
    }

    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextArea);

    pub const Meta = struct {
        pub const name = "HTMLTextAreaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(TextArea.getValue, TextArea.setValue, .{});
    pub const defaultValue = bridge.accessor(TextArea.getDefaultValue, null, .{});
    pub const disabled = bridge.accessor(TextArea.getDisabled, TextArea.setDisabled, .{});
    pub const form = bridge.accessor(TextArea.getForm, null, .{});
};

pub const Build = struct {
    const CData = @import("../../CData.zig");

    pub fn complete(node: *Node, _: *const Page) !void {
        var self = node.as(TextArea);

        // Get default value from text content
        if (node.firstChild()) |child| {
            if (child.is(CData.Text)) |txt| {
                self._default_value = txt.getWholeText();
            }
        }

        // Current state starts equal to default
        self._value = self._default_value;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TextArea" {
    try testing.htmlRunner("element/html/textarea.html", .{});
}

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

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");

const TextArea = @This();

_proto: *HtmlElement,
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
pub fn asConstNode(self: *const TextArea) *const Node {
    return self.asConstElement().asConstNode();
}

pub fn getValue(self: *const TextArea) []const u8 {
    return self._value orelse self.getDefaultValue();
}

pub fn setValue(self: *TextArea, value: []const u8, page: *Page) !void {
    const owned = try page.arena.dupe(u8, value);
    self._value = owned;
}

pub fn getDefaultValue(self: *const TextArea) []const u8 {
    const node = self.asConstNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            return txt.getWholeText();
        }
    }
    return "";
}

pub fn setDefaultValue(self: *TextArea, value: []const u8, page: *Page) !void {
    const owned = try page.dupeString(value);

    const node = self.asNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            txt._proto._data = owned;
            return;
        }
    }

    // No text child exists, create one
    const text_node = try page.createTextNode(owned);
    _ = try node.appendChild(text_node, page);
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

pub fn getName(self: *const TextArea) []const u8 {
    return self.asConstElement().getAttributeSafe("name") orelse "";
}

pub fn setName(self: *TextArea, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("name", name, page);
}

pub fn getRequired(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe("required") != null;
}

pub fn setRequired(self: *TextArea, required: bool, page: *Page) !void {
    if (required) {
        try self.asElement().setAttributeSafe("required", "", page);
    } else {
        try self.asElement().removeAttribute("required", page);
    }
}

pub fn getForm(self: *TextArea, page: *Page) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe("form")) |form_id| {
        if (page.document.getElementById(form_id, page)) |form_element| {
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
    pub const defaultValue = bridge.accessor(TextArea.getDefaultValue, TextArea.setDefaultValue, .{});
    pub const disabled = bridge.accessor(TextArea.getDisabled, TextArea.setDisabled, .{});
    pub const name = bridge.accessor(TextArea.getName, TextArea.setName, .{});
    pub const required = bridge.accessor(TextArea.getRequired, TextArea.setRequired, .{});
    pub const form = bridge.accessor(TextArea.getForm, null, .{});
};

pub const Build = struct {
    pub fn cloned(source_element: *Element, cloned_element: *Element, _: *Page) !void {
        const source = source_element.as(TextArea);
        const clone = cloned_element.as(TextArea);
        clone._value = source._value;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TextArea" {
    try testing.htmlRunner("element/html/textarea.html", .{});
}

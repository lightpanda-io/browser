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

const Button = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Button) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Button) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Button) *Node {
    return self.asElement().asNode();
}

pub fn getDisabled(self: *const Button) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Button, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getName(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Button, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

pub fn getType(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "submit";
}

pub fn setType(self: *Button, typ: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(typ), page);
}

pub fn getValue(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("value")) orelse "";
}

pub fn setValue(self: *Button, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), page);
}

pub fn getRequired(self: *const Button) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn setRequired(self: *Button, required: bool, page: *Page) !void {
    if (required) {
        try self.asElement().setAttributeSafe(comptime .wrap("required"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("required"), page);
    }
}

pub fn getForm(self: *Button, page: *Page) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
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
    pub const bridge = js.Bridge(Button);

    pub const Meta = struct {
        pub const name = "HTMLButtonElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const disabled = bridge.accessor(Button.getDisabled, Button.setDisabled, .{});
    pub const name = bridge.accessor(Button.getName, Button.setName, .{});
    pub const required = bridge.accessor(Button.getRequired, Button.setRequired, .{});
    pub const form = bridge.accessor(Button.getForm, null, .{});
    pub const value = bridge.accessor(Button.getValue, Button.setValue, .{});
    pub const @"type" = bridge.accessor(Button.getType, Button.setType, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Page) !void {
        // No initialization needed - disabled is lazy from attribute
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Button" {
    try testing.htmlRunner("element/html/button.html", .{});
}

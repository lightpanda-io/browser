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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");

const Input = @This();

pub const Type = enum {
    text,
    password,
    checkbox,
    radio,
    submit,
    reset,
    button,
    hidden,
    image,
    file,
    email,
    url,
    tel,
    search,
    number,
    range,
    date,
    time,
    datetime_local,
    month,
    week,
    color,

    pub fn fromString(str: []const u8) Type {
        // Longest type name is "datetime-local" at 14 chars
        if (str.len > 32) return .text;

        var buf: [32]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, str);
        return std.meta.stringToEnum(Type, lower) orelse .text;
    }

    pub fn toString(self: Type) []const u8 {
        return switch (self) {
            .datetime_local => "datetime-local",
            else => @tagName(self),
        };
    }
};

_proto: *HtmlElement,
_default_value: ?[]const u8 = null,
_default_checked: bool = false,
_value: ?[]const u8 = null,
_checked: bool = false,
_input_type: Type = .text,

pub fn asElement(self: *Input) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Input) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Input) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Input) []const u8 {
    return self._input_type.toString();
}

pub fn setType(self: *Input, typ: []const u8, page: *Page) !void {
    // Setting the type property should update the attribute, which will trigger attributeChange
    const type_enum = Type.fromString(typ);
    try self.asElement().setAttributeSafe("type", type_enum.toString(), page);
}

pub fn getValue(self: *const Input) []const u8 {
    return self._value orelse self._default_value orelse "";
}

pub fn setValue(self: *Input, value: []const u8, page: *Page) !void {
    // This should _not_ call setAttribute. It updates the default state only
    const owned = try page.dupeString(value);
    self._value = owned;
}

pub fn getDefaultValue(self: *const Input) []const u8 {
    return self._default_value orelse "";
}

pub fn getChecked(self: *const Input) bool {
    return self._checked;
}

pub fn setChecked(self: *Input, checked: bool, page: *Page) !void {
    // If checking a radio button, uncheck others in the group first
    if (checked and self._input_type == .radio) {
        try self.uncheckRadioGroup(page);
    }
    // This should _not_ call setAttribute. It updates the default state only
    self._checked = checked;
}

pub fn getDefaultChecked(self: *const Input) bool {
    return self._default_checked;
}

pub fn getDisabled(self: *const Input) bool {
    // TODO: Also check for disabled fieldset ancestors
    // (but not if we're inside a <legend> of that fieldset)
    return self.asConstElement().getAttributeSafe("disabled") != null;
}

pub fn setDisabled(self: *Input, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe("disabled", "", page);
    } else {
        try self.asElement().removeAttribute("disabled", page);
    }
}

pub fn getForm(self: *Input, page: *Page) ?*Form {
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

fn uncheckRadioGroup(self: *Input, page: *Page) !void {
    const element = self.asElement();

    const name = element.getAttributeSafe("name") orelse return;
    if (name.len == 0) {
        return;
    }

    const my_form = self.getForm(page);

    const TreeWalker = @import("../../TreeWalker.zig");
    var walker = TreeWalker.Full.init(page.document.asNode(), .{});

    while (walker.next()) |node| {
        const other_element = node.is(Element) orelse continue;
        const other_input = other_element.is(Input) orelse continue;

        if (other_input._input_type != .radio) {
            continue;
        }

        const other_name = other_element.getAttributeSafe("name") orelse continue;
        if (!std.mem.eql(u8, name, other_name)) {
            continue;
        }

        // Check if same form context
        const other_form = other_input.getForm(page);
        if (my_form == null and other_form == null) {
            other_input._checked = false;
            continue;
        }

        if (my_form) |mf| {
            if (other_form) |of| {
                if (mf == of) {
                    other_input._checked = false;
                }
            }
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Input);

    pub const Meta = struct {
        pub const name = "HTMLInputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(Input.getType, Input.setType, .{});
    pub const value = bridge.accessor(Input.getValue, Input.setValue, .{});
    pub const defaultValue = bridge.accessor(Input.getDefaultValue, null, .{});
    pub const checked = bridge.accessor(Input.getChecked, Input.setChecked, .{});
    pub const defaultChecked = bridge.accessor(Input.getDefaultChecked, null, .{});
    pub const disabled = bridge.accessor(Input.getDisabled, Input.setDisabled, .{});
    pub const form = bridge.accessor(Input.getForm, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, page: *Page) !void {
        var self = node.as(Input);
        const element = self.asElement();

        // Store initial values from attributes
        self._default_value = element.getAttributeSafe("value");
        self._default_checked = element.getAttributeSafe("checked") != null;

        // Current state starts equal to default
        self._value = self._default_value;
        self._checked = self._default_checked;

        self._input_type = if (element.getAttributeSafe("type")) |type_attr|
            Type.fromString(type_attr)
        else
            .text;

        // If this is a checked radio button, uncheck others in its group
        if (self._checked and self._input_type == .radio) {
            try self.uncheckRadioGroup(page);
        }
    }

    pub fn attributeChange(element: *Element, name: []const u8, value: []const u8, _: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => self._input_type = Type.fromString(value),
            .value => self._default_value = value,
            .checked => self._default_checked = true,
        }
    }

    pub fn attributeRemove(element: *Element, name: []const u8, _: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => self._input_type = .text,
            .value => self._default_value = null,
            .checked => self._default_checked = false,
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Input" {
    try testing.htmlRunner("element/html/input.html", .{});
    try testing.htmlRunner("element/html/input_radio.html", .{});
}

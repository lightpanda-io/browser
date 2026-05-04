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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");

const Button = @This();

_proto: *HtmlElement,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

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

pub fn setDisabled(self: *Button, disabled: bool, frame: *Frame) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), frame);
    }
}

pub fn getName(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Button, name: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), frame);
}

pub fn getType(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "submit";
}

pub fn setType(self: *Button, typ: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(typ), frame);
}

pub fn getValue(self: *const Button) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("value")) orelse "";
}

pub fn setValue(self: *Button, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), frame);
}

pub fn getRequired(self: *const Button) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn setRequired(self: *Button, required: bool, frame: *Frame) !void {
    if (required) {
        try self.asElement().setAttributeSafe(comptime .wrap("required"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("required"), frame);
    }
}

pub fn getForm(self: *Button, frame: *Frame) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
        if (frame.document.getElementById(form_id, frame)) |form_element| {
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

pub fn getLabels(self: *Button, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api
//
// Per spec, only buttons with type="submit" participate in constraint validation,
// and the only flag they can raise is customError. type="reset" and type="button"
// are barred from constraint validation entirely.

pub fn getWillValidate(self: *const Button) bool {
    if (self.getDisabled()) return false;
    return std.mem.eql(u8, self.getType(), "submit");
}

pub fn getValidity(self: *Button, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

pub fn getValidationMessage(self: *const Button) []const u8 {
    if (!self.getWillValidate()) return "";
    return self._custom_validity orelse "";
}

pub fn checkValidity(self: *Button, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    if (self._custom_validity == null) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *Button, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *Button, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Button) bool {
    return self._custom_validity != null;
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
    pub const labels = bridge.accessor(Button.getLabels, null, .{});
    pub const willValidate = bridge.accessor(Button.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Button.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Button.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(Button.checkValidity, .{});
    pub const reportValidity = bridge.function(Button.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Button.setCustomValidity, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Frame) !void {
        // No initialization needed - disabled is lazy from attribute
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Button" {
    try testing.htmlRunner("element/html/button.html", .{});
}

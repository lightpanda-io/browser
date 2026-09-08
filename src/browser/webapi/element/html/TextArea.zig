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

const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");
const reflection = @import("../reflection.zig");
const text_entry = @import("../text_entry.zig");

const TextArea = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_value: ?[]const u8 = null,
// Only user edits count for tooLong/tooShort; script and attribute values don't.
_user_edited: bool = false,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

_on_selectionchange: ?js.Function.Global = null,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

pub fn getOnSelectionChange(self: *TextArea) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *TextArea, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

pub fn asElement(self: *TextArea) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const TextArea) *const Element {
    return Factory.protoOf(self).asElement();
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

pub fn setValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    const changed = std.mem.eql(u8, self.getValue(), value) == false;
    if (changed == false and self._value != null) {
        // _value itself isn't changing (not to be mixed up with setValue
        // being called with the same as the default value, which would need
        // to dupe)
        self._user_edited = false;
        return;
    }
    const owned = try frame.arena.dupe(u8, value);
    self._value = owned;
    self._user_edited = false;

    // move the text entry cursor position to the end of the text control
    if (changed) {
        self._selection_start = @intCast(owned.len);
        self._selection_end = @intCast(owned.len);
        self._selection_direction = .none;
    }
}

pub fn setUserValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    try self.setValue(value, frame);
    self._user_edited = true;
}

pub fn getDefaultValue(self: *const TextArea) []const u8 {
    const node = self.asConstNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            return txt.ownData();
        }
    }
    return "";
}

pub fn setDefaultValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            txt.asCData()._data = try frame.dupeSSO(value);
            return;
        }
    }

    // No text child exists, create one
    const text_node = try Frame.node_factory.createTextNode(frame, value);
    _ = try node.appendChild(text_node, frame);
}

pub fn getMaxLength(self: *const TextArea) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("maxlength"));
}

pub fn getMinLength(self: *const TextArea) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("minlength"));
}

const entry = text_entry.TextEntry(TextArea);

pub const select = entry.select;
pub const innerInsert = entry.innerInsert;
pub const innerDelete = entry.innerDelete;
pub const moveCaret = entry.moveCaret;
pub const CaretMove = entry.CaretMove;
pub const getSelectionDirection = entry.getSelectionDirection;
pub const setSelectionStart = entry.setSelectionStart;
pub const setSelectionEnd = entry.setSelectionEnd;
pub const setSelectionRange = entry.setSelectionRange;

// <textarea> always supports selection; <input> only does for some types.
pub fn selectionAvailable(_: *const TextArea) bool {
    return true;
}

// Non-null unlike input
pub fn getSelectionStart(self: *const TextArea) u32 {
    return self._selection_start;
}

pub fn getSelectionEnd(self: *const TextArea) u32 {
    return self._selection_end;
}

pub fn getForm(self: *TextArea, frame: *Frame) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
        if (frame.getElementByIdFromNode(element.asNode(), form_id)) |form_element| {
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

pub fn getLabels(self: *TextArea, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getWillValidate(self: *const TextArea) bool {
    return !self.asConstElement().isDisabled();
}

pub fn getValidity(self: *TextArea, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

pub fn getValidationMessage(self: *const TextArea) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing()) return "Please fill out this field.";
    if (self.suffersTooLong()) return "Please shorten this text.";
    if (self.suffersTooShort()) return "Please lengthen this text.";
    return "";
}

pub fn checkValidity(self: *TextArea, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    const v = ValidityState{ ._owner = self.asElement() };
    if (v.getValid(frame)) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *TextArea, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *TextArea, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const TextArea) bool {
    return self._custom_validity != null;
}

pub fn suffersValueMissing(self: *const TextArea) bool {
    if (!self.getWillValidate()) return false;
    if (!self.getRequired()) return false;
    return self.getValue().len == 0;
}

pub fn suffersTooLong(self: *const TextArea) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    const max = self.getMaxLength();
    if (max < 0) return false;
    const count = std.unicode.utf8CountCodepoints(value) catch value.len;
    return count > @as(usize, @intCast(max));
}

pub fn suffersTooShort(self: *const TextArea) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    const min = self.getMinLength();
    if (min < 0) return false;
    const count = std.unicode.utf8CountCodepoints(value) catch value.len;
    return count < @as(usize, @intCast(min));
}

pub fn getDisabled(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn getRequired(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextArea);

    pub const Meta = struct {
        pub const name = "HTMLTextAreaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TextArea);
    pub const rows = reflect.unsignedLong("rows", .{ .default = 2, .positive = true, .fallback = true });
    pub const cols = reflect.unsignedLong("cols", .{ .default = 20, .positive = true, .fallback = true });
    pub const readOnly = reflect.boolean("readonly");
    pub const wrap = reflect.string("wrap");
    pub const placeholder = reflect.string("placeholder");
    pub const dirName = reflect.string("dirname");

    pub const labels = bridge.accessor(TextArea.getLabels, null, .{});
    pub const willValidate = bridge.accessor(TextArea.getWillValidate, null, .{});
    pub const validity = bridge.accessor(TextArea.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(TextArea.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(TextArea.checkValidity, .{});
    pub const reportValidity = bridge.function(TextArea.reportValidity, .{});
    pub const setCustomValidity = bridge.function(TextArea.setCustomValidity, .{});
    pub const onselectionchange = bridge.accessor(TextArea.getOnSelectionChange, TextArea.setOnSelectionChange, .{});
    pub const value = bridge.accessor(TextArea.getValue, TextArea.setValue, .{});
    pub const defaultValue = bridge.accessor(TextArea.getDefaultValue, TextArea.setDefaultValue, .{ .ce_reactions = true });
    pub const disabled = reflect.boolean("disabled");
    pub const name = reflect.string("name");
    pub const required = reflect.boolean("required");
    pub const maxLength = reflect.limitedLong("maxlength");
    pub const minLength = reflect.limitedLong("minlength");
    pub const form = bridge.accessor(TextArea.getForm, null, .{});
    pub const select = bridge.function(TextArea.select, .{});

    pub const selectionStart = bridge.accessor(TextArea.getSelectionStart, TextArea.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(TextArea.getSelectionEnd, TextArea.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(TextArea.getSelectionDirection, null, .{});
    pub const setSelectionRange = bridge.function(TextArea.setSelectionRange, .{});
};

pub const Build = struct {
    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, _: *Frame) !void {
        _ = deep;
        const source = source_element.as(TextArea);
        const clone = cloned_element.as(TextArea);
        clone._value = source._value;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TextArea" {
    try testing.htmlRunner("element/html/textarea.html", .{});
    try testing.htmlRunner("element/html/textarea-validity.html", .{});
}

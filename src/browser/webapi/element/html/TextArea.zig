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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Selection = @import("../../Selection.zig");

const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");
const text_entry = @import("../text_entry.zig");

const Form = @import("Form.zig");
const ValidityState = @import("ValidityState.zig");

const TextArea = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_value: ?[]const u8 = null,
// Only user edits count for tooLong/tooShort; script and attribute values don't.
_user_edited: bool = false,
// The value before the user's first edit since the last change event.
_value_before_edit: ?[]const u8 = null,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,
// A queued selectionchange not yet fired; later changes fold into it.
_selectionchange_pending: bool = false,

_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

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

pub fn setValue(self: *TextArea, raw_value: []const u8, frame: *Frame) !void {
    const value = try normalizeNewlines(raw_value, frame.call_arena);
    const changed = std.mem.eql(u8, self.getValue(), value) == false;
    if (changed == false and self._value != null) {
        // _value itself isn't changing (not to be mixed up with setValue
        // being called with the same as the default value, which would need
        // to dupe)
        self._user_edited = false;
        return;
    }
    const owned = try frame.page_arena.dupe(u8, value);
    self._value = owned;
    self._user_edited = false;

    // move the text entry cursor position to the end of the text control
    if (changed) {
        self._selection_start = @intCast(owned.len);
        self._selection_end = @intCast(owned.len);
        self._selection_direction = .none;
    }
}

// The API value has LF newlines: CRLF and lone CR become LF.
fn normalizeNewlines(value: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const first = std.mem.findScalar(u8, value, '\r') orelse return value;

    var result = try arena.alloc(u8, value.len);
    @memcpy(result[0..first], value[0..first]);

    var i: usize = first;
    var j: usize = first;
    while (j < value.len) : (j += 1) {
        if (value[j] == '\r') {
            result[i] = '\n';
            if (j + 1 < value.len and value[j + 1] == '\n') {
                j += 1;
            }
        } else {
            result[i] = value[j];
        }
        i += 1;
    }
    return result[0..i];
}

pub fn reset(self: *TextArea) void {
    self._value = null;
    self._user_edited = false;
}

pub fn setUserValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    try self.setValue(value, frame);
    self._user_edited = true;
}

fn getDefaultValue(self: *const TextArea) []const u8 {
    const node = self.asConstNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            return txt.ownData();
        }
    }
    return "";
}

fn setDefaultValue(self: *TextArea, value: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            txt.asCData()._data = try frame.dupeSSO(value);
            return;
        }
    }

    // No text child exists, create one
    const text_node = try Frame.node_factory.createTextNode(node.getDocument(frame), value);
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
pub const acceptsTextEntry = entry.acceptsTextEntry;
pub const tracksSelection = entry.tracksSelection;
pub const innerDelete = entry.innerDelete;
pub const moveCaret = entry.moveCaret;
pub const caretToEnd = entry.caretToEnd;
pub const rememberValueBeforeEdit = entry.rememberValueBeforeEdit;
pub const dispatchChangeIfEdited = entry.dispatchChangeIfEdited;
pub const CaretMove = entry.CaretMove;
pub const getSelectionDirection = entry.getSelectionDirection;
pub const setSelectionStart = entry.setSelectionStart;
pub const setSelectionEnd = entry.setSelectionEnd;
pub const setSelectionRange = entry.setSelectionRange;
pub const setRangeText = entry.setRangeText;

// <textarea> always supports selection; <input> only does for some types.
pub fn selectionAvailable(_: *const TextArea) bool {
    return true;
}

// Non-null unlike input
fn getSelectionStart(self: *const TextArea) u32 {
    return entry.selectionOffsetToJs(self, self._selection_start);
}

fn getSelectionEnd(self: *const TextArea) u32 {
    return entry.selectionOffsetToJs(self, self._selection_end);
}

pub fn getForm(self: *TextArea) ?*Form {
    return Form.ownerOf(self.asElement());
}

fn getLabels(self: *TextArea, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getWillValidate(self: *const TextArea) bool {
    return !self.asConstElement().isDisabled();
}

fn getValidity(self: *TextArea, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

fn getValidationMessage(self: *const TextArea) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing()) return "Please fill out this field.";
    if (self.suffersTooLong()) return "Please shorten this text.";
    if (self.suffersTooShort()) return "Please lengthen this text.";
    return "";
}

fn checkValidity(self: *TextArea, frame: *Frame) !bool {
    return ValidityState.checkValidity(self.asElement(), frame);
}

fn reportValidity(self: *TextArea, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

fn setCustomValidity(self: *TextArea, message: []const u8, frame: *Frame) !void {
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

pub fn getRequired(self: *const TextArea) bool {
    return self.asConstElement().getAttributeInterned("required") != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextArea);

    pub const Meta = struct {
        pub const name = "HTMLTextAreaElement";
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
    pub const @"type" = bridge.property("textarea", .{ .template = false, .readonly = true });
    pub const value = bridge.accessor(_getApiValue, TextArea.setValue, .{});
    // _value is already normalized; the default value (text content) may not be.
    fn _getApiValue(self: *const TextArea, frame: *Frame) ![]const u8 {
        if (self._value) |v| {
            return v;
        }
        return normalizeNewlines(self.getDefaultValue(), frame.call_arena);
    }

    pub const textLength = bridge.accessor(struct {
        fn wrap(self: *const TextArea, frame: *Frame) !u32 {
            return @intCast(Node.CData.utf16Len(try _getApiValue(self, frame)));
        }
    }.wrap, null, .{});

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
    pub const setRangeText = bridge.function(TextArea.setRangeText, .{});
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

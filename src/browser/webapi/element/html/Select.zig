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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const Form = @import("Form.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");
pub const Option = @import("Option.zig");

const Select = @This();

_proto: *HtmlElement,
_selected_index_set: bool = false,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

pub fn asElement(self: *Select) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Select) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Select) *Node {
    return self.asElement().asNode();
}
pub fn asConstNode(self: *const Select) *const Node {
    return self.asConstElement().asConstNode();
}

// Resolves the option whose selectedness contributes to the select's value
// per HTML §form-elements§selectedness-setting-algorithm: an explicitly
// selected non-disabled option, falling back to the first non-disabled
// option in tree order. Returns null if there is no candidate (zero options
// or every option disabled), in which case the select has no selectedness
// and contributes no entry to a FormData set.
pub fn effectiveOption(self: *const Select) ?*Option {
    var first_option: ?*Option = null;
    var maybe_child = self.asConstNode().firstChild();
    while (maybe_child) |child| : (maybe_child = child.nextSibling()) {
        const option = child.is(Option) orelse continue;
        if (option.getDisabled()) continue;
        if (option.getSelected()) return option;
        if (first_option == null) first_option = option;
    }
    return first_option;
}

pub fn getValue(self: *Select, frame: *Frame) []const u8 {
    if (self.effectiveOption()) |opt| {
        return opt.getValue(frame);
    }
    return "";
}

pub fn setValue(self: *Select, value: []const u8, frame: *Frame) !void {
    // Find option with matching value and select it
    // Note: This updates the current state (_selected), not the default state (attribute)
    // Setting value always deselects all others, even for multiple selects
    var iter = self.asNode().childrenIterator();
    while (iter.next()) |child| {
        const option = child.is(Option) orelse continue;
        option._selected = std.mem.eql(u8, option.getValue(frame), value);
    }
}

pub fn getSelectedIndex(self: *Select) i32 {
    var index: i32 = 0;
    var has_options = false;
    var iter = self.asNode().childrenIterator();
    while (iter.next()) |child| {
        const option = child.is(Option) orelse continue;
        has_options = true;
        if (option.getSelected()) {
            return index;
        }
        index += 1;
    }
    // If selectedIndex was explicitly set and no option is selected, return -1
    // If selectedIndex was never set, return 0 (first option implicitly selected) if we have options
    if (self._selected_index_set) {
        return -1;
    }
    return if (has_options) 0 else -1;
}

pub fn setSelectedIndex(self: *Select, index: i32) !void {
    // Mark that selectedIndex has been explicitly set
    self._selected_index_set = true;

    // Select option at given index
    // Note: This updates the current state (_selected), not the default state (attribute)
    const is_multiple = self.getMultiple();
    var current_index: i32 = 0;
    var iter = self.asNode().childrenIterator();
    while (iter.next()) |child| {
        const option = child.is(Option) orelse continue;
        if (current_index == index) {
            option._selected = true;
        } else if (!is_multiple) {
            // Only deselect others if not multiple
            option._selected = false;
        }
        current_index += 1;
    }
}

pub fn getMultiple(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("multiple")) != null;
}

pub fn setMultiple(self: *Select, multiple: bool, frame: *Frame) !void {
    if (multiple) {
        try self.asElement().setAttributeSafe(comptime .wrap("multiple"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("multiple"), frame);
    }
}

pub fn getDisabled(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Select, disabled: bool, frame: *Frame) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), frame);
    }
}

pub fn getName(self: *const Select) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Select, name: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), frame);
}

pub fn getSize(self: *const Select) u32 {
    const s = self.asConstElement().getAttributeSafe(comptime .wrap("size")) orelse return 0;

    const trimmed = std.mem.trimLeft(u8, s, &std.ascii.whitespace);

    var end: usize = 0;
    for (trimmed) |b| {
        if (!std.ascii.isDigit(b)) {
            break;
        }
        end += 1;
    }
    if (end == 0) {
        return 0;
    }
    return std.fmt.parseInt(u32, trimmed[0..end], 10) catch 0;
}

pub fn setSize(self: *Select, size: u32, frame: *Frame) !void {
    const size_string = try std.fmt.allocPrint(frame.call_arena, "{d}", .{size});
    try self.asElement().setAttributeSafe(comptime .wrap("size"), .wrap(size_string), frame);
}

pub fn getRequired(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn setRequired(self: *Select, required: bool, frame: *Frame) !void {
    if (required) {
        try self.asElement().setAttributeSafe(comptime .wrap("required"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("required"), frame);
    }
}

pub fn getOptions(self: *Select, frame: *Frame) !*collections.HTMLOptionsCollection {
    // For options, we use the child_tag mode to filter only <option> elements
    const node_live = collections.NodeLive(.child_tag).init(self.asNode(), .option, frame);
    const html_collection = try node_live.runtimeGenericWrap(frame);

    // Create and return HTMLOptionsCollection
    return frame._factory.create(collections.HTMLOptionsCollection{
        ._proto = html_collection,
        ._select = self,
    });
}

pub fn getLength(self: *Select) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Option) != null) {
            i += 1;
        }
    }
    return i;
}

pub fn getSelectedOptions(self: *Select, frame: *Frame) !collections.NodeLive(.selected_options) {
    return collections.NodeLive(.selected_options).init(self.asNode(), {}, frame);
}

pub fn getForm(self: *Select, frame: *Frame) ?*Form {
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

pub fn getLabels(self: *Select, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getWillValidate(self: *const Select) bool {
    return !self.getDisabled();
}

pub fn getValidity(self: *Select, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

pub fn getValidationMessage(self: *const Select) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing()) return "Please select an item in the list.";
    return "";
}

pub fn checkValidity(self: *Select, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    const v = ValidityState{ ._owner = self.asElement() };
    if (v.getValid(frame)) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *Select, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *Select, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Select) bool {
    return self._custom_validity != null;
}

pub fn suffersValueMissing(self: *const Select) bool {
    if (!self.getWillValidate()) return false;
    if (!self.getRequired()) return false;
    // No selectable option ⇒ no value to submit.
    const opt = self.effectiveOption() orelse return true;
    // The selected option's `value` attribute (`opt._value`) is what matters
    // for the missing-value check; an explicit `value=""` is the canonical
    // placeholder pattern. When `value=` is absent the option's text would
    // be submitted, so it is not "missing" in the constraint-validation
    // sense.
    if (opt._value) |v| return v.len == 0;
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Select);

    pub const Meta = struct {
        pub const name = "HTMLSelectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Select.getValue, Select.setValue, .{});
    pub const selectedIndex = bridge.accessor(Select.getSelectedIndex, Select.setSelectedIndex, .{});
    pub const multiple = bridge.accessor(Select.getMultiple, Select.setMultiple, .{ .ce_reactions = true });
    pub const disabled = bridge.accessor(Select.getDisabled, Select.setDisabled, .{ .ce_reactions = true });
    pub const name = bridge.accessor(Select.getName, Select.setName, .{ .ce_reactions = true });
    pub const required = bridge.accessor(Select.getRequired, Select.setRequired, .{ .ce_reactions = true });
    pub const options = bridge.accessor(Select.getOptions, null, .{});
    pub const selectedOptions = bridge.accessor(Select.getSelectedOptions, null, .{});
    pub const form = bridge.accessor(Select.getForm, null, .{});
    pub const size = bridge.accessor(Select.getSize, Select.setSize, .{ .ce_reactions = true });
    pub const length = bridge.accessor(Select.getLength, null, .{});
    pub const labels = bridge.accessor(Select.getLabels, null, .{});
    pub const willValidate = bridge.accessor(Select.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Select.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Select.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(Select.checkValidity, .{});
    pub const reportValidity = bridge.function(Select.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Select.setCustomValidity, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Frame) !void {
        // No initialization needed - disabled is lazy from attribute
    }
};

const std = @import("std");
const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Select" {
    try testing.htmlRunner("element/html/select.html", .{});
    try testing.htmlRunner("element/html/select-validity.html", .{});
}

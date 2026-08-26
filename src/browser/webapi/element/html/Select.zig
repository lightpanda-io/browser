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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
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

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_selected_index_set: bool = false,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,

pub fn asElement(self: *Select) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Select) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Select) *Node {
    return self.asElement().asNode();
}
pub fn asConstNode(self: *const Select) *const Node {
    return self.asConstElement().asConstNode();
}

// Walks the select's list of options in tree order: its option children plus
// the option children of its optgroup children, per HTML
// §the-select-element. Options nested any deeper are not in the list.
const OptionIterator = struct {
    _node: ?*Node,
    _in_group: bool = false,

    fn init(select: *const Select) OptionIterator {
        return .{ ._node = select.asConstNode().firstChild() };
    }

    fn next(self: *OptionIterator) ?*Option {
        while (self._node) |node| {
            if (self._in_group == false and node.is(Element.Html.OptGroup) != null) {
                if (node.firstChild()) |first_child| {
                    self._in_group = true;
                    self._node = first_child;
                    continue;
                }
            }

            self._node = node.nextSibling() orelse blk: {
                if (self._in_group == false) {
                    break :blk null;
                }
                // Exhausted the optgroup, resume after it.
                self._in_group = false;
                const group = node.parentNode() orelse break :blk null;
                break :blk group.nextSibling();
            };

            if (node.is(Option)) |option| {
                return option;
            }
        }
        return null;
    }
};

// Resolves the option whose selectedness contributes to the select's value
// per HTML §form-elements§selectedness-setting-algorithm: an explicitly
// selected non-disabled option, falling back to the first non-disabled
// option in tree order. Returns null if there is no candidate (zero options
// or every option disabled), in which case the select has no selectedness
// and contributes no entry to a FormData set.
pub fn effectiveOption(self: *const Select) ?*Option {
    var first_option: ?*Option = null;
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        // Element.isDisabled, not Option.getDisabled: an option is also
        // disabled when its parent is an <optgroup disabled>
        // (HTML "concept-option-disabled").
        if (option.asElement().isDisabled()) {
            continue;
        }
        if (option.getSelected()) {
            return option;
        }
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
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        option._selected = std.mem.eql(u8, option.getValue(frame), value);
    }
}

pub fn getSelectedIndex(self: *Select) i32 {
    var index: i32 = 0;
    var has_options = false;
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
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
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        if (current_index == index) {
            option._selected = true;
        } else if (!is_multiple) {
            // Only deselect others if not multiple
            option._selected = false;
        }
        current_index += 1;
    }
}

// https://html.spec.whatwg.org/multipage/form-elements.html#dom-select-type
// The `type` IDL attribute reflects the element's mode: "select-multiple" when
// the `multiple` attribute is present, "select-one" otherwise.
pub fn getType(self: *const Select) []const u8 {
    return if (self.getMultiple()) "select-multiple" else "select-one";
}

pub fn getOptions(self: *Select, frame: *Frame) !*collections.HTMLOptionsCollection {
    // select_options mode is the select's list of options: option children
    // plus the option children of optgroup children.
    const node_live = collections.NodeLive(.select_options).init(self.asNode(), {}, frame);
    const options = try frame._factory.chained(.{
        node_live.htmlCollectionValue(),
        collections.HTMLOptionsCollection{
            ._proto = undefined,
            ._select = self,
        },
    });
    options._proto._chained = .options;
    return options;
}

pub fn getLength(self: *Select) u32 {
    var i: u32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |_| {
        i += 1;
    }
    return i;
}

const AddBeforeOption = union(enum) {
    option: *Option,
    index: u32,
};

pub fn add(self: *Select, element: *Option, before_: ?AddBeforeOption, frame: *Frame) !void {
    const self_node = self.asNode();

    var before_node: ?*Node = null;
    if (before_) |before| {
        switch (before) {
            .index => |idx| {
                var i: u32 = 0;
                var it = OptionIterator.init(self);
                while (it.next()) |option| {
                    if (i == idx) {
                        before_node = option.asNode();
                        break;
                    }
                    i += 1;
                }
            },
            .option => |before_option| before_node = before_option.asNode(),
        }
    }
    // Per HTML §dom-select-add, the insertion parent is `before`'s parent —
    // which is the optgroup when `before` sits inside one.
    const parent = if (before_node) |node| node.parentNode() orelse self_node else self_node;
    _ = try parent.insertBefore(element.asElement().asNode(), before_node, frame);
}

pub fn getSelectedOptions(self: *Select, frame: *Frame) !collections.NodeLive(.selected_options) {
    return collections.NodeLive(.selected_options).init(self.asNode(), {}, frame);
}

pub fn getForm(self: *Select, frame: *Frame) ?*Form {
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

pub fn getDisabled(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn getMultiple(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("multiple")) != null;
}

pub fn getRequired(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Select);

    pub const Meta = struct {
        pub const name = "HTMLSelectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Select);

    pub const value = bridge.accessor(Select.getValue, Select.setValue, .{});
    pub const @"type" = bridge.accessor(Select.getType, null, .{});
    pub const selectedIndex = bridge.accessor(Select.getSelectedIndex, Select.setSelectedIndex, .{});
    pub const multiple = reflect.boolean("multiple");
    pub const disabled = reflect.boolean("disabled");
    pub const name = reflect.string("name");
    pub const required = reflect.boolean("required");
    pub const options = bridge.accessor(Select.getOptions, null, .{});
    pub const selectedOptions = bridge.accessor(Select.getSelectedOptions, null, .{});
    pub const form = bridge.accessor(Select.getForm, null, .{});
    pub const size = reflect.unsignedLong("size", .{});
    pub const length = bridge.accessor(Select.getLength, null, .{});
    pub const labels = bridge.accessor(Select.getLabels, null, .{});
    pub const willValidate = bridge.accessor(Select.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Select.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Select.getValidationMessage, null, .{});
    pub const add = bridge.function(Select.add, .{ .ce_reactions = true });
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
    try testing.htmlRunner("element/html/select-optgroup.html", .{});
    try testing.htmlRunner("element/html/select-validity.html", .{});
}

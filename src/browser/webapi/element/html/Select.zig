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

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const collections = @import("../../collections.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const HtmlElement = @import("../Html.zig");
const reflection = @import("../reflection.zig");

const Form = @import("Form.zig");
pub const Option = @import("Option.zig");
const ValidityState = @import("ValidityState.zig");

const String = lp.String;

const Select = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
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

// Called by the Frame for every node, an inserted option has to update its select.
// TODO: if ever we have more of these, we should add inserted/removed Build
// hooks. For this one off, I'm sticking with a direct call from Frame because
// it's easier.
pub fn childInserted(parent: *Node, child: *Node) void {
    if (mayHoldOptions(child) == false) {
        return;
    }
    const pos = listPosition(parent) orelse return;
    var change: ListChange = .{};
    change.add(child, pos.in_optgroup);
    change.processInserted(pos.select);
}

// parser.fragment links every child of a parent at once.
pub fn childrenInserted(parent: *Node) void {
    const pos = listPosition(parent) orelse return;
    var change: ListChange = .{};
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        change.add(child, pos.in_optgroup);
    }
    change.processInserted(pos.select);
}

// Called by the Frame for every node, a removed option has to update its select.
pub fn childRemoved(parent: *Node, child: *Node) void {
    if (mayHoldOptions(child) == false) {
        return;
    }
    const pos = listPosition(parent) orelse return;
    const select = pos.select;
    if (select.isMenuList() == false) {
        return;
    }

    var change: ListChange = .{};
    change.add(child, pos.in_optgroup);
    if (change.last_selected != null or select.selectedOption() == null) {
        select.selectFirstEnabled();
    }
}

// The parser links elements before their children, so this keeps the
// ancestor walk off every node but options.
fn mayHoldOptions(node: *Node) bool {
    return node.is(Option) != null or (node.is(Element) != null and node.firstChild() != null);
}

// Where, in which select's list of options, an option placed under `parent`
// lands: the nearest select ancestor, unless a select, hr, option or datalist
// sits in between, or two optgroups do. HTML §get-the-list-of-options.
pub const ListPosition = struct {
    select: *Select,
    // Under an optgroup already: a second one hides its options.
    in_optgroup: bool,
};

pub fn listPosition(parent: *Node) ?ListPosition {
    var in_optgroup = false;
    var node: ?*Node = parent;
    while (node) |n| : (node = n.parentNode()) {
        if (n.is(Select)) |select| {
            return .{ .select = select, .in_optgroup = in_optgroup };
        }
        in_optgroup = listStep(n, in_optgroup) orelse return null;
    }
    return null;
}

// One ancestor of the walk up from an option: null when it keeps its
// descendants out of the list, else whether an optgroup has been passed.
fn listStep(node: *Node, in_optgroup: bool) ?bool {
    if (node.is(Element.Html.OptGroup) != null) {
        return if (in_optgroup) null else true;
    }
    if (closesList(node)) {
        return null;
    }
    return in_optgroup;
}

// Elements whose descendants are never in a list of options.
fn closesList(node: *Node) bool {
    return node.is(Option) != null or
        node.is(Select) != null or
        node.is(Element.Html.HR) != null or
        node.is(Element.Html.DataList) != null;
}

// The options that nodes linked into, or unlinked from, a select's list of
// options carry.
const ListChange = struct {
    has_enabled: bool = false,
    last_selected: ?*Option = null,

    // `child` sits (or sat) at a position where `in_optgroup` holds. It is
    // already unlinked on removal, so its options are judged from it down.
    fn add(self: *ListChange, child: *Node, in_optgroup: bool) void {
        var tw = TreeWalker.Full.init(child, .{});
        while (tw.next()) |node| {
            if (node.is(Option)) |option| {
                if (node == child or inListBelow(node.parentNode().?, child, in_optgroup)) {
                    self.addOption(option);
                }
            }
            if (closesList(node)) {
                tw.skipChildren();
            }
        }
    }

    // Walks up from `node` to `top`, inclusive.
    fn inListBelow(node: *Node, top: *Node, in_optgroup: bool) bool {
        var state = in_optgroup;
        var n = node;
        while (true) {
            state = listStep(n, state) orelse return false;
            if (n == top) {
                return true;
            }
            n = n.parentNode() orelse return false;
        }
    }

    fn addOption(self: *ListChange, option: *Option) void {
        if (option._selected) {
            self.last_selected = option;
        }
        if (self.has_enabled == false and option.asElement().isDisabled() == false) {
            self.has_enabled = true;
        }
    }

    fn processInserted(self: *const ListChange, select: *const Select) void {
        if (select.getMultiple()) {
            // can have multiple selected, nothing to do
            return;
        }
        if (self.last_selected) |option| {
            // the newcome wins
            select.deselectOthers(option);
        } else if (self.has_enabled) {
            // there's at least 1 enabled option
            select.resetToDefaultSelection();
        }
    }
};

pub fn optionSelectednessChanged(self: *const Select, option: *const Option) void {
    if (option._selected) {
        if (self.getMultiple() == false) {
            self.deselectOthers(option);
        }
    } else {
        // this isn't a multiple, so our only selected option became unselected
        self.resetToDefaultSelection();
    }
}

// Walks the select's list of options in tree order.
const OptionIterator = struct {
    _select: *const Select,
    _tw: TreeWalker.FullExcludeSelf,

    fn init(select: *const Select) OptionIterator {
        // TreeWalker only reads through the root
        return .{ ._select = select, ._tw = .init(@constCast(select.asConstNode()), .{}) };
    }

    fn next(self: *OptionIterator) ?*Option {
        while (self._tw.next()) |node| {
            if (closesList(node)) {
                self._tw.skipChildren();
            }
            const option = node.is(Option) orelse continue;
            if (isInList(self._select, option)) {
                return option;
            }
        }
        return null;
    }
};

fn isInList(select: *const Select, option: *Option) bool {
    const parent = option.asNode().parentNode() orelse return false;
    const pos = listPosition(parent) orelse return false;
    return pos.select == select;
}

fn deselectOthers(self: *const Select, keep: *const Option) void {
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        if (option != keep) option._selected = false;
    }
}

pub fn reset(self: *Select, frame: *Frame) void {
    var last_selected: ?*Option = null;
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        option._selected = option.asElement().hasAttributeInterned("selected");
        if (option._selected) {
            last_selected = option;
        }
    }
    if (self.asElement().hasAttributeInterned("multiple") == false) {
        if (last_selected) |keep| {
            self.deselectOthers(keep);
        }
    }
    self.resetToDefaultSelection();
    frame.domChanged();
}

// HTML's "ask for a reset". Every path that selects an option in a
// non-multiple select deselects the others, so this only has to handle a
// menu list left with nothing selected.
fn resetToDefaultSelection(self: *const Select) void {
    if (self.isMenuList() and self.selectedOption() == null) {
        self.selectFirstEnabled();
    }
}

// For a menu list with nothing selected.
fn selectFirstEnabled(self: *const Select) void {
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        if (option.asElement().isDisabled() == false) {
            option._selected = true;
            return;
        }
    }
}

// A menu list (Blink's UsesMenuList) always shows a selected option when it
// has an enabled one; multiple selects and list boxes have no default.
fn isMenuList(self: *const Select) bool {
    return self.getMultiple() == false and self.displaySize() < 2;
}

// The size attribute, as the size IDL attribute parses it (0 when absent or
// invalid). Whether the select renders as a menu list or a list box hinges on
// this, and with it whether an option can be deselected outright.
fn displaySize(self: *const Select) i64 {
    const value = self.asConstElement().getAttributeSafe(comptime .wrap("size")) orelse return 0;
    const parsed = reflection.parseInteger(value) orelse return 0;
    return @max(parsed, 0);
}

// The first selected option in tree order. Disabled options count: they can be
// selected by script, they just aren't submitted.
fn selectedOption(self: *const Select) ?*Option {
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        if (option._selected) {
            return option;
        }
    }
    return null;
}

pub fn getValue(self: *Select, frame: *Frame) []const u8 {
    const option = self.selectedOption() orelse return "";
    return option.getValue(frame);
}

pub fn setValue(self: *Select, value: []const u8, frame: *Frame) !void {
    // Selects the first matching option only, and none when nothing matches.
    // This updates the current state (_selected), not the default state
    // (attribute).
    var matched = false;
    var it = OptionIterator.init(self);
    while (it.next()) |option| {
        const is_match = matched == false and std.mem.eql(u8, option.getValue(frame), value);
        option._selected = is_match;
        matched = matched or is_match;
    }
    frame.domChanged();
}

/// The position of `option` in the list of options, or null when the option
/// is not in it.
pub fn optionIndex(self: *const Select, option: *const Option) ?u32 {
    var index: u32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |o| : (index += 1) {
        if (o == option) return index;
    }
    return null;
}

pub fn getSelectedIndex(self: *Select) i32 {
    var index: i32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |option| : (index += 1) {
        if (option._selected) {
            return index;
        }
    }
    return -1;
}

pub fn setSelectedIndex(self: *Select, index: i32, frame: *Frame) !void {
    // Every other option is deselected, even in a multiple select, and an
    // out-of-range index leaves none selected.
    var current_index: i32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |option| : (current_index += 1) {
        option._selected = current_index == index;
    }
    frame.domChanged();
}

// https://html.spec.whatwg.org/multipage/form-elements.html#dom-select-type
// The `type` IDL attribute reflects the element's mode: "select-multiple" when
// the `multiple` attribute is present, "select-one" otherwise.
pub fn getType(self: *const Select) []const u8 {
    return if (self.getMultiple()) "select-multiple" else "select-one";
}

fn getOptions(self: *Select, frame: *Frame) !*collections.HTMLOptionsCollection {
    // select_options mode is the select's list of options
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

pub const max_list_items = 100_000;
pub fn setLength(self: *Select, value: u32, frame: *Frame) !void {
    // value > options.len means add blank options
    // value < options.len means remove extra options

    // we'll collect the length AND trim at the same time

    var len: u32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |option| : (len += 1) {
        if (len >= value) {
            // we have to be in trim mode
            option.asElement().remove(frame);
        }
    }
    if (len >= value) {
        return;
    }

    // growing, we append blank options
    if (value > max_list_items) {
        lp.log.debug(.js, "select overflow", .{ .max_list_items = max_list_items, .request = value });
        return;
    }
    const self_node = self.asNode();
    const doc = self_node.ownerDocument(frame).?;
    for (len..value) |_| {
        // yes, one at time, for the correct mutation records
        const blank = try Frame.node_factory.createElementNS(doc, .html, "option", null);
        _ = try self_node.appendChild(blank, frame);
    }
}

// remove() is ChildNode's; remove(index) removes the option at index.
fn remove(self: *Select, index_: ?js.Value, frame: *Frame) !void {
    const value = index_ orelse return self.asElement().remove(frame);
    const index = try value.toI32();

    if (index < 0) {
        return;
    }
    var i: u32 = 0;
    var it = OptionIterator.init(self);
    while (it.next()) |option| : (i += 1) {
        if (i == index) {
            return option.asElement().remove(frame);
        }
    }
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

pub fn getForm(self: *Select) ?*Form {
    return Form.ownerOf(self.asElement());
}

fn getLabels(self: *Select, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

// Constraint validation
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getWillValidate(self: *const Select) bool {
    return !self.asConstElement().isDisabled();
}

fn getValidity(self: *Select, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

fn getValidationMessage(self: *const Select) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing()) return "Please select an item in the list.";
    return "";
}

fn checkValidity(self: *Select, frame: *Frame) !bool {
    return ValidityState.checkValidity(self.asElement(), frame);
}

fn reportValidity(self: *Select, frame: *Frame) !bool {
    return self.checkValidity(frame);
}

fn setCustomValidity(self: *Select, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Select) bool {
    return self._custom_validity != null;
}

// Unlike an input's, a select's rule doesn't ask for a mutable element: a
// disabled one still reports it, it's only barred from validation.
pub fn suffersValueMissing(self: *const Select) bool {
    if (!self.getRequired()) return false;
    // No selected option ⇒ no value to submit.
    const opt = self.selectedOption() orelse return true;
    // The selected option's `value` attribute (`opt._value`) is what matters
    // for the missing-value check; an explicit `value=""` is the canonical
    // placeholder pattern. When `value=` is absent the option's text would
    // be submitted, so it is not "missing" in the constraint-validation
    // sense.
    if (opt._value) |v| return v.len == 0;
    return false;
}

pub fn getMultiple(self: *const Select) bool {
    return self.asConstElement().getAttributeInterned("multiple") != null;
}

pub fn getRequired(self: *const Select) bool {
    return self.asConstElement().getAttributeInterned("required") != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Select);

    pub const Meta = struct {
        pub const name = "HTMLSelectElement";
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
    pub const length = bridge.accessor(Select.getLength, Select.setLength, .{ .ce_reactions = true });
    pub const labels = bridge.accessor(Select.getLabels, null, .{});
    pub const willValidate = bridge.accessor(Select.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Select.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Select.getValidationMessage, null, .{});
    pub const add = bridge.function(Select.add, .{ .ce_reactions = true });
    pub const remove = bridge.function(Select.remove, .{ .ce_reactions = true });
    pub const checkValidity = bridge.function(Select.checkValidity, .{});
    pub const reportValidity = bridge.function(Select.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Select.setCustomValidity, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Frame) !void {
        // No initialization needed - disabled is lazy from attribute
    }

    pub fn attributeChange(element: *Element, name: String, _: String, _: *Frame) !void {
        // Switching between a list box and a menu list asks for a reset.
        if (name.eql(comptime .wrap("size"))) {
            element.as(Select).resetToDefaultSelection();
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { multiple, size }, name.str()) orelse return;
        const self = element.as(Select);
        switch (attribute) {
            // Blink, Gecko and WebKit keep the first selected option; the
            // spec is silent.
            .multiple => if (self.selectedOption()) |option| {
                self.deselectOthers(option);
            } else {
                self.resetToDefaultSelection();
            },
            .size => self.resetToDefaultSelection(),
        }
    }
};

const std = @import("std");
const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Select" {
    try testing.htmlRunner("element/html/select.html", .{});
    try testing.htmlRunner("element/html/select-optgroup.html", .{});
    try testing.htmlRunner("element/html/select-validity.html", .{});
}

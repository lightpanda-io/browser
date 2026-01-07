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
const collections = @import("../../collections.zig");
const Form = @import("Form.zig");
pub const Option = @import("Option.zig");

const Select = @This();

_proto: *HtmlElement,
_selected_index_set: bool = false,

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

pub fn getValue(self: *Select, page: *Page) []const u8 {
    // Return value of first selected option, or first option if none selected
    var first_option: ?*Option = null;
    var iter = self.asNode().childrenIterator();
    while (iter.next()) |child| {
        const option = child.is(Option) orelse continue;
        if (option.getDisabled()) {
            continue;
        }

        if (option.getSelected()) {
            return option.getValue(page);
        }
        if (first_option == null) {
            first_option = option;
        }
    }
    // No explicitly selected option, return first option's value
    if (first_option) |opt| {
        return opt.getValue(page);
    }
    return "";
}

pub fn setValue(self: *Select, value: []const u8, page: *Page) !void {
    // Find option with matching value and select it
    // Note: This updates the current state (_selected), not the default state (attribute)
    // Setting value always deselects all others, even for multiple selects
    var iter = self.asNode().childrenIterator();
    while (iter.next()) |child| {
        const option = child.is(Option) orelse continue;
        option._selected = std.mem.eql(u8, option.getValue(page), value);
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
    return self.asConstElement().getAttributeSafe("multiple") != null;
}

pub fn setMultiple(self: *Select, multiple: bool, page: *Page) !void {
    if (multiple) {
        try self.asElement().setAttributeSafe("multiple", "", page);
    } else {
        try self.asElement().removeAttribute("multiple", page);
    }
}

pub fn getDisabled(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe("disabled") != null;
}

pub fn setDisabled(self: *Select, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe("disabled", "", page);
    } else {
        try self.asElement().removeAttribute("disabled", page);
    }
}

pub fn getName(self: *const Select) []const u8 {
    return self.asConstElement().getAttributeSafe("name") orelse "";
}

pub fn setName(self: *Select, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("name", name, page);
}

pub fn getSize(self: *const Select) u32 {
    const s = self.asConstElement().getAttributeSafe("size") orelse return 0;

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

pub fn setSize(self: *Select, size: u32, page: *Page) !void {
    const size_string = try std.fmt.allocPrint(page.call_arena, "{d}", .{size});
    try self.asElement().setAttributeSafe("size", size_string, page);
}

pub fn getRequired(self: *const Select) bool {
    return self.asConstElement().getAttributeSafe("required") != null;
}

pub fn setRequired(self: *Select, required: bool, page: *Page) !void {
    if (required) {
        try self.asElement().setAttributeSafe("required", "", page);
    } else {
        try self.asElement().removeAttribute("required", page);
    }
}

pub fn getOptions(self: *Select, page: *Page) !*collections.HTMLOptionsCollection {
    // For options, we use the child_tag mode to filter only <option> elements
    const node_live = collections.NodeLive(.child_tag).init(self.asNode(), .option, page);
    const html_collection = try node_live.runtimeGenericWrap(page);

    // Create and return HTMLOptionsCollection
    return page._factory.create(collections.HTMLOptionsCollection{
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

pub fn getSelectedOptions(self: *Select, page: *Page) !collections.NodeLive(.selected_options) {
    return collections.NodeLive(.selected_options).init(self.asNode(), {}, page);
}

pub fn getForm(self: *Select, page: *Page) ?*Form {
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
    pub const bridge = js.Bridge(Select);

    pub const Meta = struct {
        pub const name = "HTMLSelectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Select.getValue, Select.setValue, .{});
    pub const selectedIndex = bridge.accessor(Select.getSelectedIndex, Select.setSelectedIndex, .{});
    pub const multiple = bridge.accessor(Select.getMultiple, Select.setMultiple, .{});
    pub const disabled = bridge.accessor(Select.getDisabled, Select.setDisabled, .{});
    pub const name = bridge.accessor(Select.getName, Select.setName, .{});
    pub const required = bridge.accessor(Select.getRequired, Select.setRequired, .{});
    pub const options = bridge.accessor(Select.getOptions, null, .{});
    pub const selectedOptions = bridge.accessor(Select.getSelectedOptions, null, .{});
    pub const form = bridge.accessor(Select.getForm, null, .{});
    pub const size = bridge.accessor(Select.getSize, Select.setSize, .{});
    pub const length = bridge.accessor(Select.getLength, null, .{});
};

pub const Build = struct {
    pub fn created(_: *Node, _: *Page) !void {
        // No initialization needed - disabled is lazy from attribute
    }
};

const std = @import("std");
const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Select" {
    try testing.htmlRunner("element/html/select.html", .{});
}

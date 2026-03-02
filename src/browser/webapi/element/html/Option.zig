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
const String = @import("../../../../string.zig").String;

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Option = @This();

_proto: *HtmlElement,
_value: ?[]const u8 = null,
_selected: bool = false,
_default_selected: bool = false,
_disabled: bool = false,

pub fn asElement(self: *Option) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Option) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Option) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *Option, page: *Page) []const u8 {
    // If value attribute exists, use that; otherwise use text content (stripped)
    if (self._value) |v| {
        return v;
    }

    const node = self.asNode();
    const text = node.getTextContentAlloc(page.call_arena) catch return "";
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

pub fn setValue(self: *Option, value: []const u8, page: *Page) !void {
    const owned = try page.dupeString(value);
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(owned), page);
    self._value = owned;
}

pub fn getText(self: *const Option) []const u8 {
    const node: *Node = @constCast(self.asConstElement().asConstNode());
    const allocator = std.heap.page_allocator; // TODO: use proper allocator
    return node.getTextContentAlloc(allocator) catch "";
}

pub fn setText(self: *Option, value: []const u8, page: *Page) !void {
    try self.asNode().setTextContent(value, page);
}

pub fn getSelected(self: *const Option) bool {
    return self._selected;
}

pub fn setSelected(self: *Option, selected: bool, page: *Page) !void {
    // TODO: When setting selected=true, may need to unselect other options
    // in the parent <select> if it doesn't have multiple attribute
    self._selected = selected;
    page.domChanged();
}

pub fn getDefaultSelected(self: *const Option) bool {
    return self._default_selected;
}

pub fn getDisabled(self: *const Option) bool {
    return self._disabled;
}

pub fn setDisabled(self: *Option, disabled: bool, page: *Page) !void {
    self._disabled = disabled;
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getName(self: *const Option) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Option, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Option);

    pub const Meta = struct {
        pub const name = "HTMLOptionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Option.getValue, Option.setValue, .{});
    pub const text = bridge.accessor(Option.getText, Option.setText, .{});
    pub const selected = bridge.accessor(Option.getSelected, Option.setSelected, .{});
    pub const defaultSelected = bridge.accessor(Option.getDefaultSelected, null, .{});
    pub const disabled = bridge.accessor(Option.getDisabled, Option.setDisabled, .{});
    pub const name = bridge.accessor(Option.getName, Option.setName, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, _: *Page) !void {
        var self = node.as(Option);
        const element = self.asElement();

        // Check for value attribute
        self._value = element.getAttributeSafe(comptime .wrap("value"));

        // Check for selected attribute
        self._default_selected = element.getAttributeSafe(comptime .wrap("selected")) != null;
        self._selected = self._default_selected;

        // Check for disabled attribute
        self._disabled = element.getAttributeSafe(comptime .wrap("disabled")) != null;
    }

    pub fn attributeChange(element: *Element, name: String, value: String, _: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { value, selected }, name.str()) orelse return;
        const self = element.as(Option);
        switch (attribute) {
            .value => self._value = value.str(),
            .selected => {
                self._default_selected = true;
                self._selected = true;
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { value, selected }, name.str()) orelse return;
        const self = element.as(Option);
        switch (attribute) {
            .value => self._value = null,
            .selected => {
                self._default_selected = false;
                self._selected = false;
            },
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Option" {
    try testing.htmlRunner("element/html/option.html", .{});
}

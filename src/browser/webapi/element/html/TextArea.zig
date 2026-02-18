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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");

const TextArea = @This();

_proto: *HtmlElement,
_value: ?[]const u8 = null,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

_on_selectionchange: ?js.Function.Global = null,

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

fn dispatchSelectionChangeEvent(self: *TextArea, page: *Page) !void {
    const event = try Event.init("selectionchange", .{ .bubbles = true }, page);
    defer if (!event._v8_handoff) event.deinit(false);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn asElement(self: *TextArea) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const TextArea) *const Element {
    return self._proto._proto;
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

pub fn setValue(self: *TextArea, value: []const u8, page: *Page) !void {
    const owned = try page.arena.dupe(u8, value);
    self._value = owned;
}

pub fn getDefaultValue(self: *const TextArea) []const u8 {
    const node = self.asConstNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            return txt.getWholeText();
        }
    }
    return "";
}

pub fn setDefaultValue(self: *TextArea, value: []const u8, page: *Page) !void {
    const owned = try page.dupeString(value);

    const node = self.asNode();
    if (node.firstChild()) |child| {
        if (child.is(Node.CData.Text)) |txt| {
            txt._proto._data = owned;
            return;
        }
    }

    // No text child exists, create one
    const text_node = try page.createTextNode(owned);
    _ = try node.appendChild(text_node, page);
}

pub fn getDisabled(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *TextArea, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getName(self: *const TextArea) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *TextArea, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

pub fn getRequired(self: *const TextArea) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn setRequired(self: *TextArea, required: bool, page: *Page) !void {
    if (required) {
        try self.asElement().setAttributeSafe(comptime .wrap("required"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("required"), page);
    }
}

pub fn select(self: *TextArea, page: *Page) !void {
    const len = if (self._value) |v| @as(u32, @intCast(v.len)) else 0;
    try self.setSelectionRange(0, len, null, page);
    const event = try Event.init("select", .{ .bubbles = true }, page);
    defer if (!event._v8_handoff) event.deinit(false);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

const HowSelected = union(enum) { partial: struct { u32, u32 }, full, none };

fn howSelected(self: *const TextArea) HowSelected {
    const value = self._value orelse return .none;

    if (self._selection_start == self._selection_end) return .none;
    if (self._selection_start == 0 and self._selection_end == value.len) return .full;
    return .{ .partial = .{ self._selection_start, self._selection_end } };
}

pub fn innerInsert(self: *TextArea, str: []const u8, page: *Page) !void {
    const arena = page.arena;

    switch (self.howSelected()) {
        .full => {
            // if the text area is fully selected, replace the content.
            const new_value = try arena.dupe(u8, str);
            try self.setValue(new_value, page);
            self._selection_start = @intCast(new_value.len);
            self._selection_end = @intCast(new_value.len);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(page);
        },
        .partial => |range| {
            // if the text area is partially selected, replace the selected content.
            const current_value = self.getValue();
            const before = current_value[0..range[0]];
            const remaining = current_value[range[1]..];

            const new_value = try std.mem.concat(
                arena,
                u8,
                &.{ before, str, remaining },
            );
            try self.setValue(new_value, page);

            const new_pos = range[0] + str.len;
            self._selection_start = @intCast(new_pos);
            self._selection_end = @intCast(new_pos);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(page);
        },
        .none => {
            // if the text area is not selected, just insert at cursor.
            const current_value = self.getValue();
            const new_value = try std.mem.concat(arena, u8, &.{ current_value, str });
            try self.setValue(new_value, page);
        },
    }
}

pub fn getSelectionDirection(self: *const TextArea) []const u8 {
    return @tagName(self._selection_direction);
}

pub fn getSelectionStart(self: *const TextArea) u32 {
    return self._selection_start;
}

pub fn setSelectionStart(self: *TextArea, value: u32, page: *Page) !void {
    self._selection_start = value;
    try self.dispatchSelectionChangeEvent(page);
}

pub fn getSelectionEnd(self: *const TextArea) u32 {
    return self._selection_end;
}

pub fn setSelectionEnd(self: *TextArea, value: u32, page: *Page) !void {
    self._selection_end = value;
    try self.dispatchSelectionChangeEvent(page);
}

pub fn setSelectionRange(
    self: *TextArea,
    selection_start: u32,
    selection_end: u32,
    selection_dir: ?[]const u8,
    page: *Page,
) !void {
    const direction = blk: {
        if (selection_dir) |sd| {
            break :blk std.meta.stringToEnum(Selection.SelectionDirection, sd) orelse .none;
        } else break :blk .none;
    };

    const value = self._value orelse {
        self._selection_start = 0;
        self._selection_end = 0;
        self._selection_direction = .none;
        return;
    };

    const len_u32: u32 = @intCast(value.len);
    var start: u32 = if (selection_start > len_u32) len_u32 else selection_start;
    const end: u32 = if (selection_end > len_u32) len_u32 else selection_end;

    // If end is less than start, both are equal to end.
    if (end < start) {
        start = end;
    }

    self._selection_direction = direction;
    self._selection_start = start;
    self._selection_end = end;

    try self.dispatchSelectionChangeEvent(page);
}

pub fn getForm(self: *TextArea, page: *Page) ?*Form {
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
    pub const bridge = js.Bridge(TextArea);

    pub const Meta = struct {
        pub const name = "HTMLTextAreaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onselectionchange = bridge.accessor(TextArea.getOnSelectionChange, TextArea.setOnSelectionChange, .{});
    pub const value = bridge.accessor(TextArea.getValue, TextArea.setValue, .{});
    pub const defaultValue = bridge.accessor(TextArea.getDefaultValue, TextArea.setDefaultValue, .{});
    pub const disabled = bridge.accessor(TextArea.getDisabled, TextArea.setDisabled, .{});
    pub const name = bridge.accessor(TextArea.getName, TextArea.setName, .{});
    pub const required = bridge.accessor(TextArea.getRequired, TextArea.setRequired, .{});
    pub const form = bridge.accessor(TextArea.getForm, null, .{});
    pub const select = bridge.function(TextArea.select, .{});

    pub const selectionStart = bridge.accessor(TextArea.getSelectionStart, TextArea.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(TextArea.getSelectionEnd, TextArea.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(TextArea.getSelectionDirection, null, .{});
    pub const setSelectionRange = bridge.function(TextArea.setSelectionRange, .{ .dom_exception = true });
};

pub const Build = struct {
    pub fn cloned(source_element: *Element, cloned_element: *Element, _: *Page) !void {
        const source = source_element.as(TextArea);
        const clone = cloned_element.as(TextArea);
        clone._value = source._value;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TextArea" {
    try testing.htmlRunner("element/html/textarea.html", .{});
}

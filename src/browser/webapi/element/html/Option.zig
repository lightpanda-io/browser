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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Select = @import("Select.zig");

const String = lp.String;

const Option = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_value: ?[]const u8 = null,
_selected: bool = false,
_default_selected: bool = false,

pub fn asElement(self: *Option) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Option) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Option) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *Option, frame: *Frame) []const u8 {
    // If value attribute exists, use that; otherwise use text content (stripped)
    if (self._value) |v| {
        return v;
    }

    const node = self.asNode();
    const text = node.getTextContentAlloc(frame.local_arena) catch return "";
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

pub fn setValue(self: *Option, value: []const u8, frame: *Frame) !void {
    const owned = try frame.dupeString(value);
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(owned), frame);
    self._value = owned;
}

pub fn getText(self: *const Option, frame: *Frame) []const u8 {
    const node: *Node = @constCast(self.asConstElement().asConstNode());
    return node.getTextContentAlloc(frame.call_arena) catch "";
}

pub fn setText(self: *Option, value: []const u8, frame: *Frame) !void {
    try self.asNode().setTextContent(value, frame);
}

pub fn getSelected(self: *const Option) bool {
    return self._selected;
}

pub fn setSelected(self: *Option, selected: bool, frame: *Frame) !void {
    self._selected = selected;
    if (self.ownerSelect()) |select| {
        if (selected) {
            if (!select.getMultiple()) {
                select.deselectOthers(self);
            }
        } else {
            select.resetToDefaultSelection();
        }
    }
    frame.domChanged();
}

/// The <select> this option belongs to, directly or through an <optgroup>.
fn ownerSelect(self: *Option) ?*Select {
    var node = self.asNode().parentNode();
    while (node) |n| : (node = n.parentNode()) {
        if (n.is(Select)) |select| return select;
        if (n.is(Element.Html.OptGroup) == null) return null;
    }
    return null;
}

pub fn getDefaultSelected(self: *const Option) bool {
    return self.asConstElement().hasAttributeSafe(comptime .wrap("selected"));
}

pub fn setDefaultSelected(self: *Option, value: bool, frame: *Frame) !void {
    self._default_selected = value;
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("selected"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("selected"), frame);
    }
}

// https://html.spec.whatwg.org/multipage/form-elements.html#dom-option-label
// On getting, return the `label` content attribute if present (verbatim, even
// when empty), otherwise the value of the `text` IDL attribute. On setting,
// reflect to the `label` content attribute.
pub fn getLabel(self: *const Option, frame: *Frame) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("label")) orelse self.getText(frame);
}

pub fn setLabel(self: *Option, label: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("label"), .wrap(label), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Option);

    pub const Meta = struct {
        pub const name = "HTMLOptionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Option);

    pub const value = bridge.accessor(Option.getValue, Option.setValue, .{ .ce_reactions = true });
    pub const text = bridge.accessor(Option.getText, Option.setText, .{ .ce_reactions = true });
    pub const label = bridge.accessor(Option.getLabel, Option.setLabel, .{ .ce_reactions = true });
    pub const selected = bridge.accessor(Option.getSelected, Option.setSelected, .{});
    pub const defaultSelected = bridge.accessor(Option.getDefaultSelected, Option.setDefaultSelected, .{ .ce_reactions = true });
    pub const disabled = reflect.boolean("disabled");
};

pub const Build = struct {
    pub fn created(node: *Node, _: *Frame) !void {
        var self = node.as(Option);
        const element = self.asElement();

        // Check for value attribute
        self._value = element.getAttributeSafe(comptime .wrap("value"));

        // Check for selected attribute
        self._default_selected = element.getAttributeSafe(comptime .wrap("selected")) != null;
        self._selected = self._default_selected;
    }

    pub fn attributeChange(element: *Element, name: String, _: String, _: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { value, selected }, name.str()) orelse return;
        const self = element.as(Option);
        switch (attribute) {
            // `value` is passed by value; for <= 12 bytes, str() points into our
            // own parameter copy, so we have to re-read the owned bytes.
            .value => self._value = element.getAttributeSafe(comptime .wrap("value")),
            .selected => {
                self._default_selected = true;
                self._selected = true;
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
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

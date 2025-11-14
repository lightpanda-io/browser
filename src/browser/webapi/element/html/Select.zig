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
const Form = @import("Form.zig");
const Option = @import("Option.zig");

const Select = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Select) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Select) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Select) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *Select) []const u8 {
    // Return value of first selected option, or first option if none selected
    var first_option: ?*Option = null;
    var child = self.asNode().firstChild();
    while (child) |c| {
        if (c.is(Element)) |el| {
            switch (el._type) {
                .html => |html_el| {
                    switch (html_el._type) {
                        .option => |opt| {
                            if (first_option == null) {
                                first_option = opt;
                            }
                            if (opt.getSelected()) {
                                return opt.getValue();
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        child = c.nextSibling();
    }
    // No explicitly selected option, return first option's value
    if (first_option) |opt| {
        return opt.getValue();
    }
    return "";
}

pub fn setValue(self: *Select, value: []const u8, page: *Page) !void {
    _ = page;
    // Find option with matching value and select it
    var child = self.asNode().firstChild();
    while (child) |c| {
        if (c.is(Element)) |el| {
            switch (el._type) {
                .html => |html_el| {
                    switch (html_el._type) {
                        .option => |opt| {
                            const opt_value = opt.getValue();
                            if (std.mem.eql(u8, opt_value, value)) {
                                opt._selected = true;
                            } else {
                                opt._selected = false;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        child = c.nextSibling();
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

pub fn getForm(self: *Select, page: *Page) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe("form")) |form_id| {
        if (page.document.getElementById(form_id)) |form_element| {
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
    pub const disabled = bridge.accessor(Select.getDisabled, Select.setDisabled, .{});
    pub const form = bridge.accessor(Select.getForm, null, .{});
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

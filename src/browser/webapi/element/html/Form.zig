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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

pub const Input = @import("Input.zig");
pub const Button = @import("Button.zig");
pub const Select = @import("Select.zig");
pub const TextArea = @import("TextArea.zig");

const Form = @This();
_proto: *HtmlElement,

fn asConstElement(self: *const Form) *const Element {
    return self._proto._proto;
}
pub fn asElement(self: *Form) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Form) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *const Form) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Form, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

pub fn getMethod(self: *const Form) []const u8 {
    const method = self.asConstElement().getAttributeSafe(comptime .wrap("method")) orelse return "get";

    if (std.ascii.eqlIgnoreCase(method, "post")) {
        return "post";
    }
    if (std.ascii.eqlIgnoreCase(method, "dialog")) {
        return "dialog";
    }
    // invalid, or it was get all along
    return "get";
}

pub fn setMethod(self: *Form, method: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("method"), .wrap(method), page);
}

pub fn getElements(self: *Form, page: *Page) !*collections.HTMLFormControlsCollection {
    const form_id = self.asElement().getAttributeSafe(comptime .wrap("id"));
    const root = if (form_id != null)
        self.asNode().getRootNode(null) // Has ID: walk entire document to find form=ID controls
    else
        self.asNode(); // No ID: walk only form subtree (no external controls possible)

    const node_live = collections.NodeLive(.form).init(root, self, page);
    const html_collection = try node_live.runtimeGenericWrap(page);

    return page._factory.create(collections.HTMLFormControlsCollection{
        ._proto = html_collection,
    });
}

pub fn getLength(self: *Form, page: *Page) !u32 {
    const elements = try self.getElements(page);
    return elements.length(page);
}

pub fn submit(self: *Form, page: *Page) !void {
    return page.submitForm(null, self);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Form);
    pub const Meta = struct {
        pub const name = "HTMLFormElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Form.getName, Form.setName, .{});
    pub const method = bridge.accessor(Form.getMethod, Form.setMethod, .{});
    pub const elements = bridge.accessor(Form.getElements, null, .{});
    pub const length = bridge.accessor(Form.getLength, null, .{});
    pub const submit = bridge.function(Form.submit, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Form" {
    try testing.htmlRunner("element/html/form.html", .{});
}

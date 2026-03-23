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

const Page = @import("Page.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");

const Allocator = std.mem.Allocator;

pub const SelectOption = struct {
    value: []const u8,
    text: []const u8,

    pub fn jsonStringify(self: *const SelectOption, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("value");
        try jw.write(self.value);
        try jw.objectField("text");
        try jw.write(self.text);
        try jw.endObject();
    }
};

pub const FormField = struct {
    backendNodeId: ?u32 = null,
    node: *Node,
    tag_name: []const u8,
    name: ?[]const u8,
    input_type: ?[]const u8,
    required: bool,
    value: ?[]const u8,
    placeholder: ?[]const u8,
    options: []const SelectOption,

    pub fn jsonStringify(self: *const FormField, jw: anytype) !void {
        try jw.beginObject();

        if (self.backendNodeId) |id| {
            try jw.objectField("backendNodeId");
            try jw.write(id);
        }

        try jw.objectField("tagName");
        try jw.write(self.tag_name);

        if (self.name) |v| {
            try jw.objectField("name");
            try jw.write(v);
        }

        if (self.input_type) |v| {
            try jw.objectField("inputType");
            try jw.write(v);
        }

        if (self.required) {
            try jw.objectField("required");
            try jw.write(true);
        }

        if (self.value) |v| {
            try jw.objectField("value");
            try jw.write(v);
        }

        if (self.placeholder) |v| {
            try jw.objectField("placeholder");
            try jw.write(v);
        }

        if (self.options.len > 0) {
            try jw.objectField("options");
            try jw.beginArray();
            for (self.options) |opt| {
                try opt.jsonStringify(jw);
            }
            try jw.endArray();
        }

        try jw.endObject();
    }
};

pub const FormInfo = struct {
    backendNodeId: ?u32 = null,
    node: *Node,
    action: ?[]const u8,
    method: ?[]const u8,
    fields: []const FormField,

    pub fn jsonStringify(self: *const FormInfo, jw: anytype) !void {
        try jw.beginObject();

        if (self.backendNodeId) |id| {
            try jw.objectField("backendNodeId");
            try jw.write(id);
        }

        if (self.action) |v| {
            try jw.objectField("action");
            try jw.write(v);
        }

        if (self.method) |v| {
            try jw.objectField("method");
            try jw.write(v);
        }

        try jw.objectField("fields");
        try jw.beginArray();
        for (self.fields) |field| {
            try field.jsonStringify(jw);
        }
        try jw.endArray();

        try jw.endObject();
    }
};

/// Collect all forms and their fields under `root`.
pub fn collectForms(
    root: *Node,
    arena: Allocator,
    page: *Page,
) ![]FormInfo {
    var forms: std.ArrayList(FormInfo) = .empty;

    var tw = TreeWalker.Full.init(root, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (el.getTag() != .form) continue;

        const form_el = el.is(Element.Html.Form) orelse continue;

        const fields = try collectFormFields(node, arena, page);
        if (fields.len == 0) continue;

        const action_attr = el.getAttributeSafe(comptime .wrap("action"));
        const method_str = form_el.getMethod();

        try forms.append(arena, .{
            .node = node,
            .action = if (action_attr) |a| if (a.len > 0) a else null else null,
            .method = if (method_str.len > 0) method_str else null,
            .fields = fields,
        });
    }

    return forms.items;
}

fn collectFormFields(
    form_node: *Node,
    arena: Allocator,
    page: *Page,
) ![]FormField {
    var fields: std.ArrayList(FormField) = .empty;

    var tw = TreeWalker.Full.init(form_node, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;

        switch (el.getTag()) {
            .input => {
                const input = el.is(Element.Html.Input) orelse continue;
                if (input._input_type == .hidden) continue;
                if (input._input_type == .submit or input._input_type == .button or input._input_type == .image) continue;

                try fields.append(arena, .{
                    .node = node,
                    .tag_name = "input",
                    .name = el.getAttributeSafe(comptime .wrap("name")),
                    .input_type = input._input_type.toString(),
                    .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                    .value = input.getValue(),
                    .placeholder = el.getAttributeSafe(comptime .wrap("placeholder")),
                    .options = &.{},
                });
            },
            .textarea => {
                const textarea = el.is(Element.Html.TextArea) orelse continue;

                try fields.append(arena, .{
                    .node = node,
                    .tag_name = "textarea",
                    .name = el.getAttributeSafe(comptime .wrap("name")),
                    .input_type = null,
                    .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                    .value = textarea.getValue(),
                    .placeholder = el.getAttributeSafe(comptime .wrap("placeholder")),
                    .options = &.{},
                });
            },
            .select => {
                const select = el.is(Element.Html.Select) orelse continue;

                const options = try collectSelectOptions(node, arena, page);

                try fields.append(arena, .{
                    .node = node,
                    .tag_name = "select",
                    .name = el.getAttributeSafe(comptime .wrap("name")),
                    .input_type = null,
                    .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                    .value = select.getValue(page),
                    .placeholder = null,
                    .options = options,
                });
            },
            else => {},
        }
    }

    return fields.items;
}

fn collectSelectOptions(
    select_node: *Node,
    arena: Allocator,
    page: *Page,
) ![]SelectOption {
    var options: std.ArrayList(SelectOption) = .empty;
    const Option = Element.Html.Option;

    var tw = TreeWalker.Full.init(select_node, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;
        const option = el.is(Option) orelse continue;

        try options.append(arena, .{
            .value = option.getValue(page),
            .text = option.getText(page),
        });
    }

    return options.items;
}

const testing = @import("../testing.zig");

fn testForms(html: []const u8) ![]FormInfo {
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();

    const doc = page.window._document;
    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    return collectForms(div.asNode(), page.call_arena, page);
}

test "browser.forms: login form" {
    const forms = try testForms(
        \\<form action="/login" method="POST">
        \\  <input type="email" name="email" required placeholder="Email">
        \\  <input type="password" name="password" required>
        \\  <input type="submit" value="Log In">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual("/login", forms[0].action.?);
    try testing.expectEqual("post", forms[0].method.?);
    try testing.expectEqual(2, forms[0].fields.len);
    try testing.expectEqual("email", forms[0].fields[0].name.?);
    try testing.expectEqual("email", forms[0].fields[0].input_type.?);
    try testing.expect(forms[0].fields[0].required);
    try testing.expectEqual("password", forms[0].fields[1].name.?);
}

test "browser.forms: form with select" {
    const forms = try testForms(
        \\<form>
        \\  <select name="color">
        \\    <option value="red">Red</option>
        \\    <option value="blue">Blue</option>
        \\  </select>
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(1, forms[0].fields.len);
    try testing.expectEqual("select", forms[0].fields[0].tag_name);
    try testing.expectEqual(2, forms[0].fields[0].options.len);
    try testing.expectEqual("red", forms[0].fields[0].options[0].value);
    try testing.expectEqual("Red", forms[0].fields[0].options[0].text);
}

test "browser.forms: form with textarea" {
    const forms = try testForms(
        \\<form method="POST">
        \\  <textarea name="message" placeholder="Your message"></textarea>
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(1, forms[0].fields.len);
    try testing.expectEqual("textarea", forms[0].fields[0].tag_name);
    try testing.expectEqual("Your message", forms[0].fields[0].placeholder.?);
}

test "browser.forms: empty form skipped" {
    const forms = try testForms(
        \\<form action="/empty">
        \\  <p>No fields here</p>
        \\</form>
    );
    try testing.expectEqual(0, forms.len);
}

test "browser.forms: hidden inputs excluded" {
    const forms = try testForms(
        \\<form>
        \\  <input type="hidden" name="csrf" value="token123">
        \\  <input type="text" name="username">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(1, forms[0].fields.len);
    try testing.expectEqual("username", forms[0].fields[0].name.?);
}

test "browser.forms: multiple forms" {
    const forms = try testForms(
        \\<form action="/search" method="GET">
        \\  <input type="text" name="q" placeholder="Search">
        \\</form>
        \\<form action="/login" method="POST">
        \\  <input type="email" name="email">
        \\  <input type="password" name="pass">
        \\</form>
    );
    try testing.expectEqual(2, forms.len);
    try testing.expectEqual(1, forms[0].fields.len);
    try testing.expectEqual(2, forms[1].fields.len);
}

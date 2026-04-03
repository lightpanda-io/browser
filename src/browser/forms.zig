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
    disabled: bool,
    value: ?[]const u8,
    placeholder: ?[]const u8,
    options: []SelectOption,

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

        try jw.objectField("required");
        try jw.write(self.required);

        try jw.objectField("disabled");
        try jw.write(self.disabled);

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
    fields: []FormField,

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

/// Populate backendNodeId on each form and its fields by registering
/// their nodes in the given registry. Works with both CDP and MCP registries.
pub fn registerNodes(forms_data: []FormInfo, registry: anytype) !void {
    for (forms_data) |*form| {
        const form_registered = try registry.register(form.node);
        form.backendNodeId = form_registered.id;
        for (form.fields) |*field| {
            const field_registered = try registry.register(field.node);
            field.backendNodeId = field_registered.id;
        }
    }
}

/// Collect all forms and their fields under `root`.
/// Uses Form.getElements() to include fields outside the <form> that
/// reference it via the form="id" attribute, matching browser behavior.
/// `arena` must be an arena allocator — returned slices borrow its memory.
pub fn collectForms(
    arena: Allocator,
    root: *Node,
    page: *Page,
) ![]FormInfo {
    var forms: std.ArrayList(FormInfo) = .empty;

    var tw = TreeWalker.Full.init(root, .{});
    while (tw.next()) |node| {
        const form = node.is(Element.Html.Form) orelse continue;
        const el = form.asElement();

        const fields = try collectFormFields(arena, form, page);
        if (fields.len == 0) continue;

        const action_attr = el.getAttributeSafe(comptime .wrap("action"));
        const method_str = form.getMethod();

        try forms.append(arena, .{
            .node = node,
            .action = if (action_attr) |a| if (a.len > 0) a else null else null,
            .method = method_str,
            .fields = fields,
        });
    }

    return forms.items;
}

fn collectFormFields(
    arena: Allocator,
    form: *Element.Html.Form,
    page: *Page,
) ![]FormField {
    var fields: std.ArrayList(FormField) = .empty;

    var elements = try form.getElements(page);
    var it = try elements.iterator();
    while (it.next()) |el| {
        const node = el.asNode();

        const is_disabled = el.isDisabled();

        if (el.is(Element.Html.Input)) |input| {
            if (input._input_type == .hidden) continue;
            if (input._input_type == .submit or input._input_type == .button or input._input_type == .image) continue;

            try fields.append(arena, .{
                .node = node,
                .tag_name = "input",
                .name = el.getAttributeSafe(comptime .wrap("name")),
                .input_type = input._input_type.toString(),
                .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                .disabled = is_disabled,
                .value = input.getValue(),
                .placeholder = el.getAttributeSafe(comptime .wrap("placeholder")),
                .options = &.{},
            });
            continue;
        }

        if (el.is(Element.Html.TextArea)) |textarea| {
            try fields.append(arena, .{
                .node = node,
                .tag_name = "textarea",
                .name = el.getAttributeSafe(comptime .wrap("name")),
                .input_type = null,
                .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                .disabled = is_disabled,
                .value = textarea.getValue(),
                .placeholder = el.getAttributeSafe(comptime .wrap("placeholder")),
                .options = &.{},
            });
            continue;
        }

        if (el.is(Element.Html.Select)) |select| {
            const options = try collectSelectOptions(arena, node, page);

            try fields.append(arena, .{
                .node = node,
                .tag_name = "select",
                .name = el.getAttributeSafe(comptime .wrap("name")),
                .input_type = null,
                .required = el.getAttributeSafe(comptime .wrap("required")) != null,
                .disabled = is_disabled,
                .value = select.getValue(page),
                .placeholder = null,
                .options = options,
            });
            continue;
        }

        // Button elements from getElements() - skip (not fillable)
    }

    return fields.items;
}

fn collectSelectOptions(
    arena: Allocator,
    select_node: *Node,
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

    const doc = page.window._document;
    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    return collectForms(page.call_arena, div.asNode(), page);
}

test "browser.forms: login form" {
    defer testing.reset();
    defer testing.test_session.removePage();
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
    try testing.expect(!forms[0].fields[0].disabled);
    try testing.expectEqual("password", forms[0].fields[1].name.?);
}

test "browser.forms: form with select" {
    defer testing.reset();
    defer testing.test_session.removePage();
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
    defer testing.reset();
    defer testing.test_session.removePage();
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
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<form action="/empty">
        \\  <p>No fields here</p>
        \\</form>
    );
    try testing.expectEqual(0, forms.len);
}

test "browser.forms: hidden inputs excluded" {
    defer testing.reset();
    defer testing.test_session.removePage();
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
    defer testing.reset();
    defer testing.test_session.removePage();
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

test "browser.forms: disabled fields flagged" {
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<form>
        \\  <input type="text" name="enabled_field">
        \\  <input type="text" name="disabled_field" disabled>
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(2, forms[0].fields.len);
    try testing.expect(!forms[0].fields[0].disabled);
    try testing.expect(forms[0].fields[1].disabled);
}

test "browser.forms: disabled fieldset" {
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<form>
        \\  <fieldset disabled>
        \\    <input type="text" name="in_disabled_fieldset">
        \\  </fieldset>
        \\  <input type="text" name="outside_fieldset">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(2, forms[0].fields.len);
    try testing.expect(forms[0].fields[0].disabled);
    try testing.expect(!forms[0].fields[1].disabled);
}

test "browser.forms: external field via form attribute" {
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<input type="text" name="external" form="myform">
        \\<form id="myform" action="/submit">
        \\  <input type="text" name="internal">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(2, forms[0].fields.len);
}

test "browser.forms: checkbox and radio return value attribute" {
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<form>
        \\  <input type="checkbox" name="agree" value="yes" checked>
        \\  <input type="radio" name="color" value="red">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(2, forms[0].fields.len);
    try testing.expectEqual("checkbox", forms[0].fields[0].input_type.?);
    try testing.expectEqual("yes", forms[0].fields[0].value.?);
    try testing.expectEqual("radio", forms[0].fields[1].input_type.?);
    try testing.expectEqual("red", forms[0].fields[1].value.?);
}

test "browser.forms: form without action or method" {
    defer testing.reset();
    defer testing.test_session.removePage();
    const forms = try testForms(
        \\<form>
        \\  <input type="text" name="q">
        \\</form>
    );
    try testing.expectEqual(1, forms.len);
    try testing.expectEqual(null, forms[0].action);
    try testing.expectEqual("get", forms[0].method.?);
    try testing.expectEqual(1, forms[0].fields.len);
}

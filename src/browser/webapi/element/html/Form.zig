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
const Frame = @import("../../../Frame.zig");

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

pub fn asHtmlElement(self: *Form) *HtmlElement {
    return self._proto;
}
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

pub fn setName(self: *Form, name: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), frame);
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

pub fn setMethod(self: *Form, method: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("method"), .wrap(method), frame);
}

pub fn getElements(self: *Form, frame: *Frame) !*collections.HTMLFormControlsCollection {
    const node_live = self.iterator(frame);
    const html_collection = try node_live.runtimeGenericWrap(frame);

    return frame._factory.create(collections.HTMLFormControlsCollection{
        ._proto = html_collection,
    });
}

pub fn iterator(self: *Form, frame: *Frame) collections.NodeLive(.form) {
    const form_id = self.asElement().getAttributeSafe(comptime .wrap("id"));
    const root = if (form_id != null)
        self.asNode().getRootNode(null) // Has ID: walk entire document to find form=ID controls
    else
        self.asNode(); // No ID: walk only form subtree (no external controls possible)

    return collections.NodeLive(.form).init(root, .{ .form = self, .form_id = form_id }, frame);
}

pub fn getAction(self: *Form, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const action = element.getAttributeSafe(comptime .wrap("action")) orelse return frame.url;
    if (action.len == 0) {
        return frame.url;
    }
    return element.asNode().resolveURL(action, frame, .{});
}

pub fn setAction(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("action"), .wrap(value), frame);
}

pub fn getTarget(self: *Form) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub fn setTarget(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("target"), .wrap(value), frame);
}

pub fn getAcceptCharset(self: *Form) []const u8 {
    return self.asElement().getAttributeSafe(.wrap("accept-charset")) orelse "";
}

pub fn setAcceptCharset(self: *Form, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("accept-charset"), .wrap(value), frame);
}

pub fn getLength(self: *Form, frame: *Frame) !u32 {
    const elements = try self.getElements(frame);
    return elements.length(frame);
}

pub fn submit(self: *Form, frame: *Frame) !void {
    return frame.submitForm(null, self, .{ .fire_event = false });
}

/// https://html.spec.whatwg.org/multipage/forms.html#dom-form-requestsubmit
/// Like submit(), but fires the submit event and validates the form.
pub fn requestSubmit(self: *Form, submitter: ?*Element, frame: *Frame) !void {
    const submitter_element = if (submitter) |s| blk: {
        // The submitter must be a submit button.
        if (!isSubmitButton(s)) return error.TypeError;

        // The submitter's form owner must be this form element.
        const submitter_form = getFormOwner(s, frame);
        if (submitter_form == null or submitter_form.? != self) return error.NotFound;

        break :blk s;
    } else self.asElement();

    return frame.submitForm(submitter_element, self, .{});
}

/// Returns true if the element is a submit button per the HTML spec:
/// - <input type="submit"> or <input type="image">
/// - <button type="submit"> (including default, since button's default type is "submit")
pub fn isSubmitButton(element: *Element) bool {
    if (element.is(Input)) |input| {
        return input._input_type == .submit or input._input_type == .image;
    }
    if (element.is(Button)) |button| {
        return std.mem.eql(u8, button.getType(), "submit");
    }
    return false;
}

/// Returns the form owner of a submittable element (Input or Button).
fn getFormOwner(element: *Element, frame: *Frame) ?*Form {
    if (element.is(Input)) |input| {
        return input.getForm(frame);
    }
    if (element.is(Button)) |button| {
        return button.getForm(frame);
    }
    return null;
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
    pub const action = bridge.accessor(Form.getAction, Form.setAction, .{});
    pub const target = bridge.accessor(Form.getTarget, Form.setTarget, .{});
    pub const acceptCharset = bridge.accessor(Form.getAcceptCharset, Form.setAcceptCharset, .{});
    pub const elements = bridge.accessor(Form.getElements, null, .{});
    pub const length = bridge.accessor(Form.getLength, null, .{});
    pub const submit = bridge.function(Form.submit, .{});
    pub const requestSubmit = bridge.function(Form.requestSubmit, .{ .dom_exception = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Form" {
    try testing.htmlRunner("element/html/form.html", .{});
}

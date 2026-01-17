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
const log = @import("../../../../log.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const CustomElementDefinition = @import("../../CustomElementDefinition.zig");

const Custom = @This();
_proto: *HtmlElement,
_tag_name: String,
_definition: ?*CustomElementDefinition,
_connected_callback_invoked: bool = false,
_disconnected_callback_invoked: bool = false,

pub fn asElement(self: *Custom) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Custom) *Node {
    return self.asElement().asNode();
}

pub fn invokeConnectedCallback(self: *Custom, page: *Page) void {
    // Only invoke if we haven't already called it while connected
    if (self._connected_callback_invoked) {
        return;
    }

    self._connected_callback_invoked = true;
    self._disconnected_callback_invoked = false;
    self.invokeCallback("connectedCallback", .{}, page);
}

pub fn invokeDisconnectedCallback(self: *Custom, page: *Page) void {
    // Only invoke if we haven't already called it while disconnected
    if (self._disconnected_callback_invoked) {
        return;
    }

    self._disconnected_callback_invoked = true;
    self._connected_callback_invoked = false;
    self.invokeCallback("disconnectedCallback", .{}, page);
}

pub fn invokeAttributeChangedCallback(self: *Custom, name: []const u8, old_value: ?[]const u8, new_value: ?[]const u8, page: *Page) void {
    const definition = self._definition orelse return;
    if (!definition.isAttributeObserved(name)) {
        return;
    }
    self.invokeCallback("attributeChangedCallback", .{ name, old_value, new_value }, page);
}

pub fn invokeConnectedCallbackOnElement(comptime from_parser: bool, element: *Element, page: *Page) !void {
    // Autonomous custom element
    if (element.is(Custom)) |custom| {
        // If the element is undefined, check if a definition now exists and upgrade
        if (custom._definition == null) {
            const name = custom._tag_name.str();
            if (page.window._custom_elements._definitions.get(name)) |definition| {
                const CustomElementRegistry = @import("../../CustomElementRegistry.zig");
                CustomElementRegistry.upgradeCustomElement(custom, definition, page) catch {};
                return;
            }
        }

        if (comptime from_parser) {
            // From parser, we know the element is brand new
            custom._connected_callback_invoked = true;
            custom.invokeCallback("connectedCallback", .{}, page);
        } else {
            custom.invokeConnectedCallback(page);
        }
        return;
    }

    // Customized built-in element - check if it actually has a definition first
    const definition = page.getCustomizedBuiltInDefinition(element) orelse return;

    if (comptime from_parser) {
        // From parser, we know the element is brand new, skip the tracking check
        try page._customized_builtin_connected_callback_invoked.put(
            page.arena,
            element,
            {},
        );
    } else {
        // Not from parser, check if we've already invoked while connected
        const gop = try page._customized_builtin_connected_callback_invoked.getOrPut(
            page.arena,
            element,
        );
        if (gop.found_existing) {
            return;
        }
        gop.value_ptr.* = {};
    }

    _ = page._customized_builtin_disconnected_callback_invoked.remove(element);
    invokeCallbackOnElement(element, definition, "connectedCallback", .{}, page);
}

pub fn invokeDisconnectedCallbackOnElement(element: *Element, page: *Page) void {
    // Autonomous custom element
    if (element.is(Custom)) |custom| {
        custom.invokeDisconnectedCallback(page);
        return;
    }

    // Customized built-in element - check if it actually has a definition first
    const definition = page.getCustomizedBuiltInDefinition(element) orelse return;

    // Check if we've already invoked disconnectedCallback while disconnected
    const gop = page._customized_builtin_disconnected_callback_invoked.getOrPut(
        page.arena,
        element,
    ) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = {};

    _ = page._customized_builtin_connected_callback_invoked.remove(element);

    invokeCallbackOnElement(element, definition, "disconnectedCallback", .{}, page);
}

pub fn invokeAttributeChangedCallbackOnElement(element: *Element, name: []const u8, old_value: ?[]const u8, new_value: ?[]const u8, page: *Page) void {
    // Autonomous custom element
    if (element.is(Custom)) |custom| {
        custom.invokeAttributeChangedCallback(name, old_value, new_value, page);
        return;
    }

    // Customized built-in element - check if attribute is observed
    const definition = page.getCustomizedBuiltInDefinition(element) orelse return;
    if (!definition.isAttributeObserved(name)) return;
    invokeCallbackOnElement(element, definition, "attributeChangedCallback", .{ name, old_value, new_value }, page);
}

fn invokeCallbackOnElement(element: *Element, definition: *CustomElementDefinition, comptime callback_name: [:0]const u8, args: anytype, page: *Page) void {
    _ = definition;

    const ctx = page.js;

    // Get the JS element object
    const js_val = ctx.zigValueToJs(element, .{}) catch return;
    const js_element = js_val.toObject();

    // Call the callback method if it exists
    js_element.callMethod(void, callback_name, args) catch return;
}

// Check if element has "is" attribute and attach customized built-in definition
pub fn checkAndAttachBuiltIn(element: *Element, page: *Page) !void {
    const is_value = element.getAttributeSafe("is") orelse return;

    const custom_elements = page.window.getCustomElements();
    const definition = custom_elements._definitions.get(is_value) orelse return;

    const extends_tag = definition.extends orelse return;
    if (extends_tag != element.getTag()) {
        return;
    }

    // Attach the definition
    try page.setCustomizedBuiltInDefinition(element, definition);

    // Reset callback flags since this is a fresh upgrade
    _ = page._customized_builtin_connected_callback_invoked.remove(element);
    _ = page._customized_builtin_disconnected_callback_invoked.remove(element);

    // Invoke constructor
    const prev_upgrading = page._upgrading_element;
    const node = element.asNode();
    page._upgrading_element = node;
    defer page._upgrading_element = prev_upgrading;

    var caught: js.TryCatch.Caught = undefined;
    _ = definition.constructor.local().newInstance(&caught) catch |err| {
        log.warn(.js, "custom builtin ctor", .{ .name = is_value, .err = err, .caught = caught });
        return;
    };
}

fn invokeCallback(self: *Custom, comptime callback_name: [:0]const u8, args: anytype, page: *Page) void {
    if (self._definition == null) {
        return;
    }

    const ctx = page.js;

    const js_val = ctx.zigValueToJs(self, .{}) catch return;
    const js_element = js_val.toObject();

    js_element.callMethod(void, callback_name, args) catch return;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Custom);

    pub const Meta = struct {
        pub const name = "TODO-CUSTOM-NAME";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

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
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Custom = @import("element/html/Custom.zig");
const CustomElementDefinition = @import("CustomElementDefinition.zig");

const CustomElementRegistry = @This();

_definitions: std.StringHashMapUnmanaged(*CustomElementDefinition) = .{},
_when_defined: std.StringHashMapUnmanaged(js.PromiseResolver) = .{},

const DefineOptions = struct {
    extends: ?[]const u8 = null,
};

pub fn define(self: *CustomElementRegistry, name: []const u8, constructor: js.Function, options_: ?DefineOptions, page: *Page) !void {
    const options = options_ orelse DefineOptions{};

    try validateName(name);

    // Parse and validate extends option
    const extends_tag: ?Element.Tag = if (options.extends) |extends_name| blk: {
        const tag = std.meta.stringToEnum(Element.Tag, extends_name) orelse return error.NotSupported;

        // Can't extend custom elements
        if (tag == .custom) {
            return error.NotSupported;
        }

        break :blk tag;
    } else null;

    const gop = try self._definitions.getOrPut(page.arena, name);
    if (gop.found_existing) {
        // Yes, this is the correct error to return when trying to redefine a name
        return error.NotSupported;
    }

    const owned_name = try page.dupeString(name);

    const definition = try page._factory.create(CustomElementDefinition{
        .name = owned_name,
        .constructor = try constructor.persist(),
        .extends = extends_tag,
    });

    // Read observedAttributes static property from constructor
    if (constructor.getPropertyValue("observedAttributes") catch null) |observed_attrs| {
        if (observed_attrs.isArray()) {
            var js_arr = observed_attrs.toArray();
            for (0..js_arr.len()) |i| {
                const attr_val = js_arr.get(@intCast(i)) catch continue;
                const attr_name = attr_val.toString(.{ .allocator = page.arena }) catch continue;
                const owned_attr = page.dupeString(attr_name) catch continue;
                definition.observed_attributes.put(page.arena, owned_attr, {}) catch continue;
            }
        }
    }

    gop.key_ptr.* = owned_name;
    gop.value_ptr.* = definition;

    // Upgrade any undefined custom elements with this name
    var idx: usize = 0;
    while (idx < page._undefined_custom_elements.items.len) {
        const custom = page._undefined_custom_elements.items[idx];
        if (!custom._tag_name.eqlSlice(name)) {
            idx += 1;
            continue;
        }

        if (!custom.asElement().asNode().isConnected()) {
            idx += 1;
            continue;
        }

        upgradeCustomElement(custom, definition, page) catch {
            _ = page._undefined_custom_elements.swapRemove(idx);
            continue;
        };

        _ = page._undefined_custom_elements.swapRemove(idx);
    }

    if (self._when_defined.fetchRemove(name)) |entry| {
        entry.value.resolve("whenDefined", constructor);
    }
}

pub fn get(self: *CustomElementRegistry, name: []const u8) ?js.Function.Global {
    const definition = self._definitions.get(name) orelse return null;
    return definition.constructor;
}

pub fn upgrade(self: *CustomElementRegistry, root: *Node, page: *Page) !void {
    try upgradeNode(self, root, page);
}

pub fn whenDefined(self: *CustomElementRegistry, name: []const u8, page: *Page) !js.Promise {
    if (self._definitions.get(name)) |definition| {
        return page.js.resolvePromise(definition.constructor);
    }

    const gop = try self._when_defined.getOrPut(page.arena, name);
    if (gop.found_existing) {
        return gop.value_ptr.promise();
    }
    errdefer _ = self._when_defined.remove(name);
    const owned_name = try page.dupeString(name);

    const resolver = try page.js.createPromiseResolver().persist();
    gop.key_ptr.* = owned_name;
    gop.value_ptr.* = resolver;

    return resolver.promise();
}

fn upgradeNode(self: *CustomElementRegistry, node: *Node, page: *Page) !void {
    if (node.is(Element)) |element| {
        try upgradeElement(self, element, page);
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try upgradeNode(self, child, page);
    }
}

fn upgradeElement(self: *CustomElementRegistry, element: *Element, page: *Page) !void {
    const custom = element.is(Custom) orelse {
        return Custom.checkAndAttachBuiltIn(element, page);
    };

    if (custom._definition != null) return;

    const name = custom._tag_name.str();
    const definition = self._definitions.get(name) orelse return;

    try upgradeCustomElement(custom, definition, page);
}

pub fn upgradeCustomElement(custom: *Custom, definition: *CustomElementDefinition, page: *Page) !void {
    custom._definition = definition;

    // Reset callback flags since this is a fresh upgrade
    custom._connected_callback_invoked = false;
    custom._disconnected_callback_invoked = false;

    const node = custom.asNode();
    const prev_upgrading = page._upgrading_element;
    page._upgrading_element = node;
    defer page._upgrading_element = prev_upgrading;

    var caught: js.TryCatch.Caught = undefined;
    _ = definition.constructor.local().newInstance(&caught) catch |err| {
        log.warn(.js, "custom element upgrade", .{ .name = definition.name, .err = err, .caught = caught });
        return error.CustomElementUpgradeFailed;
    };

    // Invoke attributeChangedCallback for existing observed attributes
    var attr_it = custom.asElement().attributeIterator();
    while (attr_it.next()) |attr| {
        const name = attr._name.str();
        if (definition.isAttributeObserved(name)) {
            custom.invokeAttributeChangedCallback(name, null, attr._value.str(), page);
        }
    }

    if (node.isConnected()) {
        custom.invokeConnectedCallback(page);
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) {
        return error.InvalidCustomElementName;
    }

    if (std.mem.indexOf(u8, name, "-") == null) {
        return error.InvalidCustomElementName;
    }

    if (name[0] < 'a' or name[0] > 'z') {
        return error.InvalidCustomElementName;
    }

    const reserved_names = [_][]const u8{
        "annotation-xml",
        "color-profile",
        "font-face",
        "font-face-src",
        "font-face-uri",
        "font-face-format",
        "font-face-name",
        "missing-glyph",
    };

    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) {
            return error.InvalidCustomElementName;
        }
    }

    for (name) |c| {
        const valid = (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-';
        if (!valid) {
            return error.InvalidCustomElementName;
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomElementRegistry);

    pub const Meta = struct {
        pub const name = "CustomElementRegistry";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const define = bridge.function(CustomElementRegistry.define, .{ .dom_exception = true });
    pub const get = bridge.function(CustomElementRegistry.get, .{ .null_as_undefined = true });
    pub const upgrade = bridge.function(CustomElementRegistry.upgrade, .{});
    pub const whenDefined = bridge.function(CustomElementRegistry.whenDefined, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: CustomElementRegistry" {
    try testing.htmlRunner("custom_elements", .{});
}

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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Custom = @import("element/html/Custom.zig");
const CustomElementDefinition = @import("CustomElementDefinition.zig");

const log = lp.log;

const CustomElementRegistry = @This();

_definitions: std.StringHashMapUnmanaged(*CustomElementDefinition) = .{},
_when_defined: std.StringHashMapUnmanaged(js.PromiseResolver.Global) = .{},

const DefineOptions = struct {
    extends: ?[]const u8 = null,
};

pub fn define(self: *CustomElementRegistry, name: []const u8, constructor: js.Function, options_: ?DefineOptions, frame: *Frame) !void {
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

    const gop = try self._definitions.getOrPut(frame.arena, name);
    if (gop.found_existing) {
        // Yes, this is the correct error to return when trying to redefine a name
        return error.NotSupported;
    }

    const owned_name = try frame.dupeString(name);

    const definition = try frame._factory.create(CustomElementDefinition{
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
                const attr_name = attr_val.toStringSliceWithAlloc(frame.arena) catch continue;
                definition.observed_attributes.put(frame.arena, attr_name, {}) catch continue;
            }
        }
    }

    gop.key_ptr.* = owned_name;
    gop.value_ptr.* = definition;

    // Upgrade any undefined custom elements with this name
    var idx: usize = 0;
    while (idx < frame._undefined_custom_elements.items.len) {
        const custom = frame._undefined_custom_elements.items[idx];
        if (!custom._tag_name.eqlSlice(name)) {
            idx += 1;
            continue;
        }

        if (!custom.asElement().asNode().isConnected()) {
            idx += 1;
            continue;
        }

        upgradeCustomElement(custom, definition, frame) catch {
            _ = frame._undefined_custom_elements.swapRemove(idx);
            continue;
        };

        _ = frame._undefined_custom_elements.swapRemove(idx);
    }

    if (self._when_defined.fetchRemove(name)) |entry| {
        frame.js.toLocal(entry.value).resolve("whenDefined", constructor);
    }
}

pub fn get(self: *CustomElementRegistry, name: []const u8) ?js.Function.Global {
    const definition = self._definitions.get(name) orelse return null;
    return definition.constructor;
}

pub fn upgrade(self: *CustomElementRegistry, root: *Node, frame: *Frame) !void {
    try upgradeNode(self, root, frame);
}

pub fn whenDefined(self: *CustomElementRegistry, name: []const u8, frame: *Frame) !js.Promise {
    const local = frame.js.local.?;
    if (self._definitions.get(name)) |definition| {
        return local.resolvePromise(definition.constructor);
    }

    validateName(name) catch |err| switch (err) {
        error.SyntaxError => return local.rejectPromise(.{ .dom_exception = .{ .err = error.SyntaxError } }),
    };

    const gop = try self._when_defined.getOrPut(frame.arena, name);
    if (gop.found_existing) {
        return local.toLocal(gop.value_ptr.*).promise();
    }
    errdefer _ = self._when_defined.remove(name);
    const owned_name = try frame.dupeString(name);

    const resolver = local.createPromiseResolver();
    gop.key_ptr.* = owned_name;
    gop.value_ptr.* = try resolver.persist();

    return resolver.promise();
}

fn upgradeNode(self: *CustomElementRegistry, node: *Node, frame: *Frame) !void {
    if (node.is(Element)) |element| {
        try upgradeElement(self, element, frame);
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try upgradeNode(self, child, frame);
    }
}

fn upgradeElement(self: *CustomElementRegistry, element: *Element, frame: *Frame) !void {
    const custom = element.is(Custom) orelse {
        return Custom.checkAndAttachBuiltIn(element, frame);
    };

    if (custom._definition != null) return;

    const name = custom._tag_name.str();
    const definition = self._definitions.get(name) orelse return;

    try upgradeCustomElement(custom, definition, frame);
}

pub fn upgradeCustomElement(custom: *Custom, definition: *CustomElementDefinition, frame: *Frame) !void {
    custom._definition = definition;

    // Reset callback flags since this is a fresh upgrade
    custom._connected_callback_invoked = false;
    custom._disconnected_callback_invoked = false;

    const node = custom.asNode();
    const prev_upgrading = frame._upgrading_element;
    frame._upgrading_element = node;
    defer frame._upgrading_element = prev_upgrading;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var caught: js.TryCatch.Caught = undefined;
    _ = ls.toLocal(definition.constructor).newInstance(&caught) catch |err| {
        log.warn(.js, "custom element upgrade", .{ .name = definition.name, .err = err, .caught = caught });
        return error.CustomElementUpgradeFailed;
    };

    // Invoke attributeChangedCallback for existing observed attributes
    var attr_it = custom.asElement().attributeIterator();
    while (attr_it.next()) |attr| {
        const name = attr._name;
        if (definition.isAttributeObserved(name)) {
            custom.invokeAttributeChangedCallback(name, null, attr._value, null, frame);
        }
    }

    if (node.isConnected()) {
        custom.invokeConnectedCallback(frame);
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) {
        return error.SyntaxError;
    }

    if (std.mem.indexOf(u8, name, "-") == null) {
        return error.SyntaxError;
    }

    if (name[0] < 'a' or name[0] > 'z') {
        return error.SyntaxError;
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
            return error.SyntaxError;
        }
    }

    for (name) |c| {
        if (c >= 'A' and c <= 'Z') {
            return error.SyntaxError;
        }

        // Reject control characters and specific invalid characters
        // per elementLocalNameRegex: [^\0\t\n\f\r\u0020/>]*
        switch (c) {
            0, '\t', '\n', '\r', 0x0C, ' ', '/', '>' => return error.SyntaxError,
            else => {},
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
    pub const whenDefined = bridge.function(CustomElementRegistry.whenDefined, .{ .dom_exception = true });
};

const testing = @import("../../testing.zig");
test "WebApi: CustomElementRegistry" {
    try testing.htmlRunner("custom_elements", .{});
}

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
const Element = @import("Element.zig");
const CustomElementDefinition = @import("CustomElementDefinition.zig");

const CustomElementRegistry = @This();

_definitions: std.StringHashMapUnmanaged(*CustomElementDefinition) = .{},

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
        return error.AlreadyDefined;
    }

    const owned_name = try page.dupeString(name);

    const definition = try page._factory.create(CustomElementDefinition{
        .name = owned_name,
        .constructor = constructor,
        .extends = extends_tag,
    });

    // Read observedAttributes static property from constructor
    if (constructor.getPropertyValue("observedAttributes") catch null) |observed_attrs| {
        if (observed_attrs.isArray()) {
            const len = observed_attrs.arrayLength();
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const attr_val = observed_attrs.arrayGet(i) catch continue;
                const attr_name = attr_val.toString(page.arena) catch continue;
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

        custom._definition = definition;

        const node = custom.asNode();
        const prev_upgrading = page._upgrading_element;
        page._upgrading_element = node;
        defer page._upgrading_element = prev_upgrading;

        var result: js.Function.Result = undefined;
        _ = definition.constructor.newInstance(&result) catch |err| {
            log.warn(.js, "custom element upgrade", .{ .name = name, .err = err });
            _ = page._undefined_custom_elements.swapRemove(idx);
            continue;
        };

        if (node.isConnected()) {
            custom.invokeConnectedCallback(page);
        }

        _ = page._undefined_custom_elements.swapRemove(idx);
    }
}

pub fn get(self: *CustomElementRegistry, name: []const u8) ?js.Function {
    const definition = self._definitions.get(name) orelse return null;
    return definition.constructor;
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
};

const testing = @import("../../testing.zig");
test "WebApi: CustomElementRegistry" {
    try testing.htmlRunner("custom_elements", .{});
}

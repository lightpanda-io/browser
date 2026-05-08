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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const HtmlElement = @import("../Html.zig");
const CustomElementDefinition = @import("../../CustomElementDefinition.zig");
const Reaction = @import("../../../CustomElementReactions.zig").Reaction;

const log = lp.log;
const String = lp.String;

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

// Reactions are queued via enqueue* and fired via fireReaction at the outer
// CEReactions boundary (set up by the JS bridge, the parser pump, etc.).
//
// Dedup happens at enqueue time: the connected/disconnected flags flip when
// we queue a reaction so that a redundant enqueue (already-in-this-state)
// is dropped, and a remove+re-insert in the same scope queues both reactions
// in order. Fire-time is unconditional.

pub fn enqueueConnectedCallbackOnElement(comptime from_parser: bool, element: *Element, frame: *Frame) error{OutOfMemory}!void {
    // Autonomous custom element
    if (element.is(Custom)) |custom| {
        // Upgrade if a definition exists but isn't yet attached
        if (custom._definition == null) {
            const name = custom._tag_name.str();
            if (frame.window._custom_elements._definitions.get(name)) |definition| {
                const CustomElementRegistry = @import("../../CustomElementRegistry.zig");
                CustomElementRegistry.upgradeCustomElement(custom, definition, frame) catch {};
                return;
            }
            // Element is undefined and no definition exists yet — nothing to queue.
            return;
        }

        // Dedup: skip if already queued/fired while connected.
        if (custom._connected_callback_invoked) return;
        custom._connected_callback_invoked = true;
        custom._disconnected_callback_invoked = false;
        try frame._ce_reactions.enqueueConnected(element);
        return;
    }

    // Customized built-in element - check if it actually has a definition first
    if (frame.getCustomizedBuiltInDefinition(element) == null) {
        return;
    }

    if (comptime from_parser) {
        // From parser, we know the element is brand new; skip the dedup check.
        try frame._customized_builtin_connected_callback_invoked.put(
            frame.arena,
            element,
            {},
        );
    } else {
        const gop = try frame._customized_builtin_connected_callback_invoked.getOrPut(
            frame.arena,
            element,
        );
        if (gop.found_existing) {
            return;
        }
        gop.value_ptr.* = {};
    }

    _ = frame._customized_builtin_disconnected_callback_invoked.remove(element);
    try frame._ce_reactions.enqueueConnected(element);
}

pub fn enqueueDisconnectedCallbackOnElement(element: *Element, frame: *Frame) void {
    if (element.is(Custom)) |custom| {
        if (custom._definition == null) return;
        if (custom._disconnected_callback_invoked) return;
        custom._disconnected_callback_invoked = true;
        custom._connected_callback_invoked = false;
        frame._ce_reactions.enqueueDisconnected(element) catch |err| {
            log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
        };
        return;
    }

    if (frame.getCustomizedBuiltInDefinition(element) == null) {
        return;
    }

    const gop = frame._customized_builtin_disconnected_callback_invoked.getOrPut(
        frame.arena,
        element,
    ) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = {};
    _ = frame._customized_builtin_connected_callback_invoked.remove(element);

    frame._ce_reactions.enqueueDisconnected(element) catch |err| {
        log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
    };
}

pub fn enqueueAdoptedCallbackOnElement(element: *Element, old_document: *Document, new_document: *Document, frame: *Frame) void {
    if (element.is(Custom)) |custom| {
        if (custom._definition == null) return;
    } else {
        if (frame.getCustomizedBuiltInDefinition(element) == null) return;
    }
    frame._ce_reactions.enqueueAdopted(element, old_document, new_document) catch |err| {
        log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
    };
}

pub fn enqueueAttributeChangedCallbackOnElement(element: *Element, name: String, old_value: ?String, new_value: ?String, namespace: ?String, frame: *Frame) void {
    if (element.is(Custom)) |custom| {
        const definition = custom._definition orelse return;
        if (!definition.isAttributeObserved(name)) return;
    } else {
        const definition = frame.getCustomizedBuiltInDefinition(element) orelse return;
        if (!definition.isAttributeObserved(name)) return;
    }
    frame._ce_reactions.enqueueAttributeChanged(element, name, old_value, new_value, namespace) catch |err| {
        log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
    };
}

// Called by CustomElementReactions.popAndInvoke for each queued reaction.
// Filtering already happened at enqueue time, so just fire unconditionally.
pub fn fireReaction(reaction: Reaction, frame: *Frame) void {
    switch (reaction) {
        .connected => |el| {
            if (el.is(Custom)) |custom| {
                custom.invokeCallback("connectedCallback", .{}, frame);
            } else if (frame.getCustomizedBuiltInDefinition(el)) |definition| {
                invokeCallbackOnElement(el, definition, "connectedCallback", .{}, frame);
            }
        },
        .disconnected => |el| {
            if (el.is(Custom)) |custom| {
                custom.invokeCallback("disconnectedCallback", .{}, frame);
            } else if (frame.getCustomizedBuiltInDefinition(el)) |definition| {
                invokeCallbackOnElement(el, definition, "disconnectedCallback", .{}, frame);
            }
        },
        .adopted => |a| {
            if (a.element.is(Custom)) |custom| {
                custom.invokeCallback("adoptedCallback", .{ a.old_document, a.new_document }, frame);
            } else if (frame.getCustomizedBuiltInDefinition(a.element)) |definition| {
                invokeCallbackOnElement(a.element, definition, "adoptedCallback", .{ a.old_document, a.new_document }, frame);
            }
        },
        .attribute_changed => |a| {
            if (a.element.is(Custom)) |custom| {
                custom.invokeCallback("attributeChangedCallback", .{ a.name, a.old_value, a.new_value, a.namespace }, frame);
            } else if (frame.getCustomizedBuiltInDefinition(a.element)) |definition| {
                invokeCallbackOnElement(a.element, definition, "attributeChangedCallback", .{ a.name, a.old_value, a.new_value, a.namespace }, frame);
            }
        },
    }
}

fn invokeCallbackOnElement(element: *Element, definition: *CustomElementDefinition, comptime callback_name: [:0]const u8, args: anytype, frame: *Frame) void {
    _ = definition;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // Get the JS element object
    const js_val = ls.local.zigValueToJs(element, .{}) catch return;
    const js_element = js_val.toObject();

    // Call the callback method if it exists
    js_element.callMethod(void, callback_name, args) catch return;
}

// Check if element has "is" attribute and attach customized built-in definition
pub fn checkAndAttachBuiltIn(element: *Element, frame: *Frame) !void {
    const is_value = element.getAttributeSafe(comptime .wrap("is")) orelse return;

    const custom_elements = frame.window.getCustomElements();
    const definition = custom_elements._definitions.get(is_value) orelse return;

    const extends_tag = definition.extends orelse return;
    if (extends_tag != element.getTag()) {
        return;
    }

    // Attach the definition
    try frame.setCustomizedBuiltInDefinition(element, definition);

    // Reset callback flags since this is a fresh upgrade
    _ = frame._customized_builtin_connected_callback_invoked.remove(element);
    _ = frame._customized_builtin_disconnected_callback_invoked.remove(element);

    // Invoke constructor
    const prev_upgrading = frame._upgrading_element;
    const node = element.asNode();
    frame._upgrading_element = node;
    defer frame._upgrading_element = prev_upgrading;

    // PERFORMANCE OPTIMIZATION: This pattern is discouraged in general code.
    // Used here because: (1) multiple early returns before needing Local,
    // (2) called from both V8 callbacks (Local exists) and parser (no Local).
    // Prefer either: requiring *const js.Local parameter, OR always creating
    // Local.Scope upfront.
    var ls: ?js.Local.Scope = null;
    var local = blk: {
        if (frame.js.local) |l| {
            break :blk l;
        }
        ls = undefined;
        frame.js.localScope(&ls.?);
        break :blk &ls.?.local;
    };
    defer if (ls) |*_ls| {
        _ls.deinit();
    };

    var caught: js.TryCatch.Caught = undefined;
    _ = local.toLocal(definition.constructor).newInstance(&caught) catch |err| {
        log.warn(.js, "custom builtin ctor", .{ .name = is_value, .err = err, .caught = caught });
        return;
    };
}

fn invokeCallback(self: *Custom, comptime callback_name: [:0]const u8, args: anytype, frame: *Frame) void {
    if (self._definition == null) {
        return;
    }

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const js_val = ls.local.zigValueToJs(self, .{}) catch return;
    const js_element = js_val.toObject();

    js_element.callMethod(void, callback_name, args) catch return;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Custom);

    pub const Meta = struct {
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

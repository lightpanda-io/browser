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
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Reaction = @import("../../../CustomElementReactions.zig").Reaction;

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Document = @import("../../Document.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const CustomElementDefinition = @import("../../CustomElementDefinition.zig");

const HtmlElement = @import("../Html.zig");

const log = lp.log;
const String = lp.String;

const Custom = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_tag_name: String,
_definition: ?*CustomElementDefinition,
_connected_callback_invoked: bool = false,
_disconnected_callback_invoked: bool = false,
_upgrade_failed: bool = false, // a failed upgrade is never retried

pub fn asElement(self: *Custom) *Element {
    return Factory.protoOf(self).asElement();
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
            if (custom._upgrade_failed) {
                return;
            }

            {
                // a document without a browsing context (DOMParser et al.) has
                // no custom element.
                const document = element.asNode().ownerDocument(frame) orelse return;
                if (document._frame == null) {
                    return;
                }
            }

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
        try frame._ce_reactions.enqueueConnected(frame, element);
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
    try frame._ce_reactions.enqueueConnected(frame, element);
}

pub fn enqueueDisconnectedCallbackOnElement(element: *Element, frame: *Frame) void {
    if (element.is(Custom)) |custom| {
        if (custom._definition == null) return;
        if (custom._disconnected_callback_invoked) return;
        custom._disconnected_callback_invoked = true;
        custom._connected_callback_invoked = false;
        frame._ce_reactions.enqueueDisconnected(frame, element) catch |err| {
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

    frame._ce_reactions.enqueueDisconnected(frame, element) catch |err| {
        log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
    };
}

// Enqueues an atomic-move reaction (moveBefore). Unlike connect/disconnect there
// is no dedup state to flip: a move always fires, and the element's connected
// state is unchanged by the move. The element's shadow tree (if any) always
// moves with it.
pub fn enqueueMoveCallbackOnElement(element: *Element, frame: *Frame) void {
    const eligible = if (element.is(Custom)) |custom|
        custom._definition != null
    else
        frame.getCustomizedBuiltInDefinition(element) != null;

    if (eligible) {
        frame._ce_reactions.enqueueMove(frame, element) catch |err| {
            log.warn(.bug, "ce_reactions enqueue fail", .{ .err = err });
        };
    }

    const shadow_root = element.hostedShadowRoot(frame) orelse return;
    var tw = TreeWalker.FullExcludeSelf.Elements.init(shadow_root.asNode(), .{});
    while (tw.next()) |el| {
        enqueueMoveCallbackOnElement(el, frame);
    }
}

// Reactions descend through the shadodom, so when an element is connected or
// disconnected, we need to enqueue the connect/disconnect callback for any
// nested element including those nested in a shadow root.
pub fn enqueueShadowTreeCallbacks(host: *Element, comptime reaction: enum { connected, disconnected }, frame: *Frame) error{OutOfMemory}!void {
    const shadow_root = host.hostedShadowRoot(frame) orelse return;
    var tw = TreeWalker.FullExcludeSelf.Elements.init(shadow_root.asNode(), .{});
    while (tw.next()) |el| {
        switch (comptime reaction) {
            .connected => try enqueueConnectedCallbackOnElement(false, el, frame),
            .disconnected => enqueueDisconnectedCallbackOnElement(el, frame),
        }
        try enqueueShadowTreeCallbacks(el, reaction, frame);
    }
}

pub fn enqueueAdoptedCallbackOnElement(element: *Element, old_document: *Document, new_document: *Document, frame: *Frame) void {
    if (element.is(Custom)) |custom| {
        if (custom._definition == null) return;
    } else {
        if (frame.getCustomizedBuiltInDefinition(element) == null) return;
    }
    frame._ce_reactions.enqueueAdopted(frame, element, old_document, new_document) catch |err| {
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
    frame._ce_reactions.enqueueAttributeChanged(frame, element, name, old_value, new_value, namespace) catch |err| {
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
            } else if (frame.getCustomizedBuiltInDefinition(el)) |_| {
                invokeCallbackOnElement(el, "connectedCallback", .{}, frame);
            }
        },
        .disconnected => |el| {
            if (el.is(Custom)) |custom| {
                custom.invokeCallback("disconnectedCallback", .{}, frame);
            } else if (frame.getCustomizedBuiltInDefinition(el)) |_| {
                invokeCallbackOnElement(el, "disconnectedCallback", .{}, frame);
            }
        },
        .adopted => |a| {
            if (a.element.is(Custom)) |custom| {
                custom.invokeCallback("adoptedCallback", .{ a.old_document, a.new_document }, frame);
            } else if (frame.getCustomizedBuiltInDefinition(a.element)) |_| {
                invokeCallbackOnElement(a.element, "adoptedCallback", .{ a.old_document, a.new_document }, frame);
            }
        },
        .attribute_changed => |a| {
            if (a.element.is(Custom)) |custom| {
                custom.invokeCallback("attributeChangedCallback", .{ a.name, a.old_value, a.new_value, a.namespace }, frame);
            } else if (frame.getCustomizedBuiltInDefinition(a.element)) |_| {
                invokeCallbackOnElement(a.element, "attributeChangedCallback", .{ a.name, a.old_value, a.new_value, a.namespace }, frame);
            }
        },
        .move => |el| invokeCallbackOnElement(el, "move", .{}, frame),
    }
}

fn invokeCallbackOnElement(element: *Element, comptime callback_name: [:0]const u8, args: anytype, frame: *Frame) void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // Get the JS element object
    const js_val = ls.local.zigValueToJs(element, .{}) catch return;
    const js_element = js_val.toObject();

    if (comptime std.mem.eql(u8, callback_name, "move") == false) {
        // Call the callback method if it exists
        js_element.callMethod(void, callback_name, args) catch {};
        return;
    }

    // for "move", we call "connectedMoveCallback" if it exists, else we fallback
    // to  "disconnectedCallback" + "connectedCallback"
    if (js_element.has("connectedMoveCallback")) {
        js_element.callMethod(void, "connectedMoveCallback", .{}) catch {};
    } else {
        // Either callback may be undefined; the other still runs.
        js_element.callMethod(void, "disconnectedCallback", .{}) catch {};
        js_element.callMethod(void, "connectedCallback", .{}) catch {};
    }
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
    const prev_consumed = frame._upgrading_consumed;
    const node = element.asNode();
    frame._upgrading_element = node;
    frame._upgrading_consumed = false;
    defer {
        frame._upgrading_element = prev_upgrading;
        frame._upgrading_consumed = prev_consumed;
    }

    // PERFORMANCE OPTIMIZATION: This pattern is discouraged in general code.
    // Used here because: (1) multiple early returns before needing Local,
    // (2) called from both V8 callbacks (Local exists) and parser (no Local).
    // Prefer either: requiring *const js.Local parameter, OR always creating
    // Local.Scope upfront.
    var ls: js.Local.Scope = undefined;
    var ls_open = false;
    const local = blk: {
        if (frame.js.local) |l| {
            break :blk l;
        }
        frame.js.localScope(&ls);
        ls_open = true;
        break :blk &ls.local;
    };
    defer if (ls_open) {
        ls.deinit();
    };

    var caught: js.TryCatch.Caught = .{};
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

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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");
const slotting = @import("../slotting.zig");

const Slot = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
// DOM spec "assigned nodes". Maintained by slotting.assignSlottables; always
// empty while the slot isn't in a shadow tree.
_assigned: std.ArrayList(*Node) = .empty,
// DOM spec "manually assigned nodes", set via assign(). Only consulted when
// the shadow root was attached with slotAssignment: "manual".
_manually_assigned: std.ArrayList(*Node) = .empty,

pub fn asElement(self: *Slot) *Element {
    return Factory.protoOf(self).asElement();
}

pub fn asConstElement(self: *const Slot) *const Element {
    return Factory.protoOf(self).asElement();
}

pub fn asNode(self: *Slot) *Node {
    return self.asElement().asNode();
}

const AssignedNodesOptions = struct {
    flatten: bool = false,
};

pub fn assignedNodes(self: *Slot, opts_: ?AssignedNodesOptions, frame: *Frame) ![]const *Node {
    const opts = opts_ orelse AssignedNodesOptions{};
    if (!opts.flatten) {
        return self._assigned.items;
    }
    var nodes: std.ArrayList(*Node) = .empty;
    try self.collectFlattened(false, &nodes, frame);
    return nodes.items;
}

fn assignedElements(self: *Slot, opts_: ?AssignedNodesOptions, frame: *Frame) ![]const *Element {
    var elements: std.ArrayList(*Element) = .empty;
    const opts = opts_ orelse AssignedNodesOptions{};
    if (!opts.flatten) {
        for (self._assigned.items) |node| {
            if (node.is(Element)) |el| {
                try elements.append(frame.call_arena, el);
            }
        }
        return elements.items;
    }
    try self.collectFlattened(true, &elements, frame);
    return elements.items;
}

fn CollectionType(comptime elements: bool) type {
    return if (elements) *std.ArrayList(*Element) else *std.ArrayList(*Node);
}

// DOM spec "find flattened slottables"
fn collectFlattened(self: *Slot, comptime elements: bool, coll: CollectionType(elements), frame: *Frame) error{OutOfMemory}!void {
    if (self.asNode().containingShadowRoot() == null) {
        return;
    }

    if (self._assigned.items.len > 0) {
        for (self._assigned.items) |node| {
            try appendFlattened(elements, coll, node, frame);
        }
        return;
    }

    // no assigned nodes; flatten the slot's fallback content
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (!slotting.isSlottable(child)) {
            continue;
        }
        try appendFlattened(elements, coll, child, frame);
    }
}

fn appendFlattened(comptime elements: bool, coll: CollectionType(elements), node: *Node, frame: *Frame) error{OutOfMemory}!void {
    if (node.is(Slot)) |nested| {
        // a slottable (or fallback child) that is itself a slot in a shadow
        // tree flattens to its own flattened slottables
        if (nested.asNode().containingShadowRoot() != null) {
            return nested.collectFlattened(elements, coll, frame);
        }
    }

    if (comptime elements) {
        if (node.is(Element)) |el| {
            try coll.append(frame.call_arena, el);
        }
    } else {
        try coll.append(frame.call_arena, node);
    }
}

// DOM spec HTMLSlotElement.assign(...nodes). Takes js.Value so the bridge
// always treats the parameter as variadic: per WebIDL it's a rest parameter
// of (Element or Text), so passing an array must throw a TypeError.
pub fn assign(self: *Slot, values: []const js.Value, frame: *Frame) !void {
    const nodes = try frame.call_arena.alloc(*Node, values.len);
    for (values, nodes) |value, *entry| {
        const node = value.toZig(*Node) catch return error.TypeError;
        if (!slotting.isSlottable(node)) {
            return error.TypeError;
        }
        entry.* = node;
    }

    const page = frame.page;
    for (self._manually_assigned.items) |node| {
        _ = page._manual_slot_assignments.remove(node);
    }
    self._manually_assigned.clearRetainingCapacity();

    for (nodes) |node| {
        const gop = try page._manual_slot_assignments.getOrPut(page.arena, node);
        if (gop.found_existing) {
            const other = gop.value_ptr.*;
            if (other == self) {
                // duplicate within `nodes`; an ordered set keeps the first position
                continue;
            }
            // steal the node from the slot it was previously assigned to
            for (other._manually_assigned.items, 0..) |n, i| {
                if (n == node) {
                    _ = other._manually_assigned.orderedRemove(i);
                    break;
                }
            }
        }
        gop.value_ptr.* = self;
        try self._manually_assigned.append(frame.page_arena, node);
    }

    if (self.asNode().containingShadowRoot()) |shadow_root| {
        slotting.assignSlottablesForTree(shadow_root.asNode(), frame);
    }
}

pub fn getName(self: *const Slot) []const u8 {
    return self.asConstElement().getName() orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Slot);

    pub const Meta = struct {
        pub const name = "HTMLSlotElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Slot);

    pub const name = reflect.string("name");
    pub const assignedNodes = bridge.function(Slot.assignedNodes, .{});
    pub const assignedElements = bridge.function(Slot.assignedElements, .{});
    pub const assign = bridge.function(Slot.assign, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLSlotElement" {
    try testing.htmlRunner("element/html/slot.html", .{});
}

const std = @import("std");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const ShadowRoot = @import("../../ShadowRoot.zig");
const slotting = @import("../slotting.zig");

const Slot = @This();

_proto: *HtmlElement,
// DOM spec "assigned nodes". Maintained by slotting.assignSlottables; always
// empty while the slot isn't in a shadow tree.
_assigned: std.ArrayList(*Node) = .empty,
// DOM spec "manually assigned nodes", set via assign(). Only consulted when
// the shadow root was attached with slotAssignment: "manual".
_manually_assigned: std.ArrayList(*Node) = .empty,

pub fn asElement(self: *Slot) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const Slot) *const Element {
    return self._proto._proto;
}

pub fn asNode(self: *Slot) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *const Slot) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Slot, name: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), frame);
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

pub fn assignedElements(self: *Slot, opts_: ?AssignedNodesOptions, frame: *Frame) ![]const *Element {
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
    if (self.asNode().getRootNode(.{}).is(ShadowRoot) == null) {
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
        if (nested.asNode().getRootNode(.{}).is(ShadowRoot) != null) {
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

    for (self._manually_assigned.items) |node| {
        _ = frame._manual_slot_assignments.remove(node);
    }
    self._manually_assigned.clearRetainingCapacity();

    for (nodes) |node| {
        const gop = try frame._manual_slot_assignments.getOrPut(frame.arena, node);
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
        try self._manually_assigned.append(frame.arena, node);
    }

    const root = self.asNode().getRootNode(.{});
    if (root.is(ShadowRoot) != null) {
        slotting.assignSlottablesForTree(root, frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Slot);

    pub const Meta = struct {
        pub const name = "HTMLSlotElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Slot.getName, Slot.setName, .{ .ce_reactions = true });
    pub const assignedNodes = bridge.function(Slot.assignedNodes, .{});
    pub const assignedElements = bridge.function(Slot.assignedElements, .{});
    pub const assign = bridge.function(Slot.assign, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLSlotElement" {
    try testing.htmlRunner("element/html/slot.html", .{});
}

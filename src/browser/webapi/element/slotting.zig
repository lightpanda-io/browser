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
const lp = @import("lightpanda");

const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const ShadowRoot = @import("../ShadowRoot.zig");
const TreeWalker = @import("../TreeWalker.zig");

const Text = @import("../cdata/Text.zig");

const Slot = @import("html/Slot.zig");

pub fn isSlottable(node: *Node) bool {
    return switch (node._type) {
        .element => true,
        .cdata => node.is(Text) != null,
        else => false,
    };
}

// DOM spec "find a slot"
pub fn findSlot(slottable: *Node, comptime open_only: bool, frame: *Frame) ?*Slot {
    const parent = slottable.parentElement() orelse return null;

    const shadow_root = frame._element_shadow_roots.get(parent) orelse return null;

    if (open_only and shadow_root._mode != .open) {
        return null;
    }

    const shadow_node = shadow_root.asNode();

    if (shadow_root._slot_assignment == .manual) {
        const slot = frame._manual_slot_assignments.get(slottable) orelse return null;
        if (slot.asNode().getRootNode(.{}) != shadow_node) {
            return null;
        }
        return slot;
    }

    const slottable_name = blk: {
        const el = slottable.is(Element) orelse break :blk "";
        break :blk el.getAttributeSafe(comptime .wrap("slot")) orelse "";
    };
    return findNamedSlot(shadow_node, slottable_name);
}

// First slot, in tree order, with the given name.
fn findNamedSlot(node: *Node, slot_name: []const u8) ?*Slot {
    if (node.is(Slot)) |slot| {
        if (std.mem.eql(u8, slot.getName(), slot_name)) {
            return slot;
        }
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        if (findNamedSlot(child, slot_name)) |slot| {
            return slot;
        }
    }

    return null;
}

// DOM spec "assign slottables": recompute a slot's assigned nodes, signaling
// a slot change when the assignment actually changed.
fn assignSlottables(slot: *Slot, frame: *Frame) void {
    _assignSlottables(slot, frame) catch |err| {
        lp.log.err(.frame, "assignSlottables", .{ .err = err, .type = frame._type, .url = frame.url });
    };
}

fn _assignSlottables(slot: *Slot, frame: *Frame) !void {
    var slottables: std.ArrayList(*Node) = .empty;
    if (slot.asNode().getRootNode(.{}).is(ShadowRoot)) |shadow_root| {
        const host = shadow_root.getHost();
        if (shadow_root._slot_assignment == .manual) {
            // manual assignment preserves the assign(...) order, not tree order
            for (slot._manually_assigned.items) |node| {
                if (node._parent == host.asNode()) {
                    try slottables.append(frame.call_arena, node);
                }
            }
        } else {
            var it = host.asNode().childrenIterator();
            while (it.next()) |child| {
                if (!isSlottable(child)) {
                    continue;
                }
                if (findSlot(child, false, frame) == slot) {
                    try slottables.append(frame.call_arena, child);
                }
            }
        }
    }

    const old = slot._assigned.items;
    const changed = blk: {
        if (old.len != slottables.items.len) {
            break :blk true;
        }
        for (old, slottables.items) |a, b| {
            if (a != b) break :blk true;
        }
        break :blk false;
    };
    if (!changed) {
        return;
    }

    frame.signalSlotChange(slot);

    for (old) |node| {
        if (frame._assigned_slots.get(node) == slot) {
            _ = frame._assigned_slots.remove(node);
        }
    }
    slot._assigned.clearRetainingCapacity();
    try slot._assigned.appendSlice(frame.arena, slottables.items);
    for (slottables.items) |node| {
        try frame._assigned_slots.put(frame.arena, node, slot);
    }
}

fn assignASlot(slottable: *Node, frame: *Frame) void {
    const slot = findSlot(slottable, false, frame) orelse return;
    assignSlottables(slot, frame);
}

pub fn assignSlottablesForTree(root: *Node, frame: *Frame) void {
    var tw = TreeWalker.Full.Elements.init(root, .{});
    while (tw.next()) |el| {
        if (el.is(Slot)) |slot| {
            assignSlottables(slot, frame);
        }
    }
}

fn subtreeHasSlot(node: *Node) bool {
    if (node.is(Element) == null) {
        return false;
    }
    var tw = TreeWalker.Full.Elements.init(node, .{});
    while (tw.next()) |el| {
        if (el.is(Slot) != null) {
            return true;
        }
    }
    return false;
}

pub fn insertionSteps(parent: *Node, child: *Node, in_fragment_parse: bool, frame: *Frame) void {
    // The new child may be a slottable to assign in the parent's shadow tree.
    if (parent.is(Element)) |parent_el| {
        if (frame._element_shadow_roots.get(parent_el) != null and isSlottable(child)) {
            assignASlot(child, frame);
        }
    }

    // New fallback content in a slot that currently renders its fallback.
    // Skipped during fragment parsing: signaling would fire a spurious
    // slotchange when the fragment's slots end up with the same (empty)
    // assignment they were parsed with.
    if (in_fragment_parse == false) {
        if (parent.is(Slot)) |parent_slot| {
            if (parent_slot._assigned.items.len == 0 and parent.getRootNode(.{}).is(ShadowRoot) != null) {
                frame.signalSlotChange(parent_slot);
            }
        }
    }

    // A subtree containing slots was inserted into a shadow tree.
    if (subtreeHasSlot(child)) {
        const root = child.getRootNode(.{});
        if (root.is(ShadowRoot) != null) {
            assignSlottablesForTree(root, frame);
        }
    }
}

// DOM spec removing steps that affect slot assignment. Runs after child has
// been unlinked from parent.
pub fn removalSteps(parent: *Node, child: *Node, frame: *Frame) void {
    if (frame._element_shadow_roots.count() == 0) {
        // shortcut
        return;
    }

    if (frame._assigned_slots.get(child)) |slot| {
        assignSlottables(slot, frame);
    }

    // Fallback content was removed from a slot that renders its fallback.
    if (parent.is(Slot)) |parent_slot| {
        if (parent_slot._assigned.items.len == 0 and parent.getRootNode(.{}).is(ShadowRoot) != null) {
            frame.signalSlotChange(parent_slot);
        }
    }

    // A subtree containing slots was removed: update assignments in the old
    // tree, and clear assignments held by slots in the detached subtree.
    if (subtreeHasSlot(child)) {
        const root = parent.getRootNode(.{});
        if (root.is(ShadowRoot) != null) {
            assignSlottablesForTree(root, frame);
        }
        assignSlottablesForTree(child, frame);
    }
}

// DOM spec attribute change steps for the `slot` attribute on a slottable.
pub fn slotAttributeChanged(slottable: *Node, old_value: []const u8, value: []const u8, frame: *Frame) void {
    if (std.mem.eql(u8, old_value, value)) {
        return;
    }
    if (frame._element_shadow_roots.count() == 0) {
        return;
    }
    if (frame._assigned_slots.get(slottable)) |old_slot| {
        assignSlottables(old_slot, frame);
    }
    assignASlot(slottable, frame);
}

// HTML spec attribute change steps for the `name` attribute on a slot.
pub fn nameAttributeChanged(slot: *Slot, old_value: []const u8, value: []const u8, frame: *Frame) void {
    if (std.mem.eql(u8, old_value, value)) {
        return;
    }
    const root = slot.asNode().getRootNode(.{});
    if (root.is(ShadowRoot) != null) {
        assignSlottablesForTree(root, frame);
    }
}

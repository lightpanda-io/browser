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

// Per-frame MutationObserver and IntersectionObserver bookkeeping: registration,
// the scheduling of the microtask deliveries, and broadcasting DOM mutations to
// the registered observers. The state lives on the Frame (frame._mutation /
// frame._intersection); these functions operate on it.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const MutationObserver = @import("../webapi/MutationObserver.zig");
const IntersectionObserver = @import("../webapi/IntersectionObserver.zig");

const log = lp.log;
const String = lp.String;

// MutationObserver bookkeeping for a frame.
pub const Mutation = struct {
    // List of active MutationObservers
    observers: std.DoublyLinkedList = .{},
    delivery_scheduled: bool = false,
    delivery_depth: u32 = 0,
};

// IntersectionObserver bookkeeping for a frame.
pub const Intersection = struct {
    // List of active IntersectionObservers
    observers: std.ArrayList(*IntersectionObserver) = .{},
    check_scheduled: bool = false,
    delivery_scheduled: bool = false,
};

// Releases the frame's references to its registered observers. Called from
// Frame.deinit.
pub fn deinit(frame: *Frame, page: *Page) void {
    var node: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (node) |n| {
        node = n.next; // capture before we potentially delete observer
        const observer: *MutationObserver = @fieldParentPtr("node", n);
        observer.releaseRef(page);
    }

    for (frame._intersection.observers.items) |observer| {
        observer.releaseRef(page);
    }
}

pub fn registerMutationObserver(frame: *Frame, observer: *MutationObserver) !void {
    observer.acquireRef();
    frame._mutation.observers.append(&observer.node);
}

pub fn unregisterMutationObserver(frame: *Frame, observer: *MutationObserver) void {
    observer.releaseRef(frame._page);
    frame._mutation.observers.remove(&observer.node);
}

pub fn registerIntersectionObserver(frame: *Frame, observer: *IntersectionObserver) !void {
    observer.acquireRef();
    try frame._intersection.observers.append(frame.arena, observer);
}

pub fn unregisterIntersectionObserver(frame: *Frame, observer: *IntersectionObserver) void {
    for (frame._intersection.observers.items, 0..) |obs, i| {
        if (obs == observer) {
            observer.releaseRef(frame._page);
            _ = frame._intersection.observers.swapRemove(i);
            return;
        }
    }
}

pub fn hasMutationObservers(frame: *const Frame) bool {
    return frame._mutation.observers.first != null;
}

pub fn checkIntersections(frame: *Frame) !void {
    for (frame._intersection.observers.items) |observer| {
        try observer.checkIntersections(frame);
    }
}

pub fn scheduleMutationDelivery(frame: *Frame) !void {
    if (frame._mutation.delivery_scheduled) {
        return;
    }
    frame._mutation.delivery_scheduled = true;
    try frame.js.queueMutationDelivery();
}

pub fn scheduleIntersectionDelivery(frame: *Frame) !void {
    if (frame._intersection.delivery_scheduled) {
        return;
    }
    frame._intersection.delivery_scheduled = true;
    try frame.js.queueIntersectionDelivery();
}

pub fn performScheduledIntersectionChecks(frame: *Frame) void {
    if (!frame._intersection.check_scheduled) {
        return;
    }
    frame._intersection.check_scheduled = false;
    checkIntersections(frame) catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = frame._type, .url = frame.url });
    };
}

pub fn deliverIntersections(frame: *Frame) void {
    if (!frame._intersection.delivery_scheduled) {
        return;
    }
    frame._intersection.delivery_scheduled = false;

    // Iterate backwards to handle observers that disconnect during their callback
    var i = frame._intersection.observers.items.len;
    while (i > 0) {
        i -= 1;
        const observer = frame._intersection.observers.items[i];
        observer.deliverEntries(frame) catch |err| {
            log.err(.frame, "frame.deliverIntersections", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }
}

pub fn deliverMutations(frame: *Frame) void {
    if (!frame._mutation.delivery_scheduled) {
        return;
    }
    frame._mutation.delivery_scheduled = false;

    frame._mutation.delivery_depth += 1;
    defer if (!frame._mutation.delivery_scheduled) {
        // reset the depth once nothing is left to be scheduled
        frame._mutation.delivery_depth = 0;
    };

    if (frame._mutation.delivery_depth > 100) {
        log.err(.frame, "frame.MutationLimit", .{ .type = frame._type, .url = frame.url });
        frame._mutation.delivery_depth = 0;
        return;
    }

    // snapshot the pending slots to deliver. We'll deliver these AFTER the mutation
    // but new pending slots that land during mutation should only be delivered
    // on the microtask tick.
    const slots = frame.call_arena.dupe(*Element.Html.Slot, frame._slots_pending_slotchange.keys()) catch |err| blk: {
        log.err(.frame, "deliverMutations.slots", .{ .err = err, .type = frame._type, .url = frame.url });
        break :blk &.{};
    };
    frame._slots_pending_slotchange.clearRetainingCapacity();

    // We only deliver notifications for observers that have records BEFORE
    // we started the delivery. So we need to snapshot this. Any observers which
    // get records during this phase will only be processed on the next microtask tick.
    var notify: std.ArrayList(*MutationObserver) = .empty;
    var it: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        if (observer._pending_records.items.len == 0) {
            continue;
        }
        notify.append(frame.call_arena, observer) catch |err| {
            log.err(.frame, "deliverMutations.notify", .{ .err = err, .type = frame._type, .url = frame.url });
            break;
        };
    }

    for (notify.items) |observer| {
        observer.deliverRecords(frame) catch |err| {
            log.err(.frame, "frame.deliverMutations", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }

    // slotchange events fire after the observer callbacks (spec step order)
    for (slots) |slot| {
        const event = Event.initTrusted(comptime .wrap("slotchange"), .{ .bubbles = true }, frame._page) catch |err| {
            log.err(.frame, "deliverSlotchange.init", .{ .err = err, .type = frame._type, .url = frame.url });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        frame._event_manager.dispatch(target, event) catch |err| {
            log.err(.frame, "deliverSlotchange.dispatch", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }
}

// Broadcast an attribute change to every registered MutationObserver. The
// caller (Frame.attributeChange / attributeRemove) handles the non-observer
// side effects (build hooks, custom-element callbacks, slot/popover updates).
pub fn notifyAttributeChange(frame: *Frame, element: *Element, name: String, old_value: ?String) void {
    var it: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyAttributeChange(element, name, old_value, frame) catch |err| {
            log.err(.frame, "attributeChange.notifyObserver", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }
}

pub fn notifyCharacterDataChange(frame: *Frame, target: *Node, old_value: String) void {
    var it: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyCharacterDataChange(target, old_value, frame) catch |err| {
            log.err(.frame, "cdataChange.notifyObserver", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }
}

pub fn notifyChildListChange(
    frame: *Frame,
    target: *Node,
    added_nodes: []const *Node,
    removed_nodes: []const *Node,
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
) void {
    // Filter out HTML wrapper element during fragment parsing (html5ever quirk)
    if (frame._parse_mode == .fragment and added_nodes.len == 1) {
        if (added_nodes[0].is(Element.Html.Html) != null) {
            // This is the temporary HTML wrapper, added by html5ever
            // that will be unwrapped, see:
            // https://github.com/servo/html5ever/issues/583
            return;
        }
    }

    var it: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (it) |node| : (it = node.next) {
        const observer: *MutationObserver = @fieldParentPtr("node", node);
        observer.notifyChildListChange(target, added_nodes, removed_nodes, previous_sibling, next_sibling, frame) catch |err| {
            log.err(.frame, "childListChange.notifyObserver", .{ .err = err, .type = frame._type, .url = frame.url });
        };
    }
}

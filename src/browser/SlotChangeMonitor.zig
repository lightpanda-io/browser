const std = @import("std");

const log = @import("../log.zig");
const parser = @import("netsurf.zig");
const collection = @import("dom/html_collection.zig");

const Page = @import("page.zig").Page;

const SlotChangeMonitor = @This();

page: *Page,
event_node: parser.EventNode,
slots_changed: std.ArrayList(*parser.Slot),

// Monitors the document in order to trigger slotchange events.
pub fn init(page: *Page) !*SlotChangeMonitor {
    // on the heap, we need a stable address for event_node
    const self = try page.arena.create(SlotChangeMonitor);
    self.* = .{
        .page = page,
        .slots_changed = .empty,
        .event_node = .{ .func = mutationCallback },
    };
    const root = parser.documentToNode(parser.documentHTMLToDocument(page.window.document));

    _ = try parser.eventTargetAddEventListener(
        parser.toEventTarget(parser.Node, root),
        "DOMNodeInserted",
        &self.event_node,
        false,
    );

    _ = try parser.eventTargetAddEventListener(
        parser.toEventTarget(parser.Node, root),
        "DOMNodeRemoved",
        &self.event_node,
        false,
    );

    _ = try parser.eventTargetAddEventListener(
        parser.toEventTarget(parser.Node, root),
        "DOMAttrModified",
        &self.event_node,
        false,
    );

    return self;
}

// Given a element, finds its slot, if any.
pub fn findSlot(element: *parser.Element, page: *const Page) !?*parser.Slot {
    const target_name = (try parser.elementGetAttribute(element, "slot")) orelse return null;
    return findNamedSlot(element, target_name, page);
}

// Given an element and a name, find the slo, if any. This is only useful for
// MutationEvents where findSlot is unreliable because parser.elementGetAttribute(element, "slot")
// could return the new or old value.
fn findNamedSlot(element: *parser.Element, target_name: []const u8, page: *const Page) !?*parser.Slot {
    // I believe elements need to be added as direct descendents of the host,
    // so we don't need to go find the host, we just grab the parent.
    const host = parser.nodeParentNode(@ptrCast(element)) orelse return null;
    const state = page.getNodeState(host) orelse return null;
    const shadow_root = state.shadow_root orelse return null;

    // if we're here, we found a host, now find the slot
    var nodes = collection.HTMLCollectionByTagName(
        @ptrCast(@alignCast(shadow_root.proto)),
        "slot",
        .{ .include_root = false },
    );
    for (0..1000) |i| {
        const n = (try nodes.item(@intCast(i))) orelse return null;
        const slot_name = (try parser.elementGetAttribute(@ptrCast(n), "name")) orelse "";
        if (std.mem.eql(u8, target_name, slot_name)) {
            return @ptrCast(n);
        }
    }
    return null;
}

// Event callback from the mutation event, signaling either the addition of
// a node, removal of a node, or a change in attribute
fn mutationCallback(en: *parser.EventNode, event: *parser.Event) void {
    const mutation_event = parser.eventToMutationEvent(event);
    const self: *SlotChangeMonitor = @fieldParentPtr("event_node", en);
    self._mutationCallback(mutation_event) catch |err| {
        log.err(.web_api, "slot change callback", .{ .err = err });
    };
}

fn _mutationCallback(self: *SlotChangeMonitor, event: *parser.MutationEvent) !void {
    const event_type = parser.eventType(@ptrCast(event));
    if (std.mem.eql(u8, event_type, "DOMNodeInserted")) {
        const event_target = parser.eventTarget(@ptrCast(event)) orelse return;
        return self.nodeAddedOrRemoved(@ptrCast(event_target));
    }

    if (std.mem.eql(u8, event_type, "DOMNodeRemoved")) {
        const event_target = parser.eventTarget(@ptrCast(event)) orelse return;
        return self.nodeAddedOrRemoved(@ptrCast(event_target));
    }

    if (std.mem.eql(u8, event_type, "DOMAttrModified")) {
        const attribute_name = try parser.mutationEventAttributeName(event);
        if (std.mem.eql(u8, attribute_name, "slot") == false) {
            return;
        }

        const new_value = parser.mutationEventNewValue(event);
        const prev_value = parser.mutationEventPrevValue(event);
        const event_target = parser.eventTarget(@ptrCast(event)) orelse return;
        return self.nodeAttributeChanged(@ptrCast(event_target), new_value, prev_value);
    }
}

// A node was removed or added. If it's an element, and if it has a slot attribute
// then we'll dispatch a slotchange event.
fn nodeAddedOrRemoved(self: *SlotChangeMonitor, node: *parser.Node) !void {
    if (parser.nodeType(node) != .element) {
        return;
    }
    const el: *parser.Element = @ptrCast(node);
    if (try findSlot(el, self.page)) |slot| {
        return self.scheduleSlotChange(slot);
    }
}

// An attribute was modified. If the attribute is "slot", then we'll trigger 1
// slotchange for the old slot (if there was one) and 1 slotchange for the new
// one (if there is one)
fn nodeAttributeChanged(self: *SlotChangeMonitor, node: *parser.Node, new_value: ?[]const u8, prev_value: ?[]const u8) !void {
    if (parser.nodeType(node) != .element) {
        return;
    }

    const el: *parser.Element = @ptrCast(node);
    if (try findNamedSlot(el, prev_value orelse "", self.page)) |slot| {
        try self.scheduleSlotChange(slot);
    }

    if (try findNamedSlot(el, new_value orelse "", self.page)) |slot| {
        try self.scheduleSlotChange(slot);
    }
}

// OK. Our MutationEvent is not a MutationObserver - it's an older, deprecated
// API. It gets dispatched in the middle of the change. While I'm sure it has
// some rules, from our point of view, it fires too early. DOMAttrModified fires
// before the attribute is actually updated and DOMNodeRemoved before the node
// is actually removed. This is a problem if the callback will call
// `slot.assignedNodes`, since that won't return the new state.
// So, we use the page schedule to schedule the dispatching of the slotchange
// event.
fn scheduleSlotChange(self: *SlotChangeMonitor, slot: *parser.Slot) !void {
    for (self.slots_changed.items) |changed| {
        if (slot == changed) {
            return;
        }
    }

    try self.slots_changed.append(self.page.arena, slot);
    if (self.slots_changed.items.len == 1) {
        // first item added, schedule the callback
        try self.page.scheduler.add(self, scheduleCallback, 0, .{ .name = "slot change" });
    }
}

// Callback from the schedule. Time to dispatch the slotchange event
fn scheduleCallback(ctx: *anyopaque) ?u32 {
    var self: *SlotChangeMonitor = @ptrCast(@alignCast(ctx));
    self._scheduleCallback() catch |err| {
        log.err(.app, "slot change schedule", .{ .err = err });
    };
    return null;
}

fn _scheduleCallback(self: *SlotChangeMonitor) !void {
    for (self.slots_changed.items) |slot| {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, "slotchange", .{});
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(parser.Element, @ptrCast(@alignCast(slot))),
            event,
        );
    }
    self.slots_changed.clearRetainingCapacity();
}

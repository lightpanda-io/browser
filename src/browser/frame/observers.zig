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

// Per-frame MutationObserver, IntersectionObserver and ResizeObserver
// bookkeeping: registration, the scheduling of the microtask deliveries, and
// broadcasting DOM mutations to the registered observers. The state lives on
// the Frame (frame._mutation / frame._intersection / frame._resize); these
// functions operate on it.

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const ResizeObserver = @import("../webapi/ResizeObserver.zig");
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

    // Consecutive delivery sessions that hit delivery_depth's cap instead of
    // draining. delivery_depth only bounds one session's recursion; a
    // callback that reschedules itself can restart a fresh session forever.
    consecutive_full_depth: u32 = 0,
};

// IntersectionObserver bookkeeping for a frame.
pub const Intersection = struct {
    // List of active IntersectionObservers
    observers: std.ArrayList(*IntersectionObserver) = .empty,
    check_dirty: bool = false,
    delivery_scheduled: bool = false,
    slow_check_scheduled: bool = false,
    prompt_check_scheduled: bool = false,

    check_streak: u8 = 0,
    last_check_ms: u64 = 0,

    // Deliveries closer together than INTERSECTION_QUIET_MS form one burst.
    // Frame.init re-initializes the whole struct, so a navigation starts fresh.
    burst_start_ms: u64 = 0,
    last_delivery_ms: u64 = 0,
    burst_deliveries: u32 = 0,
    runaway: bool = false,
};

// ResizeObserver bookkeeping for a frame.
pub const Resize = struct {
    // List of active ResizeObservers (i.e. those with >= 1 observation)
    observers: std.ArrayList(*ResizeObserver) = .empty,
    check_scheduled: bool = false,
    delivery_scheduled: bool = false,
    delivery_depth: u32 = 0,
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

    for (frame._resize.observers.items) |observer| {
        observer.releaseRef(page);
    }
}

pub fn registerMutationObserver(frame: *Frame, observer: *MutationObserver) !void {
    observer.acquireRef();
    frame._mutation.observers.append(&observer.node);
}

pub fn unregisterMutationObserver(frame: *Frame, observer: *MutationObserver) void {
    observer.releaseRef(frame.page);
    frame._mutation.observers.remove(&observer.node);
}

pub fn registerIntersectionObserver(frame: *Frame, observer: *IntersectionObserver) !void {
    observer.acquireRef();
    try frame._intersection.observers.append(frame.page_arena, observer);
}

pub fn unregisterIntersectionObserver(frame: *Frame, observer: *IntersectionObserver) void {
    for (frame._intersection.observers.items, 0..) |obs, i| {
        if (obs == observer) {
            observer.releaseRef(frame.page);
            _ = frame._intersection.observers.orderedRemove(i);
            return;
        }
    }
}

pub fn registerResizeObserver(frame: *Frame, observer: *ResizeObserver) !void {
    observer.acquireRef();
    try frame._resize.observers.append(frame.page_arena, observer);
}

pub fn unregisterResizeObserver(frame: *Frame, observer: *ResizeObserver) void {
    for (frame._resize.observers.items, 0..) |obs, i| {
        if (obs == observer) {
            observer.releaseRef(frame.page);
            _ = frame._resize.observers.orderedRemove(i);
            return;
        }
    }
}

pub fn hasMutationObservers(frame: *const Frame) bool {
    return frame._mutation.observers.first != null;
}

pub fn hasIntersectionObservers(frame: *const Frame) bool {
    return frame._intersection.observers.items.len > 0;
}

fn checkIntersections(frame: *Frame) !void {
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

// IOs are computed once per rendering opportunity, i.e. the same 5ms frequency.
pub const INTERSECTION_CHECK_MS = 5;

// IO is expensive. We hook into the attribution system and on a stream of
// non-holding triggers, we only check every 100ms.
pub const INTERSECTION_SLOW_CHECK_MS = 100;
const INTERSECTION_STREAK = 3;
const INTERSECTION_STREAK_GAP_MS = 2 * INTERSECTION_SLOW_CHECK_MS;

/// Something that can move a target changed: the DOM, an observe(), a scroll,
/// the viewport.
pub fn scheduleIntersectionChecks(frame: *Frame) void {
    const state = &frame._intersection;
    if (state.observers.items.len == 0) {
        return;
    }
    state.check_dirty = true;
    if (state.prompt_check_scheduled) {
        return;
    }

    const now = lp.datetime.milliTimestamp(.boot);
    const streaking = state.check_streak >= INTERSECTION_STREAK and now - state.last_check_ms <= INTERSECTION_STREAK_GAP_MS;
    if (!streaking or js.Attribution.isTracked(frame.js.attribution.current())) {
        frame.js.scheduler.add(frame, runPromptIntersectionCheck, INTERSECTION_CHECK_MS, .{
            .name = "IntersectionObserver.checks",
            .kind = .observer,
        }) catch |err| {
            log.err(.frame, "scheduleIntersectionChecks", .{ .err = err, .type = frame._type, .url = frame.url });
            return;
        };
        state.prompt_check_scheduled = true;
        return;
    }

    if (state.slow_check_scheduled) {
        return;
    }
    frame.js.scheduler.add(frame, runSlowIntersectionCheck, INTERSECTION_SLOW_CHECK_MS, .{
        .name = "IntersectionObserver.slowChecks",
        .kind = .observer,
        .blocks_done = false,
    }) catch |err| {
        log.err(.frame, "scheduleIntersectionChecks", .{ .err = err, .type = frame._type, .url = frame.url });
        return;
    };
    state.slow_check_scheduled = true;
}

/// The frame's viewport moved (a scroll) or changed size.
pub fn intersectionViewportMoved(frame: *Frame) void {
    frame._intersection.last_delivery_ms = 0;
    scheduleIntersectionChecks(frame);
}

/// A scroll in frame also moves every frame nested in it, and their observers
/// are registered on them.
pub fn intersectionScrolled(frame: *Frame) void {
    intersectionViewportMoved(frame);
    for (frame.child_frames.items) |child| {
        intersectionScrolled(child);
    }
}

pub fn scheduleResizeDelivery(frame: *Frame) void {
    if (frame._resize.observers.items.len == 0) {
        return;
    }
    if (frame._resize.delivery_scheduled) {
        return;
    }
    frame._resize.delivery_scheduled = true;
    frame.js.queueResizeDelivery() catch |err| {
        frame._resize.delivery_scheduled = false;
        log.err(.frame, "frame.scheduleResizeDelivery", .{ .err = err, .type = frame._type, .url = frame.url });
    };
}

// Called on every DOM change, a full delivery is too expensive to call here.
// What we can do is schedule a check.
pub fn scheduleResizeChecks(frame: *Frame) void {
    if (frame._resize.observers.items.len == 0) {
        return;
    }
    if (frame._resize.check_scheduled or frame._resize.delivery_scheduled) {
        // check is already scheduled OR delivery is already scheduled
        return;
    }
    frame._resize.check_scheduled = true;
    frame.js.queueResizeChecks() catch |err| {
        frame._resize.check_scheduled = false;
        log.err(.frame, "frame.scheduleResizeChecks", .{ .err = err, .type = frame._type, .url = frame.url });
    };
}

pub fn performScheduledResizeChecks(frame: *Frame) void {
    if (!frame._resize.check_scheduled) {
        return;
    }

    frame._resize.check_scheduled = false;
    if (frame._resize.delivery_scheduled) {
        return;
    }

    // Check if we should schedule a delivery. If you're wondering why we're
    // scheduling within a schedule, it's because this can be expensive and we
    // want to coalesce as many of these into a single call as possible.
    for (frame._resize.observers.items) |observer| {
        if (observer.sizeChanged(frame)) {
            scheduleResizeDelivery(frame);
            return;
        }
    }
}

pub fn deliverResizes(frame: *Frame) void {
    if (!frame._resize.delivery_scheduled) {
        return;
    }
    frame._resize.delivery_scheduled = false;

    // guard against a callback that keeps mutating the layout, and thus causes
    // an endless stram of deliveries.
    frame._resize.delivery_depth += 1;
    defer if (!frame._resize.delivery_scheduled) {
        frame._resize.delivery_depth = 0;
    };
    if (frame._resize.delivery_depth > 16) {
        log.debug(.frame, "frame.ResizeLimit", .{ .type = frame._type, .url = frame.url });
        frame._resize.delivery_depth = 0;
        return;
    }

    // snapshot and acquireRef because a the callback for observer A could
    // disconnect, which would then wipe our reference from under us.
    const observers = frame.call_arena.dupe(*ResizeObserver, frame._resize.observers.items) catch |err| {
        log.err(.frame, "deliverResizes.snapshot", .{ .err = err, .type = frame._type, .url = frame.url });
        return;
    };

    for (observers) |observer| {
        observer.acquireRef();
    }
    defer for (observers) |observer| {
        observer.releaseRef(frame.page);
    };

    const attribution = frame.js.attribution;
    const task_scope = attribution.enterNew(.observer, .{ .label = "ResizeObserver" });
    defer task_scope.exit();

    for (observers) |observer| {
        observer.deliverEntries(frame) catch |err| {
            log.debug(.frame, "frame.deliverResizes", .{ .err = err, .type = frame._type, .url = frame.url });
            if (err == error.ExecutionTerminated) {
                return;
            }
        };
    }
}

fn runPromptIntersectionCheck(ctx: *anyopaque) !?u32 {
    const frame: *Frame = @ptrCast(@alignCast(ctx));
    frame._intersection.prompt_check_scheduled = false;
    performIntersectionChecks(frame);
    return null;
}

fn runSlowIntersectionCheck(ctx: *anyopaque) !?u32 {
    const frame: *Frame = @ptrCast(@alignCast(ctx));
    frame._intersection.slow_check_scheduled = false;
    performIntersectionChecks(frame);
    return null;
}

fn performIntersectionChecks(frame: *Frame) void {
    const state = &frame._intersection;
    if (!state.check_dirty) {
        return;
    }
    state.check_dirty = false;

    const now = lp.datetime.milliTimestamp(.boot);
    state.check_streak = if (now - state.last_check_ms <= INTERSECTION_STREAK_GAP_MS) state.check_streak +| 1 else 1;
    state.last_check_ms = now;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    checkIntersections(frame) catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = frame._type, .url = frame.url });
    };
    // delivery is queued as a microtask
    ls.local.runMicrotasks();
}

// A page that observes a fresh sentinel from inside its own callback never
// settles if the sentinel intersects the moment it is attached: content that
// should push it out of view doesn't (our layout made it too short), or the
// sentinel sits where content never reaches. Observed on a storefront
// paginating itself past page 18 at ~30 deliveries/s until the watchdog killed
// the page, back when every target was reported as intersecting.
//
// Only deliveries that report a target intersecting on its first check count
// towards a burst: that is the runaway's signature. Targets entering and
// leaving as the page scrolls or a carousel turns are ordinary, and a scroll or
// viewport change also starts a new burst, since something outside the page's
// observers paces those.
//
// A delivery count cannot separate this from a busy but healthy page: airbnb
// legitimately needs up to ~50 deliveries per load, and the runaway had already
// exhausted the timer table by ~70. Duration does separate them. Healthy pages
// go quiet within 5s of their first delivery; the runaway never does. Bursts
// are measured from their own start rather than from page load so that lazy
// loading triggered minutes later, by a scroll or a click, is not penalized.
// Gaps inside a healthy burst stayed under 800ms; the runaway paused once for
// 1.1s on a network stall.
//
// Each check is its own task, so even a chain that re-observes from inside its
// callback advances one delivery per INTERSECTION_CHECK_MS: the per-burst count
// stops it within about 5s, before the clock would. At 20x the busiest healthy
// page it is not a tuning knob.
pub const INTERSECTION_RUNAWAY_MS = 10_000;
pub const INTERSECTION_QUIET_MS = 2_000;
pub const INTERSECTION_BURST_LIMIT = 1024;

// No observer on the frame can make progress once this path is reached.
fn disconnectRunawayIntersectionObservers(frame: *Frame) void {
    // The page can keep creating observers after the disconnect (a framework
    // re-mounting its lazy loader will), and each one trips this path again, so
    // only the crossing itself is logged.
    if (!frame._intersection.runaway) {
        frame._intersection.runaway = true;
        log.debug(.frame, "frame.IntersectionRunaway", .{ .type = frame._type, .url = frame.url });
    }

    for (frame._intersection.observers.items) |observer| {
        observer.reset(frame.page);
        observer.releaseRef(frame.page);
    }
    frame._intersection.observers.clearRetainingCapacity();
}

pub fn deliverIntersections(frame: *Frame) void {
    if (!frame._intersection.delivery_scheduled) {
        return;
    }
    frame._intersection.delivery_scheduled = false;

    const counts = for (frame._intersection.observers.items) |observer| {
        if (observer.reportsNewTargetIntersecting()) break true;
    } else false;
    if (counts) {
        const now = lp.datetime.milliTimestamp(.boot);
        if (now - frame._intersection.last_delivery_ms > INTERSECTION_QUIET_MS) {
            frame._intersection.burst_start_ms = now;
            frame._intersection.burst_deliveries = 0;
            frame._intersection.runaway = false;
        }
        frame._intersection.last_delivery_ms = now;
        frame._intersection.burst_deliveries += 1;

        const too_long = now - frame._intersection.burst_start_ms > INTERSECTION_RUNAWAY_MS;
        if (too_long or frame._intersection.burst_deliveries > INTERSECTION_BURST_LIMIT) {
            disconnectRunawayIntersectionObservers(frame);
            return;
        }
    }

    // snapshot and acquireRef because a the callback for observer A could
    // disconnect, which would then wipe our reference from under us.
    const observers = frame.call_arena.dupe(*IntersectionObserver, frame._intersection.observers.items) catch |err| {
        log.err(.frame, "deliverIntersections.snapshot", .{ .err = err, .type = frame._type, .url = frame.url });
        return;
    };
    for (observers) |observer| {
        observer.acquireRef();
    }
    defer for (observers) |observer| {
        observer.releaseRef(frame.page);
    };

    const attribution = frame.js.attribution;
    const task_scope = attribution.enterNew(.observer, .{
        .label = "IntersectionObserver",
        .cut = true, // This is the cause of many endless loops
    });
    defer task_scope.exit();

    for (observers) |observer| {
        observer.deliverEntries(frame) catch |err| {
            log.debug(.frame, "frame.deliverIntersections", .{ .err = err, .type = frame._type, .url = frame.url });
            if (err == error.ExecutionTerminated) {
                return;
            }
        };
    }
}

// No observer on the frame can make progress once this path is reached.
fn disconnectRunawayMutationObservers(frame: *Frame) void {
    log.debug(.frame, "frame.MutationRunaway", .{ .type = frame._type, .url = frame.url });

    var node: ?*std.DoublyLinkedList.Node = frame._mutation.observers.first;
    while (node) |n| {
        node = n.next;
        const observer: *MutationObserver = @fieldParentPtr("node", n);
        observer.disconnect(frame);
    }
}

// ~1600 observer callbacks (100 cascades x 16 depth) with zero progress is
// well past any legitimate coalescing burst.
const MUTATION_RUNAWAY_LIMIT = 100;

pub fn deliverMutations(frame: *Frame) void {
    if (!frame._mutation.delivery_scheduled) {
        return;
    }
    frame._mutation.delivery_scheduled = false;

    frame._mutation.delivery_depth += 1;
    var capped = false;
    defer if (!frame._mutation.delivery_scheduled) {
        frame._mutation.delivery_depth = 0;
        if (capped) {
            frame._mutation.consecutive_full_depth += 1;
            if (frame._mutation.consecutive_full_depth >= MUTATION_RUNAWAY_LIMIT) {
                disconnectRunawayMutationObservers(frame);
            }
        } else {
            frame._mutation.consecutive_full_depth = 0;
        }
    };

    if (frame._mutation.delivery_depth > 16) {
        log.debug(.frame, "frame.MutationLimit", .{ .type = frame._type, .url = frame.url });
        frame._mutation.delivery_depth = 0;
        capped = true;
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
    defer for (notify.items) |observer| {
        observer.releaseRef(frame.page);
    };
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
        observer.acquireRef();
    }

    for (notify.items) |observer| {
        observer.deliverRecords(frame) catch |err| {
            log.debug(.frame, "frame.deliverMutations", .{ .err = err, .type = frame._type, .url = frame.url });
            if (err == error.ExecutionTerminated) {
                return;
            }
        };
    }

    // slotchange events fire after the observer callbacks (spec step order)
    for (slots) |slot| {
        const event = Event.initTrusted(comptime .wrap("slotchange"), .{ .bubbles = true }, frame.page) catch |err| {
            log.err(.frame, "deliverSlotchange.init", .{ .err = err, .type = frame._type, .url = frame.url });
            continue;
        };
        const target = slot.asNode().asEventTarget();
        frame._event_manager.dispatch(target, event) catch |err| {
            log.debug(.frame, "deliverSlotchange.dispatch", .{ .err = err, .type = frame._type, .url = frame.url });
            if (err == error.ExecutionTerminated) {
                return;
            }
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

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
const js = @import("../js/js.zig");
const log = @import("../../log.zig");

const Page = @import("../Page.zig");
const Element = @import("Element.zig");
const DOMRect = @import("DOMRect.zig");

pub fn registerTypes() []const type {
    return &.{
        IntersectionObserver,
        IntersectionObserverEntry,
    };
}

const IntersectionObserver = @This();

_callback: js.Function.Global,
_observing: std.ArrayList(*Element) = .{},
_root: ?*Element = null,
_root_margin: []const u8 = "0px",
_threshold: []const f64 = &.{0.0},
_pending_entries: std.ArrayList(*IntersectionObserverEntry) = .{},
_previous_states: std.AutoHashMapUnmanaged(*Element, bool) = .{},

// Shared zero DOMRect to avoid repeated allocations for non-intersecting elements
var zero_rect: DOMRect = .{
    ._x = 0.0,
    ._y = 0.0,
    ._width = 0.0,
    ._height = 0.0,
};

pub const ObserverInit = struct {
    root: ?*Element = null,
    rootMargin: ?[]const u8 = null,
    threshold: Threshold = .{ .scalar = 0.0 },

    const Threshold = union(enum) {
        scalar: f64,
        array: []const f64,
    };
};

pub fn init(callback: js.Function.Global, options: ?ObserverInit, page: *Page) !*IntersectionObserver {
    const opts = options orelse ObserverInit{};
    const root_margin = if (opts.rootMargin) |rm| try page.arena.dupe(u8, rm) else "0px";

    const threshold = switch (opts.threshold) {
        .scalar => |s| blk: {
            const arr = try page.arena.alloc(f64, 1);
            arr[0] = s;
            break :blk arr;
        },
        .array => |arr| try page.arena.dupe(f64, arr),
    };

    return page._factory.create(IntersectionObserver{
        ._callback = callback,
        ._root = opts.root,
        ._root_margin = root_margin,
        ._threshold = threshold,
    });
}

pub fn observe(self: *IntersectionObserver, target: *Element, page: *Page) !void {
    // Check if already observing this target
    for (self._observing.items) |elem| {
        if (elem == target) {
            return;
        }
    }

    // Register with page if this is our first observation
    if (self._observing.items.len == 0) {
        try page.registerIntersectionObserver(self);
    }

    try self._observing.append(page.arena, target);

    // Don't initialize previous state yet - let checkIntersection do it
    // This ensures we get an entry on first observation

    // Check intersection for this new target and schedule delivery
    try self.checkIntersection(target, page);
    if (self._pending_entries.items.len > 0) {
        try page.scheduleIntersectionDelivery();
    }
}

pub fn unobserve(self: *IntersectionObserver, target: *Element) void {
    for (self._observing.items, 0..) |elem, i| {
        if (elem == target) {
            _ = self._observing.swapRemove(i);
            _ = self._previous_states.remove(target);

            // Remove any pending entries for this target
            var j: usize = 0;
            while (j < self._pending_entries.items.len) {
                if (self._pending_entries.items[j]._target == target) {
                    _ = self._pending_entries.swapRemove(j);
                } else {
                    j += 1;
                }
            }
            return;
        }
    }
}

pub fn disconnect(self: *IntersectionObserver, page: *Page) void {
    page.unregisterIntersectionObserver(self);
    self._observing.clearRetainingCapacity();
    self._previous_states.clearRetainingCapacity();
    self._pending_entries.clearRetainingCapacity();
}

pub fn takeRecords(self: *IntersectionObserver, page: *Page) ![]*IntersectionObserverEntry {
    const entries = try page.call_arena.dupe(*IntersectionObserverEntry, self._pending_entries.items);
    self._pending_entries.clearRetainingCapacity();
    return entries;
}

fn calculateIntersection(
    self: *IntersectionObserver,
    target: *Element,
    page: *Page,
) !IntersectionData {
    const target_rect = try target.getBoundingClientRect(page);

    // Use root element's rect or viewport (simplified: assume 1920x1080)
    const root_rect = if (self._root) |root|
        try root.getBoundingClientRect(page)
    else
        // Simplified viewport - assume 1920x1080 for now
        try page._factory.create(DOMRect{
            ._x = 0.0,
            ._y = 0.0,
            ._width = 1920.0,
            ._height = 1080.0,
        });

    // For a headless browser without real layout, we treat all elements as fully visible.
    // This avoids fingerprinting issues (massive viewports) and matches the behavior
    // scripts expect when querying element visibility.
    // However, elements without a parent cannot intersect (they have no containing block).
    const has_parent = target.asNode().parentNode() != null;
    const is_intersecting = has_parent;
    const intersection_ratio: f64 = if (has_parent) 1.0 else 0.0;

    // Intersection rect is the same as the target rect if visible, otherwise zero rect
    const intersection_rect = if (has_parent) target_rect else &zero_rect;

    return .{
        .is_intersecting = is_intersecting,
        .intersection_ratio = intersection_ratio,
        .intersection_rect = intersection_rect,
        .bounding_client_rect = target_rect,
        .root_bounds = root_rect,
    };
}

const IntersectionData = struct {
    is_intersecting: bool,
    intersection_ratio: f64,
    intersection_rect: *DOMRect,
    bounding_client_rect: *DOMRect,
    root_bounds: *DOMRect,
};

fn meetsThreshold(self: *IntersectionObserver, ratio: f64) bool {
    for (self._threshold) |threshold| {
        if (ratio >= threshold) {
            return true;
        }
    }
    return false;
}

fn checkIntersection(self: *IntersectionObserver, target: *Element, page: *Page) !void {
    const data = try self.calculateIntersection(target, page);
    const was_intersecting_opt = self._previous_states.get(target);
    const is_now_intersecting = data.is_intersecting and self.meetsThreshold(data.intersection_ratio);

    // Create entry if:
    // 1. First time observing this target AND it's intersecting
    // 2. State changed
    const should_report = (was_intersecting_opt == null and is_now_intersecting) or
        (was_intersecting_opt != null and was_intersecting_opt.? != is_now_intersecting);

    if (should_report) {
        const entry = try page.arena.create(IntersectionObserverEntry);
        entry.* = .{
            ._target = target,
            ._time = 0.0, // TODO: Get actual timestamp
            ._bounding_client_rect = data.bounding_client_rect,
            ._intersection_rect = data.intersection_rect,
            ._root_bounds = data.root_bounds,
            ._intersection_ratio = data.intersection_ratio,
            ._is_intersecting = is_now_intersecting,
        };

        try self._pending_entries.append(page.arena, entry);
    }

    // Always update the previous state, even if we didn't report
    // This ensures we can detect state changes on subsequent checks
    try self._previous_states.put(page.arena, target, is_now_intersecting);
}

pub fn checkIntersections(self: *IntersectionObserver, page: *Page) !void {
    if (self._observing.items.len == 0) {
        return;
    }

    for (self._observing.items) |target| {
        try self.checkIntersection(target, page);
    }

    if (self._pending_entries.items.len > 0) {
        try page.scheduleIntersectionDelivery();
    }
}

pub fn deliverEntries(self: *IntersectionObserver, page: *Page) !void {
    if (self._pending_entries.items.len == 0) {
        return;
    }

    const entries = try self.takeRecords(page);
    var caught: js.TryCatch.Caught = undefined;

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).tryCall(void, .{ entries, self }, &caught) catch |err| {
        log.err(.page, "IntsctObserver.deliverEntries", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const IntersectionObserverEntry = struct {
    _target: *Element,
    _time: f64,
    _bounding_client_rect: *DOMRect,
    _intersection_rect: *DOMRect,
    _root_bounds: *DOMRect,
    _intersection_ratio: f64,
    _is_intersecting: bool,

    pub fn getTarget(self: *const IntersectionObserverEntry) *Element {
        return self._target;
    }

    pub fn getTime(self: *const IntersectionObserverEntry) f64 {
        return self._time;
    }

    pub fn getBoundingClientRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._bounding_client_rect;
    }

    pub fn getIntersectionRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._intersection_rect;
    }

    pub fn getRootBounds(self: *const IntersectionObserverEntry) ?*DOMRect {
        return self._root_bounds;
    }

    pub fn getIntersectionRatio(self: *const IntersectionObserverEntry) f64 {
        return self._intersection_ratio;
    }

    pub fn getIsIntersecting(self: *const IntersectionObserverEntry) bool {
        return self._is_intersecting;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IntersectionObserverEntry);

        pub const Meta = struct {
            pub const name = "IntersectionObserverEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const target = bridge.accessor(IntersectionObserverEntry.getTarget, null, .{});
        pub const time = bridge.accessor(IntersectionObserverEntry.getTime, null, .{});
        pub const boundingClientRect = bridge.accessor(IntersectionObserverEntry.getBoundingClientRect, null, .{});
        pub const intersectionRect = bridge.accessor(IntersectionObserverEntry.getIntersectionRect, null, .{});
        pub const rootBounds = bridge.accessor(IntersectionObserverEntry.getRootBounds, null, .{});
        pub const intersectionRatio = bridge.accessor(IntersectionObserverEntry.getIntersectionRatio, null, .{});
        pub const isIntersecting = bridge.accessor(IntersectionObserverEntry.getIsIntersecting, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(IntersectionObserver);

    pub const Meta = struct {
        pub const name = "IntersectionObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(init, .{});

    pub const observe = bridge.function(IntersectionObserver.observe, .{});
    pub const unobserve = bridge.function(IntersectionObserver.unobserve, .{});
    pub const disconnect = bridge.function(IntersectionObserver.disconnect, .{});
    pub const takeRecords = bridge.function(IntersectionObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: IntersectionObserver" {
    try testing.htmlRunner("intersection_observer", .{});
}

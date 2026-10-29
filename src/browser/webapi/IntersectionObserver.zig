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

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const Tokenizer = @import("../css/Tokenizer.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const DOMRect = @import("DOMRect.zig");

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{
        IntersectionObserver,
        IntersectionObserverEntry,
    };
}

const IntersectionObserver = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_callback: js.Function.Global,
_observing: std.ArrayList(*Element) = .empty,
_root: ?*Element = null,
/// The `root` option as given (an Element or the Document), for the getter;
/// `_root` is the element intersections are computed against.
_root_node: ?*Node = null,
/// rootMargin and scrollMargin, parsed and serialized back (four values).
_root_margin: []const u8 = "0px 0px 0px 0px",
_scroll_margin: []const u8 = "0px 0px 0px 0px",
/// Sorted ascending, each in [0, 1].
_threshold: []const f64 = &.{0.0},
_delay: i32 = 0,
_track_visibility: bool = false,
// these are RC'd (by us, and v8)
_pending_entries: std.ArrayList(*IntersectionObserverEntry) = .empty,
// tracked targets that aren't reported yet
_tracked: std.AutoHashMapUnmanaged(*Element, void) = .{},

const ObserverInit = struct {
    delay: i32 = 0,
    root: ?*Node = null,
    rootMargin: ?[]const u8 = null,
    scrollMargin: ?[]const u8 = null,
    threshold: Threshold = .{ .scalar = 0.0 },
    trackVisibility: bool = false,

    const Threshold = union(enum) {
        scalar: f64,
        array: []const f64,
    };
};

pub fn init(callback: js.Function.Global, options: ?ObserverInit, frame: *Frame) !*IntersectionObserver {
    const arena = try frame.getArena(.small, "IntersectionObserver");
    errdefer arena.release();

    const opts = options orelse ObserverInit{};

    // The options' WebIDL conversion comes first, so its TypeErrors do: a
    // root that's neither an Element nor a Document (below), and a threshold
    // that isn't a finite (restricted) double.
    const given_thresholds: []const f64 = switch (opts.threshold) {
        .scalar => |*value| value[0..1],
        .array => |arr| arr,
    };
    for (given_thresholds) |value| {
        if (!std.math.isFinite(value)) return error.TypeError;
    }

    const root: ?*Element = blk: {
        const root_opt = opts.root orelse break :blk null;
        switch (root_opt._type) {
            .element => break :blk root_opt.subtype(Element),
            .document => {
                // not strictly correct, `null` means the viewport, not the
                // entire document, but since we don't render anything, this
                // should be fine.
                break :blk null;
            },
            else => return error.TypeError,
        }
    };

    const root_margin = try serializeMargin(arena.allocator(), try parseMargin(opts.rootMargin orelse "0px"));
    const scroll_margin = try serializeMargin(arena.allocator(), try parseMargin(opts.scrollMargin orelse "0px"));

    // Each threshold is in [0, 1], sorted ascending; an empty list is [0].
    const threshold = blk: {
        if (given_thresholds.len == 0) {
            break :blk &[_]f64{0.0};
        }
        const sorted = try arena.dupe(f64, given_thresholds);
        for (sorted) |value| {
            if (value < 0 or value > 1) return error.RangeError;
        }
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        break :blk sorted;
    };

    // Tracking visibility raises the delay to at least 100ms.
    const delay = if (opts.trackVisibility and opts.delay < 100) 100 else opts.delay;

    const self = try arena.create(IntersectionObserver);
    self.* = .{
        ._arena = arena,
        ._callback = callback,
        ._root = root,
        ._root_node = opts.root,
        ._root_margin = root_margin,
        ._scroll_margin = scroll_margin,
        ._threshold = threshold,
        ._delay = delay,
        ._track_visibility = opts.trackVisibility,
    };
    return self;
}

/// One side of a rootMargin or scrollMargin: a length in px, or a percentage.
const Margin = struct {
    value: f32,
    percent: bool,
};

/// "Parse a margin": one to four px lengths or percentages, expanded like CSS
/// margins to top, right, bottom, left. An empty string is all zero. Any other
/// token (a unitless number, another unit, calc(), a comma) is a SyntaxError.
fn parseMargin(text: []const u8) error{SyntaxError}![4]Margin {
    var margins: [4]Margin = undefined;
    var count: usize = 0;
    var tokenizer: Tokenizer = .{ .input = text };
    while (tokenizer.next()) |token| {
        const margin: Margin = switch (token) {
            .white_space, .comment => continue,
            .dimension => |d| blk: {
                if (std.ascii.eqlIgnoreCase(d.unit, "px") == false) {
                    return error.SyntaxError;
                }
                break :blk .{ .value = d.value, .percent = false };
            },
            // unit_value is divided by 100; prefer the exact integer.
            .percentage => |p| .{
                .value = if (p.int_value) |int| @floatFromInt(int) else p.unit_value * 100,
                .percent = true,
            },
            else => return error.SyntaxError,
        };
        if (count == 4) {
            return error.SyntaxError;
        }
        margins[count] = margin;
        count += 1;
    }
    const zero: Margin = .{ .value = 0, .percent = false };
    return switch (count) {
        0 => .{ zero, zero, zero, zero },
        1 => .{ margins[0], margins[0], margins[0], margins[0] },
        2 => .{ margins[0], margins[1], margins[0], margins[1] },
        3 => .{ margins[0], margins[1], margins[2], margins[1] },
        else => margins,
    };
}

/// The four margins as the rootMargin/scrollMargin attributes give them.
fn serializeMargin(allocator: std.mem.Allocator, margins: [4]Margin) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    for (margins, 0..) |margin, i| {
        if (i > 0) try out.writer.writeByte(' ');
        // + 0 turns -0 into 0, which a JS number prints as "0".
        try out.writer.print("{d}{s}", .{ margin.value + 0, if (margin.percent) "%" else "px" });
    }
    return out.written();
}

pub fn getRoot(self: *const IntersectionObserver) ?*Node {
    return self._root_node;
}

pub fn getRootMargin(self: *const IntersectionObserver) []const u8 {
    return self._root_margin;
}

pub fn getScrollMargin(self: *const IntersectionObserver) []const u8 {
    return self._scroll_margin;
}

pub fn getThresholds(self: *const IntersectionObserver) []const f64 {
    return self._threshold;
}

pub fn getDelay(self: *const IntersectionObserver) i32 {
    return self._delay;
}

pub fn getTrackVisibility(self: *const IntersectionObserver) bool {
    return self._track_visibility;
}

pub fn deinit(self: *IntersectionObserver, page: *Page) void {
    self._callback.release();
    releaseAll(self._pending_entries.items, page);
    self._arena.release();
}

pub fn releaseRef(self: *IntersectionObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *IntersectionObserver) void {
    self._rc.acquire();
}

pub fn observe(self: *IntersectionObserver, target: *Element, frame: *Frame) !void {
    // Check if already observing this target
    for (self._observing.items) |elem| {
        if (elem == target) {
            return;
        }
    }

    try self._observing.append(self._arena.allocator(), target);
    if (self._observing.items.len == 1) {
        try Frame.observers.registerIntersectionObserver(frame, self);
    }

    try self._tracked.put(self._arena.allocator(), target, {});

    // Check intersection for this new target and schedule delivery
    try self.checkIntersection(target, frame);
    if (self._pending_entries.items.len > 0) {
        try Frame.observers.scheduleIntersectionDelivery(frame);
    }
}

fn unobserve(self: *IntersectionObserver, target: *Element, frame: *Frame) void {
    const original_length = self._observing.items.len;
    for (self._observing.items, 0..) |elem, i| {
        if (elem == target) {
            _ = self._observing.swapRemove(i);
            _ = self._tracked.remove(target);

            // Remove any pending entries for this target.
            var j: usize = 0;
            while (j < self._pending_entries.items.len) {
                if (self._pending_entries.items[j]._target == target) {
                    const entry = self._pending_entries.swapRemove(j);
                    entry.releaseRef(frame.page);
                } else {
                    j += 1;
                }
            }
            break;
        }
    }

    if (original_length > 0 and self._observing.items.len == 0) {
        Frame.observers.unregisterIntersectionObserver(frame, self);
    }
}

// Drops every observation without touching the frame's observer list
pub fn reset(self: *IntersectionObserver, page: *Page) void {
    releaseAll(self._pending_entries.items, page);
    self._pending_entries.clearRetainingCapacity();
    self._tracked.clearRetainingCapacity();
    self._observing.clearRetainingCapacity();
}

pub fn disconnect(self: *IntersectionObserver, frame: *Frame) void {
    const registered = self._observing.items.len > 0;
    self.reset(frame.page);
    if (registered) {
        Frame.observers.unregisterIntersectionObserver(frame, self);
    }
}

fn takeRecords(self: *IntersectionObserver, frame: *Frame) !js.Value {
    const local = frame.js.local orelse return error.NotHandled;
    const entries = try self.takePendingEntries(frame);
    // whether we safely deliver these to v8 or not, we're done with these
    defer releaseAll(entries, frame.page);
    return local.zigValueToJs(entries, .{});
}

fn takePendingEntries(self: *IntersectionObserver, frame: *Frame) ![]*IntersectionObserverEntry {
    const entries = try frame.call_arena.dupe(*IntersectionObserverEntry, self._pending_entries.items);
    self._pending_entries.clearRetainingCapacity();
    return entries;
}

fn releaseAll(entries: []const *IntersectionObserverEntry, page: *Page) void {
    for (entries) |entry| {
        entry.releaseRef(page);
    }
}

fn calculateIntersection(
    self: *IntersectionObserver,
    target: *Element,
    frame: *Frame,
) !IntersectionData {
    const target_rect = target.boundingClientRectValues(frame);

    // Use root element's rect or the faux-layout viewport.
    const root_rect = if (self._root) |root|
        root.boundingClientRectValues(frame)
    else blk: {
        const viewport = frame.page.getViewport();
        break :blk DOMRect.Data{
            .width = @floatFromInt(viewport.width),
            .height = @floatFromInt(viewport.height),
        };
    };

    // For a headless browser without real layout, we treat all elements as fully visible.
    // This avoids fingerprinting issues (massive viewports) and matches the behavior
    // scripts expect when querying element visibility.
    return .{
        .intersection_ratio = 1.0,
        .intersection_rect = target_rect,
        .bounding_client_rect = target_rect,
        .root_bounds = root_rect,
    };
}

const IntersectionData = struct {
    intersection_ratio: f64,
    intersection_rect: DOMRect.Data,
    bounding_client_rect: DOMRect.Data,
    root_bounds: DOMRect.Data,
};

fn meetsThreshold(self: *IntersectionObserver, ratio: f64) bool {
    for (self._threshold) |threshold| {
        if (ratio >= threshold) {
            return true;
        }
    }
    return false;
}

fn checkIntersection(self: *IntersectionObserver, target: *Element, frame: *Frame) !void {
    const tracked = self._tracked.getEntry(target) orelse {
        // If target isn't tracked then it was already reported. This is an
        // important optimization which lets us skip the heavy work below.
        // This function can be called a lot.
        return;
    };

    // Frameless documents (DOMParser, createHTMLDocument) aren't rendered.
    const node = target.asNode();
    const connected = node.ownerFrame(frame) != null and node.isConnected();
    const is_now_intersecting = connected and self.meetsThreshold(1.0);
    if (!is_now_intersecting) {
        // Not intersecting yet (e.g. observed while still detached) — keep
        // tracking so a later attach is reported.
        return;
    }

    // Building the entry is the expensive part — getBoundingClientRect walks the
    // document to fake a position (O(node count)) — so it only runs here.
    const data = try self.calculateIntersection(target, frame);
    const arena = try frame.getArena(.tiny, "IntersectionObserverEntry");
    errdefer arena.release();

    const entry = try arena.create(IntersectionObserverEntry);
    entry.* = .{
        ._rc = .init(1),
        ._arena = arena,
        ._target = target,
        ._time = frame.window._performance.now(),
        ._is_intersecting = is_now_intersecting,
        ._root_bounds = try DOMRect.create(data.root_bounds, frame._factory),
        ._intersection_rect = try DOMRect.create(data.intersection_rect, frame._factory),
        ._bounding_client_rect = try DOMRect.create(data.bounding_client_rect, frame._factory),
        ._intersection_ratio = data.intersection_ratio,
    };
    try self._pending_entries.append(self._arena.allocator(), entry);
    _ = self._tracked.removeByPtr(tracked.key_ptr);
}

pub fn checkIntersections(self: *IntersectionObserver, frame: *Frame) !void {
    if (self._observing.items.len == 0) {
        return;
    }

    for (self._observing.items) |target| {
        try self.checkIntersection(target, frame);
    }

    if (self._pending_entries.items.len > 0) {
        try Frame.observers.scheduleIntersectionDelivery(frame);
    }
}

pub fn deliverEntries(self: *IntersectionObserver, frame: *Frame) !void {
    if (self._pending_entries.items.len == 0) {
        return;
    }

    const entries = try self.takePendingEntries(frame);
    // whether we safely deliver these to v8 or not, we're done with these
    defer releaseAll(entries, frame.page);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).callWithThisReport(self, .{ entries, self }) catch |err| {
        log.debug(.frame, "IntsctObserver.deliverEntries", .{ .err = err });
        return err;
    };
}

pub const IntersectionObserverEntry = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _time: f64,
    _target: *Element,
    _bounding_client_rect: *DOMRect,
    _intersection_rect: *DOMRect,
    _root_bounds: *DOMRect,
    _intersection_ratio: f64,
    _is_intersecting: bool,

    pub fn deinit(self: *IntersectionObserverEntry, _: *Page) void {
        self._arena.release();
    }

    pub fn releaseRef(self: *IntersectionObserverEntry, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *IntersectionObserverEntry) void {
        self._rc.acquire();
    }

    pub fn getTarget(self: *const IntersectionObserverEntry) *Element {
        return self._target;
    }

    fn getTime(self: *const IntersectionObserverEntry) f64 {
        return self._time;
    }

    pub fn getBoundingClientRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._bounding_client_rect;
    }

    fn getIntersectionRect(self: *const IntersectionObserverEntry) *DOMRect {
        return self._intersection_rect;
    }

    fn getRootBounds(self: *const IntersectionObserverEntry) ?*DOMRect {
        return self._root_bounds;
    }

    fn getIntersectionRatio(self: *const IntersectionObserverEntry) f64 {
        return self._intersection_ratio;
    }

    fn getIsIntersecting(self: *const IntersectionObserverEntry) bool {
        return self._is_intersecting;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IntersectionObserverEntry);

        pub const Meta = struct {
            pub const name = "IntersectionObserverEntry";
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
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(init, .{});

    pub const root = bridge.accessor(IntersectionObserver.getRoot, null, .{});
    pub const rootMargin = bridge.accessor(IntersectionObserver.getRootMargin, null, .{});
    pub const scrollMargin = bridge.accessor(IntersectionObserver.getScrollMargin, null, .{});
    pub const thresholds = bridge.accessor(IntersectionObserver.getThresholds, null, .{});
    pub const delay = bridge.accessor(IntersectionObserver.getDelay, null, .{});
    pub const trackVisibility = bridge.accessor(IntersectionObserver.getTrackVisibility, null, .{});

    pub const observe = bridge.function(IntersectionObserver.observe, .{});
    pub const unobserve = bridge.function(IntersectionObserver.unobserve, .{});
    pub const disconnect = bridge.function(IntersectionObserver.disconnect, .{});
    pub const takeRecords = bridge.function(IntersectionObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");

// Infinite scroll: the callback observes a fresh sentinel, which we report as
// intersecting the moment it is connected, so the page never settles on its own.
// Old sentinels stay observed (_tracked keeps them from re-firing) so that the
// observer stays registered on the frame for as long as it is alive. `deferred`
// re-observes from a timer, one delivery per macrotask tick, the way a
// fetch-driven pager behaves; otherwise the chain never leaves the microtask
// checkpoint. New sentinels go first: an appended one would measure every
// earlier sibling, making the chain quadratic.
fn observeSentinelChain(frame: *Frame, comptime deferred: bool) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    try ls.local.eval(
        \\(function(deferred) {
        \\  const root = document.documentElement ?? document.appendChild(document.createElement('html'));
        \\  const list = root.appendChild(document.createElement('div'));
        \\  const observe = () => io.observe(list.insertBefore(document.createElement('div'), list.firstChild));
        \\  const io = new IntersectionObserver((entries) => {
        \\    for (const entry of entries) {
        \\      if (!entry.isIntersecting) continue;
        \\      if (deferred) setTimeout(observe, 0); else observe();
        \\    }
        \\  });
        \\  observe();
        \\})(
    ++ (if (deferred) "true" else "false") ++ ")", null);

    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
    try testing.expect(frame._intersection.last_delivery_ms != 0);
}

// Nested zero-delay timers are clamped to 4ms past a nesting depth of five, so
// a yielding chain needs real time to pass between ticks.
fn tick(frame: *Frame) !void {
    lp.io.sleep(.fromMilliseconds(5), .awake) catch {};
    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
}

fn tickUntilDisconnected(frame: *Frame) !void {
    for (0..200) |_| {
        try tick(frame);
        if (!Frame.observers.hasIntersectionObservers(frame)) break;
    }
}

test "WebApi: synchronous IntersectionObserver chain is disconnected" {
    testing.silenceLog(&.{.frame});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, false);
    try tickUntilDisconnected(frame);

    try testing.expectEqual(false, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(true, frame._intersection.runaway);
    try testing.expect(frame._intersection.burst_deliveries > Frame.observers.INTERSECTION_BURST_LIMIT);
}

test "WebApi: IntersectionObserver burst older than the limit is disconnected" {
    testing.silenceLog(&.{.frame});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, true);
    frame._intersection.burst_start_ms -|= Frame.observers.INTERSECTION_RUNAWAY_MS + 1;
    try tickUntilDisconnected(frame);

    try testing.expectEqual(false, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(true, frame._intersection.runaway);
    try testing.expect(frame._intersection.burst_deliveries <= Frame.observers.INTERSECTION_BURST_LIMIT);
}

test "WebApi: IntersectionObserver delivery after a quiet gap starts a new burst" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, true);

    // An old burst that went quiet: its age must not count against what follows.
    frame._intersection.burst_start_ms -|= Frame.observers.INTERSECTION_RUNAWAY_MS + 1;
    frame._intersection.last_delivery_ms -|= Frame.observers.INTERSECTION_QUIET_MS + 1;
    const stale_start = frame._intersection.burst_start_ms;

    try tick(frame);

    try testing.expectEqual(true, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(false, frame._intersection.runaway);
    try testing.expectEqual(1, frame._intersection.burst_deliveries);
    try testing.expect(frame._intersection.burst_start_ms > stale_start);
}

test "WebApi: IntersectionObserver" {
    try testing.htmlRunner("intersection_observer", .{});
}

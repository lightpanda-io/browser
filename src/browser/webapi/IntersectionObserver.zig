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
_observing: std.AutoArrayHashMapUnmanaged(*Element, Observation) = .empty,
_root: ?*Element = null,
/// The `root` option as given (an Element or the Document), for the getter;
/// `_root` is the element intersections are computed against.
_root_node: ?*Node = null,
/// rootMargin and scrollMargin, parsed and serialized back (four values).
_root_margin: []const u8 = "0px 0px 0px 0px",
/// rootMargin as applied: top, right, bottom, left.
_root_margin_values: [4]Margin = @splat(.{ .value = 0, .percent = false }),
_scroll_margin: []const u8 = "0px 0px 0px 0px",
/// Sorted ascending, each in [0, 1].
_threshold: []const f64 = &.{0.0},
_delay: i32 = 0,
_track_visibility: bool = false,
// these are RC'd (by us, and v8)
_pending_entries: std.ArrayList(*IntersectionObserverEntry) = .empty,

// What a target was last reported as
const Observation = struct {
    threshold_index: i32 = -1, // first check is always reported
    is_intersecting: bool = false,
};

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

    const root_margin_values = try parseMargin(opts.rootMargin orelse "0px");
    const root_margin = try serializeMargin(arena.allocator(), root_margin_values);
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
        ._root_margin_values = root_margin_values,
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

fn getRoot(self: *const IntersectionObserver) ?*Node {
    return self._root_node;
}

fn getRootMargin(self: *const IntersectionObserver) []const u8 {
    return self._root_margin;
}

fn getScrollMargin(self: *const IntersectionObserver) []const u8 {
    return self._scroll_margin;
}

fn getThresholds(self: *const IntersectionObserver) []const f64 {
    return self._threshold;
}

fn getDelay(self: *const IntersectionObserver) i32 {
    return self._delay;
}

fn getTrackVisibility(self: *const IntersectionObserver) bool {
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
    const gop = try self._observing.getOrPut(self._arena.allocator(), target);
    if (gop.found_existing) {
        return;
    }
    gop.value_ptr.* = .{};
    if (self._observing.count() == 1) {
        try Frame.observers.registerIntersectionObserver(frame, self);
    }
    Frame.observers.scheduleIntersectionChecks(frame);
}

fn unobserve(self: *IntersectionObserver, target: *Element, frame: *Frame) void {
    // swapRemove reorders the remaining targets, so entries can be delivered
    // out of observe() order after an unobserve (orderedRemove is O(n)).
    if (self._observing.swapRemove(target) == false) {
        return;
    }

    // Remove any pending entries for this target.
    var i: usize = 0;
    while (i < self._pending_entries.items.len) {
        if (self._pending_entries.items[i]._target == target) {
            const entry = self._pending_entries.swapRemove(i);
            entry.releaseRef(frame.page);
        } else {
            i += 1;
        }
    }

    if (self._observing.count() == 0) {
        Frame.observers.unregisterIntersectionObserver(frame, self);
    }
}

// Drops every observation without touching the frame's observer list
pub fn reset(self: *IntersectionObserver, page: *Page) void {
    releaseAll(self._pending_entries.items, page);
    self._pending_entries.clearRetainingCapacity();
    self._observing.clearRetainingCapacity();
}

pub fn disconnect(self: *IntersectionObserver, frame: *Frame) void {
    const registered = self._observing.count() > 0;
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

const Rect = DOMRect.Data;

const IntersectionData = struct {
    is_intersecting: bool,
    intersection_ratio: f64,
    intersection_rect: Rect,
    bounding_client_rect: Rect,
    root_bounds: Rect,
};

// What we report for a target that can't be measured against the root
const not_computed: IntersectionData = .{
    .is_intersecting = false,
    .intersection_ratio = 0,
    .intersection_rect = .{},
    .bounding_client_rect = .{},
    .root_bounds = .{},
};

// Rects are client rects (getBoundingClientRect), moved by the scroll offsets
// of the scroll containers they're in.
fn calculateIntersection(self: *const IntersectionObserver, target: *Element, frame: *Frame) IntersectionData {
    // A display:none target has no box.
    const owner = target.ownerFrame(frame) orelse return not_computed;
    if (!target.asNode().isConnected() or !target.isVisible(frame)) {
        return not_computed;
    }

    // getBoundingClientRect doesn't apply the scroll offsets, Chrome's does
    const target_rect = moved(target.boundingClientRectValuesForVisible(frame), scrolledBy(target, owner));
    // What's left of the target as it's mapped towards the root (null once
    // nothing is), and how far it moved from the target's own client space.
    var visible: ?Rect = target_rect;
    var offset: Point = .{};

    const root_bounds: Rect = blk: {
        if (self._root) |root| {
            // The target must be inside the root, in the same document.
            if (root == target or !root.asNode().contains(target.asNode())) {
                return not_computed;
            }
            if (!root.isVisible(frame)) {
                return not_computed;
            }
            const root_rect = moved(root.boundingClientRectValuesForVisible(frame), scrolledBy(root, owner));
            break :blk self.applyRootMargin(root_rect);
        }

        // The implicit root is the top-level viewport: each frame's viewport
        // clips the target on the way up, and its iframe places it in the
        // parent's client space.
        var current = owner;
        while (current.parent) |parent| {
            const iframe = (current.iframe orelse break).asElement();
            if (visible) |rect| {
                visible = intersect(rect, viewportRect(current));
            }
            if (!iframe.isVisible(parent)) {
                visible = null;
            }
            const origin = iframe.clientOrigin(parent);
            const scrolled = scrolledBy(iframe, parent);
            const step: Point = .{ .x = origin.x - scrolled.x, .y = origin.y - scrolled.y };
            if (visible) |rect| {
                visible = moved(rect, .{ .x = -step.x, .y = -step.y });
            }
            offset = .{ .x = offset.x + step.x, .y = offset.y + step.y };
            current = parent;
        }
        break :blk self.applyRootMargin(viewportRect(current));
    };

    const rect = intersect(visible orelse return notIntersecting(target_rect, root_bounds), root_bounds) orelse {
        return notIntersecting(target_rect, root_bounds);
    };
    const target_area = target_rect.width * target_rect.height;
    return .{
        .is_intersecting = true,
        // a zero-area target that touches the root is fully visible
        .intersection_ratio = if (target_area > 0) (rect.width * rect.height) / target_area else 1,
        // back in the target's client space
        .intersection_rect = .{ .x = rect.x - offset.x, .y = rect.y - offset.y, .width = rect.width, .height = rect.height },
        .bounding_client_rect = target_rect,
        .root_bounds = root_bounds,
    };
}

fn notIntersecting(target_rect: Rect, root_bounds: Rect) IntersectionData {
    return .{
        .is_intersecting = false,
        .intersection_ratio = 0,
        .intersection_rect = .{},
        .bounding_client_rect = target_rect,
        .root_bounds = root_bounds,
    };
}

const Point = struct { x: f64 = 0, y: f64 = 0 };

fn moved(rect: Rect, by: Point) Rect {
    return .{ .x = rect.x - by.x, .y = rect.y - by.y, .width = rect.width, .height = rect.height };
}

// Edge-adjacent rects intersect, with an empty intersection.
fn intersect(a: Rect, b: Rect) ?Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right < left or bottom < top) {
        return null;
    }
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn viewportRect(frame: *Frame) Rect {
    const window = frame.window;
    return .{
        .width = @floatFromInt(window.getInnerWidth(frame)),
        .height = @floatFromInt(window.getInnerHeight(frame)),
    };
}

// How far the scroll containers el is in have scrolled it.
fn scrolledBy(el: *Element, owner: *Frame) Point {
    const positions = &owner.page.element_scroll_positions;
    if (positions.count() == 0) {
        return .{};
    }
    var total: Point = .{};
    var current = el.asNode().parentElement();
    while (current) |ancestor| {
        if (positions.get(ancestor)) |pos| {
            total.x += @floatFromInt(pos.x);
            total.y += @floatFromInt(pos.y);
        }
        current = ancestor.asNode().parentElement();
    }
    return total;
}

// rootMargin grows (or, negative, shrinks) the root's rect; percentages are
// of the root's width for left and right, of its height for top and bottom.
fn applyRootMargin(self: *const IntersectionObserver, rect: Rect) Rect {
    const m = self._root_margin_values;
    const top = resolveMargin(m[0], rect.height);
    const right = resolveMargin(m[1], rect.width);
    const bottom = resolveMargin(m[2], rect.height);
    const left = resolveMargin(m[3], rect.width);
    return .{
        .x = rect.x - left,
        .y = rect.y - top,
        .width = @max(0, rect.width + left + right),
        .height = @max(0, rect.height + top + bottom),
    };
}

fn resolveMargin(margin: Margin, basis: f64) f64 {
    const value: f64 = margin.value;
    return if (margin.percent) value * basis / 100 else value;
}

// The index of the first threshold above the ratio, or the count when none
// is. Not intersecting is 0, whatever the ratio, as Chrome has it.
fn thresholdIndex(self: *const IntersectionObserver, data: IntersectionData) i32 {
    if (!data.is_intersecting) {
        return 0;
    }
    for (self._threshold, 0..) |threshold, i| {
        if (threshold > data.intersection_ratio) {
            return @intCast(i);
        }
    }
    return @intCast(self._threshold.len);
}

fn checkIntersection(self: *IntersectionObserver, target: *Element, observation: *Observation, frame: *Frame) !void {
    if (target.ownerFrame(frame) == null) {
        // A frameless document (DOMParser, createHTMLDocument) isn't rendered:
        // nothing is reported until the target is adopted into one that is.
        return;
    }
    const data = self.calculateIntersection(target, frame);
    const threshold_index = self.thresholdIndex(data);
    // Below the first threshold isn't intersecting, even when the rects touch
    // (w3c/IntersectionObserver#432); the ratio is still reported.
    const is_intersecting = data.is_intersecting and threshold_index > 0;
    if (threshold_index == observation.threshold_index and is_intersecting == observation.is_intersecting) {
        return;
    }
    const first_check = observation.threshold_index == -1;

    const arena = try frame.getArena(.tiny, "IntersectionObserverEntry");
    errdefer arena.release();

    const entry = try arena.create(IntersectionObserverEntry);
    entry.* = .{
        ._rc = .init(1),
        ._arena = arena,
        ._target = target,
        ._time = frame.window._performance.now(),
        ._is_intersecting = is_intersecting,
        ._root_bounds = try DOMRect.create(data.root_bounds, frame._factory),
        ._intersection_rect = try DOMRect.create(data.intersection_rect, frame._factory),
        ._bounding_client_rect = try DOMRect.create(data.bounding_client_rect, frame._factory),
        ._intersection_ratio = data.intersection_ratio,
        ._new_target_intersecting = first_check and is_intersecting,
    };
    try self._pending_entries.append(self._arena.allocator(), entry);
    observation.threshold_index = threshold_index;
    observation.is_intersecting = is_intersecting;
}

/// Whether a pending entry reports a target intersecting on its first check
pub fn reportsNewTargetIntersecting(self: *const IntersectionObserver) bool {
    for (self._pending_entries.items) |entry| {
        if (entry._new_target_intersecting) {
            return true;
        }
    }
    return false;
}

pub fn checkIntersections(self: *IntersectionObserver, frame: *Frame) !void {
    if (self._observing.count() == 0) {
        return;
    }

    // Nothing here runs JS, so no observe/unobserve can move these slices.
    for (self._observing.keys(), self._observing.values()) |target, *observation| {
        try self.checkIntersection(target, observation, frame);
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
    // for the runaway guard (Frame.observers.deliverIntersections)
    _new_target_intersecting: bool,

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

    pub const observe = bridge.fastFunction(IntersectionObserver.observe, .{});
    pub const unobserve = bridge.fastFunction(IntersectionObserver.unobserve, .{});
    pub const disconnect = bridge.fastFunction(IntersectionObserver.disconnect, .{});
    pub const takeRecords = bridge.function(IntersectionObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");

// Infinite scroll gone wrong: the callback observes a fresh sentinel at the top
// of the page, inside the viewport, so it intersects at once and the page never
// settles on its own. Old sentinels stay observed, keeping the observer
// registered on the frame. `deferred` re-observes from a timer, the way a
// fetch-driven pager behaves; otherwise from the callback itself.
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

    try tick(frame);
    try testing.expect(frame._intersection.last_delivery_ms != 0);
}

// Checks run INTERSECTION_CHECK_MS after the change, and nested zero-delay
// timers are clamped to 4ms past a nesting depth of five, so a chain needs real
// time to pass between ticks.
fn tick(frame: *Frame) !void {
    lp.io.sleep(.fromMilliseconds(Frame.observers.INTERSECTION_CHECK_MS), .awake) catch {};
    frame.js.env.runMicrotasks();
    try frame.js.env.runMacrotasks();
}

fn tickUntilDisconnected(frame: *Frame) !void {
    for (0..200) |_| {
        try tick(frame);
        if (!Frame.observers.hasIntersectionObservers(frame)) break;
    }
}

test "WebApi: synchronous IntersectionObserver chain delivers once per check" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // The callback observes the next sentinel right away; it waits for the
    // next rendering opportunity instead of spinning in this checkpoint.
    try observeSentinelChain(frame, false);
    try testing.expectEqual(1, frame._intersection.burst_deliveries);

    try tick(frame);
    try testing.expectEqual(2, frame._intersection.burst_deliveries);
    try testing.expectEqual(true, Frame.observers.hasIntersectionObservers(frame));
}

test "WebApi: synchronous IntersectionObserver chain past the burst limit is disconnected" {
    testing.silenceLog(&.{.frame});

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    try observeSentinelChain(frame, false);
    frame._intersection.burst_deliveries = Frame.observers.INTERSECTION_BURST_LIMIT;
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

    // the timer observes the next sentinel, the check after it delivers
    try tick(frame);
    try tick(frame);

    try testing.expectEqual(true, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(false, frame._intersection.runaway);
    try testing.expectEqual(1, frame._intersection.burst_deliveries);
    try testing.expect(frame._intersection.burst_start_ms > stale_start);
}

test "WebApi: IntersectionObserver targets moving in and out don't count as a runaway" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // A carousel: the same observed slides keep entering and leaving the view.
    _ = try ls.local.exec(
        \\const root = document.documentElement ?? document.appendChild(document.createElement('html'));
        \\const slide = root.appendChild(document.createElement('div'));
        \\slide.style.cssText = 'position: absolute; left: 0; top: 0; width: 100px; height: 100px';
        \\globalThis.entries = 0;
        \\new IntersectionObserver((es) => { entries += es.length; }).observe(slide);
        \\globalThis.turn = () => { slide.style.top = slide.style.top === '0px' ? '5000px' : '0px'; };
    , null);
    try tick(frame);
    try testing.expectEqual(1, frame._intersection.burst_deliveries);

    // A burst older than the limit, still going. Each turn comes from a
    // script, so it's checked at the next frame.
    frame._intersection.burst_start_ms -|= Frame.observers.INTERSECTION_RUNAWAY_MS + 1;
    const attribution = frame.js.attribution;
    for (0..4) |_| {
        const scope = attribution.enter(attribution.begin(.script, .{ .root = true }));
        _ = try ls.local.exec("turn()", null);
        scope.exit();
        try tick(frame);
    }

    try testing.expectEqual(true, Frame.observers.hasIntersectionObservers(frame));
    try testing.expectEqual(false, frame._intersection.runaway);
    try testing.expectEqual(5, try (try ls.local.exec("entries", null)).toU32());
}

test "WebApi: IntersectionObserver checks slow down only for a page that keeps changing" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec("new IntersectionObserver(() => {}).observe(document.createElement('div'))", null);
    try tick(frame);

    const state = &frame._intersection;
    const now = lp.datetime.milliTimestamp(.boot);

    // A one-off change from work that doesn't hold the page's settle (here,
    // none at all) is checked at the next frame, before "done".
    state.check_streak = 0;
    Frame.observers.scheduleIntersectionChecks(frame);
    try testing.expectEqual(true, state.prompt_check_scheduled);
    try testing.expectEqual(true, frame.js.scheduler.blocksCompletion());
    try tick(frame);

    // Checks running back to back: the same change waits for the slow pace,
    // without holding "done".
    state.check_streak = 10;
    state.last_check_ms = now;
    Frame.observers.scheduleIntersectionChecks(frame);
    try testing.expectEqual(false, state.prompt_check_scheduled);
    try testing.expectEqual(true, state.slow_check_scheduled);
    try testing.expectEqual(false, frame.js.scheduler.blocksCompletion());

    // Work that holds the settle is checked at the next frame whatever.
    const attribution = frame.js.attribution;
    const scope = attribution.enter(attribution.begin(.script, .{ .root = true }));
    Frame.observers.scheduleIntersectionChecks(frame);
    scope.exit();
    try testing.expectEqual(true, state.prompt_check_scheduled);
}

test "WebApi: IntersectionObserver" {
    try testing.htmlRunner("intersection_observer", .{});
}

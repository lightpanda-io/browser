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

pub fn registerTypes() []const type {
    return &.{
        ResizeObserver,
        ResizeObserverEntry,
    };
}

pub const ResizeObserver = @This();

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

_arena: Allocator,
_callback: js.Function.Temp,
_observing: std.ArrayList(Observation) = .{},
_pending_entries: std.ArrayList(*ResizeObserverEntry) = .{},
_previous_sizes: std.AutoHashMapUnmanaged(*Element, ObservedSize) = .{},

const Observation = struct {
    target: *Element,
    observed_box: ObservedBox,
};

const ObservedSize = struct {
    inline_size: f64,
    block_size: f64,
};

const ObservedBox = enum {
    content_box,
    border_box,
    device_pixel_content_box,
};

fn init(cbk: js.Function.Temp, page: *Page) !*ResizeObserver {
    const arena = try page.getArena(.{ .debug = "ResizeObserver" });
    errdefer page.releaseArena(arena);

    const self = try arena.create(ResizeObserver);
    self.* = .{
        ._arena = arena,
        ._callback = cbk,
    };
    return self;
}

pub fn deinit(self: *ResizeObserver, shutdown: bool, page: *Page) void {
    page.js.release(self._callback);
    if ((comptime IS_DEBUG) and !shutdown) {
        std.debug.assert(self._observing.items.len == 0);
    }
    page.releaseArena(self._arena);
}

const Options = struct {
    box: ?[]const u8 = null,
};

fn resolveObservedBox(options_: ?Options) ObservedBox {
    const opts = options_ orelse Options{};
    const box = opts.box orelse return .content_box;
    if (std.mem.eql(u8, box, "border-box")) return .border_box;
    if (std.mem.eql(u8, box, "device-pixel-content-box")) return .device_pixel_content_box;
    return .content_box;
}

pub fn observe(self: *ResizeObserver, element: *Element, options_: ?Options, page: *Page) !void {
    const observed_box = resolveObservedBox(options_);

    for (self._observing.items) |*observation| {
        if (observation.target == element) {
            observation.observed_box = observed_box;
            try self.checkObservation(observation.*, page);
            if (self._pending_entries.items.len > 0) {
                try page.scheduleResizeDelivery();
            }
            return;
        }
    }

    if (self._observing.items.len == 0) {
        page.js.strongRef(self);
        try page.registerResizeObserver(self);
    }

    const observation = Observation{
        .target = element,
        .observed_box = observed_box,
    };
    try self._observing.append(self._arena, observation);
    try self.checkObservation(observation, page);
    if (self._pending_entries.items.len > 0) {
        try page.scheduleResizeDelivery();
    }
}

pub fn unobserve(self: *ResizeObserver, element: *Element, page: *Page) void {
    for (self._observing.items, 0..) |observation, i| {
        if (observation.target != element) continue;
        _ = self._observing.swapRemove(i);
        _ = self._previous_sizes.remove(element);

        var j: usize = 0;
        while (j < self._pending_entries.items.len) {
            if (self._pending_entries.items[j]._target == element) {
                const entry = self._pending_entries.swapRemove(j);
                entry.deinit(false, page);
            } else {
                j += 1;
            }
        }
        break;
    }

    if (self._observing.items.len == 0) {
        page.js.safeWeakRef(self);
    }
}

pub fn disconnect(self: *ResizeObserver, page: *Page) void {
    page.unregisterResizeObserver(self);
    self._observing.clearRetainingCapacity();
    self._previous_sizes.clearRetainingCapacity();
    for (self._pending_entries.items) |entry| {
        entry.deinit(false, page);
    }
    self._pending_entries.clearRetainingCapacity();
    page.js.safeWeakRef(self);
}

pub fn takeRecords(self: *ResizeObserver, page: *Page) ![]*ResizeObserverEntry {
    const entries = try page.call_arena.dupe(*ResizeObserverEntry, self._pending_entries.items);
    self._pending_entries.clearRetainingCapacity();
    return entries;
}

fn cssObservedSize(element: *Element, page: *Page) ObservedSize {
    if (!element.asNode().isConnected()) {
        return .{ .inline_size = 0, .block_size = 0 };
    }
    const rect = element.getBoundingClientRect(page);
    return .{
        .inline_size = @max(0.0, rect._width),
        .block_size = @max(0.0, rect._height),
    };
}

fn observedSizeForBox(size: ObservedSize, observed_box: ObservedBox, page: *Page) ObservedSize {
    return switch (observed_box) {
        .content_box, .border_box => size,
        .device_pixel_content_box => .{
            .inline_size = size.inline_size * page.window.getDevicePixelRatio(),
            .block_size = size.block_size * page.window.getDevicePixelRatio(),
        },
    };
}

fn checkObservation(self: *ResizeObserver, observation: Observation, page: *Page) !void {
    const target = observation.target;
    const previous_size = self._previous_sizes.get(target);
    if (!target.asNode().isConnected() and previous_size == null) {
        return;
    }

    const css_size = cssObservedSize(target, page);
    const current_size = observedSizeForBox(css_size, observation.observed_box, page);
    const should_report = previous_size == null or
        previous_size.?.inline_size != current_size.inline_size or
        previous_size.?.block_size != current_size.block_size;

    if (should_report) {
        const arena = try page.getArena(.{ .debug = "ResizeObserverEntry" });
        errdefer page.releaseArena(arena);

        const entry = try arena.create(ResizeObserverEntry);
        entry.* = .{
            ._arena = arena,
            ._target = target,
            ._content_inline_size = css_size.inline_size,
            ._content_block_size = css_size.block_size,
            ._border_inline_size = css_size.inline_size,
            ._border_block_size = css_size.block_size,
            ._device_inline_size = css_size.inline_size * page.window.getDevicePixelRatio(),
            ._device_block_size = css_size.block_size * page.window.getDevicePixelRatio(),
        };
        try self._pending_entries.append(self._arena, entry);
    }

    try self._previous_sizes.put(self._arena, target, current_size);
}

pub fn checkSizes(self: *ResizeObserver, page: *Page) !void {
    if (self._observing.items.len == 0) {
        return;
    }
    for (self._observing.items) |observation| {
        try self.checkObservation(observation, page);
    }
    if (self._pending_entries.items.len > 0) {
        try page.scheduleResizeDelivery();
    }
}

pub fn deliverEntries(self: *ResizeObserver, page: *Page) !void {
    if (self._pending_entries.items.len == 0) {
        return;
    }

    const entries = try self.takeRecords(page);
    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var caught: js.TryCatch.Caught = undefined;
    ls.toLocal(self._callback).tryCall(void, .{ entries, self }, &caught) catch |err| {
        log.err(.page, "ResizeObserver.deliverEntries", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const ResizeObserverEntry = struct {
    _arena: Allocator,
    _target: *Element,
    _content_inline_size: f64,
    _content_block_size: f64,
    _border_inline_size: f64,
    _border_block_size: f64,
    _device_inline_size: f64,
    _device_block_size: f64,

    const SizeValue = struct {
        inlineSize: f64,
        blockSize: f64,
    };

    const RectValue = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        top: f64,
        right: f64,
        bottom: f64,
        left: f64,
    };

    pub fn deinit(self: *const ResizeObserverEntry, _: bool, page: *Page) void {
        page.releaseArena(self._arena);
    }

    pub fn getTarget(self: *const ResizeObserverEntry) *Element {
        return self._target;
    }

    pub fn getContentRect(self: *const ResizeObserverEntry) RectValue {
        return .{
            .x = 0,
            .y = 0,
            .width = self._content_inline_size,
            .height = self._content_block_size,
            .top = 0,
            .right = self._content_inline_size,
            .bottom = self._content_block_size,
            .left = 0,
        };
    }

    pub fn getContentBoxSize(self: *const ResizeObserverEntry) [1]SizeValue {
        return .{.{
            .inlineSize = self._content_inline_size,
            .blockSize = self._content_block_size,
        }};
    }

    pub fn getBorderBoxSize(self: *const ResizeObserverEntry) [1]SizeValue {
        return .{.{
            .inlineSize = self._border_inline_size,
            .blockSize = self._border_block_size,
        }};
    }

    pub fn getDevicePixelContentBoxSize(self: *const ResizeObserverEntry) [1]SizeValue {
        return .{.{
            .inlineSize = self._device_inline_size,
            .blockSize = self._device_block_size,
        }};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverEntry);

        pub const Meta = struct {
            pub const name = "ResizeObserverEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const weak = true;
            pub const finalizer = bridge.finalizer(ResizeObserverEntry.deinit);
        };

        pub const target = bridge.accessor(ResizeObserverEntry.getTarget, null, .{});
        pub const contentRect = bridge.accessor(ResizeObserverEntry.getContentRect, null, .{});
        pub const contentBoxSize = bridge.accessor(ResizeObserverEntry.getContentBoxSize, null, .{});
        pub const borderBoxSize = bridge.accessor(ResizeObserverEntry.getBorderBoxSize, null, .{});
        pub const devicePixelContentBoxSize = bridge.accessor(ResizeObserverEntry.getDevicePixelContentBoxSize, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ResizeObserver);

    pub const Meta = struct {
        pub const name = "ResizeObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(ResizeObserver.deinit);
    };

    pub const constructor = bridge.constructor(ResizeObserver.init, .{});
    pub const observe = bridge.function(ResizeObserver.observe, .{});
    pub const unobserve = bridge.function(ResizeObserver.unobserve, .{});
    pub const disconnect = bridge.function(ResizeObserver.disconnect, .{});
    pub const takeRecords = bridge.function(ResizeObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ResizeObserver" {
    try testing.htmlRunner("resize_observer", .{});
}

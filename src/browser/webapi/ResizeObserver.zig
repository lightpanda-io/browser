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

// We're a headless browser, so this is never goig to be perfect, but we CAN
// correctly deliver some effects, e.g. the initial entry when observe() is
// called and some changes to display or style's width/height.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Element = @import("Element.zig");
const DOMRect = @import("DOMRect.zig");
const Factory = @import("../Factory.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        ResizeObserver,
        ResizeObserverEntry,
        ResizeObserverSize,
    };
}

const ResizeObserver = @This();

_rc: lp.RC = .{},
_arena: Allocator,
_callback: js.Function.Global,
_observations: std.ArrayList(Observation) = .empty,

const Observation = struct {
    target: *Element,
    last_width: f64 = 0,
    last_height: f64 = 0,
};

const Options = struct {
    box: []const u8 = "content-box",
};

pub fn init(callback: js.Function.Global, frame: *Frame) !*ResizeObserver {
    const arena = try frame.getArena(.small, "ResizeObserver");
    errdefer frame.releaseArena(arena);

    const self = try arena.create(ResizeObserver);
    self.* = .{
        ._arena = arena,
        ._callback = callback,
    };
    return self;
}

pub fn deinit(self: *ResizeObserver, page: *Page) void {
    self._callback.release();
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *ResizeObserver) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *ResizeObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub fn observe(self: *ResizeObserver, target: *Element, options_: ?Options, frame: *Frame) !void {
    _ = options_; // Can't make use of this

    for (self._observations.items) |obs| {
        if (obs.target == target) {
            return;
        }
    }

    try self._observations.append(self._arena, .{ .target = target });
    if (self._observations.items.len == 1) {
        try Frame.observers.registerResizeObserver(frame, self);
    }

    Frame.observers.scheduleResizeDelivery(frame);
}

pub fn unobserve(self: *ResizeObserver, target: *Element, frame: *Frame) void {
    for (self._observations.items, 0..) |obs, i| {
        if (obs.target == target) {
            _ = self._observations.swapRemove(i);
            break;
        }
    }

    if (self._observations.items.len == 0) {
        Frame.observers.unregisterResizeObserver(frame, self);
    }
}

pub fn disconnect(self: *ResizeObserver, frame: *Frame) void {
    if (self._observations.items.len == 0) {
        return;
    }
    self._observations.clearRetainingCapacity();
    Frame.observers.unregisterResizeObserver(frame, self);
}

// Gather the observations whose size changed since the last delivery and, if
// any, invoke the callback.
pub fn deliverEntries(self: *ResizeObserver, frame: *Frame) !void {
    var entries: std.ArrayList(*ResizeObserverEntry) = .empty;
    for (self._observations.items) |*obs| {
        const target = obs.target;

        const width, const height = blk: {
            if (obs.target.asNode().isConnected() == false) {
                break :blk .{ 0, 0 };
            }
            break :blk .{ target.getClientWidth(frame), target.getClientHeight(frame) };
        };

        if (width == obs.last_width and height == obs.last_height) {
            continue;
        }
        obs.last_width = width;
        obs.last_height = height;

        const entry = try ResizeObserverEntry.create(obs.target, width, height, frame._factory);
        try entries.append(frame.call_arena, entry);
    }

    if (entries.items.len == 0) {
        return;
    }

    var caught: js.TryCatch.Caught = undefined;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).tryCall(void, .{ entries.items, self }, &caught) catch |err| {
        log.err(.frame, "ResizeObserver.deliverEntries", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const ResizeObserverEntry = struct {
    _target: *Element,
    _content_rect: *DOMRect,
    _box_size: [1]*ResizeObserverSize,

    pub fn create(target: *Element, width: f64, height: f64, factory: *Factory) !*ResizeObserverEntry {
        const content_rect = try DOMRect.create(.{ .width = width, .height = height }, factory);
        const size = try ResizeObserverSize.create(width, height, factory);
        return factory.create(ResizeObserverEntry{
            ._target = target,
            ._content_rect = content_rect,
            ._box_size = .{size},
        });
    }

    pub fn getTarget(self: *const ResizeObserverEntry) *Element {
        return self._target;
    }

    pub fn getContentRect(self: *const ResizeObserverEntry) *DOMRect {
        return self._content_rect;
    }

    pub fn getBorderBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._box_size;
    }

    pub fn getContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._box_size;
    }

    pub fn getDevicePixelContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._box_size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverEntry);

        pub const Meta = struct {
            pub const name = "ResizeObserverEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const target = bridge.accessor(ResizeObserverEntry.getTarget, null, .{});
        pub const contentRect = bridge.accessor(ResizeObserverEntry.getContentRect, null, .{});
        pub const borderBoxSize = bridge.accessor(ResizeObserverEntry.getBorderBoxSize, null, .{});
        pub const contentBoxSize = bridge.accessor(ResizeObserverEntry.getContentBoxSize, null, .{});
        pub const devicePixelContentBoxSize = bridge.accessor(ResizeObserverEntry.getDevicePixelContentBoxSize, null, .{});
    };
};

pub const ResizeObserverSize = struct {
    _inline_size: f64,
    _block_size: f64,

    pub fn create(inline_size: f64, block_size: f64, factory: *Factory) !*ResizeObserverSize {
        return factory.create(ResizeObserverSize{
            ._inline_size = inline_size,
            ._block_size = block_size,
        });
    }

    pub fn getInlineSize(self: *const ResizeObserverSize) f64 {
        return self._inline_size;
    }

    pub fn getBlockSize(self: *const ResizeObserverSize) f64 {
        return self._block_size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverSize);

        pub const Meta = struct {
            pub const name = "ResizeObserverSize";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const inlineSize = bridge.accessor(ResizeObserverSize.getInlineSize, null, .{});
        pub const blockSize = bridge.accessor(ResizeObserverSize.getBlockSize, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ResizeObserver);

    pub const Meta = struct {
        pub const name = "ResizeObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ResizeObserver.init, .{});
    pub const observe = bridge.function(ResizeObserver.observe, .{});
    pub const unobserve = bridge.function(ResizeObserver.unobserve, .{});
    pub const disconnect = bridge.function(ResizeObserver.disconnect, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ResizeObserver" {
    try testing.htmlRunner("resize_observer", .{});
}

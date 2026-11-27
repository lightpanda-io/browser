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
const layout = @import("../layout.zig");
const Factory = @import("../Factory.zig");

const Element = @import("Element.zig");
const DOMRect = @import("DOMRect.zig");

const log = lp.log;

pub fn registerTypes() []const type {
    return &.{
        ResizeObserver,
        ResizeObserverEntry,
        ResizeObserverSize,
    };
}

const ResizeObserver = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_callback: js.Function.Global,
_observations: std.ArrayList(Observation) = .empty,

const Observation = struct {
    target: *Element,
    box: Box,
    // The first delivery _always_ reports, even for a 0x0
    last: Size = .{ .width = -1, .height = -1 },
};

const Box = enum {
    @"content-box",
    @"border-box",
    @"device-pixel-content-box",
};

const Options = struct {
    box: []const u8 = "content-box",
};

const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
};

// TODO: No border (just padding for now)
const Boxes = struct {
    x: f64 = 0,
    y: f64 = 0,
    content: Size = .{},
    border: Size = .{},
    device_pixel: Size = .{},

    fn of(target: *Element, frame: *Frame) Boxes {
        if (!target.asNode().isConnected() or !target.isVisible(frame)) {
            return .{};
        }
        const owner = target.ownerFrame(frame) orelse return .{};
        if (owner._style_manager.isPlainInline(target)) {
            return .{};
        }
        const content: Size = .{
            .width = layout.innerWidth(target, owner),
            .height = layout.innerHeight(target, owner),
        };
        const scale: f64 = frame.page.getViewport().scale;
        return .{
            .x = layout.contentStart(target, .width, owner),
            .y = layout.contentStart(target, .height, owner),
            .content = content,
            .border = .{
                .width = target.boxAxis(frame, .width),
                .height = target.boxAxis(frame, .height),
            },
            .device_pixel = .{
                .width = @round(content.width * scale),
                .height = @round(content.height * scale),
            },
        };
    }

    fn observed(self: *const Boxes, box: Box) Size {
        return switch (box) {
            .@"content-box" => self.content,
            .@"border-box" => self.border,
            .@"device-pixel-content-box" => self.device_pixel,
        };
    }
};

pub fn init(callback: js.Function.Global, frame: *Frame) !*ResizeObserver {
    const arena = try frame.getArena(.small, "ResizeObserver");
    errdefer arena.release();

    const self = try arena.create(ResizeObserver);
    self.* = .{
        ._arena = arena,
        ._callback = callback,
    };
    return self;
}

pub fn deinit(self: *ResizeObserver, _: *Page) void {
    self._callback.release();
    self._arena.release();
}

pub fn acquireRef(self: *ResizeObserver) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *ResizeObserver, page: *Page) void {
    self._rc.release(self, page);
}

pub fn observe(self: *ResizeObserver, target: *Element, options_: ?Options, frame: *Frame) !void {
    const options = options_ orelse Options{};
    const box = std.meta.stringToEnum(Box, options.box) orelse return error.TypeError;

    for (self._observations.items, 0..) |obs, i| {
        if (obs.target == target) {
            // Observing a target again replaces its observation
            _ = self._observations.orderedRemove(i);
            break;
        }
    }

    try self._observations.append(self._arena.allocator(), .{ .target = target, .box = box });
    if (self._observations.items.len == 1) {
        try Frame.observers.registerResizeObserver(frame, self);
    }

    Frame.observers.scheduleResizeChecks(frame);
}

fn unobserve(self: *ResizeObserver, target: *Element, frame: *Frame) void {
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
        const boxes = Boxes.of(obs.target, frame);
        const size = boxes.observed(obs.box);
        if (size.width == obs.last.width and size.height == obs.last.height) {
            continue;
        }
        obs.last = size;

        const entry = try ResizeObserverEntry.create(obs.target, &boxes, frame._factory);
        try entries.append(frame.call_arena, entry);
    }

    if (entries.items.len == 0) {
        return;
    }

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._callback).callWithThisReport(self, .{ entries.items, self }) catch |err| {
        log.debug(.frame, "ResizeObserver.deliverEntries", .{ .err = err });
        return err;
    };
}

pub const ResizeObserverEntry = struct {
    _target: *Element,
    _content_rect: *DOMRect,
    _content_box_size: [1]*ResizeObserverSize,
    _border_box_size: [1]*ResizeObserverSize,
    _device_pixel_content_box_size: [1]*ResizeObserverSize,

    fn create(target: *Element, boxes: *const Boxes, factory: *Factory) !*ResizeObserverEntry {
        const content_rect = try DOMRect.create(.{
            .x = boxes.x,
            .y = boxes.y,
            .width = boxes.content.width,
            .height = boxes.content.height,
        }, factory);
        return factory.create(ResizeObserverEntry{
            ._target = target,
            ._content_rect = content_rect,
            ._content_box_size = .{try ResizeObserverSize.create(boxes.content, factory)},
            ._border_box_size = .{try ResizeObserverSize.create(boxes.border, factory)},
            ._device_pixel_content_box_size = .{try ResizeObserverSize.create(boxes.device_pixel, factory)},
        });
    }

    pub fn getTarget(self: *const ResizeObserverEntry) *Element {
        return self._target;
    }

    fn getContentRect(self: *const ResizeObserverEntry) *DOMRect {
        return self._content_rect;
    }

    fn getBorderBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._border_box_size;
    }

    fn getContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._content_box_size;
    }

    fn getDevicePixelContentBoxSize(self: *const ResizeObserverEntry) []const *ResizeObserverSize {
        return &self._device_pixel_content_box_size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverEntry);

        pub const Meta = struct {
            pub const name = "ResizeObserverEntry";
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

    // No vertical writing modes: inline is width, block is height
    fn create(size: Size, factory: *Factory) !*ResizeObserverSize {
        return factory.create(ResizeObserverSize{
            ._inline_size = size.width,
            ._block_size = size.height,
        });
    }

    fn getInlineSize(self: *const ResizeObserverSize) f64 {
        return self._inline_size;
    }

    fn getBlockSize(self: *const ResizeObserverSize) f64 {
        return self._block_size;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResizeObserverSize);

        pub const Meta = struct {
            pub const name = "ResizeObserverSize";
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

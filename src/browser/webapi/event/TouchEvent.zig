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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const Element = @import("../Element.zig");
const EventTarget = @import("../EventTarget.zig");
const UIEvent = @import("UIEvent.zig");
const Touch = @import("Touch.zig");
const TouchList = @import("TouchList.zig");

const String = lp.String;

// https://w3c.github.io/touch-events/#touchevent-interface
const TouchEvent = @This();

pub const Proto = UIEvent;

_proto: *UIEvent,
_alt_key: bool = false,
_meta_key: bool = false,
_ctrl_key: bool = false,
_shift_key: bool = false,
// The touch input dispatched this event for, whose target dispatch retargets.
_trusted_touch: ?*Touch = null,
// Each entry holds a ref on its Touch, released in deinit.
_touches: []const *Touch = &.{},
_target_touches: []const *Touch = &.{},
_changed_touches: []const *Touch = &.{},
_touches_list: ?*TouchList = null,
_target_touches_list: ?*TouchList = null,
_changed_list: ?*TouchList = null,

const TouchEventOptions = struct {
    altKey: bool = false,
    changedTouches: []const *Touch = &.{},
    ctrlKey: bool = false,
    metaKey: bool = false,
    shiftKey: bool = false,
    targetTouches: []const *Touch = &.{},
    touches: []const *Touch = &.{},
};

pub const Options = Event.inheritOptions(
    TouchEvent,
    TouchEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

/// An event for touch input: its one touch is the changed one, and also the
/// active one unless it's being lifted (touchend, touchcancel).
pub fn initTrustedWithTouch(typ: []const u8, _opts: ?Options, target: *Element, point: Touch.Point, frame: *Frame) !*TouchEvent {
    const event = try initWithTrusted(typ, _opts, true, frame);
    // The lists are replaced below, which would leak refs taken on given ones.
    std.debug.assert(event._touches.len == 0 and event._target_touches.len == 0 and event._changed_touches.len == 0);
    const one = try event.asEvent()._arena.allocator().alloc(*Touch, 1);
    const touch = try Touch.initTrusted(target.asEventTarget(), point, frame);
    one[0] = touch;
    event._trusted_touch = touch;
    event._changed_touches = one;
    touch.acquireRef();
    const lifted = std.mem.eql(u8, typ, "touchend") or std.mem.eql(u8, typ, "touchcancel");
    if (!lifted) {
        event._touches = one;
        event._target_touches = one;
        touch.acquireRef();
        touch.acquireRef();
    }
    return event;
}

fn initWithTrusted(typ: []const u8, _opts: ?Options, trusted: bool, frame: *Frame) !*TouchEvent {
    const arena = try frame.getArena(.tiny, "TouchEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.uiEvent(
        arena,
        type_string,
        TouchEvent{
            ._proto = undefined,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._touches = try arena.allocator().dupe(*Touch, opts.touches),
            ._target_touches = try arena.allocator().dupe(*Touch, opts.targetTouches),
            ._changed_touches = try arena.allocator().dupe(*Touch, opts.changedTouches),
        },
    );

    for ([_][]const *Touch{ event._touches, event._target_touches, event._changed_touches }) |list| {
        for (list) |touch| touch.acquireRef();
    }

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *TouchEvent, page: *Page) void {
    for ([_][]const *Touch{ self._touches, self._target_touches, self._changed_touches }) |list| {
        for (list) |touch| touch.releaseRef(page);
    }
}

pub fn asEvent(self: *TouchEvent) *Event {
    return self._proto.asEvent();
}

/// Only a trusted touch's target is retargeted: one the page put in an event
/// it built keeps the target it was given.
pub fn touchTargetPtr(self: *TouchEvent) ?*?*EventTarget {
    if (self._trusted_touch) |t| return &t._target;
    return null;
}

/// Cached, so repeated reads don't grow the event's arena. touches and
/// targetTouches can hold the same set but keep separate lists: they are
/// distinct objects in real browsers ([SameObject] only ties identity to
/// repeated reads of one attribute).
fn touchList(self: *TouchEvent, touches: []const *Touch, cache: *?*TouchList) !*TouchList {
    if (cache.*) |list| {
        return list;
    }
    const list = try self.asEvent()._arena.create(TouchList);
    list.* = .{ ._event = self, ._touches = touches };
    cache.* = list;
    return list;
}

fn getTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(self._touches, &self._touches_list);
}

fn getTargetTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(self._target_touches, &self._target_touches_list);
}

fn getChangedTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(self._changed_touches, &self._changed_list);
}

pub fn getAltKey(self: *const TouchEvent) bool {
    return self._alt_key;
}

pub fn getMetaKey(self: *const TouchEvent) bool {
    return self._meta_key;
}

pub fn getCtrlKey(self: *const TouchEvent) bool {
    return self._ctrl_key;
}

pub fn getShiftKey(self: *const TouchEvent) bool {
    return self._shift_key;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TouchEvent);

    pub const Meta = struct {
        pub const name = "TouchEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TouchEvent.init, .{});
    pub const touches = bridge.accessor(TouchEvent.getTouches, null, .{});
    pub const targetTouches = bridge.accessor(TouchEvent.getTargetTouches, null, .{});
    pub const changedTouches = bridge.accessor(TouchEvent.getChangedTouches, null, .{});
    pub const altKey = bridge.accessor(TouchEvent.getAltKey, null, .{});
    pub const metaKey = bridge.accessor(TouchEvent.getMetaKey, null, .{});
    pub const ctrlKey = bridge.accessor(TouchEvent.getCtrlKey, null, .{});
    pub const shiftKey = bridge.accessor(TouchEvent.getShiftKey, null, .{});
};

const testing = @import("../../../testing.zig");

test "WebApi: TouchEvent caches its touch lists" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    const target = frame.document.getDocumentElement().?;

    const event = try initTrustedWithTouch("touchstart", null, target, .{ .x = 10, .y = 20 }, frame);
    event.asEvent().acquireRef();
    defer event.asEvent().releaseRef(frame.page);

    try testing.expect(try event.getTouches() == try event.getTouches());
    try testing.expect(try event.getTargetTouches() == try event.getTargetTouches());
    try testing.expect(try event.getChangedTouches() == try event.getChangedTouches());
    try testing.expect(try event.getTouches() != try event.getTargetTouches());
}

test "WebApi: TouchEvent" {
    try testing.htmlRunner("event/touch.html", .{});
}

test "WebApi: TouchEvent releases its touches" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    const target = frame.document.getDocumentElement().?;

    const event = try initTrustedWithTouch("touchstart", null, target, .{ .x = 10, .y = 20 }, frame);
    const touch = event._trusted_touch.?;
    touch.acquireRef();
    defer touch.releaseRef(frame.page);

    // One ref per list, plus ours.
    try testing.expectEqual(4, touch._rc._refs.load(.monotonic));
    try frame._event_manager.dispatch(target.asEventTarget(), event.asEvent());
    try testing.expectEqual(1, touch._rc._refs.load(.monotonic));
}

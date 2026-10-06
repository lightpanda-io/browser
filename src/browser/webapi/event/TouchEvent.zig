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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
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
_touch: ?Touch = null,
_touches_list: ?*TouchList = null,
_target_touches_list: ?*TouchList = null,
_changed_list: ?*TouchList = null,

const TouchEventOptions = struct {
    altKey: bool = false,
    ctrlKey: bool = false,
    metaKey: bool = false,
    shiftKey: bool = false,
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

pub fn initTrustedWithTouch(typ: []const u8, _opts: ?Options, target: *Element, point: Touch.Point, frame: *Frame) !*TouchEvent {
    const event = try initWithTrusted(typ, _opts, true, frame);
    event._touch = .{ ._event = event, ._target = target.asEventTarget(), ._point = point };
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
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *TouchEvent) *Event {
    return self._proto.asEvent();
}

pub fn touchTargetPtr(self: *TouchEvent) ?*?*EventTarget {
    if (self._touch) |*t| return &t._target;
    return null;
}

/// Cached, so repeated reads don't grow the event's arena. touches and
/// targetTouches hold the same set here but keep separate lists: they are
/// distinct objects in real browsers ([SameObject] only ties identity to
/// repeated reads of one attribute).
fn touchList(self: *TouchEvent, active_only: bool, cache: *?*TouchList) !*TouchList {
    if (cache.*) |list| {
        return list;
    }

    const event = self.asEvent();
    // touchend and touchcancel report the lifted contact in changedTouches only.
    const lifted = event._type_string.eql(comptime .wrap("touchend")) or event._type_string.eql(comptime .wrap("touchcancel"));
    const touch: ?*Touch = if (self._touch) |*t| (if (active_only and lifted) null else t) else null;

    const list = try event._arena.create(TouchList);
    list.* = .{ ._event = self, ._touch = touch };
    cache.* = list;
    return list;
}

fn getTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(true, &self._touches_list);
}

fn getTargetTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(true, &self._target_touches_list);
}

fn getChangedTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(false, &self._changed_list);
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
        pub const prototype_chain = bridge.prototypeChain();
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

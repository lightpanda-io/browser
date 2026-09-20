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
//
// The Touch is stored by value and the lists are cached on first read, so
// repeated property reads don't grow the event's arena.
const TouchEvent = @This();

pub const Proto = UIEvent;

_proto: *UIEvent,
_alt_key: bool = false,
_meta_key: bool = false,
_ctrl_key: bool = false,
_shift_key: bool = false,
_touch: ?Touch = null,
_touch_active: bool = false,
_touches_list: ?*TouchList = null,
_target_touches_list: ?*TouchList = null,
_changed_list: ?*TouchList = null,

pub const TouchEventOptions = struct {
    altKey: bool = false,
    ctrlKey: bool = false,
    metaKey: bool = false,
    shiftKey: bool = false,
};

pub const Options = Event.inheritOptions(
    TouchEvent,
    TouchEventOptions,
);

pub const TouchInit = struct {
    identifier: i32 = 0,
    target: *Element,
    clientX: f64,
    clientY: f64,
};

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, false, frame);
}

pub fn initTrusted(typ: []const u8, _opts: ?Options, frame: *Frame) !*TouchEvent {
    return initWithTrusted(typ, _opts, true, frame);
}

// Assigning the touch is a plain value write (no arena allocation), so
// nothing can fail between creating the event and returning it.
pub fn initTrustedWithTouch(typ: []const u8, _opts: ?Options, touch_init: TouchInit, active: bool, frame: *Frame) !*TouchEvent {
    const event = try initWithTrusted(typ, _opts, true, frame);
    event._touch = .{
        ._event = event,
        ._identifier = touch_init.identifier,
        ._target = touch_init.target.asEventTarget(),
        ._client_x = touch_init.clientX,
        ._client_y = touch_init.clientY,
    };
    event._touch_active = active;
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

// The live Touch's target, for EventManager's shadow-retargeting swap
// (mirrors Event.relatedTargetPtr). null when the event carries no touch.
pub fn touchTargetPtr(self: *TouchEvent) ?*?*EventTarget {
    if (self._touch == null) return null;
    return &self._touch.?._target;
}

// touches and targetTouches hold the same set here but keep separate cached
// lists: they are distinct objects in real browsers ([SameObject] only ties
// identity to repeated reads of one attribute).
fn touchList(self: *TouchEvent, active_only: bool, cache: *?*TouchList) !*TouchList {
    if (cache.*) |list| {
        return list;
    }

    const arena = self.asEvent()._arena;
    var touch: ?*Touch = null;
    if (self._touch) |*t| {
        if (!active_only or self._touch_active) {
            touch = t;
        }
    }

    const list = try arena.create(TouchList);
    list.* = .{ ._event = self, ._touch = touch };
    cache.* = list;
    return list;
}

pub fn getTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(true, &self._touches_list);
}

pub fn getTargetTouches(self: *TouchEvent) !*TouchList {
    return self.touchList(true, &self._target_touches_list);
}

pub fn getChangedTouches(self: *TouchEvent) !*TouchList {
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

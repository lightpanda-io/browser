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
const Event = @import("../Event.zig");
const UIEvent = @import("UIEvent.zig");
const EventTarget = @import("../EventTarget.zig");
const Window = @import("../Window.zig");
const Page = @import("../../Page.zig");
const js = @import("../../js/js.zig");

const KeyboardEvent = @This();

_proto: *UIEvent,
_key: Key,
_ctrl_key: bool,
_shift_key: bool,
_alt_key: bool,
_meta_key: bool,
_location: Location,
_repeat: bool,
_is_composing: bool,

// https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values
pub const Key = union(enum) {
    // Special Key Values
    Dead,
    Undefined,
    Alt,
    AltGraph,
    CapsLock,
    Control,
    Fn,
    FnLock,
    Hyper,
    Meta,
    NumLock,
    ScrollLock,
    Shift,
    Super,
    Symbol,
    SymbolLock,
    standard: []const u8,

    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !Key {
        const key_type_info = @typeInfo(Key);
        inline for (key_type_info.@"union".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "standard")) continue;

            if (std.mem.eql(u8, field.name, str)) {
                return @unionInit(Key, field.name, {});
            }
        }

        const duped = try allocator.dupe(u8, str);
        return .{ .standard = duped };
    }
};

pub const Location = enum(i32) {
    DOM_KEY_LOCATION_STANDARD = 0,
    DOM_KEY_LOCATION_LEFT = 1,
    DOM_KEY_LOCATION_RIGHT = 2,
    DOM_KEY_LOCATION_NUMPAD = 3,
};

pub const KeyboardEventOptions = struct {
    key: []const u8 = "",
    // TODO: code but it is not baseline.
    location: i32 = 0,
    repeat: bool = false,
    isComposing: bool = false,
    ctrlKey: bool = false,
    shiftKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
};

pub const Options = Event.inheritOptions(
    KeyboardEvent,
    KeyboardEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*KeyboardEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.uiEvent(
        typ,
        KeyboardEvent{
            ._proto = undefined,
            ._key = try Key.fromString(page.arena, opts.key),
            ._location = std.meta.intToEnum(Location, opts.location) catch return error.TypeError,
            ._repeat = opts.repeat,
            ._is_composing = opts.isComposing,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
        },
    );

    Event.populatePrototypes(event, opts);
    return event;
}

pub fn asEvent(self: *KeyboardEvent) *Event {
    return self._proto.asEvent();
}

pub fn getAltKey(self: *const KeyboardEvent) bool {
    return self._alt_key;
}

pub fn getCtrlKey(self: *const KeyboardEvent) bool {
    return self._ctrl_key;
}

pub fn getIsComposing(self: *const KeyboardEvent) bool {
    return self._is_composing;
}

pub fn getKey(self: *const KeyboardEvent) []const u8 {
    return switch (self._key) {
        .standard => |key| key,
        else => |x| @tagName(x),
    };
}

pub fn getLocation(self: *const KeyboardEvent) i32 {
    return @intFromEnum(self._location);
}

pub fn getMetaKey(self: *const KeyboardEvent) bool {
    return self._meta_key;
}

pub fn getRepeat(self: *const KeyboardEvent) bool {
    return self._repeat;
}

pub fn getShiftKey(self: *const KeyboardEvent) bool {
    return self._shift_key;
}

pub fn getModifierState(self: *const KeyboardEvent, str: []const u8, page: *Page) !bool {
    const key = try Key.fromString(page.arena, str);

    switch (key) {
        .Alt, .AltGraph => return self._alt_key,
        .Shift => return self._shift_key,
        .Control => return self._ctrl_key,
        .Meta => return self._meta_key,
        else => return false,
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(KeyboardEvent);

    pub const Meta = struct {
        pub const name = "KeyboardEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(KeyboardEvent.init, .{});
    pub const altKey = bridge.accessor(KeyboardEvent.getAltKey, null, .{});
    pub const ctrlKey = bridge.accessor(KeyboardEvent.getCtrlKey, null, .{});
    pub const isComposing = bridge.accessor(KeyboardEvent.getIsComposing, null, .{});
    pub const key = bridge.accessor(KeyboardEvent.getKey, null, .{});
    pub const location = bridge.accessor(KeyboardEvent.getLocation, null, .{});
    pub const metaKey = bridge.accessor(KeyboardEvent.getMetaKey, null, .{});
    pub const repeat = bridge.accessor(KeyboardEvent.getRepeat, null, .{});
    pub const shiftKey = bridge.accessor(KeyboardEvent.getShiftKey, null, .{});
    pub const getModifierState = bridge.function(KeyboardEvent.getModifierState, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: KeyboardEvent" {
    try testing.htmlRunner("event/keyboard.html", .{});
}

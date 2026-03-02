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
const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const UIEvent = @import("UIEvent.zig");
const Allocator = std.mem.Allocator;

const KeyboardEvent = @This();

_proto: *UIEvent,
_key: Key,
_code: []const u8,
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
    Unidentified,

    // Modifier Keys
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

    // Whitespace Keys
    Enter,
    Tab,

    // Navigation Keys
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    ArrowUp,
    End,
    Home,
    PageDown,
    PageUp,

    // Editing Keys
    Backspace,
    Clear,
    Copy,
    CrSel,
    Cut,
    Delete,
    EraseEof,
    ExSel,
    Insert,
    Paste,
    Redo,
    Undo,

    // UI Keys
    Accept,
    Again,
    Attn,
    Cancel,
    ContextMenu,
    Escape,
    Execute,
    Find,
    Finish,
    Help,
    Pause,
    Play,
    Props,
    Select,
    ZoomIn,
    ZoomOut,

    // Function Keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    // Printable keys (single character, space, etc.)
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

    /// Returns true if this key represents a printable character that should be
    /// inserted into text input elements. This includes alphanumeric characters,
    /// punctuation, symbols, and space.
    pub fn isPrintable(self: Key) bool {
        return switch (self) {
            .standard => |s| s.len > 0,
            else => false,
        };
    }

    /// Returns the string representation that should be inserted into text input.
    /// For most keys this is just the key itself, but some keys like Enter need
    /// special handling (e.g., newline for textarea, form submission for input).
    pub fn asString(self: Key) []const u8 {
        return switch (self) {
            .standard => |s| s,
            else => |k| @tagName(k),
        };
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
    code: ?[]const u8 = null,
    location: i32 = 0,
    repeat: bool = false,
    isComposing: bool = false,
    ctrlKey: bool = false,
    shiftKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
};

const Options = Event.inheritOptions(
    KeyboardEvent,
    KeyboardEventOptions,
);

pub fn initTrusted(typ: String, _opts: ?Options, page: *Page) !*KeyboardEvent {
    const arena = try page.getArena(.{ .debug = "KeyboardEvent.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, page);
}

pub fn init(typ: []const u8, _opts: ?Options, page: *Page) !*KeyboardEvent {
    const arena = try page.getArena(.{ .debug = "KeyboardEvent" });
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, page);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, page: *Page) !*KeyboardEvent {
    const opts = _opts orelse Options{};

    const event = try page._factory.uiEvent(
        arena,
        typ,
        KeyboardEvent{
            ._proto = undefined,
            ._key = try Key.fromString(arena, opts.key),
            ._location = std.meta.intToEnum(Location, opts.location) catch return error.TypeError,
            ._code = if (opts.code) |c| try arena.dupe(u8, c) else "",
            ._repeat = opts.repeat,
            ._is_composing = opts.isComposing,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *KeyboardEvent, shutdown: bool, page: *Page) void {
    self._proto.deinit(shutdown, page);
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

pub fn getKey(self: *const KeyboardEvent) Key {
    return self._key;
}

pub fn getCode(self: *const KeyboardEvent) []const u8 {
    return self._code;
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

pub fn getModifierState(self: *const KeyboardEvent, str: []const u8) !bool {
    const key = try Key.fromString(self._proto._proto._arena, str);

    switch (key) {
        .Alt, .AltGraph => return self._alt_key,
        .Shift => return self._shift_key,
        .Control => return self._ctrl_key,
        .Meta => return self._meta_key,
        .standard => |s| if (std.mem.eql(u8, s, "Accel")) {
            return self._ctrl_key or self._meta_key;
        },
        else => {},
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(KeyboardEvent);

    pub const Meta = struct {
        pub const name = "KeyboardEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(KeyboardEvent.deinit);
    };

    pub const constructor = bridge.constructor(KeyboardEvent.init, .{});
    pub const altKey = bridge.accessor(KeyboardEvent.getAltKey, null, .{});
    pub const ctrlKey = bridge.accessor(KeyboardEvent.getCtrlKey, null, .{});
    pub const isComposing = bridge.accessor(KeyboardEvent.getIsComposing, null, .{});
    pub const key = bridge.accessor(struct {
        fn keyAsString(self: *const KeyboardEvent) []const u8 {
            return self._key.asString();
        }
    }.keyAsString, null, .{});
    pub const code = bridge.accessor(KeyboardEvent.getCode, null, .{});
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

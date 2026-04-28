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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const UIEvent = @import("UIEvent.zig");

const String = lp.String;
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

    /// Legacy `KeyboardEvent.keyCode` value per UI Events spec § Annex C
    /// (https://www.w3.org/TR/uievents/#legacy-key-attributes). Returns 0 for
    /// keys without a defined fixed virtual key code.
    ///
    /// Spec note: for printable characters, `keyCode` is calculated from the
    /// **unmodified** key value's uppercase ASCII. We don't track the
    /// unmodified key, so we uppercase `_key` instead. This is exact for
    /// letters (uppercase('t') == uppercase('T')) and digits, but for
    /// shift-modified symbols (e.g., shift+1='!') it returns the modified
    /// char's ASCII rather than the digit's keyCode. Callers needing
    /// spec-strict behavior should pass `unmodifiedText` through CDP
    /// `Input.dispatchKeyEvent` and use that instead.
    pub fn keyCode(self: Key) u32 {
        return switch (self) {
            // Modifier keys
            .Alt, .AltGraph => 18,
            .CapsLock => 20,
            .Control => 17,
            .Meta, .Hyper, .Super => 91,
            .NumLock => 144,
            .ScrollLock => 145,
            .Shift => 16,

            // Whitespace keys (Space hits the .standard path below)
            .Enter => 13,
            .Tab => 9,

            // Navigation keys
            .ArrowDown => 40,
            .ArrowLeft => 37,
            .ArrowRight => 39,
            .ArrowUp => 38,
            .End => 35,
            .Home => 36,
            .PageDown => 34,
            .PageUp => 33,

            // Editing keys
            .Backspace => 8,
            .Clear => 12,
            .Delete => 46,
            .Insert => 45,

            // UI keys
            .Cancel => 3,
            .ContextMenu => 93,
            .Escape => 27,
            .Execute => 43,
            .Help => 47,
            .Pause => 19,
            .Select => 41,

            // Function keys
            .F1 => 112,
            .F2 => 113,
            .F3 => 114,
            .F4 => 115,
            .F5 => 116,
            .F6 => 117,
            .F7 => 118,
            .F8 => 119,
            .F9 => 120,
            .F10 => 121,
            .F11 => 122,
            .F12 => 123,

            .standard => |s| {
                if (s.len == 0) return 0;
                const c = s[0];
                // Letters: uppercase ASCII
                if (c >= 'a' and c <= 'z') return c - 'a' + 'A';
                if (c >= 'A' and c <= 'Z') return c;
                // Digits: ASCII
                if (c >= '0' and c <= '9') return c;
                // Space: 32 — also returned via the ASCII fall-through below,
                // but called out for clarity since it's the most common case.
                if (c == ' ') return 32;
                // Other ASCII chars (best-effort: legacy keyCode for symbols
                // is platform-specific and depends on the unmodified key,
                // which we don't track).
                return c;
            },

            // Keys without a defined legacy keyCode
            else => 0,
        };
    }

    /// Legacy `KeyboardEvent.charCode` value per UI Events spec § Annex C
    /// (https://www.w3.org/TR/uievents/#legacy-key-attributes). Returns the
    /// Unicode code point of the character produced by the key. Only
    /// meaningful inside a `keypress` event — callers must gate accordingly.
    pub fn charCode(self: Key) u32 {
        return switch (self) {
            .Enter => 13,
            .standard => |s| if (s.len > 0) s[0] else 0,
            else => 0,
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

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*KeyboardEvent {
    const arena = try frame.getArena(.tiny, "KeyboardEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*KeyboardEvent {
    const arena = try frame.getArena(.tiny, "KeyboardEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*KeyboardEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
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

    // https://w3c.github.io/uievents/#event-type-keyup
    const rootevt = event._proto._proto;
    rootevt._bubbles = true;
    rootevt._cancelable = true;
    rootevt._composed = true;

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

// https://www.w3.org/TR/uievents/#dom-keyboardevent-charcode
// charCode is the Unicode code point of the character produced by the key,
// and is only meaningful on `keypress` events. For `keydown` and `keyup` it
// is 0. (Deprecated, but read by legacy event handlers.)
//
// Chrome returns 0 for synthetic events (those created via
// `new KeyboardEvent(...)` rather than dispatched by the user agent), so we
// gate on `_is_trusted` to match.
pub fn getCharCode(self: *const KeyboardEvent) u32 {
    const event = self._proto._proto;
    if (event._is_trusted == false) return 0;
    if (event._type_string.eql(comptime .wrap("keypress")) == false) return 0;
    return self._key.charCode();
}

// https://www.w3.org/TR/uievents/#dom-keyboardevent-keycode
//
// As with `charCode`, Chrome returns 0 for synthetic events.
pub fn getKeyCode(self: *const KeyboardEvent) u32 {
    if (self._proto._proto._is_trusted == false) return 0;
    return self._key.keyCode();
}

pub fn initKeyboardEvent(
    self: *KeyboardEvent,
    typ: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    view: ?*@import("../Window.zig"),
    key: ?[]const u8,
    location: ?u32,
    ctrl_key: ?bool,
    alt_key: ?bool,
    shift_key: ?bool,
    meta_key: ?bool,
) !void {
    const ui = self._proto;
    const event = ui._proto;
    if (event._event_phase != .none) {
        return;
    }

    const arena = event._arena;
    event._type_string = try String.init(arena, typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    ui._view = view;
    self._key = try Key.fromString(arena, key orelse "");
    self._location = std.meta.intToEnum(Location, location orelse 0) catch return error.TypeError;
    self._ctrl_key = ctrl_key orelse false;
    self._alt_key = alt_key orelse false;
    self._shift_key = shift_key orelse false;
    self._meta_key = meta_key orelse false;
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
    pub const charCode = bridge.accessor(KeyboardEvent.getCharCode, null, .{});
    pub const keyCode = bridge.accessor(KeyboardEvent.getKeyCode, null, .{});
    pub const getModifierState = bridge.function(KeyboardEvent.getModifierState, .{});
    pub const initKeyboardEvent = bridge.function(KeyboardEvent.initKeyboardEvent, .{});

    pub const DOM_KEY_LOCATION_STANDARD = bridge.property(@intFromEnum(Location.DOM_KEY_LOCATION_STANDARD), .{ .template = true });
    pub const DOM_KEY_LOCATION_LEFT = bridge.property(@intFromEnum(Location.DOM_KEY_LOCATION_LEFT), .{ .template = true });
    pub const DOM_KEY_LOCATION_RIGHT = bridge.property(@intFromEnum(Location.DOM_KEY_LOCATION_RIGHT), .{ .template = true });
    pub const DOM_KEY_LOCATION_NUMPAD = bridge.property(@intFromEnum(Location.DOM_KEY_LOCATION_NUMPAD), .{ .template = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: KeyboardEvent" {
    try testing.htmlRunner("event/keyboard.html", .{});
}

test "KeyboardEvent: Key.keyCode mapping" {
    // Letters: uppercase ASCII regardless of case.
    try testing.expectEqual(@as(u32, 65), Key.keyCode(.{ .standard = "a" }));
    try testing.expectEqual(@as(u32, 65), Key.keyCode(.{ .standard = "A" }));
    try testing.expectEqual(@as(u32, 84), Key.keyCode(.{ .standard = "T" }));
    try testing.expectEqual(@as(u32, 90), Key.keyCode(.{ .standard = "z" }));

    // Digits.
    try testing.expectEqual(@as(u32, 48), Key.keyCode(.{ .standard = "0" }));
    try testing.expectEqual(@as(u32, 53), Key.keyCode(.{ .standard = "5" }));
    try testing.expectEqual(@as(u32, 57), Key.keyCode(.{ .standard = "9" }));

    // Space.
    try testing.expectEqual(@as(u32, 32), Key.keyCode(.{ .standard = " " }));

    // Modifier keys.
    try testing.expectEqual(@as(u32, 16), Key.keyCode(.Shift));
    try testing.expectEqual(@as(u32, 17), Key.keyCode(.Control));
    try testing.expectEqual(@as(u32, 18), Key.keyCode(.Alt));
    try testing.expectEqual(@as(u32, 91), Key.keyCode(.Meta));
    try testing.expectEqual(@as(u32, 20), Key.keyCode(.CapsLock));

    // Whitespace keys.
    try testing.expectEqual(@as(u32, 13), Key.keyCode(.Enter));
    try testing.expectEqual(@as(u32, 9), Key.keyCode(.Tab));

    // Navigation keys.
    try testing.expectEqual(@as(u32, 37), Key.keyCode(.ArrowLeft));
    try testing.expectEqual(@as(u32, 38), Key.keyCode(.ArrowUp));
    try testing.expectEqual(@as(u32, 39), Key.keyCode(.ArrowRight));
    try testing.expectEqual(@as(u32, 40), Key.keyCode(.ArrowDown));
    try testing.expectEqual(@as(u32, 33), Key.keyCode(.PageUp));
    try testing.expectEqual(@as(u32, 34), Key.keyCode(.PageDown));
    try testing.expectEqual(@as(u32, 35), Key.keyCode(.End));
    try testing.expectEqual(@as(u32, 36), Key.keyCode(.Home));

    // Editing keys.
    try testing.expectEqual(@as(u32, 8), Key.keyCode(.Backspace));
    try testing.expectEqual(@as(u32, 46), Key.keyCode(.Delete));
    try testing.expectEqual(@as(u32, 45), Key.keyCode(.Insert));

    // UI keys.
    try testing.expectEqual(@as(u32, 27), Key.keyCode(.Escape));
    try testing.expectEqual(@as(u32, 19), Key.keyCode(.Pause));
    try testing.expectEqual(@as(u32, 93), Key.keyCode(.ContextMenu));

    // Function keys.
    try testing.expectEqual(@as(u32, 112), Key.keyCode(.F1));
    try testing.expectEqual(@as(u32, 123), Key.keyCode(.F12));

    // Keys without a defined fixed virtual key code.
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.Dead));
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.Unidentified));
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.{ .standard = "" }));
}

test "KeyboardEvent: Key.charCode mapping" {
    // Printable characters: Unicode code point of the first byte.
    try testing.expectEqual(@as(u32, 97), Key.charCode(.{ .standard = "a" }));
    try testing.expectEqual(@as(u32, 65), Key.charCode(.{ .standard = "A" }));
    try testing.expectEqual(@as(u32, 48), Key.charCode(.{ .standard = "0" }));
    try testing.expectEqual(@as(u32, 32), Key.charCode(.{ .standard = " " }));

    // Enter is the one named key that produces a charCode (\r = 13).
    try testing.expectEqual(@as(u32, 13), Key.charCode(.Enter));

    // Other named keys and the empty standard key produce no character.
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Tab));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Escape));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.ArrowLeft));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Shift));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.{ .standard = "" }));
}

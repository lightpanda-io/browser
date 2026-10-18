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

const KeyboardEvent = @This();

pub const Proto = UIEvent;

_proto: *UIEvent,
_key: Key,
_code: []const u8,
_ctrl_key: bool,
_shift_key: bool,
_alt_key: bool,
_meta_key: bool,
// Per spec an unsigned long; the Location enum only names the
// DOM_KEY_LOCATION_* constants, any value is allowed.
_location: u32,
_repeat: bool,
_is_composing: bool,
// Legacy KeyboardEventInit values, reported as-is by synthetic events. On a
// trusted keydown or keyup, `_key_code_init` is the virtual key code the user
// agent got with the key (CDP `windowsVirtualKeyCode`), 0 when there is none.
_char_code_init: u32 = 0,
_key_code_init: u32 = 0,

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
        inline for (key_type_info.@"union".field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "standard")) continue;

            if (std.mem.eql(u8, field_name, str)) {
                return @unionInit(Key, field_name, {});
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
    /// A printable character gets the virtual key code of the key that
    /// produces it on a US layout (Annex C, "Optionally fixed virtual key
    /// codes"): letters their uppercase ASCII, '!' the code of '1' (49), '.'
    /// and '>' 190. Never the character's own code: for punctuation that is
    /// another key's code ('.' is 46, Delete; '%' 37, ArrowLeft). Characters
    /// outside the US layout get 0. Only used when neither the client's
    /// virtual key code nor `code` gives the key, see `getKeyCode`.
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
                if (s.len != 1) return 0;
                const c = s[0];
                return switch (c) {
                    'a'...'z' => c - 'a' + 'A',
                    'A'...'Z', '0'...'9', ' ' => c,
                    // Shifted digits.
                    ')' => '0',
                    '!' => '1',
                    '@' => '2',
                    '#' => '3',
                    '$' => '4',
                    '%' => '5',
                    '^' => '6',
                    '&' => '7',
                    '*' => '8',
                    '(' => '9',
                    ';', ':' => 186,
                    '=', '+' => 187,
                    ',', '<' => 188,
                    '-', '_' => 189,
                    '.', '>' => 190,
                    '/', '?' => 191,
                    '`', '~' => 192,
                    '[', '{' => 219,
                    '\\', '|' => 220,
                    ']', '}' => 221,
                    '\'', '"' => 222,
                    else => 0,
                };
            },

            // Keys without a defined legacy keyCode
            else => 0,
        };
    }

    /// Legacy `keyCode` of a printable key from its `KeyboardEvent.code`, the
    /// physical key, as Chrome's US layout gives it. Unlike `keyCode`, this
    /// tells the numpad keys from the main ones ('-' is 109 on the numpad, 189
    /// otherwise). Null for codes without a printable key.
    pub fn keyCodeFromCode(code: []const u8) ?u32 {
        if (code.len == 4 and std.mem.startsWith(u8, code, "Key")) {
            const c = code[3];
            return if (c >= 'A' and c <= 'Z') c else null;
        }
        if (code.len == 6 and std.mem.startsWith(u8, code, "Digit")) {
            const c = code[5];
            return if (c >= '0' and c <= '9') c else null;
        }
        if (code.len == 7 and std.mem.startsWith(u8, code, "Numpad")) {
            const c = code[6];
            return if (c >= '0' and c <= '9') 96 + @as(u32, c - '0') else null;
        }
        const map = std.StaticStringMap(u32).initComptime(.{
            .{ "Space", 32 },
            .{ "Semicolon", 186 },
            .{ "Equal", 187 },
            .{ "Comma", 188 },
            .{ "Minus", 189 },
            .{ "Period", 190 },
            .{ "Slash", 191 },
            .{ "Backquote", 192 },
            .{ "BracketLeft", 219 },
            .{ "Backslash", 220 },
            .{ "BracketRight", 221 },
            .{ "Quote", 222 },
            .{ "IntlBackslash", 226 },
            .{ "NumpadMultiply", 106 },
            .{ "NumpadAdd", 107 },
            .{ "NumpadSubtract", 109 },
            .{ "NumpadDecimal", 110 },
            .{ "NumpadDivide", 111 },
        });
        return map.get(code);
    }

    /// Legacy `KeyboardEvent.charCode` value per UI Events spec § Annex C
    /// (https://www.w3.org/TR/uievents/#legacy-key-attributes). Returns the
    /// Unicode code point of the character produced by the key. Only
    /// meaningful inside a `keypress` event — callers must gate accordingly.
    pub fn charCode(self: Key) u32 {
        return switch (self) {
            .Enter => 13,
            .standard => |s| {
                if (s.len == 0) return 0;
                const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
                if (s.len < len) return 0;
                return std.unicode.utf8Decode(s[0..len]) catch 0;
            },
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

const KeyboardEventOptions = struct {
    altKey: bool = false,
    charCode: u32 = 0,
    code: ?[]const u8 = null,
    ctrlKey: bool = false,
    isComposing: bool = false,
    key: []const u8 = "",
    keyCode: u32 = 0,
    location: u32 = 0,
    metaKey: bool = false,
    repeat: bool = false,
    shiftKey: bool = false,
};

pub const Options = Event.inheritOptions(
    KeyboardEvent,
    KeyboardEventOptions,
);

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*KeyboardEvent {
    const arena = try frame.getArena(.tiny, "KeyboardEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, _opts, true, frame);
}

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*KeyboardEvent {
    const arena = try frame.getArena(.tiny, "KeyboardEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*KeyboardEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
        arena,
        typ,
        KeyboardEvent{
            ._proto = undefined,
            ._key = try Key.fromString(arena.allocator(), opts.key),
            ._location = opts.location,
            ._code = if (opts.code) |c| try arena.dupe(u8, c) else "",
            ._repeat = opts.repeat,
            ._is_composing = opts.isComposing,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._char_code_init = opts.charCode,
            ._key_code_init = opts.keyCode,
        },
    );

    Event.populatePrototypes(event, opts, trusted);

    if (trusted) {
        // Browser-generated key events bubble, are cancelable and composed:
        // https://w3c.github.io/uievents/#event-type-keyup
        // Synthetic ones follow the EventInit dictionary defaults.
        const rootevt = event._proto._proto;
        rootevt._bubbles = true;
        rootevt._cancelable = true;
        rootevt._composed = true;
    }

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

fn getIsComposing(self: *const KeyboardEvent) bool {
    return self._is_composing;
}

pub fn getKey(self: *const KeyboardEvent) Key {
    return self._key;
}

fn getCode(self: *const KeyboardEvent) []const u8 {
    return self._code;
}

pub fn getLocation(self: *const KeyboardEvent) u32 {
    return self._location;
}

pub fn getMetaKey(self: *const KeyboardEvent) bool {
    return self._meta_key;
}

fn getRepeat(self: *const KeyboardEvent) bool {
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
fn getCharCode(self: *const KeyboardEvent) u32 {
    const event = self._proto._proto;
    // Synthetic events report the (legacy) KeyboardEventInit value.
    if (event._is_trusted == false) return self._char_code_init;
    if (event._type_string.eql(comptime .wrap("keypress")) == false) return 0;
    return self._key.charCode();
}

// https://www.w3.org/TR/uievents/#dom-keyboardevent-keycode
//
// As with `charCode`, Chrome returns 0 for synthetic events.
//
// For a trusted `keypress` it is the character's code point, like `charCode`.
// For `keydown` and `keyup` it is the virtual key code the user agent got with
// the key (CDP `windowsVirtualKeyCode`), when there is one, as in Chrome.
// Otherwise it comes from `code`, then from `key`.
pub fn getKeyCode(self: *const KeyboardEvent) u32 {
    const event = self._proto._proto;
    // Synthetic events report the (legacy) KeyboardEventInit value.
    if (event._is_trusted == false) return self._key_code_init;
    if (event._type_string.eql(comptime .wrap("keypress"))) return self._key.charCode();
    // For a trusted event, a virtual key code from the user agent.
    if (self._key_code_init != 0) return self._key_code_init;
    if (self._key == .standard) {
        if (Key.keyCodeFromCode(self._code)) |key_code| return key_code;
    }
    return self._key.keyCode();
}

fn initKeyboardEvent(
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
    event._initialized = true;
    event._type_string = try String.init(arena.allocator(), typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    ui._view = view;
    self._key = try Key.fromString(arena.allocator(), key orelse "");
    self._location = location orelse 0;
    self._ctrl_key = ctrl_key orelse false;
    self._alt_key = alt_key orelse false;
    self._shift_key = shift_key orelse false;
    self._meta_key = meta_key orelse false;
}

fn getModifierState(self: *const KeyboardEvent, str: []const u8) !bool {
    const key = try Key.fromString(self._proto._proto._arena.allocator(), str);

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

    pub const DOM_KEY_LOCATION_STANDARD = bridge.property(@backingInt(Location.DOM_KEY_LOCATION_STANDARD), .{ .template = true });
    pub const DOM_KEY_LOCATION_LEFT = bridge.property(@backingInt(Location.DOM_KEY_LOCATION_LEFT), .{ .template = true });
    pub const DOM_KEY_LOCATION_RIGHT = bridge.property(@backingInt(Location.DOM_KEY_LOCATION_RIGHT), .{ .template = true });
    pub const DOM_KEY_LOCATION_NUMPAD = bridge.property(@backingInt(Location.DOM_KEY_LOCATION_NUMPAD), .{ .template = true });
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

    // Punctuation: the US layout key that produces it, never the character's
    // own code, which is another key's code ('.' is 46, Delete).
    try testing.expectEqual(@as(u32, 190), Key.keyCode(.{ .standard = "." }));
    try testing.expectEqual(@as(u32, 190), Key.keyCode(.{ .standard = ">" }));
    try testing.expectEqual(@as(u32, 188), Key.keyCode(.{ .standard = "," }));
    try testing.expectEqual(@as(u32, 189), Key.keyCode(.{ .standard = "-" }));
    try testing.expectEqual(@as(u32, 187), Key.keyCode(.{ .standard = "+" }));
    try testing.expectEqual(@as(u32, 186), Key.keyCode(.{ .standard = ";" }));
    try testing.expectEqual(@as(u32, 191), Key.keyCode(.{ .standard = "?" }));
    try testing.expectEqual(@as(u32, 192), Key.keyCode(.{ .standard = "~" }));
    try testing.expectEqual(@as(u32, 219), Key.keyCode(.{ .standard = "[" }));
    try testing.expectEqual(@as(u32, 220), Key.keyCode(.{ .standard = "|" }));
    try testing.expectEqual(@as(u32, 221), Key.keyCode(.{ .standard = "}" }));
    try testing.expectEqual(@as(u32, 222), Key.keyCode(.{ .standard = "'" }));
    try testing.expectEqual(@as(u32, 49), Key.keyCode(.{ .standard = "!" }));
    try testing.expectEqual(@as(u32, 53), Key.keyCode(.{ .standard = "%" }));
    try testing.expectEqual(@as(u32, 55), Key.keyCode(.{ .standard = "&" }));
    try testing.expectEqual(@as(u32, 57), Key.keyCode(.{ .standard = "(" }));
    try testing.expectEqual(@as(u32, 48), Key.keyCode(.{ .standard = ")" }));

    // Characters outside the US layout have no fixed virtual key code.
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.{ .standard = "ж" }));
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.{ .standard = "€" }));
    try testing.expectEqual(@as(u32, 0), Key.keyCode(.{ .standard = "ab" }));

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

test "KeyboardEvent: Key.keyCodeFromCode mapping" {
    try testing.expectEqual(@as(?u32, 65), Key.keyCodeFromCode("KeyA"));
    try testing.expectEqual(@as(?u32, 90), Key.keyCodeFromCode("KeyZ"));
    try testing.expectEqual(@as(?u32, 48), Key.keyCodeFromCode("Digit0"));
    try testing.expectEqual(@as(?u32, 57), Key.keyCodeFromCode("Digit9"));
    try testing.expectEqual(@as(?u32, 32), Key.keyCodeFromCode("Space"));
    try testing.expectEqual(@as(?u32, 190), Key.keyCodeFromCode("Period"));
    try testing.expectEqual(@as(?u32, 186), Key.keyCodeFromCode("Semicolon"));
    try testing.expectEqual(@as(?u32, 222), Key.keyCodeFromCode("Quote"));
    try testing.expectEqual(@as(?u32, 96), Key.keyCodeFromCode("Numpad0"));
    try testing.expectEqual(@as(?u32, 105), Key.keyCodeFromCode("Numpad9"));
    try testing.expectEqual(@as(?u32, 106), Key.keyCodeFromCode("NumpadMultiply"));
    try testing.expectEqual(@as(?u32, 109), Key.keyCodeFromCode("NumpadSubtract"));
    try testing.expectEqual(@as(?u32, 110), Key.keyCodeFromCode("NumpadDecimal"));
    try testing.expectEqual(@as(?u32, 111), Key.keyCodeFromCode("NumpadDivide"));
    try testing.expectEqual(@as(?u32, null), Key.keyCodeFromCode(""));
    try testing.expectEqual(@as(?u32, null), Key.keyCodeFromCode("Key"));
    try testing.expectEqual(@as(?u32, null), Key.keyCodeFromCode("KeyAB"));
    try testing.expectEqual(@as(?u32, null), Key.keyCodeFromCode("Unknown"));
}

test "KeyboardEvent: Key.charCode mapping" {
    // Printable characters: Unicode code point of the character.
    try testing.expectEqual(@as(u32, 97), Key.charCode(.{ .standard = "a" }));
    try testing.expectEqual(@as(u32, 65), Key.charCode(.{ .standard = "A" }));
    try testing.expectEqual(@as(u32, 48), Key.charCode(.{ .standard = "0" }));
    try testing.expectEqual(@as(u32, 32), Key.charCode(.{ .standard = " " }));
    try testing.expectEqual(@as(u32, 46), Key.charCode(.{ .standard = "." }));
    try testing.expectEqual(@as(u32, 1078), Key.charCode(.{ .standard = "ж" }));
    try testing.expectEqual(@as(u32, 1105), Key.charCode(.{ .standard = "ё" }));
    try testing.expectEqual(@as(u32, 8364), Key.charCode(.{ .standard = "€" }));
    try testing.expectEqual(@as(u32, 128512), Key.charCode(.{ .standard = "\u{1F600}" }));

    // Enter is the one named key that produces a charCode (\r = 13).
    try testing.expectEqual(@as(u32, 13), Key.charCode(.Enter));

    // Other named keys and the empty standard key produce no character.
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Tab));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Escape));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.ArrowLeft));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.Shift));
    try testing.expectEqual(@as(u32, 0), Key.charCode(.{ .standard = "" }));
}

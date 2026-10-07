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

// WebDriver's key table and key events, shared by BiDi, testdriver and the
// agent's press.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const Element = @import("../webapi/Element.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
const user_input = @import("user_input.zig");

const Modifiers = user_input.Modifiers;

pub const Direction = enum { down, up };

pub fn keyAction(frame: *Frame, cp: u21, direction: Direction, modifiers: *Modifiers) !void {
    const info = webdriverKey(cp, modifiers.shift);
    // A modifier's own keydown already carries its flag; its keyup no longer
    // does.
    setModifier(modifiers, info.modifier, direction == .down);
    return dispatch(frame, null, direction, &info, modifiers);
}

/// Without a `target`, each event goes to the element focused at that moment:
/// a key's default action can move focus.
pub fn dispatch(frame: *Frame, target: ?*Element, direction: Direction, info: *const KeyInfo, modifiers: *const Modifiers) !void {
    var buf: [4]u8 = undefined;
    const name: []const u8 = switch (info.key) {
        .name => |n| n,
        .char => |cp| buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable],
    };
    const typ: lp.String = switch (direction) {
        .down => comptime .wrap("keydown"),
        .up => comptime .wrap("keyup"),
    };
    const event = try KeyboardEvent.initTrusted(typ, .{
        .key = name,
        .code = info.code,
        .location = info.location,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.ctrl,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
    }, frame);
    const text = user_input.textForKey(event);
    switch (direction) {
        .down => _ = try if (target) |t| user_input.pressKey(frame, t, event, text) else user_input.triggerKeyDown(frame, event, text),
        .up => try if (target) |t| frame._event_manager.dispatch(t.asEventTarget(), event.asEvent()) else user_input.triggerKeyUp(frame, event),
    }
}

pub fn singleCodepoint(value: []const u8) ?u21 {
    if (value.len == 0) {
        return null;
    }
    const len = std.unicode.utf8ByteSequenceLength(value[0]) catch return null;
    if (value.len != len) {
        return null;
    }
    return std.unicode.utf8Decode(value) catch null;
}

fn setModifier(modifiers: *Modifiers, which: ?Modifier, down: bool) void {
    switch (which orelse return) {
        .alt => modifiers.alt = down,
        .ctrl => modifiers.ctrl = down,
        .meta => modifiers.meta = down,
        .shift => modifiers.shift = down,
    }
}

pub const Modifier = enum { alt, ctrl, meta, shift };

pub const KeyInfo = struct {
    // a named key, or the character itself
    key: union(enum) { name: []const u8, char: u21 },
    code: []const u8,
    location: u32 = 0,
    modifier: ?Modifier = null,
};

// WebDriver's key table: the Private Use Area - names the
// non-printing keys, anything else is the character itself.
// https://w3c.github.io/webdriver/#keyboard-actions
pub fn webdriverKey(cp: u21, shift: bool) KeyInfo {
    if (cp >= 0xE000 and cp <= 0xE05D) {
        return specialKey(cp);
    }

    const char: u21 = if (shift and cp < 128) shiftedAscii(@intCast(cp)) else cp;
    return .{ .key = .{ .char = char }, .code = asciiCode(cp) };
}

/// Where the numpad shares a name, the main-keyboard key wins.
pub fn named(name: []const u8) KeyInfo {
    if (singleCodepoint(name)) |cp| {
        return webdriverKey(cp, false);
    }
    var cp: u21 = 0xE000;
    while (cp <= 0xE05D) : (cp += 1) {
        const info = specialKey(cp);
        if (std.ascii.eqlIgnoreCase(info.key.name, name)) {
            return info;
        }
    }
    return .{ .key = .{ .name = name }, .code = "" };
}

fn specialKey(cp: u21) KeyInfo {
    const k = struct {
        fn k(key: []const u8, code: []const u8) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code };
        }
        fn m(key: []const u8, code: []const u8, location: u32, modifier: Modifier) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code, .location = location, .modifier = modifier };
        }
        fn n(key: []const u8, code: []const u8) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code, .location = 3 };
        }
    };
    return switch (cp) {
        0xE000 => k.k("Unidentified", ""),
        0xE001 => k.k("Cancel", "Abort"),
        0xE002 => k.k("Help", "Help"),
        0xE003 => k.k("Backspace", "Backspace"),
        0xE004 => k.k("Tab", "Tab"),
        0xE005 => k.k("Clear", "NumLock"),
        0xE006 => k.k("Enter", "Enter"),
        0xE007 => k.n("Enter", "NumpadEnter"),
        0xE008 => k.m("Shift", "ShiftLeft", 1, .shift),
        0xE009 => k.m("Control", "ControlLeft", 1, .ctrl),
        0xE00A => k.m("Alt", "AltLeft", 1, .alt),
        0xE00B => k.k("Pause", "Pause"),
        0xE00C => k.k("Escape", "Escape"),
        0xE00D => k.k(" ", "Space"),
        0xE00E => k.k("PageUp", "PageUp"),
        0xE00F => k.k("PageDown", "PageDown"),
        0xE010 => k.k("End", "End"),
        0xE011 => k.k("Home", "Home"),
        0xE012 => k.k("ArrowLeft", "ArrowLeft"),
        0xE013 => k.k("ArrowUp", "ArrowUp"),
        0xE014 => k.k("ArrowRight", "ArrowRight"),
        0xE015 => k.k("ArrowDown", "ArrowDown"),
        0xE016 => k.k("Insert", "Insert"),
        0xE017 => k.k("Delete", "Delete"),
        0xE018 => k.k(";", "Semicolon"),
        0xE019 => k.k("=", "Equal"),
        0xE01A => k.n("0", "Numpad0"),
        0xE01B => k.n("1", "Numpad1"),
        0xE01C => k.n("2", "Numpad2"),
        0xE01D => k.n("3", "Numpad3"),
        0xE01E => k.n("4", "Numpad4"),
        0xE01F => k.n("5", "Numpad5"),
        0xE020 => k.n("6", "Numpad6"),
        0xE021 => k.n("7", "Numpad7"),
        0xE022 => k.n("8", "Numpad8"),
        0xE023 => k.n("9", "Numpad9"),
        0xE024 => k.n("*", "NumpadMultiply"),
        0xE025 => k.n("+", "NumpadAdd"),
        0xE026 => k.n(",", "NumpadComma"),
        0xE027 => k.n("-", "NumpadSubtract"),
        0xE028 => k.n(".", "NumpadDecimal"),
        0xE029 => k.n("/", "NumpadDivide"),
        0xE031 => k.k("F1", "F1"),
        0xE032 => k.k("F2", "F2"),
        0xE033 => k.k("F3", "F3"),
        0xE034 => k.k("F4", "F4"),
        0xE035 => k.k("F5", "F5"),
        0xE036 => k.k("F6", "F6"),
        0xE037 => k.k("F7", "F7"),
        0xE038 => k.k("F8", "F8"),
        0xE039 => k.k("F9", "F9"),
        0xE03A => k.k("F10", "F10"),
        0xE03B => k.k("F11", "F11"),
        0xE03C => k.k("F12", "F12"),
        0xE03D => k.m("Meta", "MetaLeft", 1, .meta),
        0xE040 => k.k("ZenkakuHankaku", ""),
        0xE050 => k.m("Shift", "ShiftRight", 2, .shift),
        0xE051 => k.m("Control", "ControlRight", 2, .ctrl),
        0xE052 => k.m("Alt", "AltRight", 2, .alt),
        0xE053 => k.m("Meta", "MetaRight", 2, .meta),
        0xE054 => k.n("PageUp", "Numpad9"),
        0xE055 => k.n("PageDown", "Numpad3"),
        0xE056 => k.n("End", "Numpad1"),
        0xE057 => k.n("Home", "Numpad7"),
        0xE058 => k.n("ArrowLeft", "Numpad4"),
        0xE059 => k.n("ArrowUp", "Numpad8"),
        0xE05A => k.n("ArrowRight", "Numpad6"),
        0xE05B => k.n("ArrowDown", "Numpad2"),
        0xE05C => k.n("Insert", "Numpad0"),
        0xE05D => k.n("Delete", "NumpadDecimal"),
        else => k.k("Unidentified", ""),
    };
}

// slices into this literal are always valid
const key_codes = "KeyAKeyBKeyCKeyDKeyEKeyFKeyGKeyHKeyIKeyJKeyKKeyLKeyMKeyNKeyOKeyPKeyQKeyRKeySKeyTKeyUKeyVKeyWKeyXKeyYKeyZ";
const digit_codes = "Digit0Digit1Digit2Digit3Digit4Digit5Digit6Digit7Digit8Digit9";

// The `code` of a printable character on a US layout.
fn asciiCode(cp: u21) []const u8 {
    if (cp >= 128) {
        return "";
    }
    const c: u8 = @intCast(cp);
    return switch (c) {
        'a'...'z' => key_codes[(c - 'a') * 4 ..][0..4],
        'A'...'Z' => key_codes[(c - 'A') * 4 ..][0..4],
        '0'...'9' => digit_codes[(c - '0') * 6 ..][0..6],
        ' ' => "Space",
        '\n', '\r' => "Enter",
        '\t' => "Tab",
        '`', '~' => "Backquote",
        '-', '_' => "Minus",
        '=', '+' => "Equal",
        '[', '{' => "BracketLeft",
        ']', '}' => "BracketRight",
        '\\', '|' => "Backslash",
        ';', ':' => "Semicolon",
        '\'', '"' => "Quote",
        ',', '<' => "Comma",
        '.', '>' => "Period",
        '/', '?' => "Slash",
        '!' => "Digit1",
        '@' => "Digit2",
        '#' => "Digit3",
        '$' => "Digit4",
        '%' => "Digit5",
        '^' => "Digit6",
        '&' => "Digit7",
        '*' => "Digit8",
        '(' => "Digit9",
        ')' => "Digit0",
        else => "",
    };
}

// What a held Shift turns a US-layout key into.
fn shiftedAscii(c: u8) u8 {
    return switch (c) {
        'a'...'z' => std.ascii.toUpper(c),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        else => c,
    };
}

const testing = @import("../../testing.zig");
test "keyboard: named keys take WebDriver's code and location" {
    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "Enter", "Enter", 0 },
        .{ "a", "KeyA", 0 },
        .{ " ", "Space", 0 },
        .{ "ArrowUp", "ArrowUp", 0 },
        .{ "Shift", "ShiftLeft", 1 },
        .{ "pageup", "PageUp", 0 },
        .{ "Bogus", "", 0 },
    };
    for (cases) |c| {
        const name, const code, const location = c;
        const info = named(name);
        try testing.expectEqual(code, info.code);
        try testing.expectEqual(location, info.location);
    }
}

test "keyboard: Shift on a WebDriver character" {
    const info = webdriverKey('a', true);
    try testing.expectEqual('A', info.key.char);
    try testing.expectEqual("KeyA", info.code);
    try testing.expectEqual(.shift, webdriverKey(0xE008, false).modifier.?);
}

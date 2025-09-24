// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const log = @import("../../log.zig");
const builtin = @import("builtin");

const parser = @import("../netsurf.zig");
const Event = @import("event.zig").Event;

// TODO: We currently don't have a UIEvent interface so we skip it in the prototype chain.
// https://developer.mozilla.org/en-US/docs/Web/API/UIEvent
const UIEvent = Event;

// https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent
pub const KeyboardEvent = struct {
    pub const Self = parser.KeyboardEvent;
    pub const prototype = *UIEvent;

    pub const ConstructorOptions = struct {
        key: []const u8 = "",
        code: []const u8 = "",
        location: parser.KeyboardEventOpts.LocationCode = .standard,
        repeat: bool = false,
        isComposing: bool = false,
        // Currently not supported but we take as argument.
        charCode: u32 = 0,
        // Currently not supported but we take as argument.
        keyCode: u32 = 0,
        // Currently not supported but we take as argument.
        which: u32 = 0,
        ctrlKey: bool = false,
        shiftKey: bool = false,
        altKey: bool = false,
        metaKey: bool = false,
    };

    pub fn constructor(event_type: []const u8, maybe_options: ?ConstructorOptions) !*parser.KeyboardEvent {
        const options: ConstructorOptions = maybe_options orelse .{};

        const event = try parser.keyboardEventCreate();
        parser.eventSetInternalType(@ptrCast(event), .keyboard_event);

        try parser.keyboardEventInit(
            event,
            event_type,
            .{
                .key = options.key,
                .code = options.code,
                .location = options.location,
                .repeat = options.repeat,
                .is_composing = options.isComposing,
                .ctrl_key = options.ctrlKey,
                .shift_key = options.shiftKey,
                .alt_key = options.altKey,
                .meta_key = options.metaKey,
            },
        );

        return event;
    }

    // Returns the modifier state for given modifier key.
    pub fn _getModifierState(self: *Self, key: []const u8) bool {
        // Chrome and Firefox do case-sensitive match, here we prefer the same.
        if (std.mem.eql(u8, key, "Alt")) {
            return get_altKey(self);
        }

        if (std.mem.eql(u8, key, "AltGraph")) {
            return (get_altKey(self) and get_ctrlKey(self));
        }

        if (std.mem.eql(u8, key, "Control")) {
            return get_ctrlKey(self);
        }

        if (std.mem.eql(u8, key, "Shift")) {
            return get_shiftKey(self);
        }

        if (std.mem.eql(u8, key, "Meta") or std.mem.eql(u8, key, "OS")) {
            return get_metaKey(self);
        }

        // Special case for IE.
        if (comptime builtin.os.tag == .windows) {
            if (std.mem.eql(u8, key, "Win")) {
                return get_metaKey(self);
            }
        }

        // getModifierState() also accepts a deprecated virtual modifier named "Accel".
        // event.getModifierState("Accel") returns true when at least one of
        // KeyboardEvent.ctrlKey or KeyboardEvent.metaKey is true.
        //
        // https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/getModifierState#accel_virtual_modifier
        if (std.mem.eql(u8, key, "Accel")) {
            return (get_ctrlKey(self) or get_metaKey(self));
        }

        // TODO: Add support for "CapsLock", "ScrollLock".
        return false;
    }

    // Getters.

    pub fn get_altKey(self: *Self) bool {
        return parser.keyboardEventKeyIsSet(self, .alt);
    }

    pub fn get_ctrlKey(self: *Self) bool {
        return parser.keyboardEventKeyIsSet(self, .ctrl);
    }

    pub fn get_metaKey(self: *Self) bool {
        return parser.keyboardEventKeyIsSet(self, .meta);
    }

    pub fn get_shiftKey(self: *Self) bool {
        return parser.keyboardEventKeyIsSet(self, .shift);
    }

    pub fn get_isComposing(self: *Self) bool {
        return self.is_composing;
    }

    pub fn get_location(self: *Self) u32 {
        return self.location;
    }

    pub fn get_key(self: *Self) ![]const u8 {
        return parser.keyboardEventGetKey(self);
    }

    pub fn get_repeat(self: *Self) bool {
        return self.repeat;
    }
};

const testing = @import("../../testing.zig");
test "Browser: Events.Keyboard" {
    try testing.htmlRunner("events/keyboard.html");
}

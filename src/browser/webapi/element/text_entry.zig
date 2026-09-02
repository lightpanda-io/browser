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

// Input and TextArea share much in common. All shared logic between Input and
// TextArea sits here.

const std = @import("std");

const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const Selection = @import("../Selection.zig");
const InputEvent = @import("../event/InputEvent.zig");

pub fn TextEntry(comptime T: type) type {
    return struct {
        pub fn select(self: *T, frame: *Frame) !void {
            const len = if (self._value) |v| @as(u32, @intCast(v.len)) else 0;
            try setSelectionRange(self, 0, len, null, frame);
            const event = try Event.init("select", .{ .bubbles = true }, frame._page);
            try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
        }

        pub fn innerInsert(self: *T, str: []const u8, frame: *Frame) !void {
            const arena = frame.arena;

            switch (howSelected(self)) {
                .full => {
                    // fully selected, replace the content.
                    const new_value = try arena.dupe(u8, str);
                    try self.setUserValue(new_value, frame);
                    self._selection_start = @intCast(new_value.len);
                    self._selection_end = @intCast(new_value.len);
                    self._selection_direction = .none;
                    try dispatchSelectionChangeEvent(self, frame);
                },
                .partial => |range| {
                    // partially selected, replace the selected content.
                    const current_value = self.getValue();
                    const before = current_value[0..range[0]];
                    const remaining = current_value[range[1]..];

                    const new_value = try std.mem.concat(
                        arena,
                        u8,
                        &.{ before, str, remaining },
                    );
                    try self.setUserValue(new_value, frame);

                    const new_pos = range[0] + str.len;
                    self._selection_start = @intCast(new_pos);
                    self._selection_end = @intCast(new_pos);
                    self._selection_direction = .none;
                    try dispatchSelectionChangeEvent(self, frame);
                },
                .none => {
                    // nothing selected, just insert at cursor.
                    const current_value = self.getValue();
                    const new_value = try std.mem.concat(arena, u8, &.{ current_value, str });
                    try self.setUserValue(new_value, frame);
                },
            }
            try dispatchInputEvent(self, str, "insertText", frame);
        }

        // forward == delete
        // !forward == backspace
        pub fn innerDelete(self: *T, forward: bool, frame: *Frame) !void {
            const current_value = self.getValue();
            const value_len: u32 = @intCast(current_value.len);

            var start: u32 = undefined;
            var end: u32 = undefined;
            switch (howSelected(self)) {
                .full => {
                    start = 0;
                    end = value_len;
                },
                .partial => |range| {
                    start, end = range;
                },
                .none => {
                    // Controls without selection support keep no caret; edit at the end.
                    const caret = if (self.selectionAvailable()) @min(self._selection_start, value_len) else value_len;
                    if (forward) {
                        if (caret >= value_len) {
                            return;
                        }
                        start = caret;
                        end = caret + (std.unicode.utf8ByteSequenceLength(current_value[caret]) catch 1);
                    } else {
                        if (caret == 0) {
                            return;
                        }
                        end = caret;
                        start = caret - 1;
                        while (start > 0 and (current_value[start] & 0xC0) == 0x80) {
                            start -= 1;
                        }
                    }
                },
            }

            const new_value = try std.mem.concat(frame.arena, u8, &.{
                current_value[0..start],
                current_value[@min(end, value_len)..],
            });
            try self.setUserValue(new_value, frame);
            self._selection_start = start;
            self._selection_end = start;
            self._selection_direction = .none;
            try dispatchSelectionChangeEvent(self, frame);
            try dispatchInputEvent(self, null, if (forward) "deleteContentForward" else "deleteContentBackward", frame);
        }

        pub fn getSelectionDirection(self: *const T) []const u8 {
            return @tagName(self._selection_direction);
        }

        pub fn setSelectionStart(self: *T, value: u32, frame: *Frame) !void {
            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }
            self._selection_start = value;
            try dispatchSelectionChangeEvent(self, frame);
        }

        pub fn setSelectionEnd(self: *T, value: u32, frame: *Frame) !void {
            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }
            self._selection_end = value;
            try dispatchSelectionChangeEvent(self, frame);
        }

        pub fn setSelectionRange(
            self: *T,
            selection_start: u32,
            selection_end: u32,
            selection_dir: ?[]const u8,
            frame: *Frame,
        ) !void {
            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }

            const direction = blk: {
                if (selection_dir) |sd| {
                    break :blk std.meta.stringToEnum(Selection.SelectionDirection, sd) orelse .none;
                } else break :blk .none;
            };

            const value = self._value orelse {
                self._selection_start = 0;
                self._selection_end = 0;
                self._selection_direction = .none;
                return;
            };

            const len_u32: u32 = @intCast(value.len);
            var start: u32 = if (selection_start > len_u32) len_u32 else selection_start;
            const end: u32 = if (selection_end > len_u32) len_u32 else selection_end;

            // If end is less than start, both are equal to end.
            if (end < start) {
                start = end;
            }

            self._selection_direction = direction;
            self._selection_start = start;
            self._selection_end = end;

            try dispatchSelectionChangeEvent(self, frame);
        }

        const HowSelected = union(enum) { partial: struct { u32, u32 }, full, none };

        fn howSelected(self: *const T) HowSelected {
            if (self.selectionAvailable() == false) {
                return .none;
            }
            const value = self._value orelse return .none;

            if (self._selection_start == self._selection_end) {
                return .none;
            }
            if (self._selection_start == 0 and self._selection_end == value.len) {
                return .full;
            }
            return .{ .partial = .{ self._selection_start, self._selection_end } };
        }

        fn dispatchSelectionChangeEvent(self: *T, frame: *Frame) !void {
            const event = try Event.init("selectionchange", .{ .bubbles = true }, frame._page);
            try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
        }

        fn dispatchInputEvent(self: *T, data: ?[]const u8, input_type: []const u8, frame: *Frame) !void {
            const event = try InputEvent.initTrusted(comptime .wrap("input"), .{ .data = data, .inputType = input_type }, frame);
            try frame._event_manager.dispatch(self.asElement().asEventTarget(), event.asEvent());
        }
    };
}

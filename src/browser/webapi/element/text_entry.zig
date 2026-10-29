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
const Factory = @import("../../Factory.zig");

const CData = @import("../CData.zig");
const Event = @import("../Event.zig");
const Selection = @import("../Selection.zig");
const InputEvent = @import("../event/InputEvent.zig");

pub fn TextEntry(comptime T: type) type {
    return struct {
        /// Whether typing edits the control's value. Checkbox and radio share
        /// Input's value machinery but no text goes into them.
        pub fn acceptsTextEntry(self: *const T) bool {
            if (!@hasField(T, "_input_type")) {
                return true;
            }
            return switch (self._input_type) {
                .checkbox, .radio => false,
                else => true,
            };
        }

        /// Whether the control keeps a text selection/caret internally. Wider
        /// than selectionAvailable(): email and number have selectable text
        /// (and a caret) even though the selection APIs don't apply to them.
        pub fn tracksSelection(self: *const T) bool {
            if (self.selectionAvailable()) {
                return true;
            }
            if (!@hasField(T, "_input_type")) {
                return false;
            }
            return switch (self._input_type) {
                .email, .number => true,
                else => false,
            };
        }

        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#dom-textarea/input-select
        // Never throws: without selectable text it just returns.
        pub fn select(self: *T, frame: *Frame) !void {
            if (tracksSelection(self) == false) {
                return;
            }
            const len: u32 = @intCast(self.getValue().len);
            try applySelectionRange(self, 0, len, .none, frame);
            try frame.queueElementEvent(Factory.protoOf(self), .select);
        }

        pub fn innerInsert(self: *T, str: []const u8, data: ?[]const u8, input_type: []const u8, frame: *Frame) !void {
            const current_value = self.getValue();
            const value_len: u32 = @intCast(current_value.len);
            const start: u32, const end: u32 = switch (howSelected(self)) {
                .full => .{ 0, value_len },
                .partial => |range| range,
                .none => blk: {
                    // Controls without a caret (e.g. date) append.
                    const caret = if (tracksSelection(self)) @min(self._selection_start, value_len) else value_len;
                    break :blk .{ caret, caret };
                },
            };

            {
                const scratch = try frame.getArena(current_value.len + str.len, "TextEntry.innerInsert");
                defer scratch.release();
                const new_value = try std.mem.concat(scratch.allocator(), u8, &.{ current_value[0..start], str, current_value[end..] });
                try self.setUserValue(new_value, frame);
            }

            if (tracksSelection(self)) {
                // the sanitized value can be shorter than what was inserted
                const new_pos: u32 = @intCast(@min(start + str.len, self.getValue().len));
                self._selection_start = new_pos;
                self._selection_end = new_pos;
                self._selection_direction = .none;
                try scheduleSelectionChange(self, frame);
            }
            try dispatchInputEvent(self, data, input_type, frame);
        }

        // forward == delete
        // !forward == backspace
        pub fn innerDelete(self: *T, forward: bool, input_type: []const u8, frame: *Frame) !void {
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
                    // Controls without a caret (e.g. date) edit at the end.
                    const caret = if (tracksSelection(self)) @min(self._selection_start, value_len) else value_len;
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

            {
                const scratch = try frame.getArena(current_value.len, "TextEntry.innerDelete");
                defer scratch.release();
                const new_value = try std.mem.concat(scratch.allocator(), u8, &.{
                    current_value[0..start],
                    current_value[@min(end, value_len)..],
                });
                try self.setUserValue(new_value, frame);
            }
            self._selection_start = start;
            self._selection_end = start;
            self._selection_direction = .none;
            try scheduleSelectionChange(self, frame);
            try dispatchInputEvent(self, null, input_type, frame);
        }

        pub fn rememberValueBeforeEdit(self: *T, frame: *Frame) !void {
            if (self._value_before_edit != null) {
                return;
            }
            const value = self.getValue();
            // _value is never mutated in place, so it can be kept as is. A
            // textarea without one shows its text child's data, which can change.
            if (@hasField(T, "_input_type") or self._value != null) {
                self._value_before_edit = value;
            } else {
                self._value_before_edit = try frame.page_arena.dupe(u8, value);
            }
        }

        // Commits the user's edits: fires change when they left the value
        // different, as when the control loses focus or Enter submits it.
        // https://html.spec.whatwg.org/multipage/input.html#common-input-element-events
        pub fn dispatchChangeIfEdited(self: *T, frame: *Frame) !void {
            const before = self._value_before_edit orelse return;
            self._value_before_edit = null;
            if (std.mem.eql(u8, before, self.getValue())) {
                return;
            }
            const event = try Event.initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame.page);
            try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
        }

        // Collapses the selection to the end of the value. Unlike
        // setSelectionRange(), applies to email and number too.
        pub fn caretToEnd(self: *T, frame: *Frame) !void {
            if (tracksSelection(self) == false) {
                return;
            }
            const len: u32 = @intCast(self.getValue().len);
            try applySelectionRange(self, len, len, .none, frame);
        }

        pub const CaretMove = enum { backward, forward, line_start, line_end };

        // Default action of the caret movement keys (ArrowLeft, ArrowRight,
        // Home, End). With `extend` (Shift held) the selection's focus moves
        // and its anchor stays; otherwise the selection collapses. A plain
        // ArrowLeft/ArrowRight on a non-collapsed selection collapses it to
        // the corresponding edge without moving, like Chrome.
        pub fn moveCaret(self: *T, move: CaretMove, extend: bool, frame: *Frame) !void {
            if (tracksSelection(self) == false) {
                return;
            }
            const value = self.getValue();
            const len: u32 = @intCast(value.len);
            const start = @min(self._selection_start, len);
            const end = @min(self._selection_end, len);

            var new_start: u32 = undefined;
            var new_end: u32 = undefined;
            var new_direction: Selection.SelectionDirection = .none;

            if (extend) {
                const backward = self._selection_direction == .backward;
                const anchor = if (backward) end else start;
                const focus = caretTarget(value, if (backward) start else end, move);
                if (focus < anchor) {
                    new_start = focus;
                    new_end = anchor;
                    new_direction = .backward;
                } else {
                    new_start = anchor;
                    new_end = focus;
                    new_direction = if (focus > anchor) .forward else .none;
                }
            } else if (start != end and (move == .backward or move == .forward)) {
                new_start = if (move == .backward) start else end;
                new_end = new_start;
            } else {
                new_start = caretTarget(value, if (move == .backward) start else end, move);
                new_end = new_start;
            }

            if (new_start == self._selection_start and new_end == self._selection_end and new_direction == self._selection_direction) {
                return;
            }
            self._selection_start = new_start;
            self._selection_end = new_end;
            self._selection_direction = new_direction;
            try scheduleSelectionChange(self, frame);
        }

        // Byte offset the caret lands on when moved from `pos`. Steps over
        // whole UTF-8 sequences; line moves stop at the enclosing '\n' (an
        // <input>'s sanitized value has none, so they reach the value's ends).
        fn caretTarget(value: []const u8, pos: u32, move: CaretMove) u32 {
            switch (move) {
                .backward => {
                    if (pos == 0) return 0;
                    var p = pos - 1;
                    while (p > 0 and (value[p] & 0xC0) == 0x80) {
                        p -= 1;
                    }
                    return p;
                },
                .forward => {
                    if (pos >= value.len) return @intCast(value.len);
                    const next = pos + (std.unicode.utf8ByteSequenceLength(value[pos]) catch 1);
                    return @intCast(@min(next, value.len));
                },
                .line_start => {
                    const nl = std.mem.findScalarLast(u8, value[0..pos], '\n') orelse return 0;
                    return @intCast(nl + 1);
                },
                .line_end => {
                    const nl = std.mem.findScalarPos(u8, value, pos, '\n') orelse return @intCast(value.len);
                    return @intCast(nl);
                },
            }
        }

        pub fn getSelectionDirection(self: *const T) []const u8 {
            return @tagName(self._selection_direction);
        }

        // Selection offsets are kept as byte offsets into the UTF-8 value, while
        // the JS API counts UTF-16 code units.
        pub fn selectionOffsetToJs(self: *const T, offset: u32) u32 {
            const value = self.getValue();
            return @intCast(CData.utf16Len(value[0..@min(offset, value.len)]));
        }

        fn selectionOffsetFromJs(self: *const T, offset: u32) u32 {
            return @intCast(CData.utf16OffsetToUtf8Floor(self.getValue(), offset));
        }

        pub fn setSelectionStart(self: *T, value: u32, frame: *Frame) !void {
            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }
            // Spec: the end is raised to the new start, then set-range runs.
            const start = selectionOffsetFromJs(self, value);
            return applySelectionRange(self, start, @max(start, self._selection_end), self._selection_direction, frame);
        }

        pub fn setSelectionEnd(self: *T, value: u32, frame: *Frame) !void {
            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }
            return applySelectionRange(self, self._selection_start, selectionOffsetFromJs(self, value), self._selection_direction, frame);
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

            return applySelectionRange(self, selectionOffsetFromJs(self, selection_start), selectionOffsetFromJs(self, selection_end), direction, frame);
        }

        const SelectionMode = enum { select, start, end, preserve };

        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#dom-textarea/input-setrangetext
        pub fn setRangeText(
            self: *T,
            replacement: []const u8,
            range_start: ?u32,
            range_end: ?u32,
            selection_mode: ?[]const u8,
            frame: *Frame,
        ) !void {
            // Argument errors come first: Chrome throws them while converting
            // the arguments. A start needs an end.
            const mode: SelectionMode = if (selection_mode) |m|
                std.meta.stringToEnum(SelectionMode, m) orelse return error.TypeError
            else
                .preserve;
            if (range_start != null and range_end == null) {
                return error.TypeError;
            }

            if (self.selectionAvailable() == false) {
                return error.InvalidStateError;
            }

            // Offsets are in UTF-16 code units, like the spec, and only become
            // byte offsets against a given value: setValue can sanitize the new
            // one (newlines, CRLF), so its byte offsets differ from the concat's.
            const value = self.getValue();
            const value_len: u32 = @intCast(CData.utf16Len(value));
            const sel_start = selectionOffsetToJs(self, self._selection_start);
            const sel_end = selectionOffsetToJs(self, self._selection_end);

            // setRangeText(replacement) replaces the selection
            var start = sel_start;
            var end = sel_end;
            if (range_start) |js_start| {
                const js_end = range_end.?;
                if (js_start > js_end) {
                    return error.IndexSizeError;
                }
                start = @min(js_start, value_len);
                end = @min(js_end, value_len);
            }

            {
                const byte_start = selectionOffsetFromJs(self, start);
                const byte_end = selectionOffsetFromJs(self, end);
                const scratch = try frame.getArena(value.len + replacement.len, "TextEntry.setRangeText");
                defer scratch.release();
                const new_value = try std.mem.concat(scratch.allocator(), u8, &.{ value[0..byte_start], replacement, value[byte_end..] });
                try self.setValue(new_value, frame);
            }

            const new_end: u32 = start + @as(u32, @intCast(CData.utf16Len(replacement)));
            var new_start = sel_start;
            var new_sel_end = sel_end;
            switch (mode) {
                .select => {
                    new_start = start;
                    new_sel_end = new_end;
                },
                .start => {
                    new_start = start;
                    new_sel_end = start;
                },
                .end => {
                    new_start = new_end;
                    new_sel_end = new_end;
                },
                .preserve => {
                    // keep the selection on the same text: shift it past the
                    // replaced range, or snap it to the range's edges inside it
                    const delta: i64 = @as(i64, @intCast(replacement.len)) - @as(i64, end - start);
                    if (sel_start > end) {
                        new_start = @intCast(@as(i64, sel_start) + delta);
                    } else if (sel_start > start) {
                        new_start = start;
                    }
                    if (sel_end > end) {
                        new_sel_end = @intCast(@as(i64, sel_end) + delta);
                    } else if (sel_end > start) {
                        new_sel_end = new_end;
                    }
                },
            }
            return applySelectionRange(self, selectionOffsetFromJs(self, new_start), selectionOffsetFromJs(self, new_sel_end), .none, frame);
        }

        fn applySelectionRange(
            self: *T,
            selection_start: u32,
            selection_end: u32,
            direction: Selection.SelectionDirection,
            frame: *Frame,
        ) !void {
            const len_u32: u32 = @intCast(self.getValue().len);
            var start: u32 = if (selection_start > len_u32) len_u32 else selection_start;
            const end: u32 = if (selection_end > len_u32) len_u32 else selection_end;

            // If end is less than start, both are equal to end.
            if (end < start) {
                start = end;
            }

            if (start == self._selection_start and end == self._selection_end and direction == self._selection_direction) {
                return;
            }
            self._selection_direction = direction;
            self._selection_start = start;
            self._selection_end = end;

            try scheduleSelectionChange(self, frame);
        }

        const HowSelected = union(enum) { partial: struct { u32, u32 }, full, none };

        fn howSelected(self: *const T) HowSelected {
            if (tracksSelection(self) == false) {
                return .none;
            }
            const value_len: u32 = @intCast(self.getValue().len);
            const start = @min(self._selection_start, value_len);
            const end = @min(self._selection_end, value_len);

            if (start == end) {
                return .none;
            }
            if (start == 0 and end == value_len) {
                return .full;
            }
            return .{ .partial = .{ start, end } };
        }

        // https://w3c.github.io/selection-api/#scheduling-selectionchange-event
        fn scheduleSelectionChange(self: *T, frame: *Frame) !void {
            if (self._selectionchange_pending) {
                return;
            }
            try frame.queueElementEvent(Factory.protoOf(self), .selectionchange);
            self._selectionchange_pending = true;
        }

        fn dispatchInputEvent(self: *T, data: ?[]const u8, input_type: []const u8, frame: *Frame) !void {
            const event = try InputEvent.initTrusted(comptime .wrap("input"), .{ .data = data, .inputType = input_type }, frame);
            try frame._event_manager.dispatch(self.asElement().asEventTarget(), event.asEvent());
        }
    };
}

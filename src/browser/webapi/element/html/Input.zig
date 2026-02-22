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
const String = @import("../../../../string.zig").String;

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");

const Input = @This();

pub const Type = enum {
    text,
    password,
    checkbox,
    radio,
    submit,
    reset,
    button,
    hidden,
    image,
    file,
    email,
    url,
    tel,
    search,
    number,
    range,
    date,
    time,
    @"datetime-local",
    month,
    week,
    color,

    pub fn fromString(str: []const u8) Type {
        // Longest type name is "datetime-local" at 14 chars
        if (str.len > 32) {
            return .text;
        }

        var buf: [32]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, str);
        return std.meta.stringToEnum(Type, lower) orelse .text;
    }

    pub fn toString(self: Type) []const u8 {
        return @tagName(self);
    }
};

_proto: *HtmlElement,
_default_value: ?[]const u8 = null,
_default_checked: bool = false,
_value: ?[]const u8 = null,
_checked: bool = false,
_checked_dirty: bool = false,
_input_type: Type = .text,
_indeterminate: bool = false,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

_on_selectionchange: ?js.Function.Global = null,

pub fn getOnSelectionChange(self: *Input) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *Input, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

fn dispatchSelectionChangeEvent(self: *Input, page: *Page) !void {
    const event = try Event.init("selectionchange", .{ .bubbles = true }, page);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn asElement(self: *Input) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Input) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Input) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Input) []const u8 {
    return self._input_type.toString();
}

pub fn setType(self: *Input, typ: []const u8, page: *Page) !void {
    // Setting the type property should update the attribute, which will trigger attributeChange
    const type_enum = Type.fromString(typ);
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(type_enum.toString()), page);
}

pub fn getValue(self: *const Input) []const u8 {
    return self._value orelse self._default_value orelse switch (self._input_type) {
        .checkbox, .radio => "on",
        else => "",
    };
}

pub fn setValue(self: *Input, value: []const u8, page: *Page) !void {
    // File inputs cannot have their value set programmatically for security reasons
    if (self._input_type == .file) {
        return error.InvalidStateError;
    }
    // This should _not_ call setAttribute. It updates the current state only
    self._value = try self.sanitizeValue(true, value, page);
}

pub fn getDefaultValue(self: *const Input) []const u8 {
    return self._default_value orelse "";
}

pub fn setDefaultValue(self: *Input, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), page);
}

pub fn getChecked(self: *const Input) bool {
    return self._checked;
}

pub fn setChecked(self: *Input, checked: bool, page: *Page) !void {
    // If checking a radio button, uncheck others in the group first
    if (checked and self._input_type == .radio) {
        try self.uncheckRadioGroup(page);
    }
    // This should _not_ call setAttribute. It updates the current state only
    self._checked = checked;
    self._checked_dirty = true;
}

pub fn getIndeterminate(self: *const Input) bool {
    return self._indeterminate;
}

pub fn setIndeterminate(self: *Input, value: bool) !void {
    self._indeterminate = value;
}

pub fn getDefaultChecked(self: *const Input) bool {
    return self._default_checked;
}

pub fn setDefaultChecked(self: *Input, checked: bool, page: *Page) !void {
    if (checked) {
        try self.asElement().setAttributeSafe(comptime .wrap("checked"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("checked"), page);
    }
}

pub fn getDisabled(self: *const Input) bool {
    // TODO: Also check for disabled fieldset ancestors
    // (but not if we're inside a <legend> of that fieldset)
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Input, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getName(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Input, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

pub fn getAccept(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("accept")) orelse "";
}

pub fn setAccept(self: *Input, accept: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("accept"), .wrap(accept), page);
}

pub fn getAlt(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Input, alt: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(alt), page);
}

pub fn getMaxLength(self: *const Input) i32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("maxlength")) orelse return -1;
    return std.fmt.parseInt(i32, attr, 10) catch -1;
}

pub fn setMaxLength(self: *Input, max_length: i32, page: *Page) !void {
    if (max_length < 0) {
        return error.NegativeValueNotAllowed;
    }
    var buf: [32]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{max_length}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("maxlength"), .wrap(value), page);
}

pub fn getSize(self: *const Input) i32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("size")) orelse return 20;
    const parsed = std.fmt.parseInt(i32, attr, 10) catch return 20;
    return if (parsed == 0) 20 else parsed;
}

pub fn setSize(self: *Input, size: i32, page: *Page) !void {
    if (size == 0) {
        return error.ZeroNotAllowed;
    }
    if (size < 0) {
        return self.asElement().setAttributeSafe(comptime .wrap("size"), .wrap("20"), page);
    }

    var buf: [32]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{size}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("size"), .wrap(value), page);
}

pub fn getSrc(self: *const Input, page: *Page) ![]const u8 {
    const src = self.asConstElement().getAttributeSafe(comptime .wrap("src")) orelse return "";
    // If attribute is explicitly set (even if empty), resolve it against the base URL
    return @import("../../URL.zig").resolve(page.call_arena, page.base(), src, .{});
}

pub fn setSrc(self: *Input, src: []const u8, page: *Page) !void {
    const trimmed = std.mem.trim(u8, src, &std.ascii.whitespace);
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(trimmed), page);
}

pub fn getReadonly(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("readonly")) != null;
}

pub fn setReadonly(self: *Input, readonly: bool, page: *Page) !void {
    if (readonly) {
        try self.asElement().setAttributeSafe(comptime .wrap("readonly"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("readonly"), page);
    }
}

pub fn getRequired(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn setRequired(self: *Input, required: bool, page: *Page) !void {
    if (required) {
        try self.asElement().setAttributeSafe(comptime .wrap("required"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("required"), page);
    }
}

pub fn getPlaceholder(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("placeholder")) orelse "";
}

pub fn setPlaceholder(self: *Input, placeholder: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("placeholder"), .wrap(placeholder), page);
}

pub fn getMin(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("min")) orelse "";
}

pub fn setMin(self: *Input, min: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("min"), .wrap(min), page);
}

pub fn getMax(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("max")) orelse "";
}

pub fn setMax(self: *Input, max: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("max"), .wrap(max), page);
}

pub fn getStep(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("step")) orelse "";
}

pub fn setStep(self: *Input, step: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("step"), .wrap(step), page);
}

pub fn getMultiple(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("multiple")) != null;
}

pub fn setMultiple(self: *Input, multiple: bool, page: *Page) !void {
    if (multiple) {
        try self.asElement().setAttributeSafe(comptime .wrap("multiple"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("multiple"), page);
    }
}

pub fn getAutocomplete(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("autocomplete")) orelse "";
}

pub fn setAutocomplete(self: *Input, autocomplete: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("autocomplete"), .wrap(autocomplete), page);
}

pub fn select(self: *Input, page: *Page) !void {
    const len = if (self._value) |v| @as(u32, @intCast(v.len)) else 0;
    try self.setSelectionRange(0, len, null, page);
    const event = try Event.init("select", .{ .bubbles = true }, page);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

fn selectionAvailable(self: *const Input) bool {
    switch (self._input_type) {
        .text, .search, .url, .tel, .password => return true,
        else => return false,
    }
}

const HowSelected = union(enum) { partial: struct { u32, u32 }, full, none };

fn howSelected(self: *const Input) HowSelected {
    if (!self.selectionAvailable()) return .none;
    const value = self._value orelse return .none;

    if (self._selection_start == self._selection_end) return .none;
    if (self._selection_start == 0 and self._selection_end == value.len) return .full;
    return .{ .partial = .{ self._selection_start, self._selection_end } };
}

pub fn innerInsert(self: *Input, str: []const u8, page: *Page) !void {
    const arena = page.arena;

    switch (self.howSelected()) {
        .full => {
            // if the input is fully selected, replace the content.
            const new_value = try arena.dupe(u8, str);
            try self.setValue(new_value, page);
            self._selection_start = @intCast(new_value.len);
            self._selection_end = @intCast(new_value.len);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(page);
        },
        .partial => |range| {
            // if the input is partially selected, replace the selected content.
            const current_value = self.getValue();
            const before = current_value[0..range[0]];
            const remaining = current_value[range[1]..];

            const new_value = try std.mem.concat(
                arena,
                u8,
                &.{ before, str, remaining },
            );
            try self.setValue(new_value, page);

            const new_pos = range[0] + str.len;
            self._selection_start = @intCast(new_pos);
            self._selection_end = @intCast(new_pos);
            self._selection_direction = .none;
            try self.dispatchSelectionChangeEvent(page);
        },
        .none => {
            // if the input is not selected, just insert at cursor.
            const current_value = self.getValue();
            const new_value = try std.mem.concat(arena, u8, &.{ current_value, str });
            try self.setValue(new_value, page);
        },
    }
}

pub fn getSelectionDirection(self: *const Input) []const u8 {
    return @tagName(self._selection_direction);
}

pub fn getSelectionStart(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_start;
}

pub fn setSelectionStart(self: *Input, value: u32, page: *Page) !void {
    if (!self.selectionAvailable()) return error.InvalidStateError;
    self._selection_start = value;
    try self.dispatchSelectionChangeEvent(page);
}

pub fn getSelectionEnd(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_end;
}

pub fn setSelectionEnd(self: *Input, value: u32, page: *Page) !void {
    if (!self.selectionAvailable()) return error.InvalidStateError;
    self._selection_end = value;
    try self.dispatchSelectionChangeEvent(page);
}

pub fn setSelectionRange(
    self: *Input,
    selection_start: u32,
    selection_end: u32,
    selection_dir: ?[]const u8,
    page: *Page,
) !void {
    if (!self.selectionAvailable()) return error.InvalidStateError;

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

    try self.dispatchSelectionChangeEvent(page);
}

pub fn getForm(self: *Input, page: *Page) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
        if (page.document.getElementById(form_id, page)) |form_element| {
            return form_element.is(Form);
        }
        // form attribute present but invalid - no form owner
        return null;
    }

    // No form attribute - traverse ancestors looking for a <form>
    var node = element.asNode()._parent;
    while (node) |n| {
        if (n.is(Element.Html.Form)) |form| {
            return form;
        }
        node = n._parent;
    }

    return null;
}

/// Sanitize the value according to the current input type
fn sanitizeValue(self: *Input, comptime dupe: bool, value: []const u8, page: *Page) ![]const u8 {
    switch (self._input_type) {
        .text, .search, .tel, .password, .url, .email => {
            const sanitized = blk: {
                const first = std.mem.indexOfAny(u8, value, "\r\n") orelse {
                    break :blk if (comptime dupe) try page.dupeString(value) else value;
                };

                var result = try page.arena.alloc(u8, value.len);
                @memcpy(result[0..first], value[0..first]);

                var i: usize = first;
                for (value[first + 1 ..]) |c| {
                    if (c != '\r' and c != '\n') {
                        result[i] = c;
                        i += 1;
                    }
                }
                break :blk result[0..i];
            };

            return switch (self._input_type) {
                .url, .email => std.mem.trim(u8, sanitized, &std.ascii.whitespace),
                else => sanitized,
            };
        },
        .date => return if (isValidDate(value)) if (comptime dupe) try page.dupeString(value) else value else "",
        .month => return if (isValidMonth(value)) if (comptime dupe) try page.dupeString(value) else value else "",
        .week => return if (isValidWeek(value)) if (comptime dupe) try page.dupeString(value) else value else "",
        .time => return if (isValidTime(value)) if (comptime dupe) try page.dupeString(value) else value else "",
        .@"datetime-local" => return try sanitizeDatetimeLocal(dupe, value, page.arena),
        .number => return if (isValidFloatingPoint(value)) if (comptime dupe) try page.dupeString(value) else value else "",
        .range => return if (isValidFloatingPoint(value)) if (comptime dupe) try page.dupeString(value) else value else "50",
        .color => {
            if (value.len == 7 and value[0] == '#') {
                var needs_lower = false;
                for (value[1..]) |c| {
                    if (!std.ascii.isHex(c)) {
                        return "#000000";
                    }
                    if (c >= 'A' and c <= 'F') {
                        needs_lower = true;
                    }
                }
                if (!needs_lower) {
                    return if (comptime dupe) try page.dupeString(value) else value;
                }

                // Normalize to lowercase per spec
                const result = try page.arena.alloc(u8, 7);
                result[0] = '#';
                for (value[1..], 1..) |c, j| {
                    result[j] = std.ascii.toLower(c);
                }
                return result;
            }
            return "#000000";
        },
        .file => return "", // File: always empty
        .checkbox, .radio, .submit, .image, .reset, .button, .hidden => return if (comptime dupe) try page.dupeString(value) else value, // no sanitization
    }
}

/// WHATWG "valid floating-point number" grammar check + overflow detection.
/// Rejects "+1", "1.", "Infinity", "NaN", "2e308", leading whitespace, trailing junk.
fn isValidFloatingPoint(value: []const u8) bool {
    if (value.len == 0) return false;
    var pos: usize = 0;

    // Optional leading minus (no plus allowed)
    if (value[pos] == '-') {
        pos += 1;
        if (pos >= value.len) return false;
    }

    // Must have one or both of: digit-sequence, dot+digit-sequence
    var has_integer = false;
    var has_decimal = false;

    if (pos < value.len and std.ascii.isDigit(value[pos])) {
        has_integer = true;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos < value.len and value[pos] == '.') {
        pos += 1;
        if (pos < value.len and std.ascii.isDigit(value[pos])) {
            has_decimal = true;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
        } else {
            return false; // dot without trailing digits ("1.")
        }
    }

    if (!has_integer and !has_decimal) return false;

    // Optional exponent: (e|E) [+|-] digits
    if (pos < value.len and (value[pos] == 'e' or value[pos] == 'E')) {
        pos += 1;
        if (pos >= value.len) return false;
        if (value[pos] == '+' or value[pos] == '-') {
            pos += 1;
            if (pos >= value.len) return false;
        }
        if (!std.ascii.isDigit(value[pos])) return false;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos != value.len) return false; // trailing junk

    // Grammar is valid; now check the parsed value doesn't overflow
    const f = std.fmt.parseFloat(f64, value) catch return false;
    return !std.math.isInf(f) and !std.math.isNan(f);
}

/// Validate a WHATWG "valid date string": YYYY-MM-DD
fn isValidDate(value: []const u8) bool {
    // Minimum: 4-digit year + "-MM-DD" = 10 chars
    if (value.len < 10) return false;
    const year_len = value.len - 6; // "-MM-DD" is always 6 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 3] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    if (month < 1 or month > 12) return false;
    const day = parseAllDigits(value[year_len + 4 .. year_len + 6]) orelse return false;
    if (day < 1 or day > daysInMonth(@intCast(year), @intCast(month))) return false;
    return true;
}

/// Validate a WHATWG "valid month string": YYYY-MM
fn isValidMonth(value: []const u8) bool {
    if (value.len < 7) return false;
    const year_len = value.len - 3; // "-MM" is 3 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    return month >= 1 and month <= 12;
}

/// Validate a WHATWG "valid week string": YYYY-Www
fn isValidWeek(value: []const u8) bool {
    if (value.len < 8) return false;
    const year_len = value.len - 4; // "-Www" is 4 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 1] != 'W') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const week = parseAllDigits(value[year_len + 2 .. year_len + 4]) orelse return false;
    if (week < 1) return false;
    return week <= maxWeeksInYear(@intCast(year));
}

/// Validate a WHATWG "valid time string": HH:MM[:SS[.s{1,3}]]
fn isValidTime(value: []const u8) bool {
    if (value.len < 5) return false;
    if (value[2] != ':') return false;
    const hour = parseAllDigits(value[0..2]) orelse return false;
    if (hour > 23) return false;
    const minute = parseAllDigits(value[3..5]) orelse return false;
    if (minute > 59) return false;
    if (value.len == 5) return true;

    // Optional seconds
    if (value.len < 8 or value[5] != ':') return false;
    const second = parseAllDigits(value[6..8]) orelse return false;
    if (second > 59) return false;
    if (value.len == 8) return true;

    // Optional fractional seconds: 1-3 digits
    if (value[8] != '.') return false;
    const frac_len = value.len - 9;
    if (frac_len < 1 or frac_len > 3) return false;
    for (value[9..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Sanitize datetime-local: validate and normalize, or return "".
/// Spec: if valid, normalize to "YYYY-MM-DDThh:mm" (shortest time form);
/// otherwise set to "".
fn sanitizeDatetimeLocal(comptime dupe: bool, value: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (value.len < 16) {
        return "";
    }

    // Find separator (T or space) by scanning for it before a valid time start
    var sep_pos: ?usize = null;
    if (value.len >= 16) {
        for (0..value.len - 4) |i| {
            if ((value[i] == 'T' or value[i] == ' ') and
                i + 3 < value.len and
                std.ascii.isDigit(value[i + 1]) and
                std.ascii.isDigit(value[i + 2]) and
                value[i + 3] == ':')
            {
                sep_pos = i;
                break;
            }
        }
    }
    const sep = sep_pos orelse return "";

    const date_part = value[0..sep];
    const time_part = value[sep + 1 ..];
    if (!isValidDate(date_part) or !isValidTime(time_part)) {
        return "";
    }

    // Already normalized? (T separator and no trailing :00 or :00.000)
    if (value[sep] == 'T' and time_part.len == 5) {
        return if (comptime dupe) arena.dupe(u8, value) else value;
    }

    // Parse time components for normalization
    const second: u32 = if (time_part.len >= 8) (parseAllDigits(time_part[6..8]) orelse return "") else 0;
    var has_nonzero_frac = false;
    var frac_end: usize = 0;
    if (time_part.len > 9 and time_part[8] == '.') {
        for (time_part[9..], 0..) |c, fi| {
            if (c != '0') has_nonzero_frac = true;
            frac_end = fi + 1;
        }
        // Strip trailing zeros from fractional part
        while (frac_end > 0 and time_part[9 + frac_end - 1] == '0') : (frac_end -= 1) {}
    }

    // Build shortest time: HH:MM, or HH:MM:SS, or HH:MM:SS.fff
    const need_seconds = second != 0 or has_nonzero_frac;
    const time_len: usize = if (need_seconds) (if (frac_end > 0) 9 + frac_end else 8) else 5;
    const total_len = date_part.len + 1 + time_len;

    const result = try arena.alloc(u8, total_len);
    @memcpy(result[0..date_part.len], date_part);
    result[date_part.len] = 'T';
    @memcpy(result[date_part.len + 1 ..][0..5], time_part[0..5]);

    if (need_seconds) {
        @memcpy(result[date_part.len + 6 ..][0..3], time_part[5..8]);
        if (frac_end > 0) {
            result[date_part.len + 9] = '.';
            @memcpy(result[date_part.len + 10 ..][0..frac_end], time_part[9..][0..frac_end]);
        }
    }
    return result[0..total_len];
}

/// Parse a slice that must be ALL ASCII digits into a u32. Returns null if any non-digit or empty.
fn parseAllDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var result: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else 28,
        else => 0,
    };
}

/// ISO 8601: a year has 53 weeks if Jan 1 is Thursday, or Jan 1 is Wednesday and leap year.
fn maxWeeksInYear(year: u32) u32 {
    // Gauss's algorithm for Jan 1 day-of-week
    // dow: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
    const y1 = year - 1;
    const dow = (1 + 5 * (y1 % 4) + 4 * (y1 % 100) + 6 * (y1 % 400)) % 7;
    if (dow == 4) return 53; // Jan 1 is Thursday
    if (dow == 3 and isLeapYear(year)) return 53; // Jan 1 is Wednesday + leap year
    return 52;
}

fn uncheckRadioGroup(self: *Input, page: *Page) !void {
    const element = self.asElement();

    const name = element.getAttributeSafe(comptime .wrap("name")) orelse return;
    if (name.len == 0) {
        return;
    }

    const my_form = self.getForm(page);

    // Walk from the root of the tree containing this element
    // This handles both document-attached and orphaned elements
    const root = element.asNode().getRootNode(null);

    const TreeWalker = @import("../../TreeWalker.zig");
    var walker = TreeWalker.Full.init(root, .{});

    while (walker.next()) |node| {
        const other_element = node.is(Element) orelse continue;
        const other_input = other_element.is(Input) orelse continue;

        // Skip self
        if (other_input == self) {
            continue;
        }

        if (other_input._input_type != .radio) {
            continue;
        }

        const other_name = other_element.getAttributeSafe(comptime .wrap("name")) orelse continue;
        if (!std.mem.eql(u8, name, other_name)) {
            continue;
        }

        // Check if same form context
        const other_form = other_input.getForm(page);
        if (my_form == null and other_form == null) {
            other_input._checked = false;
            continue;
        }

        if (my_form) |mf| {
            if (other_form) |of| {
                if (mf == of) {
                    other_input._checked = false;
                }
            }
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Input);

    pub const Meta = struct {
        pub const name = "HTMLInputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onselectionchange = bridge.accessor(Input.getOnSelectionChange, Input.setOnSelectionChange, .{});
    pub const @"type" = bridge.accessor(Input.getType, Input.setType, .{});
    pub const value = bridge.accessor(Input.getValue, Input.setValue, .{ .dom_exception = true });
    pub const defaultValue = bridge.accessor(Input.getDefaultValue, Input.setDefaultValue, .{});
    pub const checked = bridge.accessor(Input.getChecked, Input.setChecked, .{});
    pub const defaultChecked = bridge.accessor(Input.getDefaultChecked, Input.setDefaultChecked, .{});
    pub const disabled = bridge.accessor(Input.getDisabled, Input.setDisabled, .{});
    pub const name = bridge.accessor(Input.getName, Input.setName, .{});
    pub const required = bridge.accessor(Input.getRequired, Input.setRequired, .{});
    pub const accept = bridge.accessor(Input.getAccept, Input.setAccept, .{});
    pub const readOnly = bridge.accessor(Input.getReadonly, Input.setReadonly, .{});
    pub const alt = bridge.accessor(Input.getAlt, Input.setAlt, .{});
    pub const maxLength = bridge.accessor(Input.getMaxLength, Input.setMaxLength, .{});
    pub const size = bridge.accessor(Input.getSize, Input.setSize, .{});
    pub const src = bridge.accessor(Input.getSrc, Input.setSrc, .{});
    pub const form = bridge.accessor(Input.getForm, null, .{});
    pub const indeterminate = bridge.accessor(Input.getIndeterminate, Input.setIndeterminate, .{});
    pub const placeholder = bridge.accessor(Input.getPlaceholder, Input.setPlaceholder, .{});
    pub const min = bridge.accessor(Input.getMin, Input.setMin, .{});
    pub const max = bridge.accessor(Input.getMax, Input.setMax, .{});
    pub const step = bridge.accessor(Input.getStep, Input.setStep, .{});
    pub const multiple = bridge.accessor(Input.getMultiple, Input.setMultiple, .{});
    pub const autocomplete = bridge.accessor(Input.getAutocomplete, Input.setAutocomplete, .{});
    pub const select = bridge.function(Input.select, .{});

    pub const selectionStart = bridge.accessor(Input.getSelectionStart, Input.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(Input.getSelectionEnd, Input.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(Input.getSelectionDirection, null, .{});
    pub const setSelectionRange = bridge.function(Input.setSelectionRange, .{ .dom_exception = true });
};

pub const Build = struct {
    pub fn created(node: *Node, page: *Page) !void {
        var self = node.as(Input);
        const element = self.asElement();

        // Store initial values from attributes
        self._default_value = element.getAttributeSafe(comptime .wrap("value"));
        self._default_checked = element.getAttributeSafe(comptime .wrap("checked")) != null;

        self._checked = self._default_checked;

        self._input_type = if (element.getAttributeSafe(comptime .wrap("type"))) |type_attr|
            Type.fromString(type_attr)
        else
            .text;

        // Sanitize initial value per input type (e.g. date rejects "invalid-date").
        if (self._default_value) |dv| {
            self._value = try self.sanitizeValue(false, dv, page);
        } else {
            self._value = null;
        }

        // If this is a checked radio button, uncheck others in its group
        if (self._checked and self._input_type == .radio) {
            try self.uncheckRadioGroup(page);
        }
    }

    pub fn attributeChange(element: *Element, name: String, value: String, page: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => {
                self._input_type = Type.fromString(value.str());
                // Sanitize the current value according to the new type
                if (self._value) |current_value| {
                    self._value = try self.sanitizeValue(false, current_value, page);
                    // Apply default value for checkbox/radio if value is now empty
                    if (self._value.?.len == 0 and (self._input_type == .checkbox or self._input_type == .radio)) {
                        self._value = "on";
                    }
                }
            },
            .value => self._default_value = try page.arena.dupe(u8, value.str()),
            .checked => {
                self._default_checked = true;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = true;
                    // If setting a radio button to checked, uncheck others in the group
                    if (self._input_type == .radio) {
                        try self.uncheckRadioGroup(page);
                    }
                }
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Page) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => self._input_type = .text,
            .value => self._default_value = null,
            .checked => {
                self._default_checked = false;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = false;
                }
            },
        }
    }

    pub fn cloned(source_element: *Element, cloned_element: *Element, _: *Page) !void {
        const source = source_element.as(Input);
        const clone = cloned_element.as(Input);

        // Copy runtime state from source to clone
        clone._value = source._value;
        clone._checked = source._checked;
        clone._checked_dirty = source._checked_dirty;
        clone._selection_direction = source._selection_direction;
        clone._selection_start = source._selection_start;
        clone._selection_end = source._selection_end;
        clone._indeterminate = source._indeterminate;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Input" {
    try testing.htmlRunner("element/html/input.html", .{});
    try testing.htmlRunner("element/html/input_click.html", .{});
    try testing.htmlRunner("element/html/input_radio.html", .{});
    try testing.htmlRunner("element/html/input-attrs.html", .{});
}

test "isValidFloatingPoint" {
    // Valid
    try testing.expect(isValidFloatingPoint("1"));
    try testing.expect(isValidFloatingPoint("0.5"));
    try testing.expect(isValidFloatingPoint("-1"));
    try testing.expect(isValidFloatingPoint("-0.5"));
    try testing.expect(isValidFloatingPoint("1e10"));
    try testing.expect(isValidFloatingPoint("1E10"));
    try testing.expect(isValidFloatingPoint("1e+10"));
    try testing.expect(isValidFloatingPoint("1e-10"));
    try testing.expect(isValidFloatingPoint("0.123"));
    try testing.expect(isValidFloatingPoint(".5"));
    // Invalid
    try testing.expect(!isValidFloatingPoint(""));
    try testing.expect(!isValidFloatingPoint("+1"));
    try testing.expect(!isValidFloatingPoint("1."));
    try testing.expect(!isValidFloatingPoint("Infinity"));
    try testing.expect(!isValidFloatingPoint("NaN"));
    try testing.expect(!isValidFloatingPoint(" 1"));
    try testing.expect(!isValidFloatingPoint("1 "));
    try testing.expect(!isValidFloatingPoint("1e"));
    try testing.expect(!isValidFloatingPoint("1e+"));
    try testing.expect(!isValidFloatingPoint("2e308")); // overflow
}

test "isValidDate" {
    try testing.expect(isValidDate("2024-01-01"));
    try testing.expect(isValidDate("2024-02-29")); // leap year
    try testing.expect(isValidDate("2024-12-31"));
    try testing.expect(isValidDate("10000-01-01")); // >4-digit year
    try testing.expect(!isValidDate("2024-02-30")); // invalid day
    try testing.expect(!isValidDate("2023-02-29")); // not leap year
    try testing.expect(!isValidDate("2024-13-01")); // invalid month
    try testing.expect(!isValidDate("2024-00-01")); // month 0
    try testing.expect(!isValidDate("0000-01-01")); // year 0
    try testing.expect(!isValidDate("2024-1-01")); // single-digit month
    try testing.expect(!isValidDate(""));
    try testing.expect(!isValidDate("not-a-date"));
}

test "isValidMonth" {
    try testing.expect(isValidMonth("2024-01"));
    try testing.expect(isValidMonth("2024-12"));
    try testing.expect(!isValidMonth("2024-00"));
    try testing.expect(!isValidMonth("2024-13"));
    try testing.expect(!isValidMonth("0000-01"));
    try testing.expect(!isValidMonth(""));
}

test "isValidWeek" {
    try testing.expect(isValidWeek("2024-W01"));
    try testing.expect(isValidWeek("2024-W52"));
    try testing.expect(isValidWeek("2020-W53")); // 2020 has 53 weeks
    try testing.expect(!isValidWeek("2024-W00"));
    try testing.expect(!isValidWeek("2024-W54"));
    try testing.expect(!isValidWeek("0000-W01"));
    try testing.expect(!isValidWeek(""));
}

test "isValidTime" {
    try testing.expect(isValidTime("00:00"));
    try testing.expect(isValidTime("23:59"));
    try testing.expect(isValidTime("12:30:45"));
    try testing.expect(isValidTime("12:30:45.1"));
    try testing.expect(isValidTime("12:30:45.12"));
    try testing.expect(isValidTime("12:30:45.123"));
    try testing.expect(!isValidTime("24:00"));
    try testing.expect(!isValidTime("12:60"));
    try testing.expect(!isValidTime("12:30:60"));
    try testing.expect(!isValidTime("12:30:45.1234")); // >3 frac digits
    try testing.expect(!isValidTime("12:30:45.")); // dot without digits
    try testing.expect(!isValidTime(""));
}

test "sanitizeDatetimeLocal" {
    const allocator = testing.allocator;
    // Already normalized — returns input slice, no allocation
    try testing.expectEqual("2024-01-01T12:30", try sanitizeDatetimeLocal(false, "2024-01-01T12:30", allocator));
    // Space separator → T (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01 12:30", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Strip trailing :00 (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:00", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Keep non-zero seconds (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45", allocator);
        try testing.expectEqual("2024-01-01T12:30:45", result);
        allocator.free(result);
    }
    // Keep fractional seconds, strip trailing zeros (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45.100", allocator);
        try testing.expectEqual("2024-01-01T12:30:45.1", result);
        allocator.free(result);
    }
    // Invalid → "" (no allocation)
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "not-a-datetime", allocator));
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "", allocator));
}

test "parseAllDigits" {
    try testing.expectEqual(@as(?u32, 0), parseAllDigits("0"));
    try testing.expectEqual(@as(?u32, 123), parseAllDigits("123"));
    try testing.expectEqual(@as(?u32, 2024), parseAllDigits("2024"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits(""));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("12a"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("abc"));
}

test "daysInMonth" {
    try testing.expectEqual(@as(u32, 31), daysInMonth(2024, 1));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2024, 2)); // leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(2023, 2)); // non-leap
    try testing.expectEqual(@as(u32, 30), daysInMonth(2024, 4));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2000, 2)); // century leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(1900, 2)); // century non-leap
}

test "maxWeeksInYear" {
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2024));
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2020)); // Jan 1 = Wed + leap
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2015)); // Jan 1 = Thu
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2023));
}

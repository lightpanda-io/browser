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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const CSS = @This();
_pad: bool = false,

pub const init: CSS = .{};

pub fn parseDimension(value: []const u8) ?f64 {
    if (value.len == 0) {
        return null;
    }

    var num_str = value;
    if (std.mem.endsWith(u8, value, "px")) {
        num_str = value[0 .. value.len - 2];
    }

    return std.fmt.parseFloat(f64, num_str) catch null;
}

/// Escapes a CSS identifier string
/// https://drafts.csswg.org/cssom/#the-css.escape()-method
pub fn escape(_: *const CSS, value: []const u8, page: *Page) ![]const u8 {
    if (value.len == 0) {
        return "";
    }

    const first = value[0];
    if (first == '-' and value.len == 1) {
        return "\\-";
    }

    // Count how many characters we need for the output
    var out_len: usize = escapeLen(true, first);
    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            out_len += 2 + hexDigitsNeeded(c);
        } else {
            out_len += escapeLen(false, c);
        }
    }

    if (out_len == value.len) {
        return value;
    }

    const result = try page.call_arena.alloc(u8, out_len);
    var pos: usize = 0;

    if (needsEscape(true, first)) {
        pos = writeEscape(true, result, first);
    } else {
        result[0] = first;
        pos = 1;
    }

    for (value[1..], 0..) |c, i| {
        // Second char (i==0) is a digit and first is '-', needs hex escape
        if (i == 0 and first == '-' and c >= '0' and c <= '9') {
            result[pos] = '\\';
            const hex_str = std.fmt.bufPrint(result[pos + 1 ..], "{x} ", .{c}) catch unreachable;
            pos += 1 + hex_str.len;
        } else if (!needsEscape(false, c)) {
            result[pos] = c;
            pos += 1;
        } else {
            pos += writeEscape(false, result[pos..], c);
        }
    }

    return result;
}

pub fn supports(_: *const CSS, property_or_condition: []const u8, value: ?[]const u8) bool {
    _ = property_or_condition;
    _ = value;
    return true;
}

fn escapeLen(comptime is_first: bool, c: u8) usize {
    if (needsEscape(is_first, c) == false) {
        return 1;
    }
    if (c == 0) {
        return "\u{FFFD}".len;
    }
    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        // Will be escaped as \XX (backslash + 1-6 hex digits + space)
        return 2 + hexDigitsNeeded(c);
    }
    // Escaped as \C (backslash + character)
    return 2;
}

fn needsEscape(comptime is_first: bool, c: u8) bool {
    if (comptime is_first) {
        if (c >= '0' and c <= '9') {
            return true;
        }
    }

    // Characters that need escaping
    return switch (c) {
        0...0x1F, 0x7F => true,
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '`', '{', '|', '}', '~' => true,
        ' ' => true,
        else => false,
    };
}

fn isHexEscape(c: u8) bool {
    return (c >= 0x00 and c <= 0x1F) or c == 0x7F;
}

fn hexDigitsNeeded(c: u8) usize {
    if (c < 0x10) {
        return 1;
    }
    return 2;
}

fn writeEscape(comptime is_first: bool, buf: []u8, c: u8) usize {
    if (c == 0) {
        // NULL character becomes replacement character (no backslash)
        const replacement = "\u{FFFD}";
        @memcpy(buf[0..replacement.len], replacement);
        return replacement.len;
    }

    buf[0] = '\\';
    var data = buf[1..];

    if (isHexEscape(c) or ((comptime is_first) and c >= '0' and c <= '9')) {
        const hex_str = std.fmt.bufPrint(data, "{x} ", .{c}) catch unreachable;
        return 1 + hex_str.len;
    }

    data[0] = c;
    return 2;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSS);

    pub const Meta = struct {
        pub const name = "Css";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const escape = bridge.function(CSS.escape, .{});
    pub const supports = bridge.function(CSS.supports, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: CSS" {
    try testing.htmlRunner("css.html", .{});
}

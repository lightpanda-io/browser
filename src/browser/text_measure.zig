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

const std = @import("std");

// Deterministic DOM fallback only. This intentionally does not claim to shape
// scripts, apply kerning, or select fonts; a real shaping backend can replace
// this module without changing SVGTextContentElement.

// Character counts and indices are UTF-16 code units, to match DOM string
// semantics: an astral codepoint is two addressable characters in browsers.
pub fn utf16Length(text: []const u8) u32 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: u32 = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        result += unitLength(codepoint);
    }
    return result;
}

fn unitLength(codepoint: u21) u32 {
    return if (codepoint >= 0x10000) 2 else 1;
}

pub fn width(text: []const u8, font_size: f64) f64 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: f64 = 0;
    while (iterator.nextCodepoint()) |codepoint| result += advance(codepoint, font_size);
    return result;
}

pub fn substringWidth(text: []const u8, charnum: u32, nchars: u32, font_size: f64) !f64 {
    if (charnum >= utf16Length(text)) return error.IndexSizeError;
    const end = charnum +| nchars;

    // A glyph is measured whenever its unit range intersects the request, so
    // addressing either half of a surrogate pair yields the full glyph, like
    // Chrome does.
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var unit: u32 = 0;
    var result: f64 = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        const units = unitLength(codepoint);
        if (unit >= end) break;
        if (unit + units > charnum) result += advance(codepoint, font_size);
        unit += units;
    }
    return result;
}

fn advance(codepoint: u21, font_size: f64) f64 {
    if (isZeroWidth(codepoint)) return 0;
    if (codepoint == '\n' or codepoint == '\r') return 0;
    if (codepoint == '\t') return font_size * 1.32;
    if (std.ascii.isWhitespace(@intCast(@min(codepoint, 0x7f)))) return font_size * 0.33;
    if (isWide(codepoint)) return font_size;
    return font_size * 0.6;
}

fn isZeroWidth(codepoint: u21) bool {
    return codepoint == 0x200c or codepoint == 0x200d or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        codepoint == 0x2329 or codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

test "fallback metrics count utf-16 units and ignore combining marks" {
    try std.testing.expectEqual(@as(u32, 3), utf16Length("Aé界"));
    try std.testing.expectEqual(@as(u32, 2), utf16Length("🌍"));
    try std.testing.expectApproxEqAbs(@as(f64, 16), width("A\u{0301}界", 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("A界", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("🌍", 0, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("🌍", 1, 1, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try substringWidth("A界", 1, 0, 10), 0.0001);
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 2, 1, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 1, 0, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("", 0, 0, 10));
}

// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// Deterministic DOM fallback only. This intentionally does not claim to shape
// scripts, apply kerning, or select fonts; a real shaping backend can replace
// this module without changing SVGTextContentElement.
pub fn countCodepoints(text: []const u8) u32 {
    return @intCast(std.unicode.utf8CountCodepoints(text) catch 0);
}

pub fn width(text: []const u8, font_size: f64) f64 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var result: f64 = 0;
    while (iterator.nextCodepoint()) |codepoint| result += advance(codepoint, font_size);
    return result;
}

pub fn substringWidth(text: []const u8, offset: u32, count: u32, font_size: f64) !f64 {
    if (text.len == 0) return error.IndexSizeError;

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var index: u32 = 0;
    while (index < offset) : (index += 1) {
        if (iterator.nextCodepoint() == null) return error.IndexSizeError;
    }
    if (offset > 0 and iterator.i == text.len) return error.IndexSizeError;

    var result: f64 = 0;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        const codepoint = iterator.nextCodepoint() orelse break;
        result += advance(codepoint, font_size);
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

test "fallback metrics count codepoints and ignore combining marks" {
    try std.testing.expectEqual(@as(u32, 3), countCodepoints("Aé界"));
    try std.testing.expectApproxEqAbs(@as(f64, 16), width("A\u{0301}界", 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), try substringWidth("A界", 1, 1, 10), 0.0001);
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 2, 1, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("A", 1, 0, 10));
    try std.testing.expectError(error.IndexSizeError, substringWidth("", 0, 0, 10));
}

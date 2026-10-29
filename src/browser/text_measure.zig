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

/// Line height for `line-height: normal`, in em.
pub const LINE_HEIGHT = 1.2;

/// Glyph extents above and below the baseline, in em, as in a generic
/// sans-serif face.
pub const ASCENT = 0.8;
pub const DESCENT = 0.2;

pub const WhiteSpace = struct {
    wrap: bool = true, // Lines break between words to fit.
    collapse: bool = true, // run of spaces becomes one and is removed at edges
    newlines: bool = false, // A newline breaks the line.
};

/// The lines a run of text takes: as wide as the widest one.
pub const Lines = struct {
    width: f64 = 0,
    count: u32 = 0,

    pub fn height(self: Lines, font_size: f64) f64 {
        return @as(f64, @floatFromInt(self.count)) * font_size * LINE_HEIGHT;
    }
};

pub fn layout(text: []const u8, font_size: f64, line_width: f64, white_space: WhiteSpace) Lines {
    var wrap: LineWrap = .{ .line_width = line_width, .font_size = font_size, .white_space = white_space };
    wrap.add(text);
    return wrap.lines();
}

pub const LineWrap = struct {
    line_width: f64,
    font_size: f64,
    white_space: WhiteSpace = .{},
    done: Lines = .{},
    x: f64 = 0, // Width used on the current line
    space: f64 = 0, // Spaces due before the next word
    open: bool = false, // The current line has something on it
    has_word: bool = false, // The current line has a word on it
    in_word: bool = false, // The last text added ended mid-word, so the next piece continues it

    pub fn add(self: *LineWrap, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n' and self.white_space.newlines) {
                self.endLine();
                i += 1;
                continue;
            }
            const is_space = std.ascii.isWhitespace(text[i]);
            var end = i + 1;
            while (end < text.len and std.ascii.isWhitespace(text[end]) == is_space and text[end] != '\n') {
                end += 1;
            }
            if (is_space) {
                self.addSpace(text[i..end]);
            } else {
                self.addWord(text[i..end]);
            }
            i = end;
        }
    }

    pub fn lines(self: LineWrap) Lines {
        var copy = self;
        if (copy.open) {
            copy.endLine();
        }
        return copy.done;
    }

    pub fn height(self: LineWrap) f64 {
        return self.lines().height(self.font_size);
    }

    fn addSpace(self: *LineWrap, run: []const u8) void {
        self.in_word = false;
        if (self.white_space.collapse == false) {
            self.space += width(run, self.font_size);
            self.open = true;
        } else if (self.has_word) {
            self.space = advance(' ', self.font_size);
        }
    }

    fn addWord(self: *LineWrap, word: []const u8) void {
        const w = width(word, self.font_size);
        if (self.in_word) {
            // No break inside a word
            self.x += w;
        } else if (self.white_space.wrap and self.has_word and self.x + self.space + w > self.line_width) {
            // Spaces at the break hang off the end of the line
            self.space = 0;
            self.endLine();
            self.x = w;
        } else {
            self.x += self.space + w;
        }
        self.space = 0;
        self.open = true;
        self.has_word = true;
        self.in_word = true;
    }

    fn endLine(self: *LineWrap) void {
        if (self.white_space.collapse == false) {
            self.x += self.space;
        }
        self.done.count += 1;
        self.done.width = @max(self.done.width, self.x);
        self.x = 0;
        self.space = 0;
        self.open = false;
        self.has_word = false;
        self.in_word = false;
    }
};

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

test "LineWrap: collapses whitespace and breaks between words" {
    // At 10px: a letter is 6px, a space 3.3px
    var wrap: LineWrap = .{ .line_width = 60, .font_size = 10 };
    try std.testing.expectEqual(0, wrap.height());

    wrap.add("  aaaa \n\t  aaaa   aaaa ");
    try std.testing.expectEqual(2, wrap.lines().count);

    wrap.add("aaaa");
    try std.testing.expectEqual(2, wrap.lines().count);
    // Continues the word, which can't break, so it overflows the line
    wrap.add("aaaa");
    try std.testing.expectEqual(2, wrap.lines().count);
    try std.testing.expectApproxEqAbs(24, wrap.height(), 0.0001);
    wrap.add(" aaaa");
    try std.testing.expectEqual(3, wrap.lines().count);

    // Long words aren't split
    var narrow: LineWrap = .{ .line_width = 10, .font_size = 10 };
    narrow.add("aaaa aaaa");
    try std.testing.expectEqual(2, narrow.lines().count);
}

test "layout: white-space modes" {
    // At 10px: a letter is 6px, a space 3.3px
    const normal: WhiteSpace = .{};
    const nowrap: WhiteSpace = .{ .wrap = false };
    const pre: WhiteSpace = .{ .collapse = false, .newlines = true, .wrap = false };
    const pre_line: WhiteSpace = .{ .newlines = true };

    // Spaces collapse to one and vanish at the line's edges
    var lines = layout("  ab \n\t cd  ", 10, 100, normal);
    try std.testing.expectEqual(1, lines.count);
    try std.testing.expectApproxEqAbs(27.3, lines.width, 0.0001);

    // Only spaces: no line at all, unless they're preserved
    try std.testing.expectEqual(Lines{}, layout("   ", 10, 100, normal));
    lines = layout("   ", 10, 100, pre);
    try std.testing.expectEqual(1, lines.count);
    try std.testing.expectApproxEqAbs(9.9, lines.width, 0.0001);

    // nbsp is a letter, not a collapsible space
    lines = layout("\u{a0}", 10, 100, normal);
    try std.testing.expectEqual(1, lines.count);
    try std.testing.expect(lines.width > 0);

    // A word wider than the line overflows it
    lines = layout("abc", 10, 2, normal);
    try std.testing.expectEqual(1, lines.count);
    try std.testing.expectApproxEqAbs(18, lines.width, 0.0001);

    // Wraps between words: as wide as the widest line
    lines = layout("abc de", 10, 2, normal);
    try std.testing.expectEqual(2, lines.count);
    try std.testing.expectApproxEqAbs(18, lines.width, 0.0001);
    try std.testing.expectApproxEqAbs(24, lines.height(10), 0.0001);
    try std.testing.expectEqual(1, layout("abc de", 10, 2, nowrap).count);

    // Newlines break the line, but a trailing one doesn't add another
    try std.testing.expectEqual(3, layout("ab\n\ncd\n", 10, 100, pre).count);
    try std.testing.expectEqual(2, layout("ab  \n  cd", 10, 100, pre_line).count);
    try std.testing.expectApproxEqAbs(12, layout("ab  \n  cd", 10, 100, pre_line).width, 0.0001);

    // No font, no size
    try std.testing.expectEqual(0, layout("abc", 0, 100, normal).height(0));
}

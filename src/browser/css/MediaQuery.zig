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

//! Media-query evaluator for inline `<style>` @media rules and
//! `window.matchMedia()`. Deliberately narrow scope: external
//! `<link rel="stylesheet">` fetch is not implemented and not in scope here.
//!
//! Spec subset (Media Queries Level 4 §3) sufficient for the responsive
//! patterns observed in agentic-AI / scraping targets:
//!   - Media types: `all`, `screen`, `print`, `speech`, `tv`
//!   - Features: `width` / `min-width` / `max-width`,
//!               `height` / `min-height` / `max-height`,
//!               `orientation` (portrait | landscape).
//!   - Length values: `<int>px`, `<int>em` (1em = 16px), `<int>rem`,
//!     and bare `0`.
//!   - Operators: `,` (OR), `and`, `not`, `only`.
//!
//! Per spec, any unrecognized media type, unsupported feature, or malformed
//! value evaluates the containing query to `false`. The remaining
//! comma-separated branches are still evaluated independently.
//!
//! See lightpanda-io/browser#2363 sibling and the surrounding discussion
//! around C10 (inline-only narrow scope, no external CSS fetch).

const std = @import("std");

pub const Viewport = struct {
    width: u32,
    height: u32,

    /// Mirrors the hardcoded values exposed by `Window.innerWidth` /
    /// `innerHeight`, `Screen.width` / `height`, and `VisualViewport.width` /
    /// `height`. When viewport emulation lands, this is the single helper to
    /// rewire so the cascade and `matchMedia` move together.
    pub const default = Viewport{
        .width = 1920,
        .height = 1080,
    };
};

/// Returns true if `query` matches the given viewport. Comma-separated
/// queries are evaluated independently and combined with OR.
pub fn matches(query: []const u8, viewport: Viewport) bool {
    // Reject any input with an unbalanced `/* ...` before parsing. Every
    // downstream scanner is comment-aware but only on the assumption that
    // each comment is closed; an unterminated one would otherwise silently
    // swallow the rest of the input and could flip a partially-parsed query
    // to `true`.
    if (hasUnterminatedComment(query)) return false;

    var rest = trimWsAndComments(query);
    if (rest.len == 0) return false;

    while (rest.len > 0) {
        const cut = nextTopLevelComma(rest);
        const piece = trimWsAndComments(rest[0..cut]);
        if (piece.len > 0 and matchesSingle(piece, viewport)) return true;
        if (cut == rest.len) break;
        rest = rest[cut + 1 ..];
    }
    return false;
}

/// Returns true if `s` contains an opening `/*` without a matching `*/`.
/// Called once at the top of `matches`; lets every other scanner trust that
/// comments are balanced.
fn hasUnterminatedComment(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) {
        if (s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return true;
            i = close + 2;
            continue;
        }
        i += 1;
    }
    return false;
}

/// Advance `i` past any whitespace and `/* ... */` comments. Assumes
/// comments are balanced (see `hasUnterminatedComment`); an unterminated
/// comment encountered defensively returns `s.len` so the caller breaks out.
fn skipWsAndComments(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        if (std.ascii.isWhitespace(s[i])) {
            i += 1;
        } else if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return s.len;
            i = close + 2;
        } else break;
    }
    return i;
}

/// Strip leading and trailing whitespace and `/* ... */` comments from `s`.
/// Interior trivia is preserved; token-by-token scanners skip it as they go.
fn trimWsAndComments(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        if (std.ascii.isWhitespace(s[start])) {
            start += 1;
        } else if (start + 1 < end and s[start] == '/' and s[start + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, start + 2, "*/") orelse return s[start..end];
            start = close + 2;
        } else break;
    }
    while (end > start) {
        if (std.ascii.isWhitespace(s[end - 1])) {
            end -= 1;
        } else if (end >= start + 2 and s[end - 1] == '/' and s[end - 2] == '*') {
            const open_rel = std.mem.lastIndexOf(u8, s[start .. end - 2], "/*") orelse return s[start..end];
            end = start + open_rel;
        } else break;
    }
    return s[start..end];
}

/// First occurrence of `needle` in `s` that is not inside a `/* ... */`
/// comment. Comments are assumed balanced (see `hasUnterminatedComment`).
fn indexOfScalarSkippingComments(s: []const u8, needle: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return null;
            i = close + 2;
            continue;
        }
        if (s[i] == needle) return i;
        i += 1;
    }
    return null;
}

fn nextTopLevelComma(s: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return s.len;
            i = close + 2;
            continue;
        }
        switch (s[i]) {
            '(' => depth += 1,
            ')' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return s.len;
}

const MediaType = enum { all, screen, print, speech, tv };

fn parseMediaType(word: []const u8) ?MediaType {
    if (std.mem.eql(u8, word, "all")) return .all;
    if (std.mem.eql(u8, word, "screen")) return .screen;
    if (std.mem.eql(u8, word, "print")) return .print;
    if (std.mem.eql(u8, word, "speech")) return .speech;
    if (std.mem.eql(u8, word, "tv")) return .tv;
    return null;
}

fn matchesSingle(query: []const u8, viewport: Viewport) bool {
    var negate = false;
    var type_set: ?MediaType = null;
    var features_match = true;
    var saw_token = false;

    var i: usize = 0;
    while (i < query.len) {
        i = skipWsAndComments(query, i);
        if (i >= query.len) break;

        if (query[i] == '(') {
            const end = findClosingParen(query, i) orelse return false;
            const inner = query[i + 1 .. end];
            if (!evalFeature(inner, viewport)) features_match = false;
            saw_token = true;
            i = end + 1;
            continue;
        }

        const start = i;
        while (i < query.len and isIdentChar(query[i])) {
            i += 1;
        }

        const len = i - start;
        if (len < 2 or len > 16) {
            return false;
        }

        var word_buf: [16]u8 = undefined;
        const word = std.ascii.lowerString(&word_buf, query[start..i]);

        saw_token = true;
        if (std.mem.eql(u8, word, "not")) {
            negate = true;
        } else if (std.mem.eql(u8, word, "only")) {
            // 'only' is a hint to legacy parsers — treat as a no-op qualifier.
        } else if (std.mem.eql(u8, word, "and")) {
            // separator between media-type and feature, or between features.
        } else if (parseMediaType(word)) |t| {
            type_set = t;
        } else {
            // Unknown ident in media-type position: per spec the whole query
            // is treated as a non-matching type.
            return false;
        }
    }

    if (!saw_token) {
        return false;
    }

    const type_matches = if (type_set) |t|
        switch (t) {
            .all, .screen => true,
            .print, .speech, .tv => false,
        }
    else
        true;

    const result = type_matches and features_match;
    return if (negate) !result else result;
}

fn findClosingParen(s: []const u8, open: usize) ?usize {
    std.debug.assert(s[open] == '(');
    var depth: usize = 1;
    var i = open + 1;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, s, i + 2, "*/") orelse return null;
            i = close + 2;
            continue;
        }
        if (s[i] == '(') {
            depth += 1;
        } else if (s[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn evalFeature(text: []const u8, viewport: Viewport) bool {
    const trimmed = trimWsAndComments(text);
    if (trimmed.len == 0) return false;

    if (indexOfScalarSkippingComments(trimmed, ':')) |colon| {
        const name = trimWsAndComments(trimmed[0..colon]);
        const value = trimWsAndComments(trimmed[colon + 1 ..]);
        return evalNameValue(name, value, viewport);
    }

    return evalBoolean(trimmed, viewport);
}

fn evalNameValue(name: []const u8, value: []const u8, viewport: Viewport) bool {
    if (name.len > 16) {
        return false;
    }

    var buf: [16]u8 = undefined;
    const lname = std.ascii.lowerString(&buf, name);
    if (std.mem.eql(u8, lname, "min-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width >= px;
    }
    if (std.mem.eql(u8, lname, "max-width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width <= px;
    }
    if (std.mem.eql(u8, lname, "width")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.width == px;
    }
    if (std.mem.eql(u8, lname, "min-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height >= px;
    }
    if (std.mem.eql(u8, lname, "max-height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height <= px;
    }
    if (std.mem.eql(u8, lname, "height")) {
        const px = parseLengthPx(value) orelse return false;
        return viewport.height == px;
    }
    if (std.mem.eql(u8, lname, "orientation")) {
        if (std.ascii.eqlIgnoreCase(value, "landscape")) return viewport.width >= viewport.height;
        if (std.ascii.eqlIgnoreCase(value, "portrait")) return viewport.height > viewport.width;
        return false;
    }
    return false;
}

fn evalBoolean(name: []const u8, viewport: Viewport) bool {
    if (name.len > 16) {
        return false;
    }
    var buf: [16]u8 = undefined;
    const lname = std.ascii.lowerString(&buf, name);

    if (std.mem.eql(u8, lname, "width")) return viewport.width > 0;
    if (std.mem.eql(u8, lname, "height")) return viewport.height > 0;
    if (std.mem.eql(u8, lname, "orientation")) return true;
    return false;
}

/// Parse `<int>px`, `<int>em` (1em=16px), `<int>rem`, or bare `0`.
/// Negative lengths are rejected per the Media Queries spec (`<length>` in
/// media features may not be negative). Returns null on any other form.
fn parseLengthPx(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '-') return null;

    var i: usize = 0;
    if (i < trimmed.len and trimmed[i] == '+') i += 1;
    const num_start = i;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i == num_start) return null;

    const num = std.fmt.parseInt(u32, trimmed[num_start..i], 10) catch return null;
    const unit = std.mem.trim(u8, trimmed[i..], &std.ascii.whitespace);

    if (unit.len == 0) {
        return if (num == 0) 0 else null;
    }
    if (std.ascii.eqlIgnoreCase(unit, "px")) return num;
    // `em` / `rem`: 1em = 16px. `std.math.mul` returns an error on u32 overflow
    // (e.g. `268435456em` would otherwise wrap or panic in debug); treat that
    // as an unparseable length so the query fails closed per MQ4.
    if (std.ascii.eqlIgnoreCase(unit, "em")) return std.math.mul(u32, num, 16) catch null;
    if (std.ascii.eqlIgnoreCase(unit, "rem")) return std.math.mul(u32, num, 16) catch null;
    return null;
}

const testing = std.testing;

test "MediaQuery: empty query is false" {
    try testing.expect(!matches("", Viewport.default));
    try testing.expect(!matches("   ", Viewport.default));
}

test "MediaQuery: bare media types" {
    const v = Viewport.default;
    try testing.expect(matches("all", v));
    try testing.expect(matches("screen", v));
    try testing.expect(matches("ALL", v));
    try testing.expect(matches("Screen", v));
    try testing.expect(!matches("print", v));
    try testing.expect(!matches("speech", v));
    try testing.expect(!matches("tv", v));
}

test "MediaQuery: unknown ident is false" {
    try testing.expect(!matches("foo", Viewport.default));
    try testing.expect(!matches("braille", Viewport.default));
}

test "MediaQuery: min-width on 1920x1080 viewport" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 1px)", v));
    try testing.expect(matches("(min-width: 600px)", v));
    try testing.expect(matches("(min-width: 1920px)", v));
    try testing.expect(!matches("(min-width: 1921px)", v));
    try testing.expect(!matches("(min-width: 3000px)", v));
}

test "MediaQuery: max-width" {
    const v = Viewport.default;
    try testing.expect(matches("(max-width: 1920px)", v));
    try testing.expect(matches("(max-width: 2000px)", v));
    try testing.expect(!matches("(max-width: 1919px)", v));
    try testing.expect(!matches("(max-width: 0)", v));
}

test "MediaQuery: width (exact)" {
    const v = Viewport.default;
    try testing.expect(matches("(width: 1920px)", v));
    try testing.expect(!matches("(width: 1921px)", v));
    try testing.expect(!matches("(width: 1919px)", v));
}

test "MediaQuery: min-height / max-height / height" {
    const v = Viewport.default;
    try testing.expect(matches("(min-height: 1080px)", v));
    try testing.expect(!matches("(min-height: 1081px)", v));
    try testing.expect(matches("(max-height: 1080px)", v));
    try testing.expect(!matches("(max-height: 1079px)", v));
    try testing.expect(matches("(height: 1080px)", v));
    try testing.expect(!matches("(height: 1081px)", v));
}

test "MediaQuery: orientation" {
    const v = Viewport.default;
    try testing.expect(matches("(orientation: landscape)", v));
    try testing.expect(!matches("(orientation: portrait)", v));

    const portrait: Viewport = .{ .width = 600, .height = 800 };
    try testing.expect(!matches("(orientation: landscape)", portrait));
    try testing.expect(matches("(orientation: portrait)", portrait));

    const square: Viewport = .{ .width = 500, .height = 500 };
    try testing.expect(matches("(orientation: landscape)", square));
    try testing.expect(!matches("(orientation: portrait)", square));
}

test "MediaQuery: combined with `and`" {
    const v = Viewport.default;
    try testing.expect(matches("screen and (min-width: 600px)", v));
    try testing.expect(!matches("print and (min-width: 600px)", v));
    try testing.expect(matches("(min-width: 600px) and (max-width: 2000px)", v));
    try testing.expect(!matches("(min-width: 600px) and (max-width: 1000px)", v));
    try testing.expect(matches("all and (orientation: landscape)", v));
}

test "MediaQuery: `not` negates" {
    const v = Viewport.default;
    try testing.expect(matches("not print", v));
    try testing.expect(!matches("not screen", v));
    try testing.expect(!matches("not (min-width: 600px)", v));
    try testing.expect(matches("not (min-width: 3000px)", v));
}

test "MediaQuery: comma is OR" {
    const v = Viewport.default;
    try testing.expect(matches("print, screen", v));
    try testing.expect(matches("(max-width: 100px), (min-width: 600px)", v));
    try testing.expect(!matches("(max-width: 100px), (min-width: 3000px)", v));
    try testing.expect(matches("foo, screen", v));
}

test "MediaQuery: `only` is no-op" {
    const v = Viewport.default;
    try testing.expect(matches("only screen", v));
    try testing.expect(matches("only screen and (min-width: 600px)", v));
    try testing.expect(!matches("only print", v));
}

test "MediaQuery: em units (1em=16px)" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 30em)", v)); // 480px <= 1920px
    try testing.expect(matches("(min-width: 120em)", v)); // 1920px == 1920
    try testing.expect(!matches("(min-width: 121em)", v)); // 1936px > 1920
}

test "MediaQuery: rem treated as em" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 30rem)", v));
    try testing.expect(!matches("(min-width: 121rem)", v));
}

test "MediaQuery: bare 0 is valid" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width: 0)", v));
    try testing.expect(!matches("(max-width: 0)", v));
}

test "MediaQuery: unknown feature is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(monochrome)", v));
    try testing.expect(!matches("(prefers-color-scheme: dark)", v));
    try testing.expect(!matches("(prefers-reduced-motion: reduce)", v));
    try testing.expect(!matches("(hover: hover)", v));
    try testing.expect(!matches("(color)", v));
}

test "MediaQuery: malformed value is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: foo)", v));
    try testing.expect(!matches("(min-width:)", v));
    try testing.expect(!matches("(min-width: -100px)", v));
    try testing.expect(!matches("(min-width: 100xx)", v));
}

test "MediaQuery: boolean form (feature presence)" {
    const v = Viewport.default;
    try testing.expect(matches("(width)", v));
    try testing.expect(matches("(height)", v));
    try testing.expect(matches("(orientation)", v));
    try testing.expect(!matches("(monochrome)", v));
    try testing.expect(!matches("(color)", v));
}

test "MediaQuery: viewport-default values" {
    const v = Viewport.default;
    try testing.expectEqual(@as(u32, 1920), v.width);
    try testing.expectEqual(@as(u32, 1080), v.height);
}

test "MediaQuery: leading whitespace and case" {
    const v = Viewport.default;
    try testing.expect(matches("  (MIN-WIDTH: 600PX)  ", v));
    try testing.expect(matches("SCREEN AND (Min-Width: 600px)", v));
}

test "MediaQuery: malformed query is false" {
    const v = Viewport.default;
    try testing.expect(!matches("(", v));
    try testing.expect(!matches("(min-width: 600px", v));
    try testing.expect(!matches("@@@", v));
}

test "MediaQuery: not print is true on screen viewport" {
    // Common pattern: `<style media="not print">`
    const v = Viewport.default;
    try testing.expect(matches("not print", v));
}

test "MediaQuery: common responsive breakpoint" {
    // Pattern: hide one of mobile/desktop CTA duplicates above a breakpoint.
    const v = Viewport.default; // 1920×1080 — desktop side.
    try testing.expect(matches("(min-width: 768px)", v));
    try testing.expect(!matches("(max-width: 767px)", v));
}

test "MediaQuery: comments are stripped" {
    const v = Viewport.default;
    // Comment between tokens.
    try testing.expect(matches("screen and /*hidden*/ (min-width: 1px)", v));
    // Comment at the start.
    try testing.expect(matches("/* leading */ screen", v));
    // Comment that would otherwise change parens depth.
    try testing.expect(matches("(min-width: /* hi */ 600px)", v));
    // Comment containing a comma — must not split the query.
    try testing.expect(matches("screen /*, print*/", v));
    // Unclosed comment falls through to the parser, which fails closed.
    try testing.expect(!matches("/* unterminated", v));
}

test "MediaQuery: em / rem overflow fails closed" {
    const v = Viewport.default;
    // 268435456 × 16 overflows u32 (would wrap to 0); the evaluator must
    // treat the length as unparseable and the query as non-matching.
    try testing.expect(!matches("(min-width: 268435456em)", v));
    try testing.expect(!matches("(min-width: 268435456rem)", v));
    // Just below the overflow threshold still parses (but doesn't match
    // because 268435455 × 16 > viewport width).
    try testing.expect(!matches("(min-width: 268435455em)", v));
}

test "MediaQuery: unimplemented units fail closed" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: 5cm)", v));
    try testing.expect(!matches("(min-width: 50mm)", v));
    try testing.expect(!matches("(min-width: 10pt)", v));
    try testing.expect(!matches("(min-width: 1in)", v));
    try testing.expect(!matches("(min-width: 50vw)", v));
}

test "MediaQuery: range syntax is unsupported (fails closed)" {
    const v = Viewport.default;
    // MQ4 range form is not implemented — should evaluate false rather than
    // accidentally matching via the `width` boolean form.
    try testing.expect(!matches("(width >= 600px)", v));
    try testing.expect(!matches("(width <= 600px)", v));
    try testing.expect(!matches("(width < 100px)", v));
    try testing.expect(!matches("(600px <= width <= 1200px)", v));
}

test "MediaQuery: decimal lengths are rejected" {
    const v = Viewport.default;
    try testing.expect(!matches("(min-width: 600.5px)", v));
    try testing.expect(!matches("(min-width: 0.5em)", v));
    try testing.expect(!matches("(width: 1920.0px)", v));
}

test "MediaQuery: whitespace-tight and -loose features" {
    const v = Viewport.default;
    try testing.expect(matches("(min-width:600px)", v));
    try testing.expect(matches("( min-width : 600px )", v));
    try testing.expect(matches("(  min-width  :  600px  )", v));
}

test "MediaQuery: additional comment placements" {
    const v = Viewport.default;
    // Two adjacent comments between tokens.
    try testing.expect(matches("screen /*a*/ /*b*/ and (min-width: 1px)", v));
    // Comments on both sides of the feature content.
    try testing.expect(matches("(/*a*/ min-width: 600px /*b*/)", v));
    // Comment that contains a colon — must not be confused with the
    // feature's `:` separator.
    try testing.expect(matches("(/* foo:bar */ min-width: 600px)", v));
    // Comment that contains parens — must not derail paren matching.
    try testing.expect(matches("(min-width: 600px /* ) ( */ )", v));
}

test "MediaQuery: u32 boundaries on length" {
    const v = Viewport.default;
    // u32 max parses; the viewport (1920) doesn't reach it.
    try testing.expect(!matches("(min-width: 4294967295px)", v));
    // Beyond u32 max overflows parseInt and fails closed.
    try testing.expect(!matches("(min-width: 4294967296px)", v));
    try testing.expect(!matches("(min-width: 9999999999px)", v));
}

test "MediaQuery: empty parens" {
    const v = Viewport.default;
    try testing.expect(!matches("()", v));
    try testing.expect(!matches("(   )", v));
    try testing.expect(!matches("screen and ()", v));
}

test "MediaQuery: long AND chains" {
    const v = Viewport.default;
    try testing.expect(matches(
        "screen and (min-width: 600px) and (max-width: 2000px) and (orientation: landscape)",
        v,
    ));
    try testing.expect(!matches(
        "screen and (min-width: 600px) and (max-width: 1000px) and (orientation: landscape)",
        v,
    ));
}

test "MediaQuery: not all is always false" {
    try testing.expect(!matches("not all", Viewport.default));
}

test "MediaQuery: not applies to the whole query" {
    const v = Viewport.default;
    // For 1920×1080: (min-width:3000px)=false, (orientation:landscape)=true.
    // Combined feature match is false; `not` flips it to true.
    try testing.expect(matches("not (min-width: 3000px) and (orientation: landscape)", v));
    // Both branches true → combined true → `not` flips to false.
    try testing.expect(!matches("not (min-width: 1px) and (orientation: landscape)", v));
}

test "MediaQuery: multibyte UTF-8 tokens fail closed" {
    const v = Viewport.default;
    // Unsupported feature name with a multi-byte character.
    try testing.expect(!matches("(café-width: 600px)", v));
    // Multi-byte identifier in media-type position.
    try testing.expect(!matches("café", v));
}

test "MediaQuery: trailing unterminated comment fails closed" {
    const v = Viewport.default;
    // A valid prefix followed by an unbalanced `/* ...` must still evaluate
    // to false. Without an explicit guard, the inline comment-skipper would
    // silently consume the rest of the input and return whatever the prefix
    // already parsed to.
    try testing.expect(!matches("screen /* unterminated", v));
    try testing.expect(!matches("(min-width: 600px) /* unterminated", v));
    // Terminated then unterminated.
    try testing.expect(!matches("screen /* a */ /* b", v));
}

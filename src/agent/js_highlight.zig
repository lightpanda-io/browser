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

pub const Kind = enum { comment, string, variable, number, keyword, global };

/// Carried between calls because fenced code is tokenized one line at a time:
/// block comments and template literals outlive a line boundary.
pub const State = enum { normal, block_comment, template };

pub const StringSpan = struct { end: usize, closed: bool };

/// Scan the quoted run opening at `text[start]`, including the triple-delimiter
/// form. Escapes are not honored, matching the prompt highlighter's behavior.
pub fn scanString(text: []const u8, start: usize) StringSpan {
    if (start >= text.len) return .{ .end = start, .closed = false };
    const ch = text[start];
    if (start + 2 < text.len and text[start + 1] == ch and text[start + 2] == ch) {
        const delim = text[start .. start + 3];
        const close = std.mem.indexOfPos(u8, text, start + 3, delim) orelse
            return .{ .end = text.len, .closed = false };
        return .{ .end = close + 3, .closed = true };
    }
    const close = std.mem.indexOfScalarPos(u8, text, start + 1, ch) orelse
        return .{ .end = text.len, .closed = false };
    return .{ .end = close + 1, .closed = true };
}

/// Tokenize `text` as JavaScript starting from `state`, reporting spans to
/// `sink.emit(start, len, kind)` and returning the state at end of input.
/// Spans arrive in order and never overlap — the gaps between them are plain
/// text — so an emitter that writes sequentially (ANSI) works as well as one
/// that paints cells (isocline).
pub fn tokenize(text: []const u8, state: State, sink: anytype) State {
    var i: usize = 0;

    switch (state) {
        .block_comment => {
            const close = std.mem.indexOfPos(u8, text, 0, "*/");
            i = if (close) |p| p + 2 else text.len;
            if (i > 0) sink.emit(0, i, .comment);
            if (close == null) return .block_comment;
        },
        .template => {
            const close = std.mem.indexOfScalarPos(u8, text, 0, '`');
            i = if (close) |p| p + 1 else text.len;
            emitString(text, 0, i, sink);
            if (close == null) return .template;
        },
        .normal => {},
    }

    while (i < text.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and (text[i + 1] == '/' or text[i + 1] == '*')) {
            const start = i;
            if (text[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, text, i + 2, '\n') orelse text.len;
                sink.emit(start, i - start, .comment);
                continue;
            }
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/");
            i = if (close) |p| p + 2 else text.len;
            sink.emit(start, i - start, .comment);
            if (close == null) return .block_comment;
            continue;
        }
        if (ch == '\'' or ch == '"' or ch == '`') {
            const span = scanString(text, i);
            emitString(text, i, span.end, sink);
            i = span.end;
            // Only a template literal may legally continue on the next line.
            if (!span.closed and ch == '`') return .template;
            continue;
        }
        if (ch == '$') {
            const start = i;
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
            if (i > start + 1) sink.emit(start, i - start, .variable);
            continue;
        }
        if (std.ascii.isDigit(ch) or (ch == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            const start = i;
            i += 1;
            while (i < text.len and (std.ascii.isHex(text[i]) or text[i] == '.' or text[i] == '_' or text[i] == 'x' or text[i] == 'X')) i += 1;
            sink.emit(start, i - start, .number);
            continue;
        }
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            i += 1;
            while (i < text.len and isIdChar(text[i])) i += 1;
            const tok = text[start..i];
            if (isKeyword(tok)) {
                sink.emit(start, i - start, .keyword);
            } else if (isGlobal(tok) and (start == 0 or text[start - 1] != '.')) {
                // `.document` is a property access, not the global
                sink.emit(start, i - start, .global);
            }
            continue;
        }
        i += 1;
    }
    return .normal;
}

/// Emit `text[start..end]` as string spans split around any `$name` refs, so
/// the two never overlap. The prompt highlighter used to paint the ref over the
/// string and lean on isocline's last-write-wins per cell; splitting keeps the
/// same result while staying safe for a sequential writer.
fn emitString(text: []const u8, start: usize, end: usize, sink: anytype) void {
    var seg = start;
    var i = start;
    while (i < end) {
        if (text[i] != '$') {
            i += 1;
            continue;
        }
        const tok = i;
        i += 1;
        while (i < end and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
        if (i > tok + 1) {
            if (tok > seg) sink.emit(seg, tok - seg, .string);
            sink.emit(tok, i - tok, .variable);
            seg = i;
        }
    }
    if (end > seg) sink.emit(seg, end - seg, .string);
}

const keywords = [_][]const u8{
    "function", "async",  "await", "yield",   "return",    "if",     "else",
    "for",      "while",  "do",    "switch",  "case",      "break",  "continue",
    "var",      "let",    "const", "new",     "delete",    "typeof", "instanceof",
    "in",       "of",     "void",  "this",    "super",     "class",  "extends",
    "import",   "export", "from",  "default", "try",       "catch",  "finally",
    "throw",    "true",   "false", "null",    "undefined", "NaN",    "Infinity",
};

// Globals available in the JS-mode page context; highlighted so it's visible
// at the prompt that they're in scope.
const globals = [_][]const u8{ "document", "window", "globalThis", "console", "lp" };

pub fn isKeyword(tok: []const u8) bool {
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, tok)) return true;
    }
    return false;
}

pub fn isGlobal(tok: []const u8) bool {
    for (globals) |g| {
        if (std.mem.eql(u8, g, tok)) return true;
    }
    return false;
}

pub fn isIdChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$' or ch >= 0x80;
}

const testing = std.testing;

/// Records spans as `kind:text` so tests read as the tokenization, not offsets.
const TestSink = struct {
    text: []const u8,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    last_end: usize = 0,
    overlapped: bool = false,

    fn emit(self: *TestSink, start: usize, len: usize, kind: Kind) void {
        if (start < self.last_end) self.overlapped = true;
        self.last_end = start + len;
        self.buf.writer(testing.allocator).print("{s}:{s} ", .{
            @tagName(kind), self.text[start..][0..len],
        }) catch unreachable;
    }
};

fn expectTokens(expected: []const u8, src: []const u8) !void {
    var sink: TestSink = .{ .text = src };
    defer sink.buf.deinit(testing.allocator);
    _ = tokenize(src, .normal, &sink);
    try testing.expect(!sink.overlapped);
    try testing.expectEqualStrings(expected, std.mem.trimRight(u8, sink.buf.items, " "));
}

test "js_highlight: keywords, globals, numbers" {
    try expectTokens("keyword:const number:1", "const x = 1");
    try expectTokens("global:document", "document.body");
    // A property access is not the global.
    try expectTokens("", "el.document");
}

test "js_highlight: comments and strings" {
    try expectTokens("comment:// hi", "// hi");
    try expectTokens("comment:/* hi */ keyword:const", "/* hi */ const");
    try expectTokens("string:'hi'", "'hi'");
}

test "js_highlight: $refs inside strings do not overlap" {
    try expectTokens("string:'a  variable:$LP_KEY string:'", "'a $LP_KEY'");
    try expectTokens("variable:$LP_KEY", "$LP_KEY");
}

test "js_highlight: block comment spans lines" {
    var sink: TestSink = .{ .text = "/* open" };
    defer sink.buf.deinit(testing.allocator);
    try testing.expectEqual(State.block_comment, tokenize("/* open", .normal, &sink));

    var sink2: TestSink = .{ .text = "still */ const" };
    defer sink2.buf.deinit(testing.allocator);
    try testing.expectEqual(State.normal, tokenize("still */ const", .block_comment, &sink2));
    try testing.expectEqualStrings("comment:still */ keyword:const", std.mem.trimRight(u8, sink2.buf.items, " "));
}

test "js_highlight: template literal spans lines" {
    var sink: TestSink = .{ .text = "`<div>" };
    defer sink.buf.deinit(testing.allocator);
    try testing.expectEqual(State.template, tokenize("`<div>", .normal, &sink));

    var sink2: TestSink = .{ .text = "</div>` + x" };
    defer sink2.buf.deinit(testing.allocator);
    try testing.expectEqual(State.normal, tokenize("</div>` + x", .template, &sink2));
    try testing.expectEqualStrings("string:</div>`", std.mem.trimRight(u8, sink2.buf.items, " "));
}

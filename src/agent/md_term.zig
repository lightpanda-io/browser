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
const ansi = @import("Terminal.zig").ansi;

/// Render markdown `src` to an ANSI-styled terminal string owned by `arena`.
pub fn render(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    // Output is the input plus a bounded number of short escape sequences.
    var aw: std.Io.Writer.Allocating = try .initCapacity(arena, src.len + src.len / 4);
    const w = &aw.writer;

    var in_fence = false;
    var wrote_any = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        // Drop the ``` delimiter entirely: no line, no separator.
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (wrote_any) try w.writeByte('\n');
        wrote_any = true;
        try renderLine(w, line, in_fence);
    }
    return aw.written();
}

fn renderLine(w: *std.Io.Writer, line: []const u8, in_fence: bool) !void {
    if (in_fence) {
        try styled(w, line, ansi.dim);
        return;
    }

    const indent_len = line.len - std.mem.trimLeft(u8, line, " \t").len;
    const indent = line[0..indent_len];
    const trimmed = line[indent_len..];

    if (trimmed.len >= 1 and trimmed[0] == '>') {
        try styled(w, "│", ansi.dim);
        try w.writeByte(' ');
        try renderInline(w, std.mem.trimLeft(u8, trimmed[1..], " "));
        return;
    }

    if (isHorizontalRule(trimmed)) {
        try styled(w, "─" ** 24, ansi.dim);
        return;
    }

    var hashes: usize = 0;
    while (hashes < trimmed.len and trimmed[hashes] == '#') hashes += 1;
    if (hashes >= 1 and hashes <= 6 and hashes < trimmed.len and trimmed[hashes] == ' ') {
        try w.writeAll(ansi.bold);
        try renderInline(w, std.mem.trimLeft(u8, trimmed[hashes..], " "));
        try w.writeAll(ansi.reset);
        return;
    }

    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        try w.writeAll(indent);
        try styled(w, "•", ansi.dim);
        try w.writeByte(' ');
        try renderInline(w, trimmed[2..]);
        return;
    }

    // Numbered list keeps its marker verbatim; a bullet is normalized to '•'.
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits > 0 and digits + 1 < trimmed.len and
        (trimmed[digits] == '.' or trimmed[digits] == ')') and trimmed[digits + 1] == ' ')
    {
        try w.writeAll(indent);
        try w.writeAll(trimmed[0 .. digits + 2]);
        try renderInline(w, trimmed[digits + 2 ..]);
        return;
    }

    try renderInline(w, line);
}

fn renderInline(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            // Only unescape markdown-special chars; leave e.g. `C:\Users` intact.
            '\\' => if (i + 1 < text.len and isEscapable(text[i + 1])) {
                try w.writeByte(text[i + 1]);
                i += 2;
                continue;
            },
            '`' => if (std.mem.indexOfPos(u8, text, i + 1, "`")) |end| {
                try styled(w, text[i + 1 .. end], ansi.cyan);
                i = end + 1;
                continue;
            },
            '*', '_' => |ch| {
                const double = [2]u8{ ch, ch };
                if (i + 1 < text.len and text[i + 1] == ch) {
                    if (std.mem.indexOfPos(u8, text, i + 2, &double)) |end| {
                        try styled(w, text[i + 2 .. end], ansi.bold);
                        i = end + 2;
                        continue;
                    }
                } else if (std.mem.indexOfScalarPos(u8, text, i + 1, ch)) |end| {
                    try styled(w, text[i + 1 .. end], ansi.italic);
                    i = end + 1;
                    continue;
                }
            },
            '~' => if (i + 1 < text.len and text[i + 1] == '~') {
                if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                    try styled(w, text[i + 2 .. end], ansi.strike);
                    i = end + 2;
                    continue;
                }
            },
            '[' => if (std.mem.indexOfPos(u8, text, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, text, mid + 2, ')')) |end| {
                    try renderLink(w, text[i + 1 .. mid], text[mid + 2 .. end]);
                    i = end + 1;
                    continue;
                }
            },
            else => {},
        }
        try w.writeByte(text[i]);
        i += 1;
    }
}

fn styled(w: *std.Io.Writer, inner: []const u8, style: []const u8) !void {
    try w.writeAll(style);
    try w.writeAll(inner);
    try w.writeAll(ansi.reset);
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '*', '_', '`', '~', '[', ']', '(', ')', '\\' => true,
        else => false,
    };
}

/// A line of 3+ identical `-`, `*` or `_` markers (spaces ignored).
fn isHorizontalRule(s: []const u8) bool {
    var marker: ?u8 = null;
    var count: usize = 0;
    for (s) |c| switch (c) {
        ' ', '\t' => {},
        '-', '*', '_' => {
            if (marker) |m| {
                if (c != m) return false;
            } else marker = c;
            count += 1;
        },
        else => return false,
    };
    return count >= 3;
}

fn renderLink(w: *std.Io.Writer, label: []const u8, url: []const u8) !void {
    // OSC 8 makes the label clickable where supported and is ignored elsewhere;
    // the trailing dim url is the fallback for terminals without OSC 8.
    try w.print("\x1b]8;;{s}\x1b\\", .{url});
    try styled(w, label, ansi.underline);
    try w.writeAll("\x1b]8;;\x1b\\");
    if (!std.mem.eql(u8, label, url)) try w.print(" {s}({s}){s}", .{ ansi.dim, url, ansi.reset });
}

const testing = std.testing;

fn expectRender(expected: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try render(arena.allocator(), src));
}

test "md_term: inline styles" {
    try expectRender("say \x1b[1mhi\x1b[0m now", "say **hi** now");
    try expectRender("say \x1b[3mhi\x1b[0m now", "say *hi* now");
    try expectRender("say \x1b[3mhi\x1b[0m now", "say _hi_ now");
    try expectRender("run \x1b[36mls\x1b[0m ok", "run `ls` ok");
    try expectRender("no \x1b[9mway\x1b[0m", "no ~~way~~");
}

test "md_term: blocks" {
    try expectRender("\x1b[1mTitle\x1b[0m", "# Title");
    try expectRender("\x1b[1mSub\x1b[0m", "### Sub");
    try expectRender("\x1b[2m•\x1b[0m item", "- item");
    try expectRender("1. item", "1. item");
}

test "md_term: fenced code block" {
    try expectRender("\x1b[2mlet x = 1;\x1b[0m", "```\nlet x = 1;\n```");
}

test "md_term: link" {
    // OSC 8 hyperlink around the label, plus a dim fallback url.
    try expectRender(
        "\x1b]8;;https://x.io\x1b\\\x1b[4mLP\x1b[0m\x1b]8;;\x1b\\ \x1b[2m(https://x.io)\x1b[0m",
        "[LP](https://x.io)",
    );
    // A bare link (label == url) omits the redundant suffix.
    try expectRender(
        "\x1b]8;;https://x.io\x1b\\\x1b[4mhttps://x.io\x1b[0m\x1b]8;;\x1b\\",
        "[https://x.io](https://x.io)",
    );
}

test "md_term: blockquote" {
    try expectRender("\x1b[2m│\x1b[0m quoted \x1b[1mnote\x1b[0m", "> quoted **note**");
}

test "md_term: horizontal rule" {
    try expectRender("\x1b[2m" ++ "─" ** 24 ++ "\x1b[0m", "---");
    try expectRender("\x1b[2m" ++ "─" ** 24 ++ "\x1b[0m", "***");
}

test "md_term: backslash escapes" {
    try expectRender("a * b", "a \\* b");
    try expectRender("keep \\d and C:\\Users", "keep \\d and C:\\Users");
}

test "md_term: unterminated markers stay literal" {
    try expectRender("say **hi now", "say **hi now");
    try expectRender("a * b", "a * b");
    try expectRender("see [x](y", "see [x](y");
}

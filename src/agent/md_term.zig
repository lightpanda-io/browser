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
const js_highlight = @import("js_highlight.zig");

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const strike = "\x1b[9m";
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const clear_eol = "\x1b[K";
    pub const clear_line = "\x1b[2K";
};

/// Render markdown `src` as ANSI-styled terminal output to `w`.
pub fn render(w: *std.Io.Writer, src: []const u8) !void {
    var in_fence = false;
    var js: js_highlight.State = .normal;
    var wrote_any = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        // Drop the ``` delimiter entirely: no line, no separator.
        if (isFenceDelimiter(line)) {
            in_fence = !in_fence;
            js = .normal;
            continue;
        }
        if (wrote_any) try w.writeByte('\n');
        wrote_any = true;
        if (!in_fence and isTableRow(line)) {
            if (it.peek()) |next| if (isTableSeparator(next)) {
                try renderTable(w, line, &it);
                continue;
            };
        }
        try renderLine(w, line, if (in_fence) &js else null);
    }
}

const LineIterator = std.mem.SplitIterator(u8, .scalar);

const max_table_columns = 16;

/// Shown while a streamed table is withheld; written without a newline so
/// `clear_placeholder` can erase it in place before the table renders.
const table_placeholder = ansi.dim ++ "… rendering table" ++ ansi.reset;
const clear_placeholder = "\r" ++ ansi.clear_line;

/// Cells are inline-rendered and padded to per-column visible width. Widths
/// count codepoints, so double-width glyphs (CJK, emoji) may misalign.
fn renderTable(w: *std.Io.Writer, header: []const u8, it: *LineIterator) !void {
    var widths: [max_table_columns]usize = @splat(0);
    var ncols: usize = 0;
    var ok = measureRow(header, &widths, &ncols);
    if (ok) {
        var scan = it.*;
        _ = scan.next();
        while (scan.peek()) |line| {
            if (!isTableRow(line)) break;
            _ = scan.next();
            if (!measureRow(line, &widths, &ncols)) {
                ok = false;
                break;
            }
        }
    }
    if (!ok or ncols == 0) return renderTableVerbatim(w, header, it);

    try emitRow(w, header, widths[0..ncols], true);
    _ = it.next();
    try w.writeByte('\n');
    try emitSeparator(w, widths[0..ncols]);
    while (it.peek()) |line| {
        if (!isTableRow(line)) break;
        _ = it.next();
        try w.writeByte('\n');
        try emitRow(w, line, widths[0..ncols], false);
    }
}

/// Fallback for tables the aligner can't measure (too many columns, or a
/// rendered cell overflowing its fixed buffer): rows pass through untouched.
fn renderTableVerbatim(w: *std.Io.Writer, header: []const u8, it: *LineIterator) !void {
    try styled(w, header, ansi.bold);
    while (it.peek()) |line| {
        if (!isTableRow(line) and !isTableSeparator(line)) break;
        _ = it.next();
        try w.writeByte('\n');
        if (isTableSeparator(line)) {
            try styled(w, line, ansi.dim);
        } else {
            try w.writeAll(line);
        }
    }
}

fn measureRow(row: []const u8, widths: *[max_table_columns]usize, ncols: *usize) bool {
    var cells = cellIterator(row);
    var col: usize = 0;
    while (cells.next()) |cell| {
        // A row's trailing `|` leaves one empty last segment; drop it.
        if (cell.len == 0 and cells.pos >= cells.row.len) break;
        if (col == max_table_columns) return false;
        const width = cellDisplayWidth(cell) orelse return false;
        widths[col] = @max(widths[col], width);
        col += 1;
    }
    ncols.* = @max(ncols.*, col);
    return true;
}

fn emitRow(w: *std.Io.Writer, row: []const u8, widths: []const usize, is_header: bool) !void {
    var cells = cellIterator(row);
    for (widths) |width| {
        try styled(w, "│", ansi.dim);
        try w.writeByte(' ');
        const cell = cells.next() orelse "";
        var used: usize = 0;
        if (cell.len > 0) {
            // Render once into scratch so `used` is measured from the exact
            // bytes written. The header's bold re-applies add escapes on top
            // of what measureRow saw, hence the extra headroom.
            var buf: [1024]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            if (renderCell(&fw, cell, is_header)) {
                try w.writeAll(fw.buffered());
                used = visibleWidth(fw.buffered());
            } else |_| {
                // Overflow, possible only for a marker-dense header cell:
                // keep the content, sacrifice the padding.
                try renderCell(w, cell, is_header);
                used = width;
            }
        }
        try w.splatByteAll(' ', width - used + 1);
    }
    try styled(w, "│", ansi.dim);
}

fn renderCell(w: *std.Io.Writer, cell: []const u8, is_header: bool) std.Io.Writer.Error!void {
    if (is_header) {
        try w.writeAll(ansi.bold);
        try renderInlineStyled(w, cell, &bold_style);
        try w.writeAll(ansi.reset);
    } else {
        try renderInline(w, cell);
    }
}

fn emitSeparator(w: *std.Io.Writer, widths: []const usize) !void {
    try w.writeAll(ansi.dim);
    for (widths, 0..) |width, col| {
        try w.writeAll(if (col == 0) "├" else "┼");
        try w.splatBytesAll("─", width + 2);
    }
    try w.writeAll("┤");
    try w.writeAll(ansi.reset);
}

const CellIterator = struct {
    row: []const u8,
    pos: usize,

    fn next(self: *CellIterator) ?[]const u8 {
        if (self.pos >= self.row.len) return null;
        var i = self.pos;
        var in_code = false;
        while (i < self.row.len) : (i += 1) {
            switch (self.row[i]) {
                '`' => in_code = !in_code,
                '\\' => i += 1,
                '|' => if (!in_code) break,
                else => {},
            }
        }
        const end = @min(i, self.row.len);
        const cell = std.mem.trim(u8, self.row[self.pos..end], " \t");
        self.pos = i + 1;
        return cell;
    }
};

fn cellIterator(row: []const u8) CellIterator {
    const first_pipe = std.mem.indexOfScalar(u8, row, '|');
    return .{ .row = row, .pos = if (first_pipe) |p| p + 1 else 0 };
}

fn cellDisplayWidth(cell: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    renderInline(&fw, cell) catch return null;
    return visibleWidth(fw.buffered());
}

/// Display columns of rendered output: escapes are zero, codepoints are one.
fn visibleWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len) {
            switch (s[i + 1]) {
                '[' => {
                    i += 2;
                    while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
                    i += 1;
                    continue;
                },
                ']' => {
                    i += 2;
                    while (i < s.len and s[i] != 0x07 and s[i] != 0x1b) i += 1;
                    i += @as(usize, if (i < s.len and s[i] == 0x1b) 2 else 1);
                    continue;
                },
                '\\' => {
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        if (s[i] & 0xc0 != 0x80) n += 1;
        i += 1;
    }
    return n;
}

fn isFenceDelimiter(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "```");
}

fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return trimmed.len >= 1 and trimmed[0] == '|';
}

/// A row of `-`, `:`, `|` and spaces with at least one dash and one pipe,
/// e.g. `| --- |:---:|`.
fn isTableSeparator(line: []const u8) bool {
    var has_dash = false;
    var has_pipe = false;
    for (line) |c| switch (c) {
        '-' => has_dash = true,
        '|' => has_pipe = true,
        ':', ' ', '\t' => {},
        else => return false,
    };
    return has_dash and has_pipe;
}

/// Incremental renderer for streamed deltas: buffers until each newline,
/// then renders the completed line. Fence state carries across lines. Table
/// rows are withheld and re-rendered aligned once the table ends — alignment
/// needs the whole table, so it can't stream row by row.
pub const Stream = struct {
    len: usize = 0,
    in_fence: bool = false,
    /// Fenced-code lexer state, carried across lines and chunks.
    js_state: js_highlight.State = .normal,
    /// A line that outgrew `buf` passes through unrendered to its newline.
    raw: bool = false,
    /// `held`: one pipe row buffered, pending the separator that confirms a
    /// table. `table`: rows accumulate in `table_buf` until the table ends.
    mode: enum { text, held, table } = .text,
    table_len: usize = 0,
    buf: [4096]u8 = undefined,
    /// A table that outgrows this falls back to per-line rendering.
    table_buf: [16384]u8 = undefined,

    pub fn feed(self: *Stream, w: *std.Io.Writer, data: []const u8) !void {
        var rest = data;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const head = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (self.raw) {
                try w.writeAll(head);
                try w.writeByte('\n');
                self.raw = false;
            } else if (self.len == 0) {
                try self.emitLine(w, head);
            } else if (self.len + head.len <= self.buf.len) {
                @memcpy(self.buf[self.len..][0..head.len], head);
                const full = self.buf[0 .. self.len + head.len];
                self.len = 0;
                try self.emitLine(w, full);
            } else {
                try w.writeAll(self.buf[0..self.len]);
                try w.writeAll(head);
                try w.writeByte('\n');
                self.len = 0;
            }
        }
        if (rest.len == 0) return;
        if (self.raw) {
            try w.writeAll(rest);
        } else if (self.len + rest.len <= self.buf.len) {
            @memcpy(self.buf[self.len..][0..rest.len], rest);
            self.len += rest.len;
        } else {
            try w.writeAll(self.buf[0..self.len]);
            try w.writeAll(rest);
            self.len = 0;
            self.raw = true;
        }
    }

    /// Flush any withheld table and a trailing partial line (no newline is
    /// written for it), then reset all state for the next message.
    pub fn close(self: *Stream, w: *std.Io.Writer) !void {
        // A message often ends inside a table: adopt the partial last row.
        if (self.len > 0 and !self.raw) {
            const partial = self.buf[0..self.len];
            const adopt = switch (self.mode) {
                .table => isTableRow(partial),
                .held => isTableSeparator(partial),
                .text => false,
            };
            if (adopt and self.appendTableLine(partial)) {
                self.mode = .table;
                self.len = 0;
            }
        }
        switch (self.mode) {
            .text => {},
            .held => try self.releaseHeldRow(w),
            .table => try self.renderBufferedTable(w),
        }
        const partial = self.buf[0..self.len];
        const in_fence = self.in_fence;
        var js = self.js_state;
        self.len = 0;
        self.raw = false;
        self.in_fence = false;
        self.js_state = .normal;
        if (partial.len == 0 or isFenceDelimiter(partial)) return;
        try renderLine(w, partial, if (in_fence) &js else null);
    }

    fn emitLine(self: *Stream, w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        switch (self.mode) {
            .text => {
                if (isFenceDelimiter(text)) {
                    self.in_fence = !self.in_fence;
                    self.js_state = .normal;
                    return;
                }
                if (!self.in_fence and isTableRow(text) and self.appendTableLine(text)) {
                    self.mode = .held;
                    return;
                }
                try renderLine(w, text, if (self.in_fence) &self.js_state else null);
                try w.writeByte('\n');
            },
            .held => {
                if (isTableSeparator(text) and self.appendTableLine(text)) {
                    self.mode = .table;
                    // Withholding goes quiet; leave a marker until the
                    // table renders over it.
                    try w.writeAll(table_placeholder);
                    return;
                }
                try self.releaseHeldRow(w);
                try self.emitLine(w, text);
            },
            .table => {
                if (isTableRow(text)) {
                    if (self.appendTableLine(text)) return;
                    try self.flushTableUnaligned(w);
                    try renderLine(w, text, null);
                    try w.writeByte('\n');
                    return;
                }
                try self.renderBufferedTable(w);
                try self.emitLine(w, text);
            },
        }
    }

    /// No separator followed, so the held row wasn't a table header.
    fn releaseHeldRow(self: *Stream, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try renderLine(w, self.tableText(), null);
        try w.writeByte('\n');
        self.resetTable();
    }

    fn renderBufferedTable(self: *Stream, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(clear_placeholder);
        var it: LineIterator = std.mem.splitScalar(u8, self.tableText(), '\n');
        const header = it.first();
        try renderTable(w, header, &it);
        try w.writeByte('\n');
        self.resetTable();
    }

    fn flushTableUnaligned(self: *Stream, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(clear_placeholder);
        var it = std.mem.splitScalar(u8, self.tableText(), '\n');
        while (it.next()) |line| {
            try renderLine(w, line, null);
            try w.writeByte('\n');
        }
        self.resetTable();
    }

    fn appendTableLine(self: *Stream, line: []const u8) bool {
        const sep: usize = if (self.table_len == 0) 0 else 1;
        if (self.table_len + sep + line.len > self.table_buf.len) return false;
        if (sep == 1) {
            self.table_buf[self.table_len] = '\n';
            self.table_len += 1;
        }
        @memcpy(self.table_buf[self.table_len..][0..line.len], line);
        self.table_len += line.len;
        return true;
    }

    fn tableText(self: *const Stream) []const u8 {
        return self.table_buf[0..self.table_len];
    }

    fn resetTable(self: *Stream) void {
        self.table_len = 0;
        self.mode = .text;
    }
};

/// `js` carries the fenced-code lexer state across lines; null outside a fence.
fn renderLine(w: *std.Io.Writer, line: []const u8, js: ?*js_highlight.State) !void {
    if (js) |state| {
        state.* = try renderCodeLine(w, line, state.*);
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
        try renderInlineStyled(w, std.mem.trimLeft(u8, trimmed[hashes..], " "), &bold_style);
        try w.writeAll(ansi.reset);
        return;
    }

    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        try w.writeAll(indent);
        try styled(w, "•", ansi.dim);
        try w.writeByte(' ');
        try renderInline(w, std.mem.trimLeft(u8, trimmed[2..], " "));
        return;
    }

    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits > 0 and digits + 1 < trimmed.len and
        (trimmed[digits] == '.' or trimmed[digits] == ')') and trimmed[digits + 1] == ' ')
    {
        try w.writeAll(indent);
        try w.writeAll(trimmed[0 .. digits + 2]);
        try renderInline(w, std.mem.trimLeft(u8, trimmed[digits + 2 ..], " "));
        return;
    }

    try renderInline(w, line);
}

/// Stack-threaded chain of enclosing span styles; a nested span's reset
/// re-applies the whole chain, so styling survives arbitrary nesting depth.
const Style = struct {
    code: []const u8,
    parent: ?*const Style,

    fn apply(self: *const Style, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.parent) |p| try p.apply(w);
        try w.writeAll(self.code);
    }

    fn applyOpt(active: ?*const Style, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (active) |a| try a.apply(w);
    }
};

const bold_style: Style = .{ .code = ansi.bold, .parent = null };

fn renderInline(w: *std.Io.Writer, text: []const u8) !void {
    try renderInlineStyled(w, text, null);
}

fn renderInlineStyled(w: *std.Io.Writer, text: []const u8, active: ?*const Style) std.Io.Writer.Error!void {
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
                try Style.applyOpt(active, w);
                i = end + 1;
                continue;
            },
            '*', '_' => |ch| {
                const double = [2]u8{ ch, ch };
                if (i + 1 < text.len and text[i + 1] == ch) {
                    if (std.mem.indexOfPos(u8, text, i + 2, &double)) |end| {
                        try span(w, text[i + 2 .. end], ansi.bold, active);
                        i = end + 2;
                        continue;
                    }
                } else if (std.mem.indexOfScalarPos(u8, text, i + 1, ch)) |end| {
                    try span(w, text[i + 1 .. end], ansi.italic, active);
                    i = end + 1;
                    continue;
                }
            },
            '~' => if (i + 1 < text.len and text[i + 1] == '~') {
                if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                    try span(w, text[i + 2 .. end], ansi.strike, active);
                    i = end + 2;
                    continue;
                }
            },
            '[' => if (std.mem.indexOfPos(u8, text, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, text, mid + 2, ')')) |end| {
                    try renderLink(w, text[i + 1 .. mid], text[mid + 2 .. end]);
                    try Style.applyOpt(active, w);
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

fn span(w: *std.Io.Writer, inner: []const u8, style: []const u8, active: ?*const Style) std.Io.Writer.Error!void {
    try w.writeAll(style);
    try renderInlineStyled(w, inner, &.{ .code = style, .parent = active });
    try w.writeAll(ansi.reset);
    try Style.applyOpt(active, w);
}

/// Writes `js_highlight` spans as ANSI, filling the gaps between them with
/// unstyled text. `emit` cannot fail, so a write error is stashed and returned
/// by `finish`.
const JsSink = struct {
    w: *std.Io.Writer,
    text: []const u8,
    last: usize = 0,
    err: ?std.Io.Writer.Error = null,

    fn color(kind: js_highlight.Kind) []const u8 {
        return switch (kind) {
            .comment => ansi.dim ++ ansi.italic,
            .string => ansi.green,
            .variable => ansi.yellow ++ ansi.bold,
            .number => ansi.magenta,
            .keyword => ansi.blue ++ ansi.bold,
            .global => ansi.cyan,
        };
    }

    pub fn emit(self: *JsSink, start: usize, len: usize, kind: js_highlight.Kind) void {
        self.write(start, len, kind) catch |err| {
            self.err = self.err orelse err;
        };
    }

    fn write(self: *JsSink, start: usize, len: usize, kind: js_highlight.Kind) !void {
        if (start > self.last) try self.w.writeAll(self.text[self.last..start]);
        try styled(self.w, self.text[start..][0..len], color(kind));
        self.last = start + len;
    }

    fn finish(self: *JsSink) !void {
        if (self.err) |err| return err;
        if (self.last < self.text.len) try self.w.writeAll(self.text[self.last..]);
    }
};

/// Syntax-highlight one line of fenced code as JavaScript — the only language
/// this agent emits in practice. Returns the lexer state for the next line.
fn renderCodeLine(w: *std.Io.Writer, line: []const u8, state: js_highlight.State) !js_highlight.State {
    var sink: JsSink = .{ .w = w, .text = line };
    const next = js_highlight.tokenize(line, state, &sink);
    try sink.finish();
    return next;
}

fn styled(w: *std.Io.Writer, inner: []const u8, style: []const u8) !void {
    try w.writeAll(style);
    try w.writeAll(inner);
    try w.writeAll(ansi.reset);
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '*', '_', '`', '~', '[', ']', '(', ')', '|', '\\' => true,
        else => false,
    };
}

/// A left-trimmed line of 3+ identical `-`, `*` or `_` markers — the whole
/// line, so `***bold***` stays inline text.
fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const first = line[0];
    if (first != '-' and first != '*' and first != '_') return false;
    for (line[1..]) |c| {
        if (c != first) return false;
    }
    return true;
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
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try render(&aw.writer, src);
    try testing.expectEqualStrings(expected, aw.written());
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

test "md_term: alignment spaces after list marker collapse" {
    try expectRender("\x1b[2m•\x1b[0m item", "-   item");
    try expectRender("1. item", "1.   item");
}

test "md_term: nested inline styles" {
    // The code span's reset re-applies the enclosing bold.
    try expectRender(
        "\x1b[1muse \x1b[36mls\x1b[0m\x1b[1m now\x1b[0m",
        "**use `ls` now**",
    );
    try expectRender(
        "\x1b[1m\x1b[36mgoto(url)\x1b[0m\x1b[1m\x1b[0m: nav",
        "**`goto(url)`**: nav",
    );
    // Inside a heading too: bold survives past the code span.
    try expectRender(
        "\x1b[1mrun \x1b[36mls\x1b[0m\x1b[1m first\x1b[0m",
        "## run `ls` first",
    );
    // Italic nested in bold stacks, then bold is restored.
    try expectRender(
        "\x1b[1ma \x1b[3mb\x1b[0m\x1b[1m c\x1b[0m",
        "**a *b* c**",
    );
    // Depth 2: the code span's reset re-applies the full bold+italic chain.
    try expectRender(
        "\x1b[1ma \x1b[3mb \x1b[36mc\x1b[0m\x1b[1m\x1b[3m d\x1b[0m\x1b[1m e\x1b[0m",
        "**a *b `c` d* e**",
    );
}

test "md_term: fenced code block is highlighted as JavaScript" {
    try expectRender(
        "\x1b[34m\x1b[1mlet\x1b[0m x = \x1b[35m1\x1b[0m;",
        "```\nlet x = 1;\n```",
    );
    // Untokenized text passes through unstyled.
    try expectRender("plain", "```\nplain\n```");
}

test "md_term: fenced template literal spans lines" {
    try expectRender(
        "\x1b[32m`<div>\x1b[0m\n\x1b[32m</div>`\x1b[0m",
        "```\n`<div>\n</div>`\n```",
    );
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
    try expectRender("---x", "---x");
}

test "md_term: tables align columns and style cells" {
    const B = "\x1b[1m";
    const C = "\x1b[36m";
    const D = "\x1b[2m";
    const R = "\x1b[0m";
    const pipe = D ++ "│" ++ R;

    // Source is already padded; rendering keeps the alignment after
    // stripping the cell markers.
    try expectRender(
        pipe ++ " " ++ B ++ "Tool" ++ R ++ " " ++ pipe ++ " " ++ B ++ "Use" ++ R ++ " " ++ pipe ++ "\n" ++
            D ++ "├──────┼─────┤" ++ R ++ "\n" ++
            pipe ++ " " ++ C ++ "goto" ++ R ++ " " ++ pipe ++ " nav " ++ pipe,
        "| Tool   | Use |\n|--------|-----|\n| `goto` | nav |",
    );
    // Gemini-style unpadded source: columns are padded to the widest
    // rendered cell.
    try expectRender(
        pipe ++ " " ++ B ++ "Tool" ++ R ++ " " ++ pipe ++ " " ++ B ++ "Usage" ++ R ++ "       " ++ pipe ++ "\n" ++
            D ++ "├──────┼─────────────┤" ++ R ++ "\n" ++
            pipe ++ " goto " ++ pipe ++ " " ++ B ++ "Nav:" ++ R ++ " to url " ++ pipe,
        "| Tool | Usage |\n| :--- | :--- |\n| goto | **Nav:** to url |",
    );
    // A pipe line without a separator row underneath is not a table.
    try expectRender("| just \x1b[1mtext\x1b[0m |", "| just **text** |");
}

test "md_term: overwide table falls back to verbatim rows" {
    const header = "|a" ** 17 ++ "|";
    const sep = "|-" ** 17 ++ "|";
    try expectRender(
        "\x1b[1m" ++ header ++ "\x1b[0m\n\x1b[2m" ++ sep ++ "\x1b[0m",
        header ++ "\n" ++ sep,
    );
}

test "md_term: stream renders across chunk boundaries" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stream = .{};
    try s.feed(&aw.writer, "say **h");
    try s.feed(&aw.writer, "i** now\n- ite");
    try s.feed(&aw.writer, "m\ntail");
    try s.close(&aw.writer);
    try testing.expectEqualStrings(
        "say \x1b[1mhi\x1b[0m now\n\x1b[2m•\x1b[0m item\ntail",
        aw.written(),
    );
}

test "md_term: stream withholds tables and renders them aligned" {
    const B = "\x1b[1m";
    const C = "\x1b[36m";
    const D = "\x1b[2m";
    const R = "\x1b[0m";
    const pipe = D ++ "│" ++ R;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stream = .{};
    try s.feed(&aw.writer, "| Tool | Use |\n| :--- | :-");
    try testing.expectEqualStrings("", aw.written());
    try s.feed(&aw.writer, "-- |\n| `goto` | nav |\ndone\n");
    try testing.expectEqualStrings(
        D ++ "… rendering table" ++ R ++ "\r\x1b[2K" ++
            pipe ++ " " ++ B ++ "Tool" ++ R ++ " " ++ pipe ++ " " ++ B ++ "Use" ++ R ++ " " ++ pipe ++ "\n" ++
            D ++ "├──────┼─────┤" ++ R ++ "\n" ++
            pipe ++ " " ++ C ++ "goto" ++ R ++ " " ++ pipe ++ " nav " ++ pipe ++ "\n" ++
            "done\n",
        aw.written(),
    );
}

test "md_term: stream table ending at close adopts the partial row" {
    const B = "\x1b[1m";
    const D = "\x1b[2m";
    const R = "\x1b[0m";
    const pipe = D ++ "│" ++ R;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stream = .{};
    try s.feed(&aw.writer, "| A | B |\n|-|-|\n| x | y |");
    try s.close(&aw.writer);
    try testing.expectEqualStrings(
        D ++ "… rendering table" ++ R ++ "\r\x1b[2K" ++
            pipe ++ " " ++ B ++ "A" ++ R ++ " " ++ pipe ++ " " ++ B ++ "B" ++ R ++ " " ++ pipe ++ "\n" ++
            D ++ "├───┼───┤" ++ R ++ "\n" ++
            pipe ++ " x " ++ pipe ++ " y " ++ pipe ++ "\n",
        aw.written(),
    );
}

test "md_term: stream releases a lone pipe row" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stream = .{};
    try s.feed(&aw.writer, "| a |\nplain\n");
    try s.close(&aw.writer);
    try testing.expectEqualStrings("| a |\nplain\n", aw.written());
}

test "md_term: stream fence state spans chunks" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stream = .{};
    try s.feed(&aw.writer, "```\ncode\n``");
    try s.feed(&aw.writer, "`\nafter\n");
    try s.close(&aw.writer);
    try testing.expectEqualStrings(
        "code\nafter\n",
        aw.written(),
    );
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

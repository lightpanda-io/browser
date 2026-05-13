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
const lp = @import("lightpanda");

pub const TypeArgs = struct {
    selector: []const u8,
    value: []const u8,
};

pub const ScrollArgs = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const SelectArgs = struct {
    selector: []const u8,
    value: []const u8,
};

pub const CheckArgs = struct {
    selector: []const u8,
    checked: bool,
};

pub const Command = union(enum) {
    goto: []const u8,
    click: []const u8,
    type_cmd: TypeArgs,
    wait: []const u8,
    scroll: ScrollArgs,
    hover: []const u8,
    select: SelectArgs,
    check: CheckArgs,
    tree: void,
    markdown: void,
    extract: []const u8,
    eval_js: []const u8,
    login: void,
    accept_cookies: void,
    comment: void,
    natural_language: []const u8,

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .tree, .markdown, .comment, .natural_language => false,
            .goto, .click, .type_cmd, .wait, .scroll, .hover, .select, .check, .extract, .eval_js, .login, .accept_cookies => true,
        };
    }

    /// True if running this command produces output the user typically wants to
    /// capture (and so should land on stdout). False for action commands whose
    /// only output is an acknowledgment.
    pub fn producesData(self: Command) bool {
        return switch (self) {
            .extract, .eval_js, .markdown, .tree => true,
            else => false,
        };
    }

    /// True if running this command requires an LLM (i.e. an `ai_client` must
    /// be configured). LOGIN and ACCEPT_COOKIES are canned prompts; natural
    /// language is forwarded verbatim to the model. All three are unavailable
    /// in basic PandaScript-only mode (no `--provider`, or `--no-llm`).
    pub fn needsLlm(self: Command) bool {
        return switch (self) {
            .login, .accept_cookies, .natural_language => true,
            else => false,
        };
    }

    /// Serializes back to PandaScript. Every string argument is wrapped in
    /// content-aware quotes so the output round-trips through `parse()`:
    ///   - single quotes by default,
    ///   - double quotes if the content contains `'` but not `"`,
    ///   - triple quotes (`'''…'''` or `"""…"""`) if it contains both — the
    ///     triple delimiter is whichever the content doesn't include.
    ///
    /// There is no escape syntax, so a value that contains BOTH `'''` and
    /// `"""` still cannot round-trip — vanishingly rare for selectors and
    /// form values, which is the entire input domain here.
    pub fn format(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .goto => |url| try writer.print("GOTO {s}", .{url}),
            .click => |sel| try writer.print("CLICK {f}", .{quote(sel)}),
            .type_cmd => |args| try writer.print("TYPE {f} {f}", .{ quote(args.selector), quote(args.value) }),
            .wait => |sel| try writer.print("WAIT {f}", .{quote(sel)}),
            .scroll => |args| try writer.print("SCROLL {d} {d}", .{ args.x, args.y }),
            .hover => |sel| try writer.print("HOVER {f}", .{quote(sel)}),
            .select => |args| try writer.print("SELECT {f} {f}", .{ quote(args.selector), quote(args.value) }),
            .check => |args| if (args.checked)
                try writer.print("CHECK {f}", .{quote(args.selector)})
            else
                try writer.print("CHECK {f} false", .{quote(args.selector)}),
            .tree => try writer.writeAll("TREE"),
            .markdown => try writer.writeAll("MARKDOWN"),
            .extract => |schema| try writeBlockOrInline(writer, "EXTRACT", schema),
            .eval_js => |script| try writeBlockOrInline(writer, "EVAL", script),
            .login => try writer.writeAll("LOGIN"),
            .accept_cookies => try writer.writeAll("ACCEPT_COOKIES"),
            .comment => try writer.writeAll("#"),
            .natural_language => |text| try writer.writeAll(text),
        }
    }
};

fn writeBlockOrInline(writer: *std.Io.Writer, keyword: []const u8, body: []const u8) std.Io.Writer.Error!void {
    if (std.mem.indexOfScalar(u8, body, '\n') != null) {
        const q = QuoteType.pickFor(body).toLiteral();
        try writer.print("{s} {s}\n{s}\n{s}", .{ keyword, q, body, q });
    } else {
        try writer.print("{s} {f}", .{ keyword, quote(body) });
    }
}

fn splitHead(line: []const u8) struct { head: []const u8, rest: []const u8 } {
    const end = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse line.len;
    return .{
        .head = line[0..end],
        .rest = std.mem.trim(u8, line[end..], &std.ascii.whitespace),
    };
}

/// Parse a line of REPL input into a PandaScript command.
/// Unrecognized input is returned as `.natural_language`.
/// For multi-line EVAL blocks in scripts, use `ScriptParser`.
pub fn parse(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .natural_language = trimmed };

    if (trimmed[0] == '#') return .{ .comment = {} };

    const split = splitHead(trimmed);
    const cmd_word = split.head;
    const rest = split.rest;

    if (std.mem.eql(u8, cmd_word, "GOTO")) {
        if (rest.len == 0) return .{ .natural_language = trimmed };
        return .{ .goto = rest };
    }

    if (std.mem.eql(u8, cmd_word, "CLICK")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .click = arg };
    }

    if (std.mem.eql(u8, cmd_word, "TYPE")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = trimMatchingQuotes(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .type_cmd = .{ .selector = first.value, .value = second } };
    }

    if (std.mem.eql(u8, cmd_word, "WAIT")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .wait = arg };
    }

    if (std.mem.eql(u8, cmd_word, "SCROLL")) {
        // SCROLL          → scroll to (0, 0)
        // SCROLL 100      → scroll y=100
        // SCROLL 50 200   → scroll x=50, y=200
        if (rest.len == 0) return .{ .scroll = .{} };
        var it = std.mem.tokenizeAny(u8, rest, &std.ascii.whitespace);
        const first = it.next() orelse return .{ .scroll = .{} };
        const second = it.next();
        if (second) |s| {
            const x = std.fmt.parseInt(i32, first, 10) catch return .{ .natural_language = trimmed };
            const y = std.fmt.parseInt(i32, s, 10) catch return .{ .natural_language = trimmed };
            return .{ .scroll = .{ .x = x, .y = y } };
        }
        const y = std.fmt.parseInt(i32, first, 10) catch return .{ .natural_language = trimmed };
        return .{ .scroll = .{ .x = 0, .y = y } };
    }

    if (std.mem.eql(u8, cmd_word, "HOVER")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .hover = arg };
    }

    if (std.mem.eql(u8, cmd_word, "SELECT")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = trimMatchingQuotes(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .select = .{ .selector = first.value, .value = second } };
    }

    if (std.mem.eql(u8, cmd_word, "CHECK")) {
        // CHECK '<sel>'         → checked = true
        // CHECK '<sel>' true    → checked = true
        // CHECK '<sel>' false   → checked = false
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const after = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        if (after.len == 0) {
            return .{ .check = .{ .selector = first.value, .checked = true } };
        }
        if (std.ascii.eqlIgnoreCase(after, "true")) {
            return .{ .check = .{ .selector = first.value, .checked = true } };
        }
        if (std.ascii.eqlIgnoreCase(after, "false")) {
            return .{ .check = .{ .selector = first.value, .checked = false } };
        }
        return .{ .natural_language = trimmed };
    }

    if (std.mem.eql(u8, cmd_word, "TREE")) {
        if (rest.len > 0) return .{ .natural_language = trimmed };
        return .{ .tree = {} };
    }

    if (std.mem.eql(u8, cmd_word, "MARKDOWN")) {
        if (rest.len > 0) return .{ .natural_language = trimmed };
        return .{ .markdown = {} };
    }

    if (std.mem.eql(u8, cmd_word, "EXTRACT")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .extract = arg };
    }

    if (std.mem.eql(u8, cmd_word, "EVAL")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .eval_js = arg };
    }

    if (std.mem.eql(u8, cmd_word, "LOGIN")) {
        if (rest.len > 0) return .{ .natural_language = trimmed };
        return .{ .login = {} };
    }

    if (std.mem.eql(u8, cmd_word, "ACCEPT_COOKIES")) {
        if (rest.len > 0) return .{ .natural_language = trimmed };
        return .{ .accept_cookies = {} };
    }

    return .{ .natural_language = trimmed };
}

pub const KeywordSyntax = struct {
    name: []const u8,
    /// Null for argless commands; the agent renders a different error.
    args: ?[]const u8,
    /// Pre-rendered positional-arg fragments shown progressively in the inline
    /// hint as the user fills them in. Empty for argless commands. The visual
    /// notation matches `args` (e.g. `'<selector>'` for quoted, `[x]` for
    /// optional bare). Drives `analyzePandaBody`-based hint narrowing.
    params: []const []const u8 = &.{},
};

// Shared positional-arg fragments used in the keyword table below.
const selector_arg = "'<selector>'";
const value_arg = "'<value>'";
const schema_arg = "'<schema-json>'";

/// Single source of truth for PandaScript keyword names — consumed by the
/// parser, the REPL highlighter, and Tab completion.
pub const keywords = [_]KeywordSyntax{
    .{ .name = "GOTO", .args = "<url>", .params = &.{"<url>"} },
    .{ .name = "CLICK", .args = selector_arg, .params = &.{selector_arg} },
    .{ .name = "TYPE", .args = selector_arg ++ " " ++ value_arg, .params = &.{ selector_arg, value_arg } },
    .{ .name = "WAIT", .args = selector_arg, .params = &.{selector_arg} },
    .{ .name = "SCROLL", .args = "[x] [y]", .params = &.{ "[x]", "[y]" } },
    .{ .name = "HOVER", .args = selector_arg, .params = &.{selector_arg} },
    .{ .name = "SELECT", .args = selector_arg ++ " " ++ value_arg, .params = &.{ selector_arg, value_arg } },
    .{ .name = "CHECK", .args = selector_arg ++ " [true|false]", .params = &.{ selector_arg, "[true|false]" } },
    .{ .name = "TREE", .args = null },
    .{ .name = "MARKDOWN", .args = null },
    .{ .name = "EXTRACT", .args = schema_arg, .params = &.{schema_arg} },
    .{ .name = "EVAL", .args = "'<script>'", .params = &.{"'<script>'"} },
    .{ .name = "LOGIN", .args = null },
    .{ .name = "ACCEPT_COOKIES", .args = null },
};

/// Result of `analyzePandaBody`: how many positional args the user has already
/// fully entered, and whether the cursor is at a token boundary (ready to
/// accept the next arg). Used by the REPL inline-hint renderer to narrow the
/// shown params as the user types.
pub const BodyCursor = struct {
    complete_args: usize,
    at_boundary: bool,
};

/// Walks a PandaScript command body (the text after the keyword and its
/// separating space) and reports how many positional args have been
/// completed. Quote-aware: handles single, double, and triple-quoted strings.
/// An unterminated quote sets `at_boundary = false` so the hint suppresses
/// while the user is still inside the string. A bare token without trailing
/// whitespace likewise suppresses (cursor is mid-token).
pub fn analyzePandaBody(body: []const u8) BodyCursor {
    var i: usize = 0;
    var complete: usize = 0;
    while (i < body.len) {
        while (i < body.len and std.ascii.isWhitespace(body[i])) : (i += 1) {}
        if (i >= body.len) break;
        const ch = body[i];
        if (ch == '\'' or ch == '"') {
            if (QuoteType.fromPrefix(body[i..])) |tq| {
                const lit = tq.toLiteral();
                const end_idx = std.mem.indexOfPos(u8, body, i + lit.len, lit) orelse
                    return .{ .complete_args = complete, .at_boundary = false };
                i = end_idx + lit.len;
            } else {
                const end_idx = std.mem.indexOfScalarPos(u8, body, i + 1, ch) orelse
                    return .{ .complete_args = complete, .at_boundary = false };
                i = end_idx + 1;
            }
            complete += 1;
        } else {
            while (i < body.len and !std.ascii.isWhitespace(body[i])) : (i += 1) {}
            complete += 1;
        }
    }
    const boundary = body.len == 0 or std.ascii.isWhitespace(body[body.len - 1]);
    return .{ .complete_args = complete, .at_boundary = boundary };
}

/// If the first word of `line` is a recognized PandaScript keyword, returns
/// its entry. Used by the REPL to surface a syntax error when `Command.parse`
/// rejects a line whose first word *looked* like a command — either an argful
/// keyword missing its args, or an argless keyword followed by junk.
pub fn keywordSyntax(line: []const u8) ?KeywordSyntax {
    const word = splitHead(std.mem.trim(u8, line, &std.ascii.whitespace)).head;
    for (keywords) |kc| {
        if (std.mem.eql(u8, word, kc.name)) return kc;
    }
    return null;
}

/// Iterator for parsing a script file, handling multi-line EVAL """ ... """ blocks.
pub const ScriptIterator = struct {
    allocator: std.mem.Allocator,
    lines: std.mem.SplitIterator(u8, .scalar),
    line_num: u32,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) ScriptIterator {
        return .{
            .allocator = allocator,
            .lines = std.mem.splitScalar(u8, content, '\n'),
            .line_num = 0,
        };
    }

    pub const Entry = struct {
        line_num: u32,
        raw_line: []const u8,
        /// The full slice of the original content buffer covering this entry,
        /// including trailing newline(s). For multi-line EVAL blocks this spans
        /// from the EVAL keyword through the closing triple-quote line.
        raw_span: []const u8,
        command: Command,
    };

    /// Multi-line EVAL / EXTRACT blocks are assembled into a single command.
    pub fn next(self: *ScriptIterator) std.mem.Allocator.Error!?Entry {
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr);

            if (BlockKeyword.fromOpener(trimmed)) |opener| {
                const start_line = self.line_num;
                const body_or_null = try self.collectMultiLineBlock(opener.quote_type);
                const span_end = self.lines.index orelse self.lines.buffer.len;
                const cmd: Command = switch (opener.kind) {
                    .eval => if (body_or_null) |body| .{ .eval_js = body } else .{ .natural_language = "unterminated EVAL block" },
                    .extract => if (body_or_null) |body| .{ .extract = body } else .{ .natural_language = "unterminated EXTRACT block" },
                };
                return .{
                    .line_num = start_line,
                    .raw_line = trimmed,
                    .raw_span = self.lines.buffer[line_start..span_end],
                    .command = cmd,
                };
            }

            const span_end = self.lines.index orelse self.lines.buffer.len;
            return .{
                .line_num = self.line_num,
                .raw_line = trimmed,
                .raw_span = self.lines.buffer[line_start..span_end],
                .command = parse(trimmed),
            };
        }
        return null;
    }

    /// The triple-quote must stand alone on the line — inline forms like
    /// `EVAL '''a'''` fall through to single-line `parse()`.
    const BlockKeyword = struct {
        kind: enum { eval, extract },
        quote_type: QuoteType,

        fn fromOpener(line: []const u8) ?BlockKeyword {
            const split = splitHead(line);
            const quote_type = QuoteType.fromLiteral(split.rest) orelse return null;
            if (std.mem.eql(u8, split.head, "EVAL")) return .{ .kind = .eval, .quote_type = quote_type };
            if (std.mem.eql(u8, split.head, "EXTRACT")) return .{ .kind = .extract, .quote_type = quote_type };
            return null;
        }
    };

    fn collectMultiLineBlock(self: *ScriptIterator, quote_type: QuoteType) std.mem.Allocator.Error!?[]const u8 {
        const closer = quote_type.toLiteral();
        var parts: std.ArrayList(u8) = .empty;
        // toOwnedSlice empties `parts`, so this defer is a no-op on success.
        defer parts.deinit(self.allocator);
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, closer)) {
                return try parts.toOwnedSlice(self.allocator);
            }
            if (parts.items.len > 0) {
                try parts.append(self.allocator, '\n');
            }
            try parts.appendSlice(self.allocator, line);
        }
        return null;
    }
};

const QuotedResult = struct {
    value: []const u8,
    remainder: []const u8,
};

const QuoteType = enum {
    triple_double,
    triple_single,

    fn fromLiteral(s: []const u8) ?QuoteType {
        return if (s.len == 3) fromPrefix(s) else null;
    }

    fn fromPrefix(s: []const u8) ?QuoteType {
        if (std.mem.startsWith(u8, s, "\"\"\"")) return .triple_double;
        if (std.mem.startsWith(u8, s, "'''")) return .triple_single;
        return null;
    }

    fn toLiteral(self: QuoteType) []const u8 {
        return switch (self) {
            .triple_double => "\"\"\"",
            .triple_single => "'''",
        };
    }

    /// Pick the triple-quote delimiter that does not collide with `body`.
    /// Defaults to `triple_single`; swaps to `triple_double` only when the
    /// body already contains `'''`.
    fn pickFor(body: []const u8) QuoteType {
        if (std.mem.indexOf(u8, body, "'''") != null) return .triple_double;
        return .triple_single;
    }
};

fn extractQuotedWithRemainder(s: []const u8) ?QuotedResult {
    if (s.len < 2) return null;

    if (QuoteType.fromPrefix(s)) |tq| {
        const end = std.mem.indexOf(u8, s[3..], tq.toLiteral()) orelse return null;
        return .{
            .value = s[3 .. 3 + end],
            .remainder = s[3 + end + 3 ..],
        };
    }

    const q = s[0];
    if (q != '"' and q != '\'') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, q) orelse return null;
    return .{
        .value = s[1..end],
        .remainder = s[end + 1 ..],
    };
}

/// Extract a single string argument from `s`:
///   - strip one layer of matching outer `'…'`, `"…"`, `'''…'''`, or `"""…"""` if present
///   - return `s` unchanged if unquoted
///   - return null if empty, malformed (starts with quote, no matching close),
///     or stripped to empty (`''` / `""` / `''''''` / `""""""`)
fn trimMatchingQuotes(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;

    if (QuoteType.fromPrefix(s)) |tq| {
        if (s.len < 6 or !std.mem.endsWith(u8, s, tq.toLiteral())) return null;
        const inner = s[3 .. s.len - 3];
        return if (inner.len == 0) null else inner;
    }

    const q = s[0];
    if (q == '\'' or q == '"') {
        if (s.len < 2 or s[s.len - 1] != q) return null;
        const inner = s[1 .. s.len - 1];
        return if (inner.len == 0) null else inner;
    }
    return s;
}

/// Wraps a string in outer quotes when formatted via `{f}`, choosing the
/// quote character so the output round-trips through `parse()`:
///   - prefer `'…'`
///   - use `"…"` if the content contains `'` but not `"`
///   - use `'''…'''` if it contains both
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const has_single = std.mem.indexOfScalar(u8, self.s, '\'') != null;
        const has_double = std.mem.indexOfScalar(u8, self.s, '"') != null;

        if (has_single and has_double) {
            const q = QuoteType.pickFor(self.s).toLiteral();
            try writer.writeAll(q);
            try writer.writeAll(self.s);
            try writer.writeAll(q);
        } else {
            const q: u8 = if (has_single) '"' else '\'';
            try writer.writeByte(q);
            try writer.writeAll(self.s);
            try writer.writeByte(q);
        }
    }
};

fn quote(s: []const u8) Quoted {
    return .{ .s = s };
}

/// A serialized LLM tool call: tool name plus JSON arguments.
/// `args_json` is empty for no-arg tools (e.g. tree, markdown).
pub const ToolCall = struct {
    name: []const u8,
    args_json: []const u8,
};

/// Callback for resolving placeholder strings (typically `$LP_*` env vars)
/// inside selector-like fields before serialization. Pass `noSubstitute`
/// when raw output is desired (e.g. in tests).
pub const SubstituteFn = *const fn (arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8;

pub fn noSubstitute(_: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return input;
}

/// Same shape as `ToolCall` but the args are an already-built `std.json.Value`,
/// so callers can hand them straight to `lp.tools.call` without a stringify/
/// reparse round-trip on the hot replay path.
pub const ToolCallValue = struct {
    name: []const u8,
    args: ?std.json.Value,
};

/// Map a Command to its (tool_name, JSON args) representation. Returns
/// null for variants without a 1:1 tool mapping (login, accept_cookies,
/// natural_language, comment, extract — extract is handled by the caller
/// via `extractSchema`, which compiles the schema into a single eval).
///
/// `substitute` is applied to selector-like fields. The `value` field of
/// `type_cmd` is intentionally NOT substituted: `execFill` in
/// `browser/tools.zig` substitutes it itself so the secret never appears
/// in the result text echoed back to the LLM/terminal.
pub fn toToolCallValue(arena: std.mem.Allocator, cmd: Command, substitute: SubstituteFn) std.mem.Allocator.Error!?ToolCallValue {
    const Action = lp.tools.Action;
    var obj: std.json.ObjectMap = .init(arena);
    switch (cmd) {
        .goto => |url| {
            try obj.put("url", .{ .string = try substitute(arena, url) });
            return .{ .name = @tagName(Action.goto), .args = .{ .object = obj } };
        },
        .click => |sel| {
            try obj.put("selector", .{ .string = try substitute(arena, sel) });
            return .{ .name = @tagName(Action.click), .args = .{ .object = obj } };
        },
        .type_cmd => |args| {
            try obj.put("selector", .{ .string = try substitute(arena, args.selector) });
            try obj.put("value", .{ .string = args.value });
            return .{ .name = @tagName(Action.fill), .args = .{ .object = obj } };
        },
        .wait => |sel| {
            try obj.put("selector", .{ .string = sel });
            return .{ .name = @tagName(Action.waitForSelector), .args = .{ .object = obj } };
        },
        .scroll => |args| {
            try obj.put("x", .{ .integer = args.x });
            try obj.put("y", .{ .integer = args.y });
            return .{ .name = @tagName(Action.scroll), .args = .{ .object = obj } };
        },
        .hover => |sel| {
            try obj.put("selector", .{ .string = try substitute(arena, sel) });
            return .{ .name = @tagName(Action.hover), .args = .{ .object = obj } };
        },
        .select => |args| {
            try obj.put("selector", .{ .string = try substitute(arena, args.selector) });
            try obj.put("value", .{ .string = try substitute(arena, args.value) });
            return .{ .name = @tagName(Action.selectOption), .args = .{ .object = obj } };
        },
        .check => |args| {
            try obj.put("selector", .{ .string = try substitute(arena, args.selector) });
            try obj.put("checked", .{ .bool = args.checked });
            return .{ .name = @tagName(Action.setChecked), .args = .{ .object = obj } };
        },
        .tree => return .{ .name = @tagName(Action.tree), .args = null },
        .markdown => return .{ .name = @tagName(Action.markdown), .args = null },
        .eval_js => |script| {
            try obj.put("script", .{ .string = script });
            return .{ .name = @tagName(Action.eval), .args = .{ .object = obj } };
        },
        .extract, .natural_language, .comment, .login, .accept_cookies => return null,
    }
}

/// Stringified flavor of `toToolCallValue` — used by the recorder/diagnostic
/// paths (and tests) that want a JSON string. Hot dispatch should use
/// `toToolCallValue` instead and skip the stringify+reparse.
pub fn toToolCall(arena: std.mem.Allocator, cmd: Command, substitute: SubstituteFn) std.mem.Allocator.Error!?ToolCall {
    const tcv = (try toToolCallValue(arena, cmd, substitute)) orelse return null;
    return .{
        .name = tcv.name,
        .args_json = if (tcv.args) |v| try std.json.Stringify.valueAlloc(arena, v, .{}) else "",
    };
}

/// Inverse of `toToolCall`: parse an LLM tool call into a Command, or
/// return null if the tool name doesn't correspond to a PandaScript
/// command. Variants emitted by `toToolCall` round-trip through this.
pub fn fromToolCall(arena: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) ?Command {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch return null;
    return fromToolCallValue(tool_name, parsed);
}

/// Like `fromToolCall` but takes the already-parsed JSON value directly,
/// skipping the string round-trip when the caller already has it (e.g. the
/// MCP server, which dispatches off `std.json.Value`).
pub fn fromToolCallValue(tool_name: []const u8, arguments: std.json.Value) ?Command {
    const Action = lp.tools.Action;
    const action = std.meta.stringToEnum(Action, tool_name) orelse return null;
    const obj = switch (arguments) {
        .object => |o| o,
        else => return null,
    };

    return switch (action) {
        .goto => .{ .goto = getJsonString(obj, "url") orelse return null },
        .click => .{ .click = getJsonString(obj, "selector") orelse return null },
        .hover => .{ .hover = getJsonString(obj, "selector") orelse return null },
        .eval => .{ .eval_js = getJsonString(obj, "script") orelse return null },
        .waitForSelector => .{ .wait = getJsonString(obj, "selector") orelse return null },
        .fill => .{ .type_cmd = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .value = getJsonString(obj, "value") orelse return null,
        } },
        .selectOption => .{ .select = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .value = getJsonString(obj, "value") orelse return null,
        } },
        .setChecked => .{ .check = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .checked = switch (obj.get("checked") orelse return null) {
                .bool => |b| b,
                else => return null,
            },
        } },
        .scroll => blk: {
            if (obj.get("backendNodeId") != null) break :blk null;
            break :blk .{ .scroll = .{ .x = getJsonI32(obj, "x", 0), .y = getJsonI32(obj, "y", 0) } };
        },
        else => null,
    };
}

fn getJsonString(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonI32(o: std.json.ObjectMap, key: []const u8, default: i32) i32 {
    return switch (o.get(key) orelse return default) {
        .integer => |i| std.math.cast(i32, i) orelse default,
        else => default,
    };
}

// --- Tests ---

fn testUpcase(ar: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try ar.alloc(u8, input.len);
    return std.ascii.upperString(out, input);
}

test "parse GOTO" {
    const cmd = parse("GOTO https://example.com");
    try std.testing.expectEqualStrings("https://example.com", cmd.goto);
}

test "parse lowercase keyword falls through to natural_language" {
    // Commands must be ALL CAPS so that prose like "click the login button"
    // can flow through to the LLM without being misread as a CLICK command.
    try std.testing.expect(parse("goto https://example.com") == .natural_language);
    try std.testing.expect(parse("click '#submit'") == .natural_language);
    try std.testing.expect(parse("type '#email' 'a@b.c'") == .natural_language);
}

test "parse mixed-case keyword falls through to natural_language" {
    try std.testing.expect(parse("Click '#foo'") == .natural_language);
    try std.testing.expect(parse("Goto https://x") == .natural_language);
    try std.testing.expect(parse("Markdown") == .natural_language);
}

test "parse natural language starting with command verb" {
    try std.testing.expect(parse("click on the login button") == .natural_language);
    try std.testing.expect(parse("type the username into the form") == .natural_language);
    try std.testing.expect(parse("wait for the page to load") == .natural_language);
}

test "parse GOTO missing url" {
    const cmd = parse("GOTO");
    try std.testing.expect(cmd == .natural_language);
}

test "keywordSyntax: argful keyword without args returns its shape" {
    const k = keywordSyntax("CLICK").?;
    try std.testing.expectEqualStrings("CLICK", k.name);
    try std.testing.expectEqualStrings("'<selector>'", k.args.?);
}

test "keywordSyntax: trailing whitespace tolerated" {
    try std.testing.expect(keywordSyntax("  GOTO   ") != null);
}

test "keywordSyntax: argless keyword returns entry with null args" {
    const k = keywordSyntax("LOGIN").?;
    try std.testing.expectEqualStrings("LOGIN", k.name);
    try std.testing.expect(k.args == null);
}

test "keywordSyntax: unknown word returns null" {
    try std.testing.expect(keywordSyntax("FOOBAR") == null);
    try std.testing.expect(keywordSyntax("click the button") == null);
}

test "parse argless keyword with trailing junk falls through to natural_language" {
    try std.testing.expect(parse("LOGIN abc") == .natural_language);
    try std.testing.expect(parse("TREE foo") == .natural_language);
    try std.testing.expect(parse("MARKDOWN x") == .natural_language);
    try std.testing.expect(parse("ACCEPT_COOKIES y") == .natural_language);
}

test "parse CLICK quoted" {
    const cmd = parse("CLICK \"Login\"");
    try std.testing.expectEqualStrings("Login", cmd.click);
}

test "parse CLICK unquoted" {
    const cmd = parse("CLICK .submit-btn");
    try std.testing.expectEqualStrings(".submit-btn", cmd.click);
}

test "parse TYPE two quoted args" {
    const cmd = parse("TYPE \"#email\" \"user@test.com\"");
    try std.testing.expectEqualStrings("#email", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("user@test.com", cmd.type_cmd.value);
}

test "parse TYPE with triple-quoted selector" {
    const cmd = parse("TYPE '''a[x='y'][z=\"w\"]''' 'value'");
    try std.testing.expectEqualStrings("a[x='y'][z=\"w\"]", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("value", cmd.type_cmd.value);
}

test "parse TYPE single-quoted with inner double quotes" {
    const cmd = parse("TYPE 'input[name=\"acct\"]' '$LP_USERNAME'");
    try std.testing.expectEqualStrings("input[name=\"acct\"]", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("$LP_USERNAME", cmd.type_cmd.value);
}

test "parse CLICK single-quoted" {
    const cmd = parse("CLICK 'a[href*=\"login\"]'");
    try std.testing.expectEqualStrings("a[href*=\"login\"]", cmd.click);
}

test "parse CLICK with nested single quotes" {
    // Input: CLICK 'a[href='login?goto=news']'
    const cmd = parse("CLICK 'a[href='login?goto=news']'");
    try std.testing.expectEqualStrings("a[href='login?goto=news']", cmd.click);
}

test "parse CLICK malformed quotes falls through to natural_language" {
    try std.testing.expect(parse("CLICK '#foo") == .natural_language);
    try std.testing.expect(parse("WAIT \".foo") == .natural_language);
    try std.testing.expect(parse("HOVER '#x\"") == .natural_language);
}

test "parse EXTRACT with nested quotes in schema" {
    const cmd = parse("EXTRACT '{\"link\": \"a[href*='news']\"}'");
    try std.testing.expectEqualStrings("{\"link\": \"a[href*='news']\"}", cmd.extract);
}

test "parse EVAL with single-quoted inner string" {
    const cmd = parse("EVAL 'document.querySelector('h1').innerText'");
    try std.testing.expectEqualStrings("document.querySelector('h1').innerText", cmd.eval_js);
}

test "parse TYPE nested inner quote in value" {
    const cmd = parse("TYPE '#comment' 'she said 'hi''");
    try std.testing.expectEqualStrings("#comment", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("she said 'hi'", cmd.type_cmd.value);
}

test "parse TYPE unquoted value" {
    const cmd = parse("TYPE '#email' user@example.com");
    try std.testing.expectEqualStrings("#email", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("user@example.com", cmd.type_cmd.value);
}

test "parse TYPE multi-word unquoted value" {
    // The whole remainder after the first arg becomes the value — spaces included.
    const cmd = parse("TYPE '#comment' hello world");
    try std.testing.expectEqualStrings("#comment", cmd.type_cmd.selector);
    try std.testing.expectEqualStrings("hello world", cmd.type_cmd.value);
}

test "parse TYPE missing second arg" {
    const cmd = parse("TYPE \"#email\"");
    try std.testing.expect(cmd == .natural_language);
}

test "parse WAIT" {
    const cmd = parse("WAIT \".dashboard\"");
    try std.testing.expectEqualStrings(".dashboard", cmd.wait);
}

test "parse SCROLL" {
    const cases = [_]struct {
        in: []const u8,
        expected: ?struct { x: i32, y: i32 },
    }{
        .{ .in = "SCROLL", .expected = .{ .x = 0, .y = 0 } },
        .{ .in = "SCROLL 500", .expected = .{ .x = 0, .y = 500 } },
        .{ .in = "SCROLL 100 200", .expected = .{ .x = 100, .y = 200 } },
        .{ .in = "SCROLL down", .expected = null },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("failing case {d}: {s}\n", .{ i, c.in });
        const cmd = parse(c.in);
        if (c.expected) |e| {
            try std.testing.expectEqual(e.x, cmd.scroll.x);
            try std.testing.expectEqual(e.y, cmd.scroll.y);
        } else {
            try std.testing.expect(cmd == .natural_language);
        }
    }
}

test "parse HOVER" {
    const cmd = parse("HOVER '#menu'");
    try std.testing.expectEqualStrings("#menu", cmd.hover);
}

test "parse HOVER missing selector" {
    const cmd = parse("HOVER");
    try std.testing.expect(cmd == .natural_language);
}

test "parse SELECT two args" {
    const cmd = parse("SELECT '#country' 'France'");
    try std.testing.expectEqualStrings("#country", cmd.select.selector);
    try std.testing.expectEqualStrings("France", cmd.select.value);
}

test "parse SELECT missing value" {
    const cmd = parse("SELECT '#country'");
    try std.testing.expect(cmd == .natural_language);
}

test "parse CHECK" {
    const cases = [_]struct {
        in: []const u8,
        expected: ?struct { selector: []const u8, checked: bool },
    }{
        .{ .in = "CHECK '#agree'", .expected = .{ .selector = "#agree", .checked = true } },
        .{ .in = "CHECK '#agree' true", .expected = .{ .selector = "#agree", .checked = true } },
        .{ .in = "CHECK '#newsletter' false", .expected = .{ .selector = "#newsletter", .checked = false } },
        .{ .in = "CHECK '#x' maybe", .expected = null },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("failing case {d}: {s}\n", .{ i, c.in });
        const cmd = parse(c.in);
        if (c.expected) |e| {
            try std.testing.expectEqualStrings(e.selector, cmd.check.selector);
            try std.testing.expectEqual(e.checked, cmd.check.checked);
        } else {
            try std.testing.expect(cmd == .natural_language);
        }
    }
}

test "parse TREE" {
    const cmd = parse("TREE");
    try std.testing.expect(cmd == .tree);
}

test "parse MARKDOWN" {
    try std.testing.expect(parse("MARKDOWN") == .markdown);
    try std.testing.expect(parse("markdown") == .natural_language);
}

test "parse EXTRACT" {
    const cmd = parse("EXTRACT '{\"titles\": [\".title\"]}'");
    try std.testing.expectEqualStrings("{\"titles\": [\".title\"]}", cmd.extract);
}

test "format EXTRACT single-line schema round-trip" {
    const schema = "{\"title\":\"h1\",\"items\":[\".item\"]}";
    const cmd: Command = .{ .extract = schema };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("EXTRACT '{\"title\":\"h1\",\"items\":[\".item\"]}'", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings(schema, round.extract);
}

test "format EXTRACT multi-line schema uses triple quotes" {
    const schema = "{\n  \"title\": \"h1\"\n}";
    const cmd: Command = .{ .extract = schema };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("EXTRACT '''\n{\n  \"title\": \"h1\"\n}\n'''", aw.written());
}

test "parse EVAL single line" {
    const cmd = parse("EVAL \"document.title\"");
    try std.testing.expectEqualStrings("document.title", cmd.eval_js);
}

test "parse LOGIN" {
    try std.testing.expect(parse("LOGIN") == .login);
    try std.testing.expect(parse("login") == .natural_language);
}

test "parse ACCEPT_COOKIES" {
    try std.testing.expect(parse("ACCEPT_COOKIES") == .accept_cookies);
    try std.testing.expect(parse("accept_cookies") == .natural_language);
}

test "parse EVAL triple-quote opener requires uppercase" {
    try std.testing.expect(parse("eval '''") == .natural_language);
    try std.testing.expect(parse("eval \"\"\"") == .natural_language);
}

test "parse comment" {
    try std.testing.expect(parse("# this is a comment") == .comment);
    try std.testing.expect(parse("# INTENT: LOGIN") == .comment);
}

test "parse natural language fallback" {
    const cmd = parse("what is on this page?");
    try std.testing.expectEqualStrings("what is on this page?", cmd.natural_language);
}

test "parse whitespace trimming" {
    const cmd = parse("  GOTO  https://example.com  ");
    try std.testing.expectEqualStrings("https://example.com", cmd.goto);
}

test "parse empty input" {
    const cmd = parse("");
    try std.testing.expect(cmd == .natural_language);
}

test "isRecorded" {
    try std.testing.expect(parse("GOTO https://example.com").isRecorded());
    try std.testing.expect(parse("CLICK \"btn\"").isRecorded());
    try std.testing.expect(parse("TYPE \"sel\" \"val\"").isRecorded());
    try std.testing.expect(parse("WAIT \".x\"").isRecorded());
    try std.testing.expect(parse("SCROLL 0 200").isRecorded());
    try std.testing.expect(parse("HOVER '#menu'").isRecorded());
    try std.testing.expect(parse("SELECT '#sel' 'a'").isRecorded());
    try std.testing.expect(parse("CHECK '#chk'").isRecorded());
    try std.testing.expect(parse("CHECK '#chk' false").isRecorded());
    try std.testing.expect(parse("EXTRACT '{\"t\":\".title\"}'").isRecorded());
    try std.testing.expect(parse("EVAL \"1+1\"").isRecorded());
    try std.testing.expect(!parse("TREE").isRecorded());
    try std.testing.expect(!parse("MARKDOWN").isRecorded());
}

test "ScriptIterator basic commands" {
    const script =
        \\GOTO https://example.com
        \\TREE
        \\CLICK "Login"
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("https://example.com", e1.command.goto);
    try std.testing.expectEqual(@as(u32, 1), e1.line_num);

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.command == .tree);

    const e3 = (try iter.next()).?;
    try std.testing.expectEqualStrings("Login", e3.command.click);

    try std.testing.expect((try iter.next()) == null);
}

test "ScriptIterator skips blank lines and comments" {
    const script =
        \\# Navigate
        \\GOTO https://example.com
        \\
        \\# Extract
        \\TREE
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .comment);

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.command == .goto);

    const e3 = (try iter.next()).?;
    try std.testing.expect(e3.command == .comment);

    const e4 = (try iter.next()).?;
    try std.testing.expect(e4.command == .tree);

    try std.testing.expect((try iter.next()) == null);
}

test "ScriptIterator multi-line EVAL" {
    const script =
        \\GOTO https://example.com
        \\EVAL """
        \\  const x = 1;
        \\  const y = 2;
        \\  return x + y;
        \\"""
        \\TREE
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .goto);

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.command == .eval_js);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.eval_js, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.eval_js, "return x + y;") != null);
    defer std.testing.allocator.free(e2.command.eval_js);

    const e3 = (try iter.next()).?;
    try std.testing.expect(e3.command == .tree);

    try std.testing.expect((try iter.next()) == null);
}

test "ScriptIterator unterminated EVAL" {
    const script =
        \\EVAL """
        \\  const x = 1;
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .natural_language);
    try std.testing.expectEqualStrings("unterminated EVAL block", e1.command.natural_language);
}

test "ScriptIterator inline triple-quoted EVAL stays single-line" {
    // The opening ''' has content on the same line, so this is NOT a
    // multi-line block — trimMatchingQuotes handles it via parse().
    const script =
        \\EVAL '''console.log("x")'''
        \\CLICK '.btn'
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .eval_js);
    try std.testing.expectEqualStrings("console.log(\"x\")", e1.command.eval_js);

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.command == .click);
    try std.testing.expectEqualStrings(".btn", e2.command.click);

    try std.testing.expect((try iter.next()) == null);
}

test "ScriptIterator multi-line EXTRACT" {
    const script =
        \\GOTO https://example.com
        \\EXTRACT '''
        \\{
        \\  "title": "h1",
        \\  "items": [".item"]
        \\}
        \\'''
        \\TREE
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .goto);

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.command == .extract);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.extract, "\"title\": \"h1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.extract, "\"items\": [\".item\"]") != null);
    defer std.testing.allocator.free(e2.command.extract);

    const e3 = (try iter.next()).?;
    try std.testing.expect(e3.command == .tree);

    try std.testing.expect((try iter.next()) == null);
}

test "ScriptIterator unterminated EXTRACT" {
    const script =
        \\EXTRACT """
        \\{"t":"h1"
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .natural_language);
    try std.testing.expectEqualStrings("unterminated EXTRACT block", e1.command.natural_language);
}

test "ScriptIterator multi-line EVAL mismatched triple quote" {
    const script =
        \\EVAL """
        \\  const s = " ''' ";
        \\  console.log(s);
        \\"""
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = (try iter.next()).?;
    try std.testing.expect(e1.command == .eval_js);
    try std.testing.expectEqualStrings("  const s = \" ''' \";\n  console.log(s);", e1.command.eval_js);
    std.testing.allocator.free(e1.command.eval_js);
}

test "trimMatchingQuotes" {
    const cases = [_]struct { in: []const u8, out: ?[]const u8 }{
        .{ .in = "'hello'", .out = "hello" },
        .{ .in = "\"hello\"", .out = "hello" },
        // Nested same-quote — one layer stripped, inner quotes preserved.
        .{ .in = "'a[href='login']'", .out = "a[href='login']" },
        // Mismatched outer quote characters → malformed.
        .{ .in = "'foo\"", .out = null },
        // Starts with quote but no matching close → malformed.
        .{ .in = "'foo", .out = null },
        .{ .in = "'", .out = null },
        // Not quoted — returned unchanged.
        .{ .in = "plain", .out = "plain" },
        // Empty input and empty quoted → null (no usable argument).
        .{ .in = "", .out = null },
        .{ .in = "''", .out = null },
        .{ .in = "\"\"", .out = null },
        // Triple quotes are stripped as a single layer.
        .{ .in = "'''a'''", .out = "a" },
        .{ .in = "\"\"\"a\"\"\"", .out = "a" },
        .{ .in = "'''a'b\"c'''", .out = "a'b\"c" },
        // Empty triple-quoted → null, matching '' / "" rejection.
        .{ .in = "''''''", .out = null },
        .{ .in = "\"\"\"\"\"\"", .out = null },
        // Unterminated triple quote → malformed.
        .{ .in = "'''abc", .out = null },
        // Too short to close a triple quote → malformed.
        .{ .in = "'''abc''", .out = null },
        // Never recurse — only one layer is stripped.
        .{ .in = "''a''", .out = "'a'" },
    };
    for (cases, 0..) |c, i| {
        errdefer std.debug.print("failing case {d}: trimMatchingQuotes({s})\n", .{ i, c.in });
        const got = trimMatchingQuotes(c.in);
        if (c.out) |expected| {
            try std.testing.expect(got != null);
            try std.testing.expectEqualStrings(expected, got.?);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "format round-trip for quoted selectors" {
    const cases = [_]struct { input: []const u8, expected_line: []const u8 }{
        // No inner quotes → single-quote wrap (preferred).
        .{ .input = "#login", .expected_line = "CLICK '#login'" },
        // Inner single quotes only → falls back to double-quote wrap.
        .{ .input = "input[name='acct']", .expected_line = "CLICK \"input[name='acct']\"" },
        // Inner double quotes only → stays single-quote wrap.
        .{ .input = "input[name=\"acct\"]", .expected_line = "CLICK 'input[name=\"acct\"]'" },
    };

    for (cases, 0..) |c, i| {
        errdefer std.debug.print("failing case {d}: {s}\n", .{ i, c.input });
        const cmd: Command = .{ .click = c.input };

        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try cmd.format(&aw.writer);
        try std.testing.expectEqualStrings(c.expected_line, aw.written());

        const round = parse(aw.written());
        try std.testing.expectEqualStrings(c.input, round.click);
    }
}

test "format TYPE with nested single quotes round-trip" {
    const cmd: Command = .{ .type_cmd = .{
        .selector = "input[name='acct']",
        .value = "$LP_USERNAME",
    } };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("TYPE \"input[name='acct']\" '$LP_USERNAME'", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings("input[name='acct']", round.type_cmd.selector);
    try std.testing.expectEqualStrings("$LP_USERNAME", round.type_cmd.value);
}

test "format with both quote types uses triple quotes" {
    const cmd: Command = .{ .click = "a[x='y'][z=\"w\"]" };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("CLICK '''a[x='y'][z=\"w\"]'''", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings("a[x='y'][z=\"w\"]", round.click);
}

test "format TYPE with both quote types round-trip" {
    const cmd: Command = .{ .type_cmd = .{
        .selector = "a[x='y'][z=\"w\"]",
        .value = "some 'value' with \"quotes\"",
    } };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("TYPE '''a[x='y'][z=\"w\"]''' '''some 'value' with \"quotes\"'''", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings("a[x='y'][z=\"w\"]", round.type_cmd.selector);
    try std.testing.expectEqualStrings("some 'value' with \"quotes\"", round.type_cmd.value);
}

test "format swaps to triple-double when body contains '''" {
    // Value contains a literal ''' plus a single `"`, forcing the triple-quote
    // branch. The recorder must pick """…""" so the line round-trips.
    const cmd: Command = .{ .click = "weird '''selector\"" };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("CLICK \"\"\"weird '''selector\"\"\"\"", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings("weird '''selector\"", round.click);
}

// --- Tool-call round-trip tests ---
//
// These lock the (Action ↔ Command) mapping table. If you add a new Command
// variant, extend both `toToolCall` and `fromToolCall` and add a case here.

fn expectRoundTrip(cmd: Command) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tc = (try toToolCall(a, cmd, noSubstitute)) orelse return error.NoToolMapping;
    const back = fromToolCall(a, tc.name, if (tc.args_json.len == 0) "{}" else tc.args_json) orelse
        return error.RoundTripFailed;
    try std.testing.expectEqualDeep(cmd, back);
}

test "toToolCall/fromToolCall round-trip: goto" {
    try expectRoundTrip(.{ .goto = "https://example.com" });
}

test "toToolCall/fromToolCall round-trip: click" {
    try expectRoundTrip(.{ .click = "#login-btn" });
}

test "toToolCall/fromToolCall round-trip: type_cmd" {
    try expectRoundTrip(.{ .type_cmd = .{ .selector = "#email", .value = "x@y.z" } });
}

test "toToolCall/fromToolCall round-trip: wait" {
    try expectRoundTrip(.{ .wait = ".loaded" });
}

test "toToolCall/fromToolCall round-trip: scroll" {
    try expectRoundTrip(.{ .scroll = .{ .x = 0, .y = 500 } });
}

test "toToolCall/fromToolCall round-trip: hover" {
    try expectRoundTrip(.{ .hover = ".menu-item" });
}

test "toToolCall/fromToolCall round-trip: select" {
    try expectRoundTrip(.{ .select = .{ .selector = "#country", .value = "US" } });
}

test "toToolCall/fromToolCall round-trip: check true and false" {
    try expectRoundTrip(.{ .check = .{ .selector = "#tos", .checked = true } });
    try expectRoundTrip(.{ .check = .{ .selector = "#tos", .checked = false } });
}

test "toToolCall/fromToolCall round-trip: eval_js" {
    try expectRoundTrip(.{ .eval_js = "document.title" });
}

test "toToolCall: variants without tool mapping return null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try toToolCall(a, .{ .extract = "{\"x\":\".x\"}" }, noSubstitute)) == null);
    try std.testing.expect((try toToolCall(a, .login, noSubstitute)) == null);
    try std.testing.expect((try toToolCall(a, .accept_cookies, noSubstitute)) == null);
    try std.testing.expect((try toToolCall(a, .comment, noSubstitute)) == null);
    try std.testing.expect((try toToolCall(a, .{ .natural_language = "hi" }, noSubstitute)) == null);
}

test "fromToolCall: unknown tool returns null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(fromToolCall(arena.allocator(), "no_such_tool", "{}") == null);
}

test "fromToolCall: missing required field returns null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(fromToolCall(arena.allocator(), "click", "{}") == null);
}

test "toToolCall: substitute callback applied to selector fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tc = (try toToolCall(a, .{ .click = "abc" }, testUpcase)).?;
    try std.testing.expectEqualStrings("click", tc.name);
    try std.testing.expectEqualStrings("{\"selector\":\"ABC\"}", tc.args_json);
}

test "toToolCall: type_cmd value is NOT substituted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tc = (try toToolCall(a, .{ .type_cmd = .{ .selector = "abc", .value = "$LP_PASSWORD" } }, testUpcase)).?;
    try std.testing.expectEqualStrings("fill", tc.name);
    // selector substituted, value preserved as $LP_* reference
    try std.testing.expectEqualStrings("{\"selector\":\"ABC\",\"value\":\"$LP_PASSWORD\"}", tc.args_json);
}

fn expectBody(body: []const u8, complete_args: usize, at_boundary: bool) !void {
    const cur = analyzePandaBody(body);
    try std.testing.expectEqual(complete_args, cur.complete_args);
    try std.testing.expectEqual(at_boundary, cur.at_boundary);
}

test "analyzePandaBody: empty and whitespace-only" {
    try expectBody("", 0, true);
    try expectBody(" ", 0, true);
    try expectBody("   ", 0, true);
}

test "analyzePandaBody: bare token" {
    try expectBody("foo", 1, false);
    try expectBody("foo ", 1, true);
    try expectBody("100", 1, false);
    try expectBody("100 ", 1, true);
}

test "analyzePandaBody: single-quoted token" {
    try expectBody("'#x'", 1, false);
    try expectBody("'#x' ", 1, true);
    try expectBody("'#x' 'y'", 2, false);
    try expectBody("'#x' 'y' ", 2, true);
}

test "analyzePandaBody: unterminated quote suppresses boundary" {
    try expectBody("'#unterm", 0, false);
    try expectBody("'#x' 'unterm", 1, false);
}

test "analyzePandaBody: triple-quoted token" {
    try expectBody("'''abc'''", 1, false);
    try expectBody("'''abc''' ", 1, true);
    try expectBody("\"\"\"x\"\"\"", 1, false);
}

test "analyzePandaBody: unterminated triple quote" {
    try expectBody("'''abc", 0, false);
    try expectBody("'''abc''", 0, false);
}

test "analyzePandaBody: mixed quoted and bare" {
    try expectBody("'#x' false", 2, false);
    try expectBody("'#x' false ", 2, true);
}

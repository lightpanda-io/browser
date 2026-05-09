const std = @import("std");
const lp = @import("lightpanda");
pub const stringifyJson = @import("../script.zig").stringifyJson;

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
            .tree, .markdown, .comment => false,
            .goto, .click, .type_cmd, .wait, .scroll, .hover, .select, .check, .extract, .eval_js, .login, .accept_cookies => true,
            .natural_language => |text| text.len > 0,
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
    /// in dumb PandaScript-only mode (no `--provider`).
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
    ///   - triple single quotes (`'''…'''`) if the content contains both.
    ///
    /// There is no escape syntax, so a value that literally contains `'''`
    /// still cannot round-trip. This is much rarer than the mixed-quote case
    /// (CSS selectors and form values almost never contain `'''`).
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
            .extract => |sel| try writer.print("EXTRACT {f}", .{quote(sel)}),
            .eval_js => |script| if (std.mem.indexOfScalar(u8, script, '\n') != null)
                try writer.print("EVAL '''\n{s}\n'''", .{script})
            else
                try writer.print("EVAL {f}", .{quote(script)}),
            .login => try writer.writeAll("LOGIN"),
            .accept_cookies => try writer.writeAll("ACCEPT_COOKIES"),
            .comment => try writer.writeAll("#"),
            .natural_language => |text| try writer.writeAll(text),
        }
    }
};

/// Parse a line of REPL input into a PandaScript command.
/// Unrecognized input is returned as `.natural_language`.
/// For multi-line EVAL blocks in scripts, use `ScriptParser`.
pub fn parse(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .natural_language = trimmed };

    if (trimmed[0] == '#') return .{ .comment = {} };

    const cmd_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    const cmd_word = trimmed[0..cmd_end];
    const rest = std.mem.trim(u8, trimmed[cmd_end..], &std.ascii.whitespace);

    if (std.ascii.eqlIgnoreCase(cmd_word, "GOTO")) {
        if (rest.len == 0) return .{ .natural_language = trimmed };
        return .{ .goto = rest };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "CLICK")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .click = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "TYPE")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = trimMatchingQuotes(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .type_cmd = .{ .selector = first.value, .value = second } };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "WAIT")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .wait = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "SCROLL")) {
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

    if (std.ascii.eqlIgnoreCase(cmd_word, "HOVER")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .hover = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "SELECT")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = trimMatchingQuotes(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .select = .{ .selector = first.value, .value = second } };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "CHECK")) {
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

    if (std.ascii.eqlIgnoreCase(cmd_word, "TREE")) {
        return .{ .tree = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "MARKDOWN")) {
        return .{ .markdown = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "EXTRACT")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .extract = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "EVAL")) {
        const arg = trimMatchingQuotes(rest) orelse return .{ .natural_language = trimmed };
        return .{ .eval_js = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "LOGIN")) {
        return .{ .login = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "ACCEPT_COOKIES")) {
        return .{ .accept_cookies = {} };
    }

    return .{ .natural_language = trimmed };
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

    /// Multi-line EVAL blocks are assembled into a single eval_js command.
    pub fn next(self: *ScriptIterator) ?Entry {
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr);

            if (isEvalTripleQuote(trimmed)) |quote_type| {
                const start_line = self.line_num;
                const js_or_null = self.collectEvalBlock(quote_type);
                const span_end = self.lines.index orelse self.lines.buffer.len;
                const cmd: Command = if (js_or_null) |js|
                    .{ .eval_js = js }
                else
                    .{ .natural_language = "unterminated EVAL block" };
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

    fn isEvalTripleQuote(line: []const u8) ?[]const u8 {
        const cmd_end = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse line.len;
        const cmd_word = line[0..cmd_end];
        if (!std.ascii.eqlIgnoreCase(cmd_word, "EVAL")) return null;
        const rest = std.mem.trim(u8, line[cmd_end..], &std.ascii.whitespace);
        // Multi-line mode requires the opening triple-quote to stand alone —
        // inline forms like `EVAL '''a"b'c'''` fall through to single-line parse().
        if (rest.len != 3) return null;
        if (std.mem.eql(u8, rest, "\"\"\"")) return "\"\"\"";
        if (std.mem.eql(u8, rest, "'''")) return "'''";
        return null;
    }

    /// Collect lines until matching closing triple quote, return the JS content.
    fn collectEvalBlock(self: *ScriptIterator, quote_type: []const u8) ?[]const u8 {
        var parts: std.ArrayList(u8) = .empty;
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, quote_type)) {
                return parts.toOwnedSlice(self.allocator) catch null;
            }
            if (parts.items.len > 0) {
                parts.append(self.allocator, '\n') catch return null;
            }
            parts.appendSlice(self.allocator, line) catch return null;
        }
        // Unterminated
        parts.deinit(self.allocator);
        return null;
    }
};

const QuotedResult = struct {
    value: []const u8,
    remainder: []const u8,
};

/// Returns the opening `'''` or `"""` delimiter if `s` starts with one, else null.
fn tripleQuotePrefix(s: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, "'''")) return "'''";
    if (std.mem.startsWith(u8, s, "\"\"\"")) return "\"\"\"";
    return null;
}

fn extractQuotedWithRemainder(s: []const u8) ?QuotedResult {
    if (s.len < 2) return null;

    if (tripleQuotePrefix(s)) |tq| {
        const end = std.mem.indexOf(u8, s[3..], tq) orelse return null;
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

    if (tripleQuotePrefix(s)) |tq| {
        if (s.len < 6 or !std.mem.endsWith(u8, s, tq)) return null;
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
            try writer.writeAll("'''");
            try writer.writeAll(self.s);
            try writer.writeAll("'''");
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
pub const SubstituteFn = *const fn (arena: std.mem.Allocator, input: []const u8) []const u8;

pub fn noSubstitute(_: std.mem.Allocator, input: []const u8) []const u8 {
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
/// natural_language, comment, extract — extract is rendered as a
/// custom `eval` script by the caller).
///
/// `substitute` is applied to selector-like fields. The `value` field of
/// `type_cmd` is intentionally NOT substituted: `execFill` in
/// `browser/tools.zig` substitutes it itself so the secret never appears
/// in the result text echoed back to the LLM/terminal.
pub fn toToolCallValue(arena: std.mem.Allocator, cmd: Command, substitute: SubstituteFn) ?ToolCallValue {
    const Action = lp.tools.Action;
    var obj: std.json.ObjectMap = .init(arena);
    switch (cmd) {
        .goto => |url| {
            obj.put("url", .{ .string = substitute(arena, url) }) catch return null;
            return .{ .name = @tagName(Action.goto), .args = .{ .object = obj } };
        },
        .click => |sel| {
            obj.put("selector", .{ .string = substitute(arena, sel) }) catch return null;
            return .{ .name = @tagName(Action.click), .args = .{ .object = obj } };
        },
        .type_cmd => |args| {
            obj.put("selector", .{ .string = substitute(arena, args.selector) }) catch return null;
            obj.put("value", .{ .string = args.value }) catch return null;
            return .{ .name = @tagName(Action.fill), .args = .{ .object = obj } };
        },
        .wait => |sel| {
            obj.put("selector", .{ .string = sel }) catch return null;
            return .{ .name = @tagName(Action.waitForSelector), .args = .{ .object = obj } };
        },
        .scroll => |args| {
            obj.put("x", .{ .integer = args.x }) catch return null;
            obj.put("y", .{ .integer = args.y }) catch return null;
            return .{ .name = @tagName(Action.scroll), .args = .{ .object = obj } };
        },
        .hover => |sel| {
            obj.put("selector", .{ .string = substitute(arena, sel) }) catch return null;
            return .{ .name = @tagName(Action.hover), .args = .{ .object = obj } };
        },
        .select => |args| {
            obj.put("selector", .{ .string = substitute(arena, args.selector) }) catch return null;
            obj.put("value", .{ .string = substitute(arena, args.value) }) catch return null;
            return .{ .name = @tagName(Action.selectOption), .args = .{ .object = obj } };
        },
        .check => |args| {
            obj.put("selector", .{ .string = substitute(arena, args.selector) }) catch return null;
            obj.put("checked", .{ .bool = args.checked }) catch return null;
            return .{ .name = @tagName(Action.setChecked), .args = .{ .object = obj } };
        },
        .tree => return .{ .name = @tagName(Action.tree), .args = null },
        .markdown => return .{ .name = @tagName(Action.markdown), .args = null },
        .eval_js => |script| {
            obj.put("script", .{ .string = script }) catch return null;
            return .{ .name = @tagName(Action.eval), .args = .{ .object = obj } };
        },
        .extract, .natural_language, .comment, .login, .accept_cookies => return null,
    }
}

/// Stringified flavor of `toToolCallValue` — used by the recorder/diagnostic
/// paths (and tests) that want a JSON string. Hot dispatch should use
/// `toToolCallValue` instead and skip the stringify+reparse.
pub fn toToolCall(arena: std.mem.Allocator, cmd: Command, substitute: SubstituteFn) ?ToolCall {
    const tcv = toToolCallValue(arena, cmd, substitute) orelse return null;
    return .{
        .name = tcv.name,
        .args_json = if (tcv.args) |v| stringifyJson(arena, v) else "",
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
            const x: i32 = switch (obj.get("x") orelse std.json.Value{ .integer = 0 }) {
                .integer => |i| @intCast(i),
                else => 0,
            };
            const y: i32 = switch (obj.get("y") orelse std.json.Value{ .integer = 0 }) {
                .integer => |i| @intCast(i),
                else => 0,
            };
            break :blk .{ .scroll = .{ .x = x, .y = y } };
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

// --- Tests ---

test "parse GOTO" {
    const cmd = parse("GOTO https://example.com");
    try std.testing.expectEqualStrings("https://example.com", cmd.goto);
}

test "parse GOTO case insensitive" {
    const cmd = parse("goto https://example.com");
    try std.testing.expectEqualStrings("https://example.com", cmd.goto);
}

test "parse GOTO missing url" {
    const cmd = parse("GOTO");
    try std.testing.expect(cmd == .natural_language);
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

test "parse EXTRACT with nested quotes" {
    const cmd = parse("EXTRACT 'a[href*='news']'");
    try std.testing.expectEqualStrings("a[href*='news']", cmd.extract);
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
    try std.testing.expect(parse("markdown") == .markdown);
}

test "parse EXTRACT" {
    const cmd = parse("EXTRACT \".title\"");
    try std.testing.expectEqualStrings(".title", cmd.extract);
}

test "parse EVAL single line" {
    const cmd = parse("EVAL \"document.title\"");
    try std.testing.expectEqualStrings("document.title", cmd.eval_js);
}

test "parse LOGIN" {
    try std.testing.expect(parse("LOGIN") == .login);
    try std.testing.expect(parse("login") == .login);
}

test "parse ACCEPT_COOKIES" {
    try std.testing.expect(parse("ACCEPT_COOKIES") == .accept_cookies);
    try std.testing.expect(parse("accept_cookies") == .accept_cookies);
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
    try std.testing.expect(parse("EXTRACT \".title\"").isRecorded());
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

    const e1 = iter.next().?;
    try std.testing.expectEqualStrings("https://example.com", e1.command.goto);
    try std.testing.expectEqual(@as(u32, 1), e1.line_num);

    const e2 = iter.next().?;
    try std.testing.expect(e2.command == .tree);

    const e3 = iter.next().?;
    try std.testing.expectEqualStrings("Login", e3.command.click);

    try std.testing.expect(iter.next() == null);
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

    const e1 = iter.next().?;
    try std.testing.expect(e1.command == .comment);

    const e2 = iter.next().?;
    try std.testing.expect(e2.command == .goto);

    const e3 = iter.next().?;
    try std.testing.expect(e3.command == .comment);

    const e4 = iter.next().?;
    try std.testing.expect(e4.command == .tree);

    try std.testing.expect(iter.next() == null);
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

    const e1 = iter.next().?;
    try std.testing.expect(e1.command == .goto);

    const e2 = iter.next().?;
    try std.testing.expect(e2.command == .eval_js);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.eval_js, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, e2.command.eval_js, "return x + y;") != null);
    defer std.testing.allocator.free(e2.command.eval_js);

    const e3 = iter.next().?;
    try std.testing.expect(e3.command == .tree);

    try std.testing.expect(iter.next() == null);
}

test "ScriptIterator unterminated EVAL" {
    const script =
        \\EVAL """
        \\  const x = 1;
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = iter.next().?;
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

    const e1 = iter.next().?;
    try std.testing.expect(e1.command == .eval_js);
    try std.testing.expectEqualStrings("console.log(\"x\")", e1.command.eval_js);

    const e2 = iter.next().?;
    try std.testing.expect(e2.command == .click);
    try std.testing.expectEqualStrings(".btn", e2.command.click);

    try std.testing.expect(iter.next() == null);
}

test "ScriptIterator multi-line EVAL mismatched triple quote" {
    const script =
        \\EVAL """
        \\  const s = " ''' ";
        \\  console.log(s);
        \\"""
    ;
    var iter: ScriptIterator = .init(std.testing.allocator, script);

    const e1 = iter.next().?;
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
        const cmd = Command{ .click = c.input };

        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try cmd.format(&aw.writer);
        try std.testing.expectEqualStrings(c.expected_line, aw.written());

        const round = parse(aw.written());
        try std.testing.expectEqualStrings(c.input, round.click);
    }
}

test "format TYPE with nested single quotes round-trip" {
    const cmd = Command{ .type_cmd = .{
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
    const cmd = Command{ .click = "a[x='y'][z=\"w\"]" };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    try std.testing.expectEqualStrings("CLICK '''a[x='y'][z=\"w\"]'''", aw.written());

    const round = parse(aw.written());
    try std.testing.expectEqualStrings("a[x='y'][z=\"w\"]", round.click);
}

test "format TYPE with both quote types round-trip" {
    const cmd = Command{ .type_cmd = .{
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

// --- Tool-call round-trip tests ---
//
// These lock the (Action ↔ Command) mapping table. If you add a new Command
// variant, extend both `toToolCall` and `fromToolCall` and add a case here.

fn expectRoundTrip(cmd: Command) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tc = toToolCall(a, cmd, noSubstitute) orelse return error.NoToolMapping;
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
    try std.testing.expect(toToolCall(a, .{ .extract = ".x" }, noSubstitute) == null);
    try std.testing.expect(toToolCall(a, .login, noSubstitute) == null);
    try std.testing.expect(toToolCall(a, .accept_cookies, noSubstitute) == null);
    try std.testing.expect(toToolCall(a, .comment, noSubstitute) == null);
    try std.testing.expect(toToolCall(a, .{ .natural_language = "hi" }, noSubstitute) == null);
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

    const upcase = struct {
        fn f(ar: std.mem.Allocator, input: []const u8) []const u8 {
            const out = ar.alloc(u8, input.len) catch return input;
            for (input, 0..) |c, i| out[i] = std.ascii.toUpper(c);
            return out;
        }
    }.f;

    const tc = toToolCall(a, .{ .click = "abc" }, upcase).?;
    try std.testing.expectEqualStrings("click", tc.name);
    try std.testing.expectEqualStrings("{\"selector\":\"ABC\"}", tc.args_json);
}

test "toToolCall: type_cmd value is NOT substituted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const upcase = struct {
        fn f(ar: std.mem.Allocator, input: []const u8) []const u8 {
            const out = ar.alloc(u8, input.len) catch return input;
            for (input, 0..) |c, i| out[i] = std.ascii.toUpper(c);
            return out;
        }
    }.f;

    const tc = toToolCall(a, .{ .type_cmd = .{ .selector = "abc", .value = "$LP_PASSWORD" } }, upcase).?;
    try std.testing.expectEqualStrings("fill", tc.name);
    // selector substituted, value preserved as $LP_* reference
    try std.testing.expectEqualStrings("{\"selector\":\"ABC\",\"value\":\"$LP_PASSWORD\"}", tc.args_json);
}

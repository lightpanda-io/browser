const std = @import("std");

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
    exit: void,
    comment: void,
    natural_language: []const u8,

    pub fn isRecorded(self: Command) bool {
        return switch (self) {
            .tree, .markdown, .comment, .exit => false,
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
    /// in dumb Pandascript-only mode (no `--provider`).
    pub fn needsLlm(self: Command) bool {
        return switch (self) {
            .login, .accept_cookies, .natural_language => true,
            else => false,
        };
    }

    /// Serializes back to Pandascript. Every string argument is wrapped in
    /// content-aware quotes so the output round-trips through `parse()` —
    /// single quotes by default, double quotes if the content contains `'`.
    ///
    /// The one case we do NOT round-trip cleanly is a string containing BOTH
    /// `'` and `"`. There's no escape syntax, so we fall back to `'…'` and
    /// the resulting line will be ambiguous when replayed. This is rare in
    /// practice (CSS selectors and form values almost never mix styles).
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
            .exit => try writer.writeAll("EXIT"),
            .comment => try writer.writeAll("#"),
            .natural_language => |text| try writer.writeAll(text),
        }
    }
};

/// Parse a line of REPL input into a Pandascript command.
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

    if (std.ascii.eqlIgnoreCase(cmd_word, "MARKDOWN") or std.ascii.eqlIgnoreCase(cmd_word, "MD")) {
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

    if (std.ascii.eqlIgnoreCase(cmd_word, "ACCEPT_COOKIES") or std.ascii.eqlIgnoreCase(cmd_word, "ACCEPT-COOKIES")) {
        return .{ .accept_cookies = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "EXIT") or std.ascii.eqlIgnoreCase(cmd_word, "QUIT")) {
        return .{ .exit = {} };
    }

    return .{ .natural_language = trimmed };
}

/// Iterator for parsing a script file, handling multi-line EVAL """ ... """ blocks.
pub const ScriptIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_num: u32,
    allocator: std.mem.Allocator,

    pub fn init(content: []const u8, allocator: std.mem.Allocator) ScriptIterator {
        return .{
            .lines = std.mem.splitScalar(u8, content, '\n'),
            .line_num = 0,
            .allocator = allocator,
        };
    }

    pub const Entry = struct {
        line_num: u32,
        raw_line: []const u8,
        command: Command,
    };

    /// Returns the next command from the script, or null at EOF.
    /// Multi-line EVAL blocks are assembled into a single eval_js command.
    pub fn next(self: *ScriptIterator) ?Entry {
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            if (isEvalTripleQuote(trimmed)) |quote_type| {
                const start_line = self.line_num;
                if (self.collectEvalBlock(quote_type)) |js| {
                    return .{
                        .line_num = start_line,
                        .raw_line = trimmed,
                        .command = .{ .eval_js = js },
                    };
                } else {
                    return .{
                        .line_num = start_line,
                        .raw_line = trimmed,
                        .command = .{ .natural_language = "unterminated EVAL block" },
                    };
                }
            }

            return .{
                .line_num = self.line_num,
                .raw_line = trimmed,
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
        if (std.mem.startsWith(u8, rest, "\"\"\"")) return "\"\"\"";
        if (std.mem.startsWith(u8, rest, "'''")) return "'''";
        return null;
    }

    /// Collect lines until matching closing triple quote, return the JS content.
    fn collectEvalBlock(self: *ScriptIterator, quote_type: []const u8) ?[]const u8 {
        var parts: std.ArrayListUnmanaged(u8) = .empty;
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

fn extractQuotedWithRemainder(s: []const u8) ?QuotedResult {
    if (s.len < 2) return null;
    const q = s[0];
    if (q != '"' and q != '\'') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, q) orelse return null;
    return .{
        .value = s[1..end],
        .remainder = s[end + 1 ..],
    };
}

/// Extract a single string argument from `s`:
///   - strip one layer of matching outer `'…'` or `"…"` if present
///   - return `s` unchanged if unquoted
///   - return null if empty, malformed (starts with quote, no matching close),
///     or stripped to empty (`''` / `""`)
fn trimMatchingQuotes(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
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
///   - fall back to `"…"` if the content contains `'` but not `"`
///   - if it contains both, emit `'…'` anyway (ambiguous — see format docs)
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const has_single = std.mem.indexOfScalar(u8, self.s, '\'') != null;
        const q: u8 = if (has_single and std.mem.indexOfScalar(u8, self.s, '"') == null) '"' else '\'';
        try writer.writeByte(q);
        try writer.writeAll(self.s);
        try writer.writeByte(q);
    }
};

fn quote(s: []const u8) Quoted {
    return .{ .s = s };
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

test "parse MARKDOWN alias MD" {
    try std.testing.expect(parse("MARKDOWN") == .markdown);
    try std.testing.expect(parse("md") == .markdown);
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
    try std.testing.expect(parse("ACCEPT-COOKIES") == .accept_cookies);
}

test "parse EXIT" {
    try std.testing.expect(parse("EXIT") == .exit);
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
    try std.testing.expect(!parse("md").isRecorded());
}

test "ScriptIterator basic commands" {
    const script =
        \\GOTO https://example.com
        \\TREE
        \\CLICK "Login"
    ;
    var iter = ScriptIterator.init(script, std.testing.allocator);

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
    var iter = ScriptIterator.init(script, std.testing.allocator);

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
    var iter = ScriptIterator.init(script, std.testing.allocator);

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
    var iter = ScriptIterator.init(script, std.testing.allocator);

    const e1 = iter.next().?;
    try std.testing.expect(e1.command == .natural_language);
    try std.testing.expectEqualStrings("unterminated EVAL block", e1.command.natural_language);
}

test "ScriptIterator multi-line EVAL mismatched triple quote" {
    const script =
        \\EVAL """
        \\  const s = " ''' ";
        \\  console.log(s);
        \\"""
    ;
    var iter: ScriptIterator = .init(script, std.testing.allocator);

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
        // Never recurse — only one layer is stripped.
        .{ .in = "'''a'''", .out = "''a''" },
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

test "format with both quote types falls back to single quotes" {
    const cmd = Command{ .click = "a[x='y'][z=\"w\"]" };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try cmd.format(&aw.writer);
    // Fallback — output is ambiguous on parse, but the format is pinned.
    try std.testing.expectEqualStrings("CLICK 'a[x='y'][z=\"w\"]'", aw.written());
}

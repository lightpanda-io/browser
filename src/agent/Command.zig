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

    pub fn format(self: Command, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .goto => |url| try writer.print("GOTO {s}", .{url}),
            .click => |sel| try writer.print("CLICK '{s}'", .{sel}),
            .type_cmd => |args| try writer.print("TYPE '{s}' '{s}'", .{ args.selector, args.value }),
            .wait => |sel| try writer.print("WAIT '{s}'", .{sel}),
            .scroll => |args| try writer.print("SCROLL {d} {d}", .{ args.x, args.y }),
            .hover => |sel| try writer.print("HOVER '{s}'", .{sel}),
            .select => |args| try writer.print("SELECT '{s}' '{s}'", .{ args.selector, args.value }),
            .check => |args| if (args.checked)
                try writer.print("CHECK '{s}'", .{args.selector})
            else
                try writer.print("CHECK '{s}' false", .{args.selector}),
            .tree => try writer.writeAll("TREE"),
            .markdown => try writer.writeAll("MARKDOWN"),
            .extract => |selector| try writer.print("EXTRACT '{s}'", .{selector}),
            .eval_js => |script| {
                if (std.mem.indexOfScalar(u8, script, '\n') != null) {
                    try writer.print("EVAL '''\n{s}\n'''", .{script});
                } else {
                    try writer.print("EVAL '{s}'", .{script});
                }
            },
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
        const arg = extractQuoted(rest) orelse rest;
        if (arg.len == 0) return .{ .natural_language = trimmed };
        return .{ .click = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "TYPE")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = extractQuoted(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .type_cmd = .{ .selector = first.value, .value = second } };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "WAIT")) {
        const arg = extractQuoted(rest) orelse rest;
        if (arg.len == 0) return .{ .natural_language = trimmed };
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
        const arg = extractQuoted(rest) orelse rest;
        if (arg.len == 0) return .{ .natural_language = trimmed };
        return .{ .hover = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "SELECT")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = extractQuoted(second_arg) orelse return .{ .natural_language = trimmed };
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
        if (rest.len == 0) return .{ .natural_language = trimmed };
        const selector = extractQuoted(rest) orelse rest;
        return .{ .extract = selector };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "EVAL")) {
        if (rest.len == 0) return .{ .natural_language = trimmed };
        const arg = extractQuoted(rest) orelse rest;
        return .{ .eval_js = arg };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "LOGIN")) {
        return .{ .login = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "ACCEPT_COOKIES") or std.ascii.eqlIgnoreCase(cmd_word, "ACCEPT-COOKIES")) {
        return .{ .accept_cookies = {} };
    }

    if (std.ascii.eqlIgnoreCase(cmd_word, "EXIT")) {
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

            if (isEvalTripleQuote(trimmed)) {
                const start_line = self.line_num;
                if (self.collectEvalBlock()) |js| {
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

    fn isEvalTripleQuote(line: []const u8) bool {
        const cmd_end = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse line.len;
        const cmd_word = line[0..cmd_end];
        if (!std.ascii.eqlIgnoreCase(cmd_word, "EVAL")) return false;
        const rest = std.mem.trim(u8, line[cmd_end..], &std.ascii.whitespace);
        return std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''");
    }

    /// Collect lines until closing triple quote (""" or '''), return the JS content.
    fn collectEvalBlock(self: *ScriptIterator) ?[]const u8 {
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, "\"\"\"") or std.mem.eql(u8, trimmed, "'''")) {
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
    const quote = s[0];
    if (quote != '"' and quote != '\'') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, quote) orelse return null;
    return .{
        .value = s[1..end],
        .remainder = s[end + 1 ..],
    };
}

fn extractQuoted(s: []const u8) ?[]const u8 {
    const result = extractQuotedWithRemainder(s) orelse return null;
    return result.value;
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

test "parse TYPE missing second arg" {
    const cmd = parse("TYPE \"#email\"");
    try std.testing.expect(cmd == .natural_language);
}

test "parse WAIT" {
    const cmd = parse("WAIT \".dashboard\"");
    try std.testing.expectEqualStrings(".dashboard", cmd.wait);
}

test "parse SCROLL bare" {
    const cmd = parse("SCROLL");
    try std.testing.expectEqual(@as(i32, 0), cmd.scroll.x);
    try std.testing.expectEqual(@as(i32, 0), cmd.scroll.y);
}

test "parse SCROLL single arg is y" {
    const cmd = parse("SCROLL 500");
    try std.testing.expectEqual(@as(i32, 0), cmd.scroll.x);
    try std.testing.expectEqual(@as(i32, 500), cmd.scroll.y);
}

test "parse SCROLL two args" {
    const cmd = parse("SCROLL 100 200");
    try std.testing.expectEqual(@as(i32, 100), cmd.scroll.x);
    try std.testing.expectEqual(@as(i32, 200), cmd.scroll.y);
}

test "parse SCROLL invalid falls through" {
    const cmd = parse("SCROLL down");
    try std.testing.expect(cmd == .natural_language);
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

test "parse CHECK default true" {
    const cmd = parse("CHECK '#agree'");
    try std.testing.expectEqualStrings("#agree", cmd.check.selector);
    try std.testing.expectEqual(true, cmd.check.checked);
}

test "parse CHECK explicit true" {
    const cmd = parse("CHECK '#agree' true");
    try std.testing.expectEqual(true, cmd.check.checked);
}

test "parse CHECK explicit false" {
    const cmd = parse("CHECK '#newsletter' false");
    try std.testing.expectEqualStrings("#newsletter", cmd.check.selector);
    try std.testing.expectEqual(false, cmd.check.checked);
}

test "parse CHECK invalid bool falls through" {
    const cmd = parse("CHECK '#x' maybe");
    try std.testing.expect(cmd == .natural_language);
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

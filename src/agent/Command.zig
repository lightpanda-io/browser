const std = @import("std");

pub const TypeArgs = struct {
    selector: []const u8,
    value: []const u8,
};

pub const ExtractArgs = struct {
    selector: []const u8,
    file: ?[]const u8,
};

pub const Command = union(enum) {
    goto: []const u8,
    click: []const u8,
    type_cmd: TypeArgs,
    wait: []const u8,
    tree: void,
    markdown: void,
    extract: ExtractArgs,
    eval_js: []const u8,
    login: void,
    accept_cookies: void,
    exit: void,
    comment: void,
    natural_language: []const u8,
};

/// Parse a line of REPL input into a Pandascript command.
/// Unrecognized input is returned as `.natural_language`.
/// For multi-line EVAL blocks in scripts, use `ScriptParser`.
pub fn parse(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .natural_language = trimmed };

    // Skip comment lines
    if (trimmed[0] == '#') return .{ .comment = {} };

    // Find the command word (first whitespace-delimited token)
    const cmd_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    const cmd_word = trimmed[0..cmd_end];
    const rest = std.mem.trim(u8, trimmed[cmd_end..], &std.ascii.whitespace);

    if (eqlIgnoreCase(cmd_word, "GOTO")) {
        if (rest.len == 0) return .{ .natural_language = trimmed };
        return .{ .goto = rest };
    }

    if (eqlIgnoreCase(cmd_word, "CLICK")) {
        const arg = extractQuoted(rest) orelse rest;
        if (arg.len == 0) return .{ .natural_language = trimmed };
        return .{ .click = arg };
    }

    if (eqlIgnoreCase(cmd_word, "TYPE")) {
        const first = extractQuotedWithRemainder(rest) orelse return .{ .natural_language = trimmed };
        const second_arg = std.mem.trim(u8, first.remainder, &std.ascii.whitespace);
        const second = extractQuoted(second_arg) orelse return .{ .natural_language = trimmed };
        return .{ .type_cmd = .{ .selector = first.value, .value = second } };
    }

    if (eqlIgnoreCase(cmd_word, "WAIT")) {
        const arg = extractQuoted(rest) orelse rest;
        if (arg.len == 0) return .{ .natural_language = trimmed };
        return .{ .wait = arg };
    }

    if (eqlIgnoreCase(cmd_word, "TREE")) {
        return .{ .tree = {} };
    }

    if (eqlIgnoreCase(cmd_word, "MARKDOWN") or eqlIgnoreCase(cmd_word, "MD")) {
        return .{ .markdown = {} };
    }

    if (eqlIgnoreCase(cmd_word, "EXTRACT")) {
        const selector = extractQuoted(rest) orelse {
            if (rest.len == 0) return .{ .natural_language = trimmed };
            return .{ .extract = .{ .selector = rest, .file = null } };
        };
        // Look for > filename after the quoted selector
        const after_quote = extractQuotedWithRemainder(rest) orelse return .{ .extract = .{ .selector = selector, .file = null } };
        const after = std.mem.trim(u8, after_quote.remainder, &std.ascii.whitespace);
        if (after.len > 0 and after[0] == '>') {
            const file = std.mem.trim(u8, after[1..], &std.ascii.whitespace);
            return .{ .extract = .{ .selector = selector, .file = if (file.len > 0) file else null } };
        }
        return .{ .extract = .{ .selector = selector, .file = null } };
    }

    if (eqlIgnoreCase(cmd_word, "EVAL")) {
        if (rest.len == 0) return .{ .natural_language = trimmed };
        const arg = extractQuoted(rest) orelse rest;
        return .{ .eval_js = arg };
    }

    if (eqlIgnoreCase(cmd_word, "LOGIN")) {
        return .{ .login = {} };
    }

    if (eqlIgnoreCase(cmd_word, "ACCEPT_COOKIES") or eqlIgnoreCase(cmd_word, "ACCEPT-COOKIES")) {
        return .{ .accept_cookies = {} };
    }

    if (eqlIgnoreCase(cmd_word, "EXIT")) {
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

            // Check for EVAL """ multi-line block
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
        if (!eqlIgnoreCase(cmd_word, "EVAL")) return false;
        const rest = std.mem.trim(u8, line[cmd_end..], &std.ascii.whitespace);
        return std.mem.startsWith(u8, rest, "\"\"\"");
    }

    /// Collect lines until closing """, return the JS content.
    fn collectEvalBlock(self: *ScriptIterator) ?[]const u8 {
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        while (self.lines.next()) |line| {
            self.line_num += 1;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, "\"\"\"")) {
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
    if (s.len < 2 or s[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse return null;
    return .{
        .value = s[1..end],
        .remainder = s[end + 1 ..],
    };
}

fn extractQuoted(s: []const u8) ?[]const u8 {
    const result = extractQuotedWithRemainder(s) orelse return null;
    return result.value;
}

pub fn eqlIgnoreCase(a: []const u8, comptime upper: []const u8) bool {
    if (a.len != upper.len) return false;
    for (a, upper) |ac, uc| {
        if (std.ascii.toUpper(ac) != uc) return false;
    }
    return true;
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

test "parse TYPE missing second arg" {
    const cmd = parse("TYPE \"#email\"");
    try std.testing.expect(cmd == .natural_language);
}

test "parse WAIT" {
    const cmd = parse("WAIT \".dashboard\"");
    try std.testing.expectEqualStrings(".dashboard", cmd.wait);
}

test "parse TREE" {
    const cmd = parse("TREE");
    try std.testing.expect(cmd == .tree);
}

test "parse MARKDOWN alias MD" {
    try std.testing.expect(parse("MARKDOWN") == .markdown);
    try std.testing.expect(parse("md") == .markdown);
}

test "parse EXTRACT with file" {
    const cmd = parse("EXTRACT \".title\" > titles.json");
    try std.testing.expectEqualStrings(".title", cmd.extract.selector);
    try std.testing.expectEqualStrings("titles.json", cmd.extract.file.?);
}

test "parse EXTRACT without file" {
    const cmd = parse("EXTRACT \".title\"");
    try std.testing.expectEqualStrings(".title", cmd.extract.selector);
    try std.testing.expect(cmd.extract.file == null);
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

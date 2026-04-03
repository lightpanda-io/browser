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
    extract: ExtractArgs,
    eval_js: []const u8,
    exit: void,
    natural_language: []const u8,
};

/// Parse a line of REPL input into a Pandascript command.
/// Unrecognized input is returned as `.natural_language`.
pub fn parse(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .natural_language = trimmed };

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

    if (eqlIgnoreCase(cmd_word, "EXIT")) {
        return .{ .exit = {} };
    }

    return .{ .natural_language = trimmed };
}

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

fn eqlIgnoreCase(a: []const u8, comptime upper: []const u8) bool {
    if (a.len != upper.len) return false;
    for (a, upper) |ac, uc| {
        if (std.ascii.toUpper(ac) != uc) return false;
    }
    return true;
}

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const c = @cImport({
    @cInclude("linenoise.h");
});

const Self = @This();

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_cyan = "\x1b[36m";
const ansi_green = "\x1b[32m";
const ansi_red = "\x1b[31m";

history_path: ?[:0]const u8,

const CommandInfo = struct { name: [:0]const u8, hint: [:0]const u8 };

const commands = [_]CommandInfo{
    .{ .name = "GOTO", .hint = " <url>" },
    .{ .name = "CLICK", .hint = " '<selector>'" },
    .{ .name = "TYPE", .hint = " '<selector>' '<value>'" },
    .{ .name = "WAIT", .hint = " '<selector>'" },
    .{ .name = "SCROLL", .hint = " [x] [y]" },
    .{ .name = "HOVER", .hint = " '<selector>'" },
    .{ .name = "SELECT", .hint = " '<selector>' '<value>'" },
    .{ .name = "CHECK", .hint = " '<selector>' [true|false]" },
    .{ .name = "TREE", .hint = "" },
    .{ .name = "MARKDOWN", .hint = "" },
    .{ .name = "EXTRACT", .hint = " '<selector>'" },
    .{ .name = "EVAL", .hint = " '<script>'" },
    .{ .name = "LOGIN", .hint = "" },
    .{ .name = "ACCEPT_COOKIES", .hint = "" },
};

// Meta slash commands handled directly by the agent (not by ToolExecutor).
// Kept in sync with `handleSlash` in `Agent.zig`.
const meta_slash_commands = [_][:0]const u8{ "help", "quit" };

pub fn init(history_path: ?[:0]const u8) Self {
    c.linenoiseSetMultiLine(1);
    c.linenoiseSetCompletionCallback(&completionCallback);
    c.linenoiseSetHintsCallback(&hintsCallback);
    if (history_path) |path| {
        _ = c.linenoiseHistoryLoad(path.ptr);
    }
    return .{ .history_path = history_path };
}

fn addSlashCompletion(lc: [*c]c.linenoiseCompletions, name_buf: *[64:0]u8, name: []const u8, partial: []const u8) void {
    const total = 1 + name.len;
    if (total >= name_buf.len) return;
    if (name.len < partial.len) return;
    if (!std.ascii.eqlIgnoreCase(name[0..partial.len], partial)) return;
    name_buf[0] = '/';
    @memcpy(name_buf[1..total], name);
    name_buf[total] = 0;
    c.linenoiseAddCompletion(lc, name_buf);
}

fn slashHint(name: []const u8, partial: []const u8) ?[]const u8 {
    if (name.len <= partial.len) return null;
    if (!std.ascii.eqlIgnoreCase(name[0..partial.len], partial)) return null;
    return name[partial.len..];
}

fn completionCallback(buf: [*c]const u8, lc: [*c]c.linenoiseCompletions) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);

    if (input.len > 0 and std.mem.indexOfScalar(u8, input, ' ') == null) {
        if (input[0] == '/') {
            const partial = input[1..];
            // linenoise strdup's the string, so a stack buffer reused per match
            // is fine. 64 covers every name comfortably.
            var name_buf: [64:0]u8 = undefined;
            for (browser_tools.tool_defs) |td| addSlashCompletion(lc, &name_buf, td.name, partial);
            for (meta_slash_commands) |name| addSlashCompletion(lc, &name_buf, name, partial);
        } else {
            for (commands) |cmd| {
                if (cmd.name.len >= input.len and std.ascii.eqlIgnoreCase(cmd.name[0..input.len], input)) {
                    c.linenoiseAddCompletion(lc, cmd.name.ptr);
                }
            }
        }
    }

    // If we found nothing, register the input itself so linenoise enters
    // completion mode anyway. Otherwise it returns the Tab keypress to its
    // edit loop, which inserts '\t' into the buffer and corrupts the line.
    if (lc.*.len == 0) {
        c.linenoiseAddCompletion(lc, buf);
    }
}

// File-scope so the pointer survives the callback's stack frame; linenoise
// reads the returned hint in refreshShowHints() *after* this function has
// already returned, so a stack-local buffer would be UB.
var hint_buf: [64:0]u8 = undefined;

fn hintsCallback(buf: [*c]const u8, color: [*c]c_int, bold: [*c]c_int) callconv(.c) [*c]u8 {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
    if (input.len == 0) return null;
    if (std.mem.indexOfScalar(u8, input, ' ') != null) return null;

    color.* = 90;
    bold.* = 0;

    if (input[0] == '/') {
        const partial = input[1..];
        const suffix = blk: {
            for (browser_tools.tool_defs) |td| {
                if (slashHint(td.name, partial)) |s| break :blk s;
            }
            for (meta_slash_commands) |name| {
                if (slashHint(name, partial)) |s| break :blk s;
            }
            return null;
        };
        if (suffix.len + 1 > hint_buf.len) return null;
        @memcpy(hint_buf[0..suffix.len], suffix);
        hint_buf[suffix.len] = 0;
        return @ptrCast(&hint_buf);
    }

    for (commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(cmd.name, input)) {
            if (cmd.hint.len == 0) return null;
            return @ptrCast(@constCast(cmd.hint.ptr));
        }
        if (cmd.name.len > input.len and std.ascii.eqlIgnoreCase(cmd.name[0..input.len], input)) {
            return @ptrCast(@constCast(cmd.name.ptr + input.len));
        }
    }
    return null;
}

pub fn readLine(self: *Self, prompt: [*:0]const u8) ?[]const u8 {
    const line = c.linenoise(prompt) orelse return null;
    const slice = std.mem.sliceTo(line, 0);
    if (slice.len > 0) {
        _ = c.linenoiseHistoryAdd(line);
        if (self.history_path) |path| {
            _ = c.linenoiseHistorySave(path.ptr);
        }
    }
    return slice;
}

pub fn freeLine(_: *Self, line: []const u8) void {
    c.linenoiseFree(@ptrCast(@constCast(line.ptr)));
}

pub fn printAssistant(_: *Self, text: []const u8) void {
    const fd = std.posix.STDOUT_FILENO;
    _ = std.posix.write(fd, text) catch {};
    _ = std.posix.write(fd, "\n") catch {};
}

/// Print the result of an action command (GOTO, CLICK, ...) to stderr so
/// stdout stays reserved for data-producing commands.
pub fn printActionResult(_: *Self, text: []const u8) void {
    std.debug.print("{s}\n", .{text});
}

pub fn printToolCall(_: *Self, name: []const u8, args: []const u8) void {
    std.debug.print("\n{s}{s}[tool: {s}]{s} {s}\n", .{ ansi_dim, ansi_cyan, name, ansi_reset, args });
}

// 2000 keeps stderr readable while exposing the full window the LLM-judge
// actually consumes (SNAPSHOT_MAX_CHARS=900 in benchmarks/llm_judge.py); the
// 500 cap was the binding upstream limit and silently starved the judge of
// grounding evidence on tasks where the agent had observed the answer.
// Does NOT affect the agent's own LLM, which gets up to tool_output_max_bytes
// (1 MiB) via Agent.zig:capToolOutput.
const max_result_display_len = 2000;

pub fn printToolResult(_: *Self, name: []const u8, result: []const u8) void {
    const truncated = result[0..@min(result.len, max_result_display_len)];
    const ellipsis: []const u8 = if (result.len > max_result_display_len) "..." else "";
    std.debug.print("{s}{s}[result: {s}]{s} {s}{s}\n", .{ ansi_dim, ansi_green, name, ansi_reset, truncated, ellipsis });
}

pub fn printError(_: *Self, msg: []const u8) void {
    std.debug.print("{s}{s}Error: {s}{s}\n", .{ ansi_bold, ansi_red, msg, ansi_reset });
}

pub fn printErrorFmt(_: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}{s}Error: " ++ fmt ++ "{s}\n", .{ ansi_bold, ansi_red } ++ args ++ .{ansi_reset});
}

pub fn printInfo(_: *Self, msg: []const u8) void {
    std.debug.print("{s}{s}{s}\n", .{ ansi_dim, msg, ansi_reset });
}

pub fn printInfoFmt(_: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}" ++ fmt ++ "{s}\n", .{ansi_dim} ++ args ++ .{ansi_reset});
}

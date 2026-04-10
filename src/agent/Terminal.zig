const std = @import("std");
const c = @cImport({
    @cInclude("linenoise.h");
});

const Self = @This();

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_cyan = "\x1b[36m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";
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
    .{ .name = "MD", .hint = "" },
    .{ .name = "EXTRACT", .hint = " '<selector>'" },
    .{ .name = "EVAL", .hint = " '<script>'" },
    .{ .name = "LOGIN", .hint = "" },
    .{ .name = "ACCEPT_COOKIES", .hint = "" },
    .{ .name = "EXIT", .hint = "" },
};

pub fn init(history_path: ?[:0]const u8) Self {
    c.linenoiseSetMultiLine(1);
    c.linenoiseSetCompletionCallback(&completionCallback);
    c.linenoiseSetHintsCallback(&hintsCallback);
    if (history_path) |path| {
        _ = c.linenoiseHistoryLoad(path.ptr);
    }
    return .{ .history_path = history_path };
}

fn completionCallback(buf: [*c]const u8, lc: [*c]c.linenoiseCompletions) callconv(.c) void {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
    if (input.len == 0) return;
    if (std.mem.indexOfScalar(u8, input, ' ') != null) return;
    for (commands) |cmd| {
        if (cmd.name.len >= input.len and std.ascii.eqlIgnoreCase(cmd.name[0..input.len], input)) {
            c.linenoiseAddCompletion(lc, cmd.name.ptr);
        }
    }
}

fn hintsCallback(buf: [*c]const u8, color: [*c]c_int, bold: [*c]c_int) callconv(.c) [*c]u8 {
    const input = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
    if (input.len == 0) return null;
    if (std.mem.indexOfScalar(u8, input, ' ') != null) return null;
    for (commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(cmd.name, input) and cmd.hint.len > 0) {
            color.* = 90;
            bold.* = 0;
            return @ptrCast(@constCast(cmd.hint.ptr));
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

const max_result_display_len = 500;

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

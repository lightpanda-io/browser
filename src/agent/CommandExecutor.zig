const std = @import("std");
const browser_tools = @import("lightpanda").tools;
const Command = @import("Command.zig");
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");

const Self = @This();

tool_executor: *ToolExecutor,
terminal: *Terminal,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, tool_executor: *ToolExecutor, terminal: *Terminal) Self {
    return .{
        .allocator = allocator,
        .tool_executor = tool_executor,
        .terminal = terminal,
    };
}

pub const ExecResult = struct {
    output: []const u8,
    failed: bool,
};

/// Execute a command and return the result with success/failure status.
pub fn executeWithResult(self: *Self, a: std.mem.Allocator, cmd: Command.Command) ExecResult {
    return switch (cmd) {
        .goto => |url| self.execGoto(a, url),
        .click => |sel| self.callTool(a, "click", buildJson(a, .{ .selector = substituteEnvVars(a, sel) })),
        .type_cmd => |args| self.execType(a, args),
        .wait => |selector| self.callTool(a, "waitForSelector", buildJson(a, .{ .selector = selector })),
        .scroll => |args| self.callTool(a, "scroll", buildJson(a, .{ .x = args.x, .y = args.y })),
        .hover => |sel| self.callTool(a, "hover", buildJson(a, .{ .selector = substituteEnvVars(a, sel) })),
        .select => |args| self.callTool(a, "selectOption", buildJson(a, .{
            .selector = substituteEnvVars(a, args.selector),
            .value = substituteEnvVars(a, args.value),
        })),
        .check => |args| self.callTool(a, "setChecked", buildJson(a, .{
            .selector = substituteEnvVars(a, args.selector),
            .checked = args.checked,
        })),
        .tree => self.callTool(a, "semanticTree", ""),
        .markdown => self.callTool(a, "markdown", ""),
        .extract => |args| self.execExtract(a, args),
        .eval_js => |script| self.callTool(a, "eval", buildJson(a, .{ .script = script })),
        .exit, .natural_language, .comment, .login, .accept_cookies => unreachable,
    };
}

pub fn execute(self: *Self, cmd: Command.Command) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const result = self.executeWithResult(arena.allocator(), cmd);

    self.terminal.printAssistant(result.output);
    std.debug.print("\n", .{});
}

fn callTool(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) ExecResult {
    if (self.tool_executor.call(arena, tool_name, arguments_json)) |output|
        return .{ .output = output, .failed = false }
    else |err|
        return .{ .output = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tool_name, @errorName(err) }) catch "tool failed", .failed = true };
}

fn execGoto(self: *Self, arena: std.mem.Allocator, raw_url: []const u8) ExecResult {
    const url = substituteEnvVars(arena, raw_url);
    return self.callTool(arena, "goto", buildJson(arena, .{ .url = url }));
}

fn execType(self: *Self, arena: std.mem.Allocator, args: Command.TypeArgs) ExecResult {
    const selector = substituteEnvVars(arena, args.selector);
    const value = substituteEnvVars(arena, args.value);
    return self.callTool(arena, "fill", buildJson(arena, .{ .selector = selector, .value = value }));
}

fn execExtract(self: *Self, arena: std.mem.Allocator, args: Command.ExtractArgs) ExecResult {
    const selector = escapeJs(arena, substituteEnvVars(arena, args.selector));

    const script = std.fmt.allocPrint(arena,
        \\JSON.stringify(Array.from(document.querySelectorAll("{s}")).map(el => el.textContent.trim()))
    , .{selector}) catch return .{ .output = "failed to build extract script", .failed = true };

    const result = self.tool_executor.call(arena, "eval", buildJson(arena, .{ .script = script })) catch
        return .{ .output = "extract failed", .failed = true };

    if (args.file) |raw_file| {
        const file = sanitizePath(raw_file) orelse {
            self.terminal.printError("Invalid output path: must be relative and not traverse above working directory");
            return .{ .output = result, .failed = false };
        };
        std.fs.cwd().writeFile(.{
            .sub_path = file,
            .data = result,
        }) catch {
            self.terminal.printError("Failed to write to file");
            return .{ .output = result, .failed = false };
        };
        const msg = std.fmt.allocPrint(arena, "Extracted to {s}", .{file}) catch "Extracted.";
        return .{ .output = msg, .failed = false };
    }

    return .{ .output = result, .failed = false };
}

const substituteEnvVars = browser_tools.substituteEnvVars;

/// Escape a string for safe interpolation inside a JS double-quoted string literal.
fn escapeJs(arena: std.mem.Allocator, input: []const u8) []const u8 {
    // Quick scan: if nothing to escape, return as-is
    const needs_escape = for (input) |ch| {
        if (ch == '"' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') break true;
    } else false;
    if (!needs_escape) return input;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (input) |ch| {
        switch (ch) {
            '\\' => out.appendSlice(arena, "\\\\") catch return input,
            '"' => out.appendSlice(arena, "\\\"") catch return input,
            '\n' => out.appendSlice(arena, "\\n") catch return input,
            '\r' => out.appendSlice(arena, "\\r") catch return input,
            '\t' => out.appendSlice(arena, "\\t") catch return input,
            else => out.append(arena, ch) catch return input,
        }
    }
    return out.toOwnedSlice(arena) catch input;
}

/// Validate that a file path is safe: relative, no traversal above cwd.
fn sanitizePath(path: []const u8) ?[]const u8 {
    // Reject absolute paths
    if (path.len > 0 and path[0] == '/') return null;

    // Reject paths containing ".." components
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }

    return path;
}

fn buildJson(arena: std.mem.Allocator, value: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return "{}";
    return aw.written();
}

// --- Tests ---

test "escapeJs no escaping needed" {
    const result = escapeJs(std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "escapeJs quotes and backslashes" {
    const result = escapeJs(std.testing.allocator, "say \"hello\\world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hello\\\\world\\\"", result);
}

test "escapeJs newlines and tabs" {
    const result = escapeJs(std.testing.allocator, "line1\nline2\ttab");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", result);
}

test "escapeJs injection attempt" {
    const result = escapeJs(std.testing.allocator, "\"; alert(1); //");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\\\"; alert(1); //", result);
}

test "sanitizePath allows relative" {
    try std.testing.expectEqualStrings("output.json", sanitizePath("output.json").?);
    try std.testing.expectEqualStrings("dir/file.json", sanitizePath("dir/file.json").?);
}

test "sanitizePath rejects absolute" {
    try std.testing.expect(sanitizePath("/etc/passwd") == null);
}

test "sanitizePath rejects traversal" {
    try std.testing.expect(sanitizePath("../../../etc/passwd") == null);
    try std.testing.expect(sanitizePath("foo/../../bar") == null);
}

test "substituteEnvVars no vars" {
    const result = substituteEnvVars(std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "substituteEnvVars with HOME" {
    // Use arena since substituteEnvVars makes intermediate allocations (dupeZ)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = substituteEnvVars(a, "dir=$HOME/test");
    // Result should not contain $HOME literally (it got substituted)
    try std.testing.expect(std.mem.indexOf(u8, result, "$HOME") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/test") != null);
}

test "substituteEnvVars missing var kept literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = substituteEnvVars(arena.allocator(), "$UNLIKELY_VAR_12345");
    try std.testing.expectEqualStrings("$UNLIKELY_VAR_12345", result);
}

test "substituteEnvVars bare dollar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = substituteEnvVars(arena.allocator(), "price is $ 5");
    try std.testing.expectEqualStrings("price is $ 5", result);
}

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

pub fn executeWithResult(self: *Self, a: std.mem.Allocator, cmd: Command.Command) ExecResult {
    // EXTRACT has no 1:1 tool mapping — it compiles to a custom `eval` script.
    if (cmd == .extract) return self.execExtract(a, cmd.extract);

    const tc = Command.toToolCall(a, cmd, browser_tools.substituteEnvVars) orelse switch (cmd) {
        .exit, .natural_language, .comment, .login, .accept_cookies => unreachable,
        else => return .{ .output = "command has no tool mapping", .failed = true },
    };
    return self.callTool(a, tc.name, tc.args_json);
}

pub fn execute(self: *Self, cmd: Command.Command) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const result = self.executeWithResult(arena.allocator(), cmd);
    self.printResult(cmd, result);
}

/// Data-producing commands (EXTRACT/EVAL/MARKDOWN/TREE) go to stdout so shell
/// redirection captures only their output; action commands go to stderr.
pub fn printResult(self: *Self, cmd: Command.Command, result: ExecResult) void {
    if (cmd.producesData()) {
        self.terminal.printAssistant(result.output);
    } else {
        self.terminal.printActionResult(result.output);
    }
}

fn callTool(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) ExecResult {
    if (self.tool_executor.call(arena, tool_name, arguments_json)) |output|
        return .{ .output = output, .failed = false }
    else |err|
        return .{ .output = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tool_name, @errorName(err) }) catch "tool failed", .failed = true };
}

fn execExtract(self: *Self, arena: std.mem.Allocator, raw_selector: []const u8) ExecResult {
    const selector = browser_tools.substituteEnvVars(arena, raw_selector);

    // `std.json.Stringify.value` emits a quoted, JS-safe string literal, which
    // is also a valid JS string literal — reuse it to splice the selector into
    // the querySelectorAll call.
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(selector, .{}, &aw.writer) catch
        return .{ .output = "failed to encode selector", .failed = true };

    const script = std.fmt.allocPrint(
        arena,
        "JSON.stringify(Array.from(document.querySelectorAll({s})).map(el => el.textContent.trim()))",
        .{aw.written()},
    ) catch return .{ .output = "failed to build extract script", .failed = true };

    const tc = Command.toToolCall(arena, .{ .eval_js = script }, Command.noSubstitute) orelse unreachable;
    return self.callTool(arena, tc.name, tc.args_json);
}

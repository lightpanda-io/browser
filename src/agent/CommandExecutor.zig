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

/// Caller contract: `cmd` must not be `.natural_language`, `.comment`,
/// `.login`, or `.accept_cookies` — those are filtered upstream (see
/// `Agent.runRepl`) because they have no tool mapping and would hit the
/// `unreachable` arm below.
pub fn executeWithResult(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) ExecResult {
    if (cmd == .extract) return self.execExtract(arena, cmd.extract);

    const tc = Command.toToolCall(arena, cmd, browser_tools.substituteEnvVars) orelse switch (cmd) {
        .natural_language, .comment, .login, .accept_cookies => unreachable,
        else => return .{ .output = "command has no tool mapping", .failed = true },
    };
    return self.callTool(arena, tc.name, tc.args_json);
}

pub fn execute(self: *Self, cmd: Command.Command) void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
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

    const script = std.fmt.allocPrint(
        arena,
        "JSON.stringify(Array.from(document.querySelectorAll({s})).map(el => el.textContent.trim()))",
        .{Command.stringifyJson(arena, selector)},
    ) catch return .{ .output = "failed to build extract script", .failed = true };

    const result = self.tool_executor.callEval(arena, script);
    return .{ .output = result.text, .failed = result.is_error };
}

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Command = lp.script.Command;
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

    const tcv = Command.toToolCallValue(arena, cmd, browser_tools.substituteEnvVars) orelse unreachable;
    if (self.tool_executor.callValue(arena, tcv.name, tcv.args)) |output|
        return .{ .output = output, .failed = false }
    else |err|
        return .{ .output = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tcv.name, @errorName(err) }) catch "tool failed", .failed = true };
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

fn execExtract(self: *Self, arena: std.mem.Allocator, raw_schema: []const u8) ExecResult {
    const schema = browser_tools.substituteEnvVars(arena, raw_schema);
    const result = self.tool_executor.extractSchema(arena, schema);
    return .{ .output = result.text, .failed = result.is_error };
}

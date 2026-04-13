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
    const Action = browser_tools.Action;
    return switch (cmd) {
        .goto => |url| self.callTool(a, @tagName(Action.goto), buildJson(a, .{ .url = substituteEnvVars(a, url) })),
        .click => |sel| self.callTool(a, @tagName(Action.click), buildJson(a, .{ .selector = substituteEnvVars(a, sel) })),
        // execFill in browser/tools.zig substitutes `value` itself so the
        // displayed result keeps the `$LP_*` reference instead of leaking
        // the resolved secret back to the terminal.
        .type_cmd => |args| self.callTool(a, @tagName(Action.fill), buildJson(a, .{
            .selector = substituteEnvVars(a, args.selector),
            .value = args.value,
        })),
        .wait => |selector| self.callTool(a, @tagName(Action.waitForSelector), buildJson(a, .{ .selector = selector })),
        .scroll => |args| self.callTool(a, @tagName(Action.scroll), buildJson(a, .{ .x = args.x, .y = args.y })),
        .hover => |sel| self.callTool(a, @tagName(Action.hover), buildJson(a, .{ .selector = substituteEnvVars(a, sel) })),
        .select => |args| self.callTool(a, @tagName(Action.selectOption), buildJson(a, .{
            .selector = substituteEnvVars(a, args.selector),
            .value = substituteEnvVars(a, args.value),
        })),
        .check => |args| self.callTool(a, @tagName(Action.setChecked), buildJson(a, .{
            .selector = substituteEnvVars(a, args.selector),
            .checked = args.checked,
        })),
        .tree => self.callTool(a, @tagName(Action.tree), ""),
        .markdown => self.callTool(a, @tagName(Action.markdown), ""),
        .extract => |selector| self.execExtract(a, selector),
        .eval_js => |script| self.callTool(a, @tagName(Action.eval), buildJson(a, .{ .script = script })),
        .exit, .natural_language, .comment, .login, .accept_cookies => unreachable,
    };
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
    const selector = substituteEnvVars(arena, raw_selector);

    // `std.json.Stringify.value` emits a quoted, JS-safe string literal, which
    // is also a valid JS string literal — reuse it to splice the selector into
    // the querySelectorAll call.
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(selector, .{}, &aw.writer) catch
        return .{ .output = "failed to encode selector", .failed = true };
    const encoded = aw.written();

    const script = std.fmt.allocPrint(
        arena,
        "JSON.stringify(Array.from(document.querySelectorAll({s})).map(el => el.textContent.trim()))",
        .{encoded},
    ) catch return .{ .output = "failed to build extract script", .failed = true };

    return self.callTool(arena, @tagName(browser_tools.Action.eval), buildJson(arena, .{ .script = script }));
}

const substituteEnvVars = browser_tools.substituteEnvVars;

fn buildJson(arena: std.mem.Allocator, value: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return "{}";
    return aw.written();
}

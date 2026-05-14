// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Command = lp.script.Command;
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");

const Self = @This();

tool_executor: *ToolExecutor,
terminal: *Terminal,

pub fn init(tool_executor: *ToolExecutor, terminal: *Terminal) Self {
    return .{
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
/// `Agent.runRepl`) because they have no tool mapping.
pub fn executeWithResult(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) ExecResult {
    switch (cmd) {
        .extract => |schema| return self.execExtract(arena, schema),
        .eval_js => |script| return evalLikeResult(self.tool_executor.callEval(arena, script)),
        else => {},
    }

    const tc = (Command.toToolCall(arena, cmd, browser_tools.substituteEnvVars) catch
        return .{ .output = "out of memory", .failed = true }) orelse
        return .{ .output = "internal: command has no tool mapping", .failed = true };
    if (self.tool_executor.callValue(arena, tc.name, tc.args)) |output|
        return .{ .output = output, .failed = false }
    else |err|
        return .{ .output = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name, @errorName(err) }) catch "tool failed", .failed = true };
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
    const schema = browser_tools.substituteEnvVars(arena, raw_schema) catch
        return .{ .output = "out of memory", .failed = true };
    return evalLikeResult(self.tool_executor.extract(arena, schema));
}

/// Collapse an `EvalResult` into an `ExecResult` while preserving `isError`:
/// V8 throws would otherwise round-trip as `failed = false` through the
/// generic `[]const u8` path.
fn evalLikeResult(result: browser_tools.ToolError!browser_tools.EvalResult) ExecResult {
    const r = result catch |err| return .{ .output = @errorName(err), .failed = true };
    return .{ .output = r.text(), .failed = r.isError() };
}

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

const CommandRunner = @This();

tool_executor: *ToolExecutor,
terminal: *Terminal,

pub fn init(tool_executor: *ToolExecutor, terminal: *Terminal) CommandRunner {
    return .{
        .tool_executor = tool_executor,
        .terminal = terminal,
    };
}

/// Caller contract: `cmd` must not be `.natural_language`, `.comment`,
/// `.login`, or `.accept_cookies` — those are filtered upstream (see
/// `Agent.runRepl`) because they have no tool mapping.
pub fn executeWithResult(self: *CommandRunner, arena: std.mem.Allocator, cmd: Command) browser_tools.ToolResult {
    switch (cmd) {
        .extract => |schema| return self.execExtract(arena, schema),
        .eval_js => |script| return browser_tools.ToolResult.unwrap(self.tool_executor.callEval(arena, script)),
        else => {},
    }

    const tc = (cmd.toToolCall(arena, browser_tools.substituteEnvVars) catch
        return .{ .text = "out of memory", .is_error = true }) orelse
        return .{ .text = "internal: command has no tool mapping", .is_error = true };
    return self.tool_executor.callValue(arena, tc.name, tc.args) catch |err| .{
        .text = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name, @errorName(err) }) catch "tool failed",
        .is_error = true,
    };
}

/// Data output (EXTRACT/EVAL/MARKDOWN/TREE) → stdout on success; everything
/// else, including failures from those same commands, → stderr.
pub fn printResult(self: *CommandRunner, cmd: Command, result: browser_tools.ToolResult) void {
    if (cmd.producesData() and !result.is_error) {
        self.terminal.printAssistant(result.text);
    } else {
        self.terminal.printActionResult(result.text);
    }
}

fn execExtract(self: *CommandRunner, arena: std.mem.Allocator, raw_schema: []const u8) browser_tools.ToolResult {
    const schema = browser_tools.substituteEnvVars(arena, raw_schema) catch
        return .{ .text = "out of memory", .is_error = true };
    return browser_tools.ToolResult.unwrap(self.tool_executor.extract(arena, schema));
}

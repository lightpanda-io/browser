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

allocator: std.mem.Allocator,
tool_executor: *ToolExecutor,
terminal: *Terminal,

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
/// `Agent.runRepl`) because they have no tool mapping.
pub fn executeWithResult(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) ExecResult {
    if (cmd == .extract) return self.execExtract(arena, cmd.extract);

    const tcv = (Command.toToolCallValue(arena, cmd, browser_tools.substituteEnvVars) catch
        return .{ .output = "out of memory", .failed = true }) orelse
        return .{ .output = "internal: command has no tool mapping", .failed = true };
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
    const schema = browser_tools.substituteEnvVars(arena, raw_schema) catch
        return .{ .output = "out of memory", .failed = true };
    const result = self.tool_executor.extractSchema(arena, schema) catch |err|
        return .{ .output = @errorName(err), .failed = true };
    return .{ .output = result.text(), .failed = result.isError() };
}

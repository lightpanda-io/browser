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
const CDPNode = @import("../cdp/Node.zig");
const Terminal = @import("Terminal.zig");

const CommandRunner = @This();

session: *lp.Session,
node_registry: *CDPNode.Registry,
terminal: *Terminal,

pub fn init(session: *lp.Session, node_registry: *CDPNode.Registry, terminal: *Terminal) CommandRunner {
    return .{
        .session = session,
        .node_registry = node_registry,
        .terminal = terminal,
    };
}

/// Caller contract: `cmd` must be `.tool_call` — `.comment`, `.login`, and
/// `.accept_cookies` are filtered upstream (see `Agent.runRepl`) because they
/// have no tool mapping.
pub fn executeWithResult(self: *CommandRunner, arena: std.mem.Allocator, cmd: Command) browser_tools.ToolResult {
    const tc = switch (cmd) {
        .tool_call => |t| t,
        else => return .{ .text = "internal: command has no tool mapping", .is_error = true },
    };
    return browser_tools.call(arena, self.session, self.node_registry, tc.name(), tc.args) catch |err| .{
        .text = if (err == error.OutOfMemory)
            "out of memory"
        else
            std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name(), @errorName(err) }) catch "tool failed",
        .is_error = true,
    };
}

/// Data output (extract/eval/markdown/tree/…) → stdout on success; everything
/// else, including failures from those same commands, → stderr.
pub fn printResult(self: *CommandRunner, cmd: Command, result: browser_tools.ToolResult) void {
    if (cmd.producesData() and !result.is_error) {
        self.terminal.printAssistant(result.text);
    } else {
        self.terminal.printActionResult(result.text);
    }
}

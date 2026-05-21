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

/// Caller contract: `cmd` must be `.tool_call` — `.comment`, `.login`, and
/// `.accept_cookies` are filtered upstream (see `Agent.runRepl`) because they
/// have no tool mapping.
pub fn executeWithResult(self: *CommandRunner, arena: std.mem.Allocator, cmd: Command) browser_tools.ToolResult {
    const tc = switch (cmd) {
        .tool_call => |t| t,
        else => return .{ .text = "internal: command has no tool mapping", .is_error = true },
    };
    const substituted = substituteStringArgs(arena, tc.name, tc.args) catch
        return .{ .text = "out of memory", .is_error = true };
    return self.tool_executor.callValue(arena, tc.name, substituted) catch |err| .{
        .text = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name, @errorName(err) }) catch "tool failed",
        .is_error = true,
    };
}

/// Resolve `$LP_*` placeholders in string args before the tool runs. `fill`'s
/// `value` is excluded — the tool resolves it internally and rewrites the
/// result text so the credential never appears in the echoed confirmation.
fn substituteStringArgs(arena: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value) error{OutOfMemory}!?std.json.Value {
    const v = args orelse return null;
    if (v != .object) return v;

    const is_fill = if (std.meta.stringToEnum(browser_tools.Action, tool_name)) |a| a == .fill else false;

    var needs_sub = false;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const exclude = is_fill and std.mem.eql(u8, key, "value");
        if (!exclude and val == .string and std.mem.indexOf(u8, val.string, "$LP_") != null) {
            needs_sub = true;
            break;
        }
    }
    if (!needs_sub) return v;

    var new_obj: std.json.ObjectMap = .init(arena);
    try new_obj.ensureTotalCapacity(v.object.count());
    it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const exclude = is_fill and std.mem.eql(u8, key, "value");
        if (!exclude and val == .string and std.mem.indexOf(u8, val.string, "$LP_") != null) {
            const resolved = try browser_tools.substituteEnvVars(arena, val.string);
            try new_obj.put(key, .{ .string = resolved });
            continue;
        }
        try new_obj.put(key, val);
    }
    return .{ .object = new_obj };
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

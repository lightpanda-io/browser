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
    const substituted = substituteStringArgs(arena, tc.action, tc.args) catch
        return .{ .text = "out of memory", .is_error = true };
    return browser_tools.call(arena, self.session, self.node_registry, tc.name(), substituted) catch |err| .{
        .text = std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name(), @errorName(err) }) catch "tool failed",
        .is_error = true,
    };
}

/// Resolve `$LP_*` placeholders in string args before the tool runs. `fill`'s
/// `value` is excluded — the tool resolves it internally and rewrites the
/// result text so the credential never appears in the echoed confirmation.
fn substituteStringArgs(arena: std.mem.Allocator, action: browser_tools.Action, args: ?std.json.Value) error{OutOfMemory}!?std.json.Value {
    const v = args orelse return null;
    if (v != .object) return v;

    const is_fill = action == .fill;

    const needsSub = struct {
        fn f(is_fill_: bool, key: []const u8, val: std.json.Value) bool {
            if (is_fill_ and std.mem.eql(u8, key, "value")) return false;
            return val == .string and std.mem.indexOf(u8, val.string, "$LP_") != null;
        }
    }.f;

    var needs_any = false;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (needsSub(is_fill, entry.key_ptr.*, entry.value_ptr.*)) {
            needs_any = true;
            break;
        }
    }
    if (!needs_any) return v;

    var new_obj: std.json.ObjectMap = .init(arena);
    try new_obj.ensureTotalCapacity(v.object.count());
    it = v.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const new_val: std.json.Value = if (needsSub(is_fill, key, val))
            .{ .string = try browser_tools.substituteEnvVars(arena, val.string) }
        else
            val;
        try new_obj.put(key, new_val);
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

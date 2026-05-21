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

//! REPL-only meta slash commands and re-exports of the PandaScript schema
//! primitives. The actual slash-command grammar lives in `script/schema.zig`;
//! this module keeps the agent-only meta commands (`/help`, `/quit`,
//! `/verbosity`) that aren't part of the script.

const std = @import("std");
const lp = @import("lightpanda");
const schema = lp.script.schema;

// Re-export so existing call sites (Agent, Terminal) keep their import path.
pub const SchemaInfo = schema.SchemaInfo;
pub const ParseError = schema.ParseError;
pub const Split = schema.Split;

pub const max_hint_slots = schema.max_hint_slots;

pub const globalSchemas = schema.globalSchemas;
pub const findSchema = schema.findSchema;
pub const findSchemaCanonical = schema.findSchemaCanonical;
pub const splitNameRest = schema.splitNameRest;

/// Meta slash commands handled directly by the agent (not by ToolExecutor).
/// Kept in sync with `handleMeta` in Agent.zig.
pub const MetaCommand = struct {
    name: [:0]const u8,
    /// Ghost-text fragment shown after the name + space. Empty when the
    /// command takes no args (`/help`, `/quit`).
    hint: []const u8,
    /// Tab-completion candidates for the first positional arg.
    values: []const [:0]const u8,
};

pub const meta_commands = [_]MetaCommand{
    .{ .name = "help", .hint = "", .values = &.{} },
    .{ .name = "quit", .hint = "", .values = &.{} },
    .{ .name = "verbosity", .hint = "<low|medium|high>", .values = &.{ "low", "medium", "high" } },
};

pub const meta_names: [meta_commands.len][:0]const u8 = blk: {
    var arr: [meta_commands.len][:0]const u8 = undefined;
    for (meta_commands, 0..) |m, i| arr[i] = m.name;
    break :blk arr;
};

pub fn findMeta(name: []const u8) ?*const MetaCommand {
    for (&meta_commands) |*m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) return m;
    }
    return null;
}

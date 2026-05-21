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
//! primitives. The actual slash-command grammar lives in `script/schema.zig`.

const std = @import("std");
const lp = @import("lightpanda");
const schema = lp.script.schema;

pub const SchemaInfo = schema.SchemaInfo;
pub const ParseError = schema.ParseError;
pub const Split = schema.Split;

pub const max_hint_slots = schema.max_hint_slots;

pub const globalSchemas = schema.globalSchemas;
pub const findSchema = schema.findSchema;
pub const splitNameRest = schema.splitNameRest;

/// Meta slash commands handled directly by Agent.handleMeta.
pub const MetaCommand = struct {
    kind: Kind,
    name: [:0]const u8,
    /// Ghost-text fragment shown after the name + space. Empty when the
    /// command takes no args (`/help`, `/quit`).
    hint: []const u8,
    /// Tab-completion candidates for the first positional arg.
    values: []const [:0]const u8,

    pub const Kind = enum { help, quit, verbosity };
};

pub const meta_commands = [_]MetaCommand{
    .{ .kind = .help, .name = "help", .hint = "", .values = &.{} },
    .{ .kind = .quit, .name = "quit", .hint = "", .values = &.{} },
    .{ .kind = .verbosity, .name = "verbosity", .hint = "<low|medium|high>", .values = &.{ "low", "medium", "high" } },
};

pub fn findMeta(name: []const u8) ?*const MetaCommand {
    for (&meta_commands) |*m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) return m;
    }
    return null;
}

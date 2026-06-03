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

//! REPL-only meta slash commands (`/help`, `/quit`, `/verbosity`, `/model`,
//! `/provider`). Meta commands aren't tool slash commands — they're handled
//! by `Agent.handleMeta` and never reach the recorder. Tool slash-command
//! schema primitives live in `lp.Schema`; consumers should import that
//! directly.

const std = @import("std");
const lp = @import("lightpanda");
const Command = lp.Command;

/// Shared row format for the `/help` listing — `name` is the command name
/// (no `/`), `description` is a terse one-liner.
pub const Help = struct {
    name: []const u8,
    description: []const u8,
};

pub const MetaCommand = struct {
    tag: Tag,
    name: [:0]const u8,
    /// Ghost-text fragment shown after the name + space. Empty when the
    /// command takes no args (`/help`, `/quit`).
    hint: []const u8,
    /// Tab-completion candidates for the first positional arg.
    values: []const []const u8,
    /// Terse one-liner for the `/help` listing; longer detail is rendered
    /// by `Agent.printSlashHelp` for the per-command lookup.
    description: []const u8,

    /// Dispatched by `Agent.handleMeta` via an exhaustive switch so adding
    /// a new meta command is a compile error until it's wired up there too.
    const Tag = enum { help, quit, verbosity, save, load, model, provider };
};

pub const meta_commands = [_]MetaCommand{
    .{ .tag = .help, .name = "help", .hint = "[command]", .values = &.{}, .description = "List commands, or show help for one" },
    .{ .tag = .quit, .name = "quit", .hint = "", .values = &.{}, .description = "Exit the REPL" },
    .{ .tag = .verbosity, .name = "verbosity", .hint = "<low|medium|high>", .values = &.{ "low", "medium", "high" }, .description = "Set agent verbosity" },
    .{ .tag = .save, .name = "save", .hint = "[filename.js] [prompt]", .values = &.{}, .description = "Save this session to a file" },
    .{ .tag = .load, .name = "load", .hint = "<path>", .values = &.{}, .description = "Load and run a script from disk" },
    .{ .tag = .model, .name = "model", .hint = "[name]", .values = &.{}, .description = "Change the model" },
    .{ .tag = .provider, .name = "provider", .hint = "[name]", .values = &.{}, .description = "Change the provider" },
};

/// Derived from `Command.LlmCommand` — name and description both come from
/// the enum, so a new trigger there surfaces here automatically.
pub const llm_commands = blk: {
    const values = std.enums.values(Command.LlmCommand);
    var rows: [values.len]Help = undefined;
    for (values, &rows) |lc, *row| row.* = .{ .name = @tagName(lc), .description = lc.description() };
    break :blk rows;
};

pub fn findMeta(name: []const u8) ?*const MetaCommand {
    for (&meta_commands) |*m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) return m;
    }
    return null;
}

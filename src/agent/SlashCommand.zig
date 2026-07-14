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

//! REPL-only meta slash commands (`/help`, `/quit`, `/verbosity`, `/effort`,
//! `/stream`, `/usage`, `/model`, `/provider`). Not tool slash commands — handled by
//! `Agent.handleMeta`, never reaching the recorder. Tool slash-command schema
//! primitives live in `lp.Schema`; import that directly.

const std = @import("std");
const lp = @import("lightpanda");
const Command = lp.Command;
const Config = lp.Config;

/// Row format for the `/help` listing — `name` carries no leading `/`.
pub const Help = struct {
    name: []const u8,
    description: []const u8,
};

pub const MetaCommand = struct {
    tag: Tag,
    name: [:0]const u8,
    /// Ghost-text fragment shown after the name + space. Empty when the command
    /// takes no args (`/help`, `/quit`).
    hint: []const u8,
    /// Tab-completion candidates for the first positional arg.
    values: []const []const u8,
    /// Terse one-liner for the `/help` listing; longer per-command detail is
    /// rendered by `Agent.printSlashHelp`.
    description: []const u8,

    /// Dispatched by `Agent.handleMeta` via an exhaustive switch, so a new meta
    /// command is a compile error until it's wired up there too.
    const Tag = enum { help, quit, verbosity, effort, stream, usage, clear, reset, save, load, model, provider };
};

const tagNames = Config.tagNames;
const tagHint = Config.tagHint;

pub const meta_commands = [_]MetaCommand{
    .{ .tag = .help, .name = "help", .hint = "[command]", .values = &.{}, .description = "List commands, or show help for one" },
    .{ .tag = .quit, .name = "quit", .hint = "", .values = &.{}, .description = "Exit the REPL" },
    .{ .tag = .verbosity, .name = "verbosity", .hint = tagHint(Config.AgentVerbosity), .values = tagNames(Config.AgentVerbosity), .description = "Set agent verbosity" },
    .{ .tag = .effort, .name = "effort", .hint = tagHint(Config.Effort), .values = tagNames(Config.Effort), .description = "Set per-turn reasoning effort" },
    .{ .tag = .stream, .name = "stream", .hint = "[on|off]", .values = &.{ "on", "off" }, .description = "Toggle streaming of assistant text" },
    .{ .tag = .usage, .name = "usage", .hint = "", .values = &.{}, .description = "Show token usage and cache stats for this session" },
    .{ .tag = .clear, .name = "clear", .hint = "", .values = &.{}, .description = "Clear conversation history and usage (keeps page/cookies)" },
    .{ .tag = .reset, .name = "reset", .hint = "", .values = &.{}, .description = "Reset conversation and browser session (drops page/cookies)" },
    .{ .tag = .save, .name = "save", .hint = "[filename.js] [prompt]", .values = &.{}, .description = "Save this session to a file" },
    .{ .tag = .load, .name = "load", .hint = "<path>", .values = &.{}, .description = "Load and run a script from disk" },
    .{ .tag = .model, .name = "model", .hint = "[name]", .values = &.{}, .description = "Change the model" },
    .{ .tag = .provider, .name = "provider", .hint = "[name|null]", .values = &.{}, .description = "Change the provider, or 'null' to disable the LLM" },
};

/// Derived from `Command.LlmCommand` — name and description both come from the
/// enum, so a new trigger there surfaces here automatically.
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

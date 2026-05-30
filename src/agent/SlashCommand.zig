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
//! `/provider`). Meta
//! commands aren't PandaScript — they're handled by `Agent.handleMeta`
//! and never reach the recorder. PandaScript schema primitives live in
//! `lp.script.Schema`; consumers should import that directly.

const std = @import("std");

/// Shared row format for the `/help` listing — `name` is the slash name
/// (no `/`), `description` is a single-sentence summary.
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
    values: []const [:0]const u8,
    /// First-sentence summary for `/help`; longer detail is rendered by
    /// `Agent.printSlashHelp` for the per-command lookup.
    description: []const u8,

    /// Dispatched by `Agent.handleMeta` via an exhaustive switch so adding
    /// a new meta command is a compile error until it's wired up there too.
    const Tag = enum { help, quit, verbosity, save, model, provider };
};

pub const meta_commands = [_]MetaCommand{
    .{ .tag = .help, .name = "help", .hint = "", .values = &.{}, .description = "Show help for a slash command, or list all when no name is given" },
    .{ .tag = .quit, .name = "quit", .hint = "", .values = &.{}, .description = "Exit the REPL" },
    .{ .tag = .verbosity, .name = "verbosity", .hint = "<low|medium|high>", .values = &.{ "low", "medium", "high" }, .description = "Set REPL agent verbosity; bare /verbosity prints the current level" },
    .{ .tag = .save, .name = "save", .hint = "[filename.lp]", .values = &.{}, .description = "Save this REPL session as a PandaScript file" },
    .{ .tag = .model, .name = "model", .hint = "[name]", .values = &.{}, .description = "Change the model (Tab completes the provider's models); bare /model shows the current one" },
    .{ .tag = .provider, .name = "provider", .hint = "[name]", .values = &.{}, .description = "Change the provider (Tab completes detected providers); bare /provider shows the current one" },
};

/// LLM-driven slash commands. Parsed via `script.Command.parse` (they're
/// variants of the `Command` union) — listed here only so the help
/// renderer and completer have a single source of names + descriptions.
pub const llm_commands = [_]Help{
    .{ .name = "login", .description = "Log in to the current site using $LP_* env-var credentials" },
    .{ .name = "acceptCookies", .description = "Find and dismiss the cookie consent banner" },
};

pub fn findMeta(name: []const u8) ?*const MetaCommand {
    for (&meta_commands) |*m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) return m;
    }
    return null;
}

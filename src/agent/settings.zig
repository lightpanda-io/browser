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

//! Provider/model settings for the agent: pick a provider+key (flag /
//! remembered / detected / interactive) and persist the selection to
//! `.lp-agent.zon`. Client construction lives in `zenai.provider.Client`.
//! The conversation loop in `Agent.zig` consumes these; they hold no
//! `Agent` state.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");
const Config = lp.Config;
const Terminal = @import("Terminal.zig");
const Credentials = zenai.provider.Credentials;

pub const api_keys_hint = "ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY";

/// Determine which provider to use and read its env key. Returns null
/// only when no `--provider` was given AND no env key exists (the caller
/// decides whether that's fatal — basic REPL tolerates it).
pub const ResolvedProvider = struct {
    credentials: Credentials,
    source: enum { flag, remembered, detected, picked },
};

/// Returns true when resolveCredentials would succeed (no error, non-null).
/// Used by callers that need to print a banner before calling resolveCredentials.
pub fn wouldResolve(opts: Config.Agent, remembered: ?Remembered) bool {
    if (opts.provider) |p| return zenai.provider.envApiKey(p) != null;
    if (remembered) |r| if (zenai.provider.envApiKey(r.provider)) |_| return true;
    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    return zenai.provider.detectKeys(&buf, zenai.provider.default_candidates).len > 0;
}

/// Precedence: `--provider` > remembered (if its key is still set) > first
/// detected. Null means no key at all (the reason is already printed).
pub fn resolveCredentials(opts: Config.Agent, remembered: ?Remembered, allow_pick: bool) !?ResolvedProvider {
    if (opts.provider) |p| {
        const key = zenai.provider.envApiKey(p) orelse {
            std.debug.print(
                "Missing API key for --provider {s}: set {s} — or pass --no-llm for the basic REPL.\n",
                .{ @tagName(p), zenai.provider.envVarName(p) },
            );
            return error.MissingApiKey;
        };
        return .{ .credentials = .{ .provider = p, .key = key }, .source = .flag };
    }

    if (remembered) |r| if (zenai.provider.envApiKey(r.provider)) |key| {
        return .{ .credentials = .{ .provider = r.provider, .key = key }, .source = .remembered };
    };

    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    const found = zenai.provider.detectKeys(&buf, zenai.provider.default_candidates);
    if (found.len == 0) {
        std.debug.print(
            \\No API key detected. Set {s}.
            \\If you want to use the REPL in basic mode (without LLM integration) you can pass the --no-llm option.
            \\
        , .{api_keys_hint});
        return null;
    }
    // A single key needs no choice; non-interactive callers (--list-models,
    // one-shot tasks, pipes) must not block on a prompt — take the first.
    if (!allow_pick or found.len == 1 or !Terminal.interactiveTty()) {
        return .{ .credentials = found[0], .source = .detected };
    }

    var names: [zenai.provider.default_candidates.len][]const u8 = undefined;
    for (found, 0..) |cred, i| names[i] = @tagName(cred.provider);
    std.debug.print("\n", .{});
    const idx = Terminal.promptNumberedChoice("  Select a provider:", names[0..found.len], 0) catch {
        return .{ .credentials = found[0], .source = .detected };
    };
    return .{ .credentials = found[idx], .source = .picked };
}

pub const remembered_path = ".lp-agent.zon";

/// Last user-selected provider/model, persisted per-directory in `.lp-agent.zon`.
/// `model` is owned by the caller.
pub const Remembered = struct {
    provider: Config.AiProvider,
    model: []const u8,
};

pub fn loadRemembered(allocator: std.mem.Allocator) ?Remembered {
    const data = std.fs.cwd().readFileAllocOptions(allocator, remembered_path, 1024, null, .of(u8), 0) catch return null;
    defer allocator.free(data);
    const remembered = std.zon.parse.fromSlice(Remembered, allocator, data, null, .{}) catch return null;
    if (remembered.model.len == 0) {
        std.zon.parse.free(allocator, remembered);
        return null;
    }
    return remembered;
}

/// Best-effort persist of the current selection; failures are ignored.
pub fn saveRemembered(provider: Config.AiProvider, model: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(Remembered{ .provider = provider, .model = model }, .{}, &w);
    try std.fs.cwd().writeFile(.{ .sub_path = remembered_path, .data = w.buffered() });
}

pub fn availableProviders(buf: []Credentials) []Credentials {
    return zenai.provider.detectKeys(buf, std.enums.values(Config.AiProvider));
}

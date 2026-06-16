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
const string = @import("../string.zig");
const Credentials = zenai.provider.Credentials;

pub const api_keys_hint = "ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, or HF_TOKEN";

/// Determine which provider to use and read its env key. Returns null
/// only when no `--provider` was given AND no env key exists (the caller
/// decides whether that's fatal — basic REPL tolerates it).
pub const ResolvedProvider = struct {
    credentials: Credentials,
    source: enum { flag, remembered, detected, picked },
};

/// Ollama needs no API key, so it's excluded from env detection
/// (`default_candidates`) and only probed here. Null means no server answered
/// with a pulled model — the only honest signal of Ollama availability, since
/// its env key is a constant placeholder.
pub fn detectOllama(allocator: std.mem.Allocator, base_url: ?[:0]const u8) ?Credentials {
    const key = zenai.provider.envApiKey(.ollama) orelse return null;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = zenai.provider.listChatModelIds(allocator, arena.allocator(), .ollama, key, base_url) catch return null;
    if (ids.len == 0) return null;
    return .{ .provider = .ollama, .key = key };
}

/// True when a non-Ollama provider key is available (flag, remembered, or
/// env-detected). Skips the Ollama probe so it isn't run twice at startup; the
/// interactive picker only fires on detected keys, which this still catches.
pub fn hasDetectableKey(opts: Config.Agent, remembered: ?Remembered) bool {
    if (opts.provider) |p| return zenai.provider.envApiKey(p) != null;
    if (remembered) |r| if (r.provider) |p| if (zenai.provider.envApiKey(p)) |_| return true;
    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    return zenai.provider.detectKeys(&buf, zenai.provider.default_candidates).len > 0;
}

/// Precedence: `--provider` > remembered (if its key is still set) > first
/// detected. Null means no key at all (the reason is already printed).
pub fn resolveCredentials(allocator: std.mem.Allocator, opts: Config.Agent, remembered: ?Remembered, allow_pick: bool) !?ResolvedProvider {
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

    if (remembered) |r| if (r.provider) |p| if (zenai.provider.envApiKey(p)) |key| {
        return .{ .credentials = .{ .provider = p, .key = key }, .source = .remembered };
    };

    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    const found = zenai.provider.detectKeys(&buf, zenai.provider.default_candidates);
    if (found.len == 0) {
        if (detectOllama(allocator, opts.base_url)) |creds| {
            return .{ .credentials = creds, .source = .detected };
        }
        std.debug.print(
            \\No API key detected. Set {s}, or run a local Ollama server with a pulled model.
            \\To use the basic REPL (without LLM integration), pass the --no-llm option.
            \\
        , .{api_keys_hint});
        return null;
    }
    // A single key needs no choice; non-interactive callers (--list-models,
    // one-shot tasks, pipes) must not block on a prompt — take the first.
    if (!allow_pick or found.len == 1 or !Terminal.interactiveTty()) {
        return .{ .credentials = found[0], .source = .detected };
    }

    var names: [zenai.provider.default_candidates.len][:0]const u8 = undefined;
    for (found, 0..) |cred, i| names[i] = @tagName(cred.provider);
    std.debug.print("\n", .{});
    const idx = Terminal.promptNumberedChoice("  Select a provider:", names[0..found.len], 0) catch {
        return .{ .credentials = found[0], .source = .detected };
    };
    return .{ .credentials = found[idx], .source = .picked };
}

pub const remembered_path = ".lp-agent.zon";

/// Last user-selected provider/model/effort/verbosity, persisted per-directory
/// in `.lp-agent.zon`. `model` is caller-owned. A null `provider` means the user
/// disabled the LLM (`/provider null`), so the REPL starts in basic mode without
/// re-prompting. `effort`/`verbosity` are optional so files predating them still
/// parse; null means "use the mode default" (see `Agent.resolveEffort` /
/// `Agent.resolveVerbosity`).
pub const Remembered = struct {
    provider: ?Config.AiProvider = null,
    model: []const u8,
    effort: ?Config.Effort = null,
    verbosity: ?Config.AgentVerbosity = null,
};

pub fn loadRemembered(allocator: std.mem.Allocator) ?Remembered {
    const data = std.fs.cwd().readFileAllocOptions(allocator, remembered_path, 1024, null, .of(u8), 0) catch return null;
    defer allocator.free(data);
    const remembered = std.zon.parse.fromSlice(Remembered, allocator, data, null, .{}) catch return null;
    // An empty model is corrupt only when a provider is set; a null provider
    // (LLM disabled) legitimately has no model to remember.
    if (remembered.provider != null and remembered.model.len == 0) {
        std.zon.parse.free(allocator, remembered);
        return null;
    }
    return remembered;
}

/// Best-effort persist of the current selection; failures are ignored.
pub fn saveRemembered(remembered: Remembered) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(remembered, .{}, &w);
    try std.fs.cwd().writeFile(.{ .sub_path = remembered_path, .data = w.buffered() });
}

/// Cloud providers with a key set. Ollama is excluded — its availability needs
/// a live probe (`detectOllama`), too costly for an unconditional startup scan.
pub fn availableProviders(buf: []Credentials) []Credentials {
    return zenai.provider.detectKeys(buf, zenai.provider.default_candidates);
}

pub fn resolveModelName(opts: Config.Agent, resolved: ?ResolvedProvider, remembered: ?Remembered) []const u8 {
    if (opts.model) |m| return m;
    if (resolved) |r| {
        // Use the remembered model whenever it matches the chosen provider,
        // not only when the provider itself came from the remembered file.
        if (remembered) |rem| {
            if (rem.provider) |p| if (p == r.credentials.provider) return rem.model;
        }
        return zenai.provider.defaultModel(r.credentials.provider);
    }
    return "";
}

/// Precedence: explicit `--effort` flag > remembered `.lp-agent.zon` value >
/// mode default. The interactive REPL defaults to `.low` so turns stay snappy;
/// one-shot `--task` defaults to `.medium`, where answer quality matters more
/// than per-turn latency. (Script runs never call the LLM, so the resolved
/// effort is unused there.)
pub fn resolveEffort(opts: Config.Agent, remembered: ?Remembered, will_repl: bool) Config.Effort {
    if (opts.effort) |e| return e;
    if (remembered) |r| if (r.effort) |e| return e;
    return if (will_repl) .low else .medium;
}

/// Precedence: explicit `--verbosity` flag > remembered `.lp-agent.zon` value >
/// mode default (see `Config.agentVerbosity`).
pub fn resolveVerbosity(opts: Config.Agent, remembered: ?Remembered) Config.AgentVerbosity {
    if (opts.verbosity) |v| return v;
    if (remembered) |r| if (r.verbosity) |v| return v;
    return Config.agentVerbosity(opts);
}

pub const ReconciledModel = union(enum) {
    /// Owned by the allocator passed to reconcileModel.
    use: []u8,
    abort,
};

/// Validate `desired` against the provider's catalog, mirroring the interactive
/// `/model` command. Empty list (unreachable server) leaves it unchecked; an
/// explicit unlisted model is fatal. Ollama's local catalog is authoritative, so
/// its default is substituted when not pulled; cloud defaults are hardcoded real
/// models, trusted as-is.
pub fn reconcileModel(
    allocator: std.mem.Allocator,
    llm: Credentials,
    desired: []const u8,
    base_url: ?[:0]const u8,
    explicit: bool,
) !ReconciledModel {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids: []const []const u8 = zenai.provider.listChatModelIds(allocator, arena.allocator(), llm.provider, llm.key, base_url) catch &.{};
    if (ids.len == 0 or string.isOneOf(desired, ids)) return .{ .use = try allocator.dupe(u8, desired) };

    if (!explicit) {
        if (llm.provider != .ollama) return .{ .use = try allocator.dupe(u8, desired) };
        std.debug.print("Default Ollama model '{s}' is not installed; using '{s}'.\n", .{ desired, ids[0] });
        return .{ .use = try allocator.dupe(u8, ids[0]) };
    }

    if (llm.provider == .ollama) {
        const installed = std.mem.join(arena.allocator(), ", ", ids) catch "";
        std.debug.print(
            "Model '{s}' is not installed in Ollama.\nInstalled: {s}\nRun `ollama pull {s}` to install it, or choose one of the above.\n",
            .{ desired, installed, desired },
        );
    } else {
        std.debug.print(
            "Model '{s}' is not available for {s}.\nRun with --list-models to see options.\n",
            .{ desired, @tagName(llm.provider) },
        );
    }
    return .abort;
}

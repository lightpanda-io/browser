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

pub const api_keys_hint = "ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, HF_TOKEN, AI_GATEWAY_API_KEY, or MISTRAL_API_KEY (Vertex AI: VERTEX_API_KEY, or GOOGLE_CLOUD_PROJECT via gcloud)";

/// Determine which provider to use and read its env key. Returns null
/// only when no `--provider` was given AND no env key exists (the caller
/// decides whether that's fatal — basic REPL tolerates it).
pub const ResolvedProvider = struct {
    credentials: Credentials,
    source: enum { flag, remembered, detected, picked },
    /// Key allocated (Vertex gcloud token) rather than an env pointer; the
    /// caller frees it, only after the client that references it is gone.
    key_owned: bool = false,
};

/// Probe a keyless local provider (Ollama, llama.cpp): its env key is a
/// placeholder, so the only honest availability signal is the server answering
/// `/v1/models` with a loaded model. Null means no server responded.
pub fn detectLocalProvider(allocator: std.mem.Allocator, tag: Config.AiProvider, base_url: ?[:0]const u8) ?Credentials {
    const key = zenai.provider.envApiKey(tag) orelse return null;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = zenai.provider.listChatModelIds(allocator, arena.allocator(), tag, key, base_url) catch return null;
    if (ids.len == 0) return null;
    return .{ .provider = tag, .key = key };
}

/// With GOOGLE_CLOUD_PROJECT set, zenai's client always sends Bearer auth —
/// an API key can never work, so the credential must be an OAuth token.
pub fn vertexProjectMode() bool {
    return std.posix.getenv("GOOGLE_CLOUD_PROJECT") != null;
}

/// Caller owns the result. Failure prints gcloud's own stderr so the real
/// cause (not logged in, missing SDK) reaches the user.
pub fn gcloudAccessToken(allocator: std.mem.Allocator) ![:0]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gcloud", "auth", "print-access-token" },
        .max_output_bytes = 64 * 1024,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("gcloud not found on PATH; install the Google Cloud SDK, or unset GOOGLE_CLOUD_PROJECT to use Vertex express mode with GOOGLE_API_KEY.\n", .{});
            return error.GcloudNotFound;
        }
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const failed = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    const token = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (failed or token.len == 0) {
        std.debug.print("`gcloud auth print-access-token` failed:\n{s}", .{result.stderr});
        return error.GcloudTokenFailed;
    }
    return allocator.dupeZ(u8, token);
}

/// True when a non-Ollama provider key is available (flag, remembered, or
/// env-detected). Skips the Ollama probe so it isn't run twice at startup; the
/// interactive picker only fires on detected keys, which this still catches.
pub fn hasDetectableKey(opts: Config.Agent, remembered: ?Remembered) bool {
    if (opts.provider) |p| return zenai.provider.envApiKey(p) != null or (p == .vertex and vertexProjectMode());
    if (remembered) |r| if (r.provider) |p| {
        if (zenai.provider.envApiKey(p) != null) return true;
        if (p == .vertex and vertexProjectMode()) return true;
    };
    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    return availableProviders(&buf).len > 0;
}

/// Precedence: `--provider` > remembered (if its key is still set) > first
/// detected. Null means no key at all (the reason is already printed).
pub fn resolveCredentials(allocator: std.mem.Allocator, opts: Config.Agent, remembered: ?Remembered, allow_pick: bool) !?ResolvedProvider {
    if (opts.provider) |p| {
        if (p == .vertex and vertexProjectMode()) {
            const token = try gcloudAccessToken(allocator);
            return .{ .credentials = .{ .provider = p, .key = token }, .source = .flag, .key_owned = true };
        }
        const key = zenai.provider.envApiKey(p) orelse {
            if (p == .vertex) {
                std.debug.print(
                    "Vertex needs VERTEX_API_KEY (express mode) or GOOGLE_CLOUD_PROJECT (project mode, token via gcloud) — or pass --no-llm for the basic REPL.\n",
                    .{},
                );
                return error.MissingApiKey;
            }
            std.debug.print(
                "Missing API key for --provider {s}: set {s} — or pass --no-llm for the basic REPL.\n",
                .{ @tagName(p), zenai.provider.envVarName(p) },
            );
            return error.MissingApiKey;
        };
        return .{ .credentials = .{ .provider = p, .key = key }, .source = .flag };
    }

    if (remembered) |r| if (r.provider) |p| {
        if (p == .vertex and vertexProjectMode()) {
            // On failure the reason is already printed; fall through to detection.
            if (gcloudAccessToken(allocator)) |token| {
                return .{ .credentials = .{ .provider = p, .key = token }, .source = .remembered, .key_owned = true };
            } else |_| {}
        } else if (zenai.provider.envApiKey(p)) |key| {
            return .{ .credentials = .{ .provider = p, .key = key }, .source = .remembered };
        }
    };

    var buf: [zenai.provider.default_candidates.len]Credentials = undefined;
    const found = availableProviders(&buf);
    if (found.len == 0) {
        if (detectLocalProvider(allocator, .ollama, opts.base_url)) |creds| {
            return .{ .credentials = creds, .source = .detected };
        }
        if (detectLocalProvider(allocator, .llama_cpp, opts.base_url)) |creds| {
            return .{ .credentials = creds, .source = .detected };
        }
        std.debug.print(
            \\No API key detected. Set {s}, or run a local Ollama or llama.cpp server with a loaded model.
            \\To use the basic REPL (without LLM integration), pass the --no-llm option.
            \\
        , .{api_keys_hint});
        return null;
    }
    // A single key needs no choice; non-interactive callers (--list-models,
    // one-shot tasks, pipes) must not block on a prompt — take the first.
    if (!allow_pick or found.len == 1 or !Terminal.interactiveTty()) {
        return try finishResolved(allocator, found[0], .detected);
    }

    var names: [zenai.provider.default_candidates.len][:0]const u8 = undefined;
    for (found, 0..) |cred, i| names[i] = @tagName(cred.provider);
    std.debug.print("\n", .{});
    const idx = Terminal.promptNumberedChoice("  Select a provider:", names[0..found.len], 0) catch {
        return try finishResolved(allocator, found[0], .detected);
    };
    return try finishResolved(allocator, found[idx], .picked);
}

/// Swaps the placeholder key of a detected project-mode Vertex for a real
/// gcloud token.
fn finishResolved(allocator: std.mem.Allocator, credentials: Credentials, source: @FieldType(ResolvedProvider, "source")) !ResolvedProvider {
    if (credentials.provider == .vertex and vertexProjectMode()) {
        const token = try gcloudAccessToken(allocator);
        return .{ .credentials = .{ .provider = .vertex, .key = token }, .source = source, .key_owned = true };
    }
    return .{ .credentials = credentials, .source = source };
}

pub const remembered_path = ".lp-agent.zon";

/// Last user-selected provider/model/effort/verbosity, persisted per-directory
/// in `.lp-agent.zon`. `model` is caller-owned. A null `provider` means the user
/// disabled the LLM (`/provider null`), so the REPL starts in basic mode without
/// re-prompting. `effort`/`verbosity` are optional so files predating them still
/// parse; null means "use the mode default" (see `Agent.resolveEffort` /
/// `Agent.resolveVerbosity`). `stream` is likewise optional: null means "use the
/// default" (see `resolveStream`).
pub const Remembered = struct {
    provider: ?Config.AiProvider = null,
    model: []const u8,
    effort: ?Config.Effort = null,
    verbosity: ?Config.AgentVerbosity = null,
    stream: ?bool = null,
};

pub fn loadRemembered(allocator: std.mem.Allocator) ?Remembered {
    const data = std.fs.cwd().readFileAllocOptions(allocator, remembered_path, 1024, null, .of(u8), 0) catch return null;
    defer allocator.free(data);
    return parseRemembered(allocator, data);
}

fn parseRemembered(allocator: std.mem.Allocator, data: [:0]const u8) ?Remembered {
    // A real Diagnostics, not null: a type-check failure allocates an owned
    // error note that leaks unless a Diagnostics owns it to free on deinit.
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    const remembered = std.zon.parse.fromSlice(Remembered, allocator, data, &diag, .{}) catch return null;
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
/// a live probe (`detectLocalProvider`), too costly for an unconditional startup scan.
/// Vertex project mode joins with a placeholder key — no subprocess during a
/// scan; the gcloud token is fetched on selection (`finishResolved`).
pub fn availableProviders(buf: []Credentials) []Credentials {
    const found = zenai.provider.detectKeys(buf, zenai.provider.default_candidates);
    if (zenai.provider.useVertex() and vertexProjectMode() and found.len < buf.len) {
        buf[found.len] = .{ .provider = .vertex, .key = "" };
        return buf[0 .. found.len + 1];
    }
    return found;
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
/// provider default > mode default. The interactive REPL defaults to `.low` so
/// turns stay snappy; one-shot `--task` defaults to `.medium`, where answer
/// quality matters more than per-turn latency. (Script runs never call the LLM,
/// so the resolved effort is unused there.)
pub fn resolveEffort(opts: Config.Agent, remembered: ?Remembered, will_repl: bool, provider: ?Config.AiProvider) Config.Effort {
    if (opts.effort) |e| return e;
    if (remembered) |r| if (r.effort) |e| return e;
    if (provider) |p| if (zenai.provider.defaultEffort(p)) |e| return e;
    return if (will_repl) .low else .medium;
}

/// Precedence: explicit `--verbosity` flag > remembered `.lp-agent.zon` value >
/// mode default (see `Config.agentVerbosity`).
pub fn resolveVerbosity(opts: Config.Agent, remembered: ?Remembered) Config.AgentVerbosity {
    if (opts.verbosity) |v| return v;
    if (remembered) |r| if (r.verbosity) |v| return v;
    return Config.agentVerbosity(opts);
}

/// Precedence: remembered `.lp-agent.zon` value > default (on). Streaming has no
/// CLI flag — the REPL `/stream` command toggles and persists it.
pub fn resolveStream(remembered: ?Remembered) bool {
    if (remembered) |r| if (r.stream) |s| return s;
    return true;
}

pub const ReconciledModel = union(enum) {
    /// Owned by the allocator passed to reconcileModel.
    use: []u8,
    abort,
};

/// Validate `desired` against the provider's catalog, mirroring the interactive
/// `/model` command. Empty list (unreachable server) leaves it unchecked; an
/// explicit unlisted model is fatal. The local servers (Ollama, llama.cpp) have
/// authoritative catalogs, so their default is substituted with the first served
/// model when unloaded; cloud defaults are hardcoded real models, trusted as-is.
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
        switch (llm.provider) {
            .ollama, .llama_cpp => {},
            else => return .{ .use = try allocator.dupe(u8, desired) },
        }
        std.debug.print("Default {s} model '{s}' is not loaded; using '{s}'.\n", .{ @tagName(llm.provider), desired, ids[0] });
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

const testing = @import("../testing.zig");

test "parseRemembered: invalid enum is rejected without leaking" {
    // A bad enum builds an owned error note; the leak detector fails here if
    // the Diagnostics doesn't free it.
    try testing.expect(parseRemembered(testing.allocator, ".{ .provider = .not_a_provider, .model = \"x\" }") == null);
}

test "parseRemembered: valid file round-trips" {
    const remembered = parseRemembered(testing.allocator, ".{ .provider = null, .model = \"some-model\" }").?;
    defer std.zon.parse.free(testing.allocator, remembered);
    try testing.expect(remembered.provider == null);
    try testing.expectString("some-model", remembered.model);
    // Absent `stream` is null so pre-streaming files still fall back to the default.
    try testing.expect(remembered.stream == null);
}

test "parseRemembered: stream field round-trips" {
    const remembered = parseRemembered(testing.allocator, ".{ .model = \"m\", .stream = false }").?;
    defer std.zon.parse.free(testing.allocator, remembered);
    try testing.expect(remembered.stream == false);
}

test "resolveStream: default on, remembered wins" {
    try testing.expect(resolveStream(null));
    try testing.expect(resolveStream(.{ .model = "m", .stream = null }));
    try testing.expect(resolveStream(.{ .model = "m", .stream = true }));
    try testing.expect(!resolveStream(.{ .model = "m", .stream = false }));
}

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
const picker = @import("picker.zig");
const string = @import("../string.zig");
const auth = @import("auth/auth.zig");
const Candidate = zenai.provider.Candidate;

pub const api_keys_hint = "ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, HF_TOKEN, AI_GATEWAY_API_KEY, or MISTRAL_API_KEY (Vertex AI: VERTEX_API_KEY, or GOOGLE_CLOUD_PROJECT via gcloud; Codex: a ChatGPT subscription via /provider codex)";

/// Determine which provider to use and read its env key. Returns null
/// only when no `--provider` was given AND no env key exists (the caller
/// decides whether that's fatal — basic REPL tolerates it).
pub const ResolvedProvider = struct {
    credential: Credential,
    source: enum { flag, remembered, detected, picked },
};

/// The provider credential in effect: the key lives in exactly one place —
/// inside the variant that owns it. The AI client borrows `keySlice()`, so
/// deinit only after that client is gone.
pub const Credential = struct {
    provider: Config.AiProvider,
    key: union(enum) {
        /// Unowned env-var pointer.
        env: [:0]const u8,
        /// Allocated key (Vertex gcloud token).
        owned: [:0]const u8,
        /// Subscription (bearer) auth; the key is the access token, refreshed
        /// between turns.
        session: auth.Session,
    },

    pub fn keySlice(self: *const Credential) [:0]const u8 {
        return switch (self.key) {
            .env, .owned => |k| k,
            .session => |*s| s.tokens.access_token,
        };
    }

    pub fn accountId(self: *const Credential) ?[]const u8 {
        return switch (self.key) {
            .session => |*s| s.tokens.account_id,
            else => null,
        };
    }

    pub fn deinit(self: *Credential, allocator: std.mem.Allocator) void {
        switch (self.key) {
            .env => {},
            .owned => |k| allocator.free(k),
            .session => |*s| s.deinit(),
        }
    }
};

/// Probe a keyless local provider (Ollama, llama.cpp): its env key is a
/// placeholder, so the only honest availability signal is the server answering
/// `/v1/models` with a loaded model. Null means no server responded.
pub fn detectLocalProvider(allocator: std.mem.Allocator, tag: Config.AiProvider, base_url: ?[:0]const u8) ?Candidate {
    const key = zenai.provider.envApiKey(lp.environ(), tag) orelse return null;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = zenai.provider.listChatModelIds(lp.io, allocator, arena.allocator(), tag, key, .{ .base_url = base_url, .environ = lp.environ() }) catch return null;
    if (ids.len == 0) return null;
    return .{ .provider = tag, .key = key };
}

/// With GOOGLE_CLOUD_PROJECT set, zenai's client always sends Bearer auth —
/// an API key can never work, so the credential must be an OAuth token.
pub fn vertexProjectMode() bool {
    return std.c.getenv("GOOGLE_CLOUD_PROJECT") != null;
}

/// Caller owns the result. Failure prints gcloud's own stderr so the real
/// cause (not logged in, missing SDK) reaches the user.
pub fn gcloudAccessToken(allocator: std.mem.Allocator) ![:0]const u8 {
    // gcloud needs the real environment (HOME for its config).
    var environ_map = try lp.environMap(allocator);
    defer environ_map.deinit();

    const result = std.process.run(allocator, lp.io, .{
        .argv = &.{ "gcloud", "auth", "print-access-token" },
        .environ_map = &environ_map,
        .stdout_limit = .limited(64 * 1024),
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
        .exited => |code| code != 0,
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
    if (opts.provider) |p| return detectableKey(p);
    if (remembered) |r| if (r.provider) |p| if (detectableKey(p)) return true;
    var buf: [zenai.provider.default_candidates.len]Candidate = undefined;
    return availableProviders(&buf).len > 0;
}

fn detectableKey(p: Config.AiProvider) bool {
    return zenai.provider.envApiKey(lp.environ(), p) != null or
        (p == .vertex and vertexProjectMode()) or
        auth.subscriptionAvailable(p);
}

/// Precedence: `--provider` > remembered (if its key is still set) > first
/// detected. Null means no key at all (the reason is already printed).
pub fn resolveCredentials(allocator: std.mem.Allocator, opts: Config.Agent, remembered: ?Remembered, allow_pick: bool) !?ResolvedProvider {
    if (opts.provider) |p| {
        if (p == .vertex and vertexProjectMode()) {
            const token = try gcloudAccessToken(allocator);
            return .{ .credential = .{ .provider = p, .key = .{ .owned = token } }, .source = .flag };
        }
        // A subscription takes priority over an API key; null = not a
        // subscription provider (or none available), so fall through.
        if (try subscriptionResolved(allocator, p, .flag)) |resolved| return resolved;
        const key = zenai.provider.envApiKey(lp.environ(), p) orelse {
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
        return .{ .credential = .{ .provider = p, .key = .{ .env = key } }, .source = .flag };
    }

    if (remembered) |r| if (r.provider) |p| {
        if (p == .vertex and vertexProjectMode()) {
            // On failure the reason is already printed; fall through to detection.
            if (gcloudAccessToken(allocator)) |token| {
                return .{ .credential = .{ .provider = p, .key = .{ .owned = token } }, .source = .remembered };
            } else |_| {}
        } else {
            // Subscription takes priority over an API key; both fall through to
            // detection on miss.
            if (try subscriptionResolved(allocator, p, .remembered)) |resolved| return resolved;
            if (zenai.provider.envApiKey(lp.environ(), p)) |key| {
                return .{ .credential = .{ .provider = p, .key = .{ .env = key } }, .source = .remembered };
            }
        }
    };

    var buf: [zenai.provider.default_candidates.len]Candidate = undefined;
    const found = availableProviders(&buf);
    if (found.len == 0) {
        if (detectLocalProvider(allocator, .ollama, opts.base_url)) |creds| {
            return .{ .credential = .{ .provider = creds.provider, .key = .{ .env = creds.key } }, .source = .detected };
        }
        if (detectLocalProvider(allocator, .llama_cpp, opts.base_url)) |creds| {
            return .{ .credential = .{ .provider = creds.provider, .key = .{ .env = creds.key } }, .source = .detected };
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
    if (!allow_pick or found.len == 1 or !picker.interactiveTty()) {
        return try finishResolved(allocator, found[0], .detected);
    }

    var names: [zenai.provider.default_candidates.len][:0]const u8 = undefined;
    for (found, 0..) |cred, i| names[i] = @tagName(cred.provider);
    std.debug.print("\n", .{});
    const idx = picker.promptNumberedChoice("  Select a provider:", names[0..found.len], 0) catch {
        return try finishResolved(allocator, found[0], .detected);
    };
    return try finishResolved(allocator, found[idx], .picked);
}

/// Swaps a placeholder credential for a live token: a gcloud token for
/// project-mode Vertex, or a stored subscription session for the subscription
/// (empty-key) placeholder.
fn finishResolved(allocator: std.mem.Allocator, candidate: Candidate, source: @FieldType(ResolvedProvider, "source")) !ResolvedProvider {
    if (candidate.provider == .vertex and vertexProjectMode()) {
        const token = try gcloudAccessToken(allocator);
        return .{ .credential = .{ .provider = .vertex, .key = .{ .owned = token } }, .source = source };
    }
    if (auth.descriptorFor(candidate.provider) != null and candidate.key.len == 0) {
        if (try subscriptionResolved(allocator, candidate.provider, source)) |resolved| return resolved;
        return error.MissingApiKey;
    }
    return .{ .credential = .{ .provider = candidate.provider, .key = .{ .env = candidate.key } }, .source = source };
}

/// Load a stored subscription session and wrap it as a resolved credential.
/// The session owns the key; the caller takes ownership via
/// `ownership.deinit`. Null when the user hasn't logged in.
fn subscriptionResolved(allocator: std.mem.Allocator, provider: Config.AiProvider, source: @FieldType(ResolvedProvider, "source")) !?ResolvedProvider {
    const session = (try auth.sessionFor(allocator, provider)) orelse return null;
    // Name the credential in effect — a set-but-ignored API key would otherwise
    // be a silent surprise.
    if (zenai.provider.envApiKey(lp.environ(), provider) != null) {
        std.debug.print("{s}: using your {s}; {s} is set but the subscription takes priority.\n", .{ @tagName(provider), session.descriptor.label, zenai.provider.envVarName(provider) });
    } else {
        std.debug.print("{s}: using your {s}.\n", .{ @tagName(provider), session.descriptor.label });
    }
    return .{
        .credential = .{ .provider = provider, .key = .{ .session = session } },
        .source = source,
    };
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
    search_engine: ?lp.tools.SearchEngine = null,
};

pub fn loadRemembered(allocator: std.mem.Allocator) ?Remembered {
    const data = std.Io.Dir.cwd().readFileAllocOptions(lp.io, remembered_path, allocator, .limited(1024), .of(u8), 0) catch return null;
    defer allocator.free(data);
    return parseRemembered(allocator, data);
}

fn parseRemembered(allocator: std.mem.Allocator, data: [:0]const u8) ?Remembered {
    // A real Diagnostics, not null: a type-check failure allocates an owned
    // error note that leaks unless a Diagnostics owns it to free on deinit.
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    const remembered = std.zon.parse.fromSliceAlloc(Remembered, allocator, data, &diag, .{}) catch return null;
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
    try std.Io.Dir.cwd().writeFile(lp.io, .{ .sub_path = remembered_path, .data = w.buffered() });
}

/// Cloud providers with a key set. Ollama is excluded — its availability needs
/// a live probe (`detectLocalProvider`), too costly for an unconditional startup scan.
/// Vertex project mode joins with a placeholder key — no subprocess during a
/// scan; the gcloud token is fetched on selection (`finishResolved`).
pub fn availableProviders(buf: []Candidate) []Candidate {
    var found = zenai.provider.detectKeys(lp.environ(), buf, zenai.provider.default_candidates);
    // A subscription takes priority over an API key: offer it as a bearer
    // placeholder (replacing any API-key entry) that `finishResolved` swaps for a
    // live token on selection, mirroring Vertex project mode below.
    for (auth.registry) |desc| {
        if (!auth.subscriptionAvailable(desc.provider)) continue;
        const placeholder: Candidate = .{ .provider = desc.provider, .key = "" };
        if (indexOfProvider(found, desc.provider)) |i| {
            found[i] = placeholder;
        } else if (found.len < buf.len) {
            buf[found.len] = placeholder;
            found = buf[0 .. found.len + 1];
        }
    }
    if (zenai.provider.useVertex(lp.environ()) and vertexProjectMode() and found.len < buf.len) {
        buf[found.len] = .{ .provider = .vertex, .key = "" };
        return buf[0 .. found.len + 1];
    }
    return found;
}

fn indexOfProvider(candidates: []const Candidate, provider: Config.AiProvider) ?usize {
    for (candidates, 0..) |c, i| if (c.provider == provider) return i;
    return null;
}

pub fn resolveModelName(opts: Config.Agent, resolved: ?ResolvedProvider, remembered: ?Remembered) []const u8 {
    if (opts.model) |m| return m;
    if (resolved) |r| {
        // Use the remembered model whenever it matches the chosen provider,
        // not only when the provider itself came from the remembered file.
        if (remembered) |rem| {
            if (rem.provider) |p| if (p == r.credential.provider) return rem.model;
        }
        return zenai.provider.defaultModel(r.credential.provider);
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

/// Precedence: remembered `.lp-agent.zon` value > default (auto). No CLI
/// flag — the REPL `/searchEngine` command sets and persists it.
pub fn resolveSearchEngine(remembered: ?Remembered) lp.tools.SearchEngine {
    if (remembered) |r| if (r.search_engine) |e| return e;
    return .auto;
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
    credential: *const Credential,
    desired: []const u8,
    base_url: ?[:0]const u8,
    explicit: bool,
) !ReconciledModel {
    // A subscription provider can't list models via the provider API; trust the
    // desired model as-is rather than error against `/models`.
    if (auth.descriptorFor(credential.provider) != null) return .{ .use = try allocator.dupe(u8, desired) };

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids: []const []const u8 = zenai.provider.listChatModelIds(lp.io, allocator, arena.allocator(), credential.provider, credential.keySlice(), .{ .base_url = base_url, .environ = lp.environ() }) catch &.{};
    if (ids.len == 0 or string.isOneOf(desired, ids)) return .{ .use = try allocator.dupe(u8, desired) };

    if (!explicit) {
        switch (credential.provider) {
            .ollama, .llama_cpp => {},
            else => return .{ .use = try allocator.dupe(u8, desired) },
        }
        std.debug.print("Default {s} model '{s}' is not loaded; using '{s}'.\n", .{ @tagName(credential.provider), desired, ids[0] });
        return .{ .use = try allocator.dupe(u8, ids[0]) };
    }

    if (credential.provider == .ollama) {
        const installed = std.mem.join(arena.allocator(), ", ", ids) catch "";
        std.debug.print(
            "Model '{s}' is not installed in Ollama.\nInstalled: {s}\nRun `ollama pull {s}` to install it, or choose one of the above.\n",
            .{ desired, installed, desired },
        );
    } else {
        std.debug.print(
            "Model '{s}' is not available for {s}.\nRun with --list-models to see options.\n",
            .{ desired, @tagName(credential.provider) },
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

test "parseRemembered: search_engine field round-trips" {
    const remembered = parseRemembered(testing.allocator, ".{ .model = \"m\", .search_engine = .brave }").?;
    defer std.zon.parse.free(testing.allocator, remembered);
    try testing.expect(remembered.search_engine == .brave);
}

test "resolveSearchEngine: default auto, remembered wins" {
    try testing.expect(resolveSearchEngine(null) == .auto);
    try testing.expect(resolveSearchEngine(.{ .model = "m", .search_engine = null }) == .auto);
    try testing.expect(resolveSearchEngine(.{ .model = "m", .search_engine = .keenable }) == .keenable);
}

test "resolveStream: default on, remembered wins" {
    try testing.expect(resolveStream(null));
    try testing.expect(resolveStream(.{ .model = "m", .stream = null }));
    try testing.expect(resolveStream(.{ .model = "m", .stream = true }));
    try testing.expect(!resolveStream(.{ .model = "m", .stream = false }));
}

test {
    // Pull the auth module tests into the suite (a `const` import alone doesn't).
    _ = @import("auth/auth.zig");
    _ = @import("auth/codex.zig");
    _ = @import("auth/models_dev.zig");
}

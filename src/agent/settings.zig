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

pub const api_keys_hint = "ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, HF_TOKEN, AI_GATEWAY_API_KEY, MISTRAL_API_KEY, OPENROUTER_API_KEY, or XAI_API_KEY (Vertex AI: VERTEX_API_KEY, or GOOGLE_CLOUD_PROJECT via gcloud; Codex: a ChatGPT subscription via /provider codex)";

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

    /// What the AI client talks to: the env's for the provider, with
    /// `base_url` (`--base-url`) over the env's and the subscription's account
    /// id.
    pub fn endpoint(self: *const Credential, base_url: ?[:0]const u8) zenai.provider.Endpoint {
        var ep = zenai.provider.fromEnv(lp.environ(), self.provider).endpoint(self.keySlice());
        if (ep.backend == .codex) ep.backend.codex.account_id = self.accountId();
        if (base_url) |u| ep.base_url = u;
        return ep;
    }

    pub fn defaultModel(self: *const Credential) []const u8 {
        return zenai.provider.defaultModel(self.provider);
    }

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

/// Probe a keyless local provider (Ollama, llama.cpp, LLMD): its env key is a
/// placeholder, so the only honest availability signal is the server answering
/// `/v1/models` with a loaded model. Returns its placeholder key; null means
/// no server responded.
pub fn detectLocalProvider(allocator: std.mem.Allocator, tag: zenai.provider.Tag, base_url: ?[:0]const u8) ?[:0]const u8 {
    const env = zenai.provider.fromEnv(lp.environ(), tag);
    const key = env.key orelse return null;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var ep = env.endpoint(key);
    ep.base_url = base_url;
    const ids = zenai.provider.listChatModelIds(lp.io, allocator, arena.allocator(), ep, .{}) catch return null;
    if (ids.len == 0) return null;
    return key;
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
    return allocator.dupeSentinel(u8, token, 0);
}

/// True when a provider can be selected without a prompt (flag, remembered,
/// or detected). Local servers aren't probed here: startup probes them again
/// when nothing else is found.
pub fn hasDetectableKey(opts: Config.Agent, remembered: ?Remembered) bool {
    if (opts.provider) |p| return available(p);
    if (remembered) |r| if (r.provider) |p| if (available(p)) return true;
    var buf: ProviderBuf = undefined;
    return availableProviders(&buf).len > 0;
}

/// Precedence: `--provider` > remembered (if its credential is still there) >
/// first detected. Null means nothing to use (the reason is already printed).
pub fn resolveCredentials(allocator: std.mem.Allocator, opts: Config.Agent, remembered: ?Remembered, allow_pick: bool) !?ResolvedProvider {
    if (opts.provider) |p| {
        const credential = try credentialFor(allocator, p) orelse {
            std.debug.print("Missing credentials for --provider {s}: set {s}, or pass --no-llm for the basic REPL.\n", .{ @tagName(p), keyHint(p) });
            return error.MissingApiKey;
        };
        return .{ .credential = credential, .source = .flag };
    }

    // A remembered provider that fails (the reason is printed) falls through
    // to detection, which then skips it.
    var failed: ?Config.AiProvider = null;
    if (remembered) |r| if (r.provider) |p| {
        const credential = credentialFor(allocator, p) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                failed = p;
                break :blk null;
            },
        };
        if (credential) |c| return .{ .credential = c, .source = .remembered };
    };

    var buf: ProviderBuf = undefined;
    var found = availableProviders(&buf);
    if (failed) |f| if (std.mem.indexOfScalar(Config.AiProvider, found, f)) |i| {
        std.mem.copyForwards(Config.AiProvider, found[i..], found[i + 1 ..]);
        found.len -= 1;
    };
    if (found.len == 0) {
        for (zenai.provider.local_providers) |local| if (detectLocalProvider(allocator, local, opts.base_url)) |key| {
            return .{ .credential = .{ .provider = local, .key = .{ .env = key } }, .source = .detected };
        };
        std.debug.print(
            \\No API key detected. Set {s}, or run a local Ollama, llama.cpp or LLMD server with a loaded model.
            \\To use the basic REPL (without LLM integration), pass the --no-llm option.
            \\
        , .{api_keys_hint});
        return null;
    }
    // Non-interactive callers (--list-models, one-shot tasks, pipes) must not
    // block on a prompt.
    if (!allow_pick or found.len == 1 or !picker.interactiveTty()) {
        return try detected(allocator, found[0], .detected);
    }

    var names: [detection_order.len][:0]const u8 = undefined;
    for (found, 0..) |p, i| names[i] = @tagName(p);
    std.debug.print("\n", .{});
    const idx = picker.promptNumberedChoice("  Select a provider:", names[0..found.len], 0) catch {
        return try detected(allocator, found[0], .detected);
    };
    return try detected(allocator, found[idx], .picked);
}

fn detected(allocator: std.mem.Allocator, p: Config.AiProvider, source: @FieldType(ResolvedProvider, "source")) !ResolvedProvider {
    const credential = try credentialFor(allocator, p) orelse return error.MissingApiKey;
    return .{ .credential = credential, .source = source };
}

/// The credential for `p` without prompting: a gcloud token for Vertex
/// project mode, a stored subscription (over an API key), else the env key. Null when there is none; on error the reason is printed.
/// Local servers get their placeholder key unprobed.
pub fn credentialFor(allocator: std.mem.Allocator, p: Config.AiProvider) !?Credential {
    if (p == .vertex and vertexProjectMode()) {
        return .{ .provider = p, .key = .{ .owned = try gcloudAccessToken(allocator) } };
    }
    if (try subscriptionCredential(allocator, p)) |c| return c;
    const key = zenai.provider.envApiKey(lp.environ(), p) orelse return null;
    return .{ .provider = p, .key = .{ .env = key } };
}

/// What to set up for `p` when `credentialFor` finds nothing.
pub fn keyHint(p: Config.AiProvider) []const u8 {
    if (p == .vertex) return "VERTEX_API_KEY (express mode) or GOOGLE_CLOUD_PROJECT (project mode, token via gcloud)";
    return zenai.provider.envVarName(p);
}

/// Whether `credentialFor(p)` has something to use, cheaply: no gcloud call,
/// no gateway fetch, no local-server probe. Vertex project mode counts only
/// with GOOGLE_GENAI_USE_VERTEXAI, so a GOOGLE_CLOUD_PROJECT set for other
/// reasons doesn't pick Vertex.
pub fn available(p: Config.AiProvider) bool {
    if (zenai.provider.envApiKey(lp.environ(), p) != null) return true;
    return switch (p) {
        .vertex => zenai.provider.useVertex(lp.environ()) and vertexProjectMode(),
        else => auth.subscriptionAvailable(p),
    };
}

/// Auto-detection order: zenai's env-detectable providers. Local servers
/// need a probe, so they're left out.
const detection_order = zenai.provider.default_candidates;

pub const ProviderBuf = [detection_order.len]Config.AiProvider;

/// The `available` providers, in detection order.
pub fn availableProviders(buf: *ProviderBuf) []Config.AiProvider {
    var n: usize = 0;
    for (detection_order) |p| if (available(p)) {
        buf[n] = p;
        n += 1;
    };
    return buf[0..n];
}

/// A stored subscription session for `provider`; null when it has none. The
/// session owns the key.
fn subscriptionCredential(allocator: std.mem.Allocator, provider: Config.AiProvider) !?Credential {
    const session = (try auth.sessionFor(allocator, provider)) orelse return null;
    // Name the credential in effect: a set-but-ignored API key would otherwise
    // be a silent surprise.
    if (zenai.provider.envApiKey(lp.environ(), provider) != null) {
        std.debug.print("{s}: using your {s}; {s} is set but the subscription takes priority.\n", .{ @tagName(provider), session.descriptor.label, zenai.provider.envVarName(provider) });
    } else {
        std.debug.print("{s}: using your {s}.\n", .{ @tagName(provider), session.descriptor.label });
    }
    return .{ .provider = provider, .key = .{ .session = session } };
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
    search_engine: ?lp.tools.search.Engine = null,
};

/// The result's strings live in `arena`.
pub fn loadRemembered(gpa: std.mem.Allocator, arena: std.mem.Allocator) ?Remembered {
    const data = std.Io.Dir.cwd().readFileAllocOptions(lp.io, remembered_path, gpa, .limited(1024), .of(u8), 0) catch return null;
    defer gpa.free(data);
    return parseRemembered(gpa, arena, data);
}

fn parseRemembered(gpa: std.mem.Allocator, arena: std.mem.Allocator, data: [:0]const u8) ?Remembered {
    var diag: std.zon.parse.Diagnostics = undefined;
    const remembered = std.zon.parse.fromSlice(Remembered, .{
        .gpa = gpa,
        .arena = arena,
        .source = data,
        .diagnostics = &diag,
    }) catch return null;
    // An empty model is corrupt only when a provider is set; a null provider
    // (LLM disabled) legitimately has no model to remember.
    if (remembered.provider != null and remembered.model.len == 0) return null;
    return remembered;
}

/// Best-effort persist of the current selection; failures are ignored.
pub fn saveRemembered(remembered: Remembered) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(remembered, .{}, &w);
    try std.Io.Dir.cwd().writeFile(lp.io, .{ .sub_path = remembered_path, .data = w.buffered() });
}

pub fn resolveModelName(opts: Config.Agent, resolved: ?ResolvedProvider, remembered: ?Remembered) []const u8 {
    if (opts.model) |m| return m;
    if (resolved) |r| {
        // Use the remembered model whenever it matches the chosen provider,
        // not only when the provider itself came from the remembered file.
        if (remembered) |rem| if (rem.provider == r.credential.provider) return rem.model;
        return r.credential.defaultModel();
    }
    return "";
}

/// Precedence: explicit `--effort` flag > remembered `.lp-agent.zon` value >
/// provider default > mode default. The interactive REPL defaults to `.low` so
/// turns stay snappy; one-shot `--task` defaults to `.medium`, where answer
/// quality matters more than per-turn latency. (Script runs never call the LLM,
/// so the resolved effort is unused there.)
pub fn resolveEffort(opts: Config.Agent, remembered: ?Remembered, will_repl: bool, provider: ?zenai.provider.Tag) Config.Effort {
    if (opts.effort) |e| return e;
    if (remembered) |r| if (r.effort) |e| return e;
    if (provider) |p| if (zenai.provider.omitsEffort(p)) return .null;
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

/// Precedence: `--search-engine` > remembered `.lp-agent.zon` value >
/// default (auto). The REPL `/searchEngine` command also sets and persists it.
pub fn resolveSearchEngine(remembered: ?Remembered) lp.tools.search.Engine {
    if (remembered) |r| if (r.search_engine) |e| return e;
    return .auto;
}

/// Validate `desired` against the provider's catalog, mirroring the interactive
/// `/model` command. Empty list (unreachable server) leaves it unchecked; an
/// explicit unlisted model is fatal. The local servers (Ollama, llama.cpp, LLMD) have
/// authoritative catalogs, so their default is substituted with the first served
/// model when unloaded; cloud defaults are hardcoded real models, trusted as-is.
pub fn reconcileModel(
    allocator: std.mem.Allocator,
    credential: *const Credential,
    desired: []const u8,
    base_url: ?[:0]const u8,
    explicit: bool,
) ![]u8 {
    // A subscription provider can't list models via the provider API; trust the
    // desired model as-is rather than error against `/models`.
    if (auth.descriptorFor(credential.provider) != null) return try allocator.dupe(u8, desired);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const endpoint = credential.endpoint(base_url);
    const ids: []const []const u8 = zenai.provider.listChatModelIds(lp.io, allocator, arena.allocator(), endpoint, .{}) catch &.{};
    if (ids.len == 0 or string.isOneOf(desired, ids)) return try allocator.dupe(u8, desired);

    if (!explicit) {
        if (!zenai.provider.info(endpoint.tag()).local) return try allocator.dupe(u8, desired);
        std.debug.print("Default {s} model '{s}' is not loaded; using '{s}'.\n", .{ @tagName(credential.provider), desired, ids[0] });
        return try allocator.dupe(u8, ids[0]);
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
    return error.ModelNotAvailable;
}

const testing = @import("../testing.zig");

test "parseRemembered: invalid enum is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parseRemembered(testing.allocator, arena.allocator(), ".{ .provider = .not_a_provider, .model = \"x\" }") == null);
}

test "parseRemembered: valid file round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const remembered = parseRemembered(testing.allocator, arena.allocator(), ".{ .provider = null, .model = \"some-model\" }").?;
    try testing.expect(remembered.provider == null);
    try testing.expectString("some-model", remembered.model);
    // Absent `stream` is null so pre-streaming files still fall back to the default.
    try testing.expect(remembered.stream == null);
}

test "parseRemembered: stream field round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const remembered = parseRemembered(testing.allocator, arena.allocator(), ".{ .model = \"m\", .stream = false }").?;
    try testing.expect(remembered.stream == false);
}

test "parseRemembered: search_engine field round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const remembered = parseRemembered(testing.allocator, arena.allocator(), ".{ .model = \"m\", .search_engine = .brave }").?;
    try testing.expect(remembered.search_engine == .brave);
}

test "parseRemembered: effort .null round-trips as a value, not an absent field" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(Remembered{ .model = "m", .effort = .null }, .{}, &w);
    var src: [257]u8 = undefined;
    @memcpy(src[0..w.buffered().len], w.buffered());
    src[w.buffered().len] = 0;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const remembered = parseRemembered(testing.allocator, arena.allocator(), src[0..w.buffered().len :0]).?;
    try testing.expect(remembered.effort.? == .null);
}

test "resolveSearchEngine: default auto, remembered wins" {
    try testing.expect(resolveSearchEngine(null) == .auto);
    try testing.expect(resolveSearchEngine(.{ .model = "m", .search_engine = null }) == .auto);
    try testing.expect(resolveSearchEngine(.{ .model = "m", .search_engine = .keenable }) == .keenable);
}

test "resolveEffort: explicit null wins, Mistral omits by default" {
    try testing.expect(resolveEffort(.{}, null, true, .anthropic) == .low);
    try testing.expect(resolveEffort(.{}, null, false, .anthropic) == .medium);
    try testing.expect(resolveEffort(.{}, null, true, .mistral) == .null);
    try testing.expect(resolveEffort(.{ .effort = .high }, null, true, .mistral) == .high);
    try testing.expect(resolveEffort(.{ .effort = .null }, .{ .model = "m", .effort = .high }, true, .anthropic) == .null);
    try testing.expect(resolveEffort(.{}, .{ .model = "m", .effort = .null }, true, .anthropic) == .null);
    try testing.expect(Config.Effort.null.level() == null);
    try testing.expect(Config.Effort.xhigh.level().? == .xhigh);
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

const std = @import("std");
const zenai = @import("zenai");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const ProviderKind = zenai.provider.ProviderKind;

/// List the models usable with the lightpanda agent for `provider` and print
/// their IDs to stdout, one per line, sorted alphabetically. Returns
/// `error.MissingApiKey` when the provider's env var isn't set; other errors
/// propagate from the underlying HTTP call.
///
/// Filtering uses each provider's `isChatModel` predicate from zenai.
/// Ollama is unfiltered — local catalogs don't follow a naming convention
/// the heuristic could rely on.
pub fn run(allocator: Allocator, provider: ProviderKind, base_url_override: ?[:0]const u8) !void {
    const api_key = zenai.provider.envApiKey(provider) orelse {
        log.fatal(.app, "missing API key", .{
            .provider = @tagName(provider),
            .env = switch (provider) {
                .anthropic => "ANTHROPIC_API_KEY",
                .openai => "OPENAI_API_KEY",
                .gemini => "GOOGLE_API_KEY or GEMINI_API_KEY",
                .ollama => "(none)",
            },
        });
        return error.MissingApiKey;
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ids: std.ArrayList([]const u8) = .empty;

    switch (provider) {
        .anthropic => {
            var client = zenai.anthropic.Client.init(allocator, api_key, .{});
            defer client.deinit();
            var resp = try client.listModels();
            defer resp.deinit();
            for (resp.value.data orelse &.{}) |m| {
                if (!zenai.anthropic.Client.isChatModel(m)) continue;
                if (m.id) |id| try ids.append(arena, try arena.dupe(u8, id));
            }
        },
        .openai => {
            var client = zenai.openai.Client.init(allocator, api_key, if (base_url_override) |u| .{ .base_url = u } else .{});
            defer client.deinit();
            var resp = try client.listModels();
            defer resp.deinit();
            for (resp.value.data orelse &.{}) |m| {
                if (!zenai.openai.Client.isChatModel(m)) continue;
                if (m.id) |id| try ids.append(arena, try arena.dupe(u8, id));
            }
        },
        .ollama => {
            const opts: zenai.openai.Client.InitOptions = if (base_url_override) |u|
                .{ .base_url = u }
            else
                .{ .base_url = "http://localhost:11434/v1" };
            var client = zenai.openai.Client.init(allocator, api_key, opts);
            defer client.deinit();
            var resp = try client.listModels();
            defer resp.deinit();
            for (resp.value.data orelse &.{}) |m| {
                if (m.id) |id| try ids.append(arena, try arena.dupe(u8, id));
            }
        },
        .gemini => {
            var client = zenai.gemini.Client.init(allocator, api_key, .{});
            defer client.deinit();
            var resp = try client.listModels(.{});
            defer resp.deinit();
            for (resp.value.models orelse &.{}) |m| {
                if (!zenai.gemini.Client.isChatModel(m)) continue;
                const name = m.name orelse continue;
                // Gemini returns "models/<id>"; strip the prefix so the
                // output is pipe-ready into `--model`.
                const stripped = if (std.mem.startsWith(u8, name, "models/")) name["models/".len..] else name;
                try ids.append(arena, try arena.dupe(u8, stripped));
            }
        },
    }

    std.mem.sort([]const u8, ids.items, {}, lessThan);

    var stdout_file = std.fs.File.stdout().writer(&.{});
    const w = &stdout_file.interface;
    for (ids.items) |id| try w.print("{s}\n", .{id});
    try w.flush();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

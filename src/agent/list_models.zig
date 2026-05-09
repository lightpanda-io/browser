const std = @import("std");
const zenai = @import("zenai");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const ProviderKind = zenai.provider.ProviderKind;

/// List the chat-capable models for `provider` and print their IDs to stdout,
/// one per line, sorted. The per-provider listing logic lives in
/// `zenai.provider.listChatModelIds`.
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
    const ids = try zenai.provider.listChatModelIds(allocator, arena_state.allocator(), provider, api_key, base_url_override);

    var stdout_file = std.fs.File.stdout().writer(&.{});
    const w = &stdout_file.interface;
    for (ids) |id| try w.print("{s}\n", .{id});
    try w.flush();
}

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

//! Model catalog from models.dev — the free, unauthenticated registry opencode
//! uses. It lets a subscription (bearer) user list a provider's models without
//! an API key, and stays current upstream instead of drifting like a hardcoded
//! list. The full `api.json` is a few MB, so only each provider's id list is
//! cached on disk (`<app_dir>/models-dev-<provider>.json`) with a TTL; the big
//! payload is parsed transiently on refresh.

const std = @import("std");
const lp = @import("lightpanda");
const auth = @import("auth.zig");

const api_url = "https://models.dev/api.json";
const cache_ttl_ms: i64 = 24 * std.time.ms_per_hour;

/// Chat-model ids for `provider_id` from models.dev, allocated in `arena`.
/// Serves a fresh on-disk cache, else fetches and refreshes it, falling back
/// to an expired cache when the fetch fails. Empty only when nothing is
/// available, so callers degrade to accepting a typed-in model name.
pub fn modelIds(arena: std.mem.Allocator, provider_id: []const u8, app_dir: ?[]const u8) []const []const u8 {
    const cached: ?Cache = if (app_dir) |dir| readCache(arena, dir, provider_id) else null;
    if (cached) |c| if (auth.nowMs() - c.fetched_ms <= cache_ttl_ms) return c.ids;
    const stale: []const []const u8 = if (cached) |c| c.ids else &.{};

    const catalog = fetch(arena) catch return stale;
    const ids = parseProviderModels(arena, catalog, provider_id) catch return stale;
    if (app_dir) |dir| writeCache(arena, dir, provider_id, ids) catch {};
    return ids;
}

const Cache = struct {
    fetched_ms: i64,
    ids: []const []const u8,
};

fn cachePath(arena: std.mem.Allocator, app_dir: []const u8, provider_id: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(arena, "models-dev-{s}.json", .{provider_id});
    return std.fs.path.join(arena, &.{ app_dir, name });
}

fn readCache(arena: std.mem.Allocator, app_dir: []const u8, provider_id: []const u8) ?Cache {
    const path = cachePath(arena, app_dir, provider_id) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena, .limited(1024 * 1024)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(Cache, arena, data, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.ids.len == 0) return null;
    return parsed;
}

fn writeCache(arena: std.mem.Allocator, app_dir: []const u8, provider_id: []const u8, ids: []const []const u8) !void {
    const path = try cachePath(arena, app_dir, provider_id);
    try auth.writeJsonAtomic(path, Cache{ .fetched_ms = auth.nowMs(), .ids = ids }, .default_file);
}

/// Model-id keys of `catalog[provider_id].models`, filtered to tool-call-capable
/// models (the agent needs tools; this also drops embedding/image entries).
/// `ignore_unknown_fields` skips the rest of the metadata, so no Value tree is
/// built for the multi-MB payload, but the parsed id map accumulates in
/// `arena`. The ids may alias `catalog`.
fn parseProviderModels(arena: std.mem.Allocator, catalog: []const u8, provider_id: []const u8) ![]const []const u8 {
    const Model = struct { tool_call: bool = false };
    const Provider = struct { models: std.json.ArrayHashMap(Model) = .{} };
    const parsed = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Provider), arena, catalog, .{ .ignore_unknown_fields = true });

    const provider = parsed.map.get(provider_id) orelse return error.ProviderMissing;
    var ids: std.ArrayList([]const u8) = .empty;
    var it = provider.models.map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.tool_call) try ids.append(arena, entry.key_ptr.*);
    }
    return ids.toOwnedSlice(arena);
}

test "parseProviderModels filters to tool-call models" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const catalog =
        \\{"openai":{"models":{
        \\  "gpt-5.5":{"tool_call":true},
        \\  "text-embedding-3-small":{"tool_call":false},
        \\  "gpt-image-1":{}
        \\}}}
    ;
    const ids = try parseProviderModels(arena.allocator(), catalog, "openai");
    try std.testing.expectEqual(1, ids.len);
    try std.testing.expectEqualStrings("gpt-5.5", ids[0]);
    try std.testing.expectError(error.ProviderMissing, parseProviderModels(arena.allocator(), catalog, "nope"));
}

fn fetch(arena: std.mem.Allocator) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = lp.io };
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{ .location = .{ .url = api_url }, .response_writer = &out.writer });
    if (res.status != .ok) return error.HttpStatus;
    return out.written();
}

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

/// Chat-model ids for `provider_id` from models.dev, allocated in `arena`. Reads
/// a fresh on-disk cache when present, else fetches and refreshes it. Returns an
/// empty slice on any failure (offline, parse error, no cache) so callers
/// degrade to accepting a typed-in model name.
pub fn modelIds(arena: std.mem.Allocator, provider_id: []const u8, app_dir: ?[]const u8) []const []const u8 {
    if (app_dir) |dir| {
        if (readCache(arena, dir, provider_id)) |ids| return ids;
    }
    const catalog = fetch(arena) catch return &.{};
    const ids = parseProviderModels(arena, catalog, provider_id) catch return &.{};
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

fn readCache(arena: std.mem.Allocator, app_dir: []const u8, provider_id: []const u8) ?[]const []const u8 {
    const path = cachePath(arena, app_dir, provider_id) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena, .limited(1024 * 1024)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(Cache, arena, data, .{ .ignore_unknown_fields = true }) catch return null;
    if (auth.nowMs() - parsed.fetched_ms > cache_ttl_ms) return null;
    if (parsed.ids.len == 0) return null;
    return parsed.ids;
}

fn writeCache(arena: std.mem.Allocator, app_dir: []const u8, provider_id: []const u8, ids: []const []const u8) !void {
    const path = try cachePath(arena, app_dir, provider_id);
    var af = try std.Io.Dir.cwd().createFileAtomic(lp.io, path, .{ .replace = true });
    defer af.deinit(lp.io);
    var buf: [1024]u8 = undefined;
    var w = af.file.writer(lp.io, &buf);
    try std.json.Stringify.value(Cache{ .fetched_ms = auth.nowMs(), .ids = ids }, .{}, &w.interface);
    try w.end();
    try af.replace(lp.io);
}

/// Model-id keys of `catalog[provider_id].models`, filtered to tool-call-capable
/// models (the agent needs tools; this also drops embedding/image entries).
/// `ignore_unknown_fields` skips the rest of the metadata, so no Value tree is
/// built for the multi-MB payload. The parse runs in a scoped arena; the ids
/// are duped into `arena`.
fn parseProviderModels(arena: std.mem.Allocator, catalog: []const u8, provider_id: []const u8) ![]const []const u8 {
    var parse_arena: std.heap.ArenaAllocator = .init(arena);
    defer parse_arena.deinit();

    const Model = struct { tool_call: bool = false };
    const Provider = struct { models: std.json.ArrayHashMap(Model) = .{} };
    const parsed = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Provider), parse_arena.allocator(), catalog, .{ .ignore_unknown_fields = true });

    const provider = parsed.map.get(provider_id) orelse return error.ProviderMissing;
    var ids: std.ArrayList([]const u8) = .empty;
    var it = provider.models.map.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.tool_call) continue;
        try ids.append(arena, try arena.dupe(u8, entry.key_ptr.*));
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

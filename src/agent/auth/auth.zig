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

//! Provider-agnostic subscription (OAuth) auth for the agent. A `Descriptor`
//! names a provider plus its `loginFn`/`refreshFn` hooks (implemented per
//! provider, e.g. `codex.zig`); this module owns the on-disk token store (in the
//! app data dir) and the `Session` lifecycle (refresh-on-expiry with silent
//! persistence). The AI client borrows `Session.tokens.access_token`, so a
//! session must outlive it.

const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;
const zenai = @import("zenai");
const Config = lp.Config;
const codex = @import("codex.zig");

/// Wall-clock ms since the Unix epoch.
pub fn nowMs() i64 {
    return @intCast(lp.datetime.milliTimestamp(.real));
}

/// Resolve the app data dir into `arena`, for callers without an `App` (the
/// store wrappers, `--list-models`). Null when no home is resolvable.
pub fn dataDir(arena: std.mem.Allocator) ?[]const u8 {
    return lp.App.getAppDataDir(arena, "lightpanda") catch null;
}

/// An OAuth credential set. `account_id` is a provider-specific extra (Codex's
/// ChatGPT account id from the JWT); null when the provider has none.
pub const TokenSet = struct {
    access_token: [:0]const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,
    account_id: ?[]const u8 = null,

    pub fn dup(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, expires_at_ms: i64, account_id: ?[]const u8) !TokenSet {
        const a = try allocator.dupeZ(u8, access);
        errdefer allocator.free(a);
        const r = try allocator.dupe(u8, refresh);
        errdefer allocator.free(r);
        const id = if (account_id) |v| try allocator.dupe(u8, v) else null;
        return .{ .access_token = a, .refresh_token = r, .expires_at_ms = expires_at_ms, .account_id = id };
    }

    pub fn deinit(self: TokenSet, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        if (self.account_id) |v| allocator.free(v);
    }
};

/// Per-provider login/refresh implementations; OAuth endpoints and client ids
/// live in the implementing file.
pub const Descriptor = struct {
    provider: Config.AiProvider,
    /// Provider key in the models.dev catalog (subscription backends have no
    /// entry of their own; codex's models are listed under "openai").
    models_dev_id: []const u8,
    /// Human label for the credential, e.g. "ChatGPT subscription".
    label: []const u8,
    /// Interactive login (device-code flow); returns freshly-minted tokens.
    /// Firing `interrupt` aborts the flow with `error.LoginCancelled`.
    loginFn: *const fn (std.mem.Allocator, interrupt: ?*zenai.http.Interrupt) anyerror!TokenSet,
    /// Exchange a refresh token for a new `TokenSet` (with re-derived account id).
    refreshFn: *const fn (std.mem.Allocator, refresh_token: []const u8) anyerror!TokenSet,
};

pub const registry = [_]*const Descriptor{&codex.descriptor};

pub fn descriptorFor(provider: Config.AiProvider) ?*const Descriptor {
    for (registry) |d| if (d.provider == provider) return d;
    return null;
}

// --- On-disk token store: <data_dir>/auth.json, a JSON map keyed by provider tag ---
// The `*At` variants take a scratch arena and an explicit dir (unit-testable);
// the public wrappers build the arena and resolve the app data dir themselves.

const StoredToken = struct {
    access: []const u8,
    refresh: []const u8,
    expires_at_ms: i64,
    account_id: ?[]const u8 = null,
};

fn storePath(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, "auth.json" });
}

/// The parsed store; empty on any failure (absent, unreadable, malformed).
fn readStoreFile(arena: std.mem.Allocator, path: []const u8) std.json.ArrayHashMap(StoredToken) {
    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena, .limited(64 * 1024)) catch return .{};
    return std.json.parseFromSliceLeaky(std.json.ArrayHashMap(StoredToken), arena, data, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Serialize `value` as JSON to `path` via temp+rename, so a failed write
/// can't corrupt an existing file.
pub fn writeJsonAtomic(path: []const u8, value: anytype, permissions: std.Io.File.Permissions) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(lp.io, path, .{ .permissions = permissions, .replace = true });
    defer af.deinit(lp.io);
    var buf: [1024]u8 = undefined;
    var w = af.file.writer(lp.io, &buf);
    try std.json.Stringify.value(value, .{}, &w.interface);
    try w.end();
    try af.replace(lp.io);
}

fn storeLoadAt(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) !?TokenSet {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try storePath(a, dir);
    const t = readStoreFile(a, path).map.get(id) orelse return null;
    return try TokenSet.dup(allocator, t.access, t.refresh, t.expires_at_ms, t.account_id);
}

fn storeSaveAt(arena: std.mem.Allocator, dir: []const u8, id: []const u8, tokens: TokenSet) !void {
    const path = try storePath(arena, dir);
    var map = readStoreFile(arena, path);
    try map.map.put(arena, id, .{
        .access = tokens.access_token,
        .refresh = tokens.refresh_token,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = tokens.account_id,
    });
    // Secrets file: owner-only perms.
    try writeJsonAtomic(path, map, .fromMode(0o600));
}

fn storeDeleteAt(arena: std.mem.Allocator, dir: []const u8, id: []const u8) !void {
    const path = try storePath(arena, dir);
    var map = readStoreFile(arena, path);
    if (!map.map.swapRemove(id)) return;
    try writeJsonAtomic(path, map, .fromMode(0o600));
}

/// Remove the stored token for `id`. No-op when absent.
fn storeDelete(allocator: std.mem.Allocator, id: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = dataDir(a) orelse return error.NoDataDir;
    return storeDeleteAt(a, dir, id);
}

/// Load the stored token for `id`, or null when absent/unreadable/no data dir.
pub fn storeLoad(allocator: std.mem.Allocator, id: []const u8) !?TokenSet {
    var da: std.heap.ArenaAllocator = .init(allocator);
    defer da.deinit();
    const dir = dataDir(da.allocator()) orelse return null;
    return storeLoadAt(allocator, dir, id);
}

pub fn storeSave(allocator: std.mem.Allocator, id: []const u8, tokens: TokenSet) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = dataDir(a) orelse return error.NoDataDir;
    return storeSaveAt(a, dir, id, tokens);
}

/// Proactive-refresh margin: refresh once the token is within this window of
/// expiry, so a turn never starts on a token about to lapse.
const refresh_skew_ms: i64 = 5 * std.time.ms_per_min;

/// A live subscription credential for one provider. Owns its `TokenSet` and
/// persists refreshed tokens back to the store.
pub const Session = struct {
    allocator: std.mem.Allocator,
    descriptor: *const Descriptor,
    tokens: TokenSet,
    /// The set displaced by the last refresh, kept until the next one (or
    /// deinit) because the AI client borrows the access token until the
    /// caller repoints it.
    displaced: ?TokenSet = null,

    /// When the access token is within `refresh_skew_ms` of expiry, exchange
    /// the refresh token for a new one and persist it. True when `tokens` was
    /// replaced — repoint anything borrowing the old access token.
    pub fn ensureFresh(self: *Session) !bool {
        const now = nowMs();
        if (self.tokens.expires_at_ms - now > refresh_skew_ms) return false;

        const fresh = self.descriptor.refreshFn(self.allocator, self.tokens.refresh_token) catch |err| {
            // A transient refresh failure while the token is still valid is not fatal.
            if (self.tokens.expires_at_ms > now) return false;
            return err;
        };
        storeSave(self.allocator, @tagName(self.descriptor.provider), fresh) catch |err| {
            log.warn(.app, "auth token persist failed", .{ .provider = @tagName(self.descriptor.provider), .err = err });
        };

        if (self.displaced) |old| old.deinit(self.allocator);
        self.displaced = self.tokens;
        self.tokens = fresh;
        return true;
    }

    pub fn deinit(self: *Session) void {
        if (self.displaced) |old| old.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
    }
};

/// Load a stored session for `provider`, or null when the user hasn't logged in.
pub fn sessionFor(allocator: std.mem.Allocator, provider: Config.AiProvider) !?Session {
    const desc = descriptorFor(provider) orelse return null;
    const tokens = (try storeLoad(allocator, @tagName(provider))) orelse return null;
    return .{ .allocator = allocator, .descriptor = desc, .tokens = tokens };
}

/// Run the interactive login and persist the result, returning a live session.
pub fn login(allocator: std.mem.Allocator, desc: *const Descriptor, interrupt: ?*zenai.http.Interrupt) !Session {
    const tokens = try desc.loginFn(allocator, interrupt);
    storeSave(allocator, @tagName(desc.provider), tokens) catch |err| {
        log.warn(.app, "auth token persist failed", .{ .provider = @tagName(desc.provider), .err = err });
    };
    return .{ .allocator = allocator, .descriptor = desc, .tokens = tokens };
}

/// Forget the stored credential for `desc`'s provider.
pub fn logout(allocator: std.mem.Allocator, desc: *const Descriptor) !void {
    return storeDelete(allocator, @tagName(desc.provider));
}

/// Is a stored credential available for `provider` — unexpired, or refreshable
/// (`ensureFresh` runs before the first request)? Lets the picker offer the
/// subscription without an API-key env var.
pub fn subscriptionAvailable(provider: Config.AiProvider) bool {
    if (descriptorFor(provider) == null) return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = dataDir(a) orelse return false;
    const path = storePath(a, dir) catch return false;
    const t = readStoreFile(a, path).map.get(@tagName(provider)) orelse return false;
    return t.refresh.len > 0 or t.expires_at_ms > nowMs();
}

test "TokenSet dup/deinit round-trips and is leak-free" {
    const a = std.testing.allocator;
    const t = try TokenSet.dup(a, "acc", "ref", 123, "acct-1");
    defer t.deinit(a);
    try std.testing.expectEqualStrings("acc", t.access_token);
    try std.testing.expectEqualStrings("ref", t.refresh_token);
    try std.testing.expectEqualStrings("acct-1", t.account_id.?);
    try std.testing.expectEqual(@as(i64, 123), t.expires_at_ms);
}

test "descriptorFor resolves codex, null for a non-OAuth provider" {
    try std.testing.expect(descriptorFor(.codex) != null);
    try std.testing.expectEqual(@as(?*const Descriptor, null), descriptorFor(.openai));
}

test "token store save/load/delete round-trips" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(lp.io, ".", scratch);

    const t = try TokenSet.dup(a, "acc-1", "ref-1", 999, "acct-9");
    defer t.deinit(a);
    try storeSaveAt(scratch, dir, "codex", t);

    const st = try tmp.dir.statFile(lp.io, "auth.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    const loaded = (try storeLoadAt(a, dir, "codex")).?;
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("acc-1", loaded.access_token);
    try std.testing.expectEqualStrings("ref-1", loaded.refresh_token);
    try std.testing.expectEqualStrings("acct-9", loaded.account_id.?);
    try std.testing.expectEqual(@as(i64, 999), loaded.expires_at_ms);

    try storeDeleteAt(scratch, dir, "codex");
    try std.testing.expectEqual(@as(?TokenSet, null), try storeLoadAt(a, dir, "codex"));
}

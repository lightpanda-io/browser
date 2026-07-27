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
//! carries the endpoints plus `loginFn`/`refreshFn` hooks (implemented per
//! provider, e.g. `codex.zig`); this module owns the on-disk token store (in the
//! app data dir) and the `Session` lifecycle (refresh-on-expiry with silent
//! persistence). The AI client borrows `Session.tokens.access_token`, so a
//! session must outlive it.

const std = @import("std");
const lp = @import("lightpanda");
const Config = lp.Config;
const codex = @import("codex.zig");

/// Wall-clock ms since the Unix epoch.
pub fn nowMs() i64 {
    return std.Io.Clock.now(.real, lp.io).toMilliseconds();
}

/// Resolve the app data dir (mirrors `App.getAppDataDir("lightpanda")`) into
/// `arena`. Null when neither XDG_DATA_HOME nor HOME is set.
fn dataDir(arena: std.mem.Allocator) ?[]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
        const x = std.mem.span(xdg);
        if (x.len > 0) return std.fs.path.join(arena, &.{ x, "lightpanda" }) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fs.path.join(arena, &.{ std.mem.span(home), ".local", "share", "lightpanda" }) catch null;
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

/// Static per-provider OAuth configuration plus the login/refresh implementations.
pub const Descriptor = struct {
    provider: Config.AiProvider,
    /// Key in the on-disk store (`auth.json`).
    id: []const u8,
    /// Human label for the credential, e.g. "ChatGPT subscription".
    label: []const u8,
    client_id: []const u8,
    scope: []const u8,
    /// OAuth token endpoint (code exchange + refresh grant).
    token_url: []const u8,
    /// Device-authorization endpoints and the URL the user visits to enter the code.
    device_code_url: []const u8,
    device_token_url: []const u8,
    verify_url: []const u8,
    /// Interactive login (device-code flow); returns freshly-minted tokens.
    loginFn: *const fn (std.mem.Allocator, *const Descriptor) anyerror!TokenSet,
    /// Exchange a refresh token for a new `TokenSet` (with re-derived account id).
    refreshFn: *const fn (std.mem.Allocator, *const Descriptor, []const u8) anyerror!TokenSet,
};

pub const registry = [_]*const Descriptor{&codex.descriptor};

pub fn descriptorFor(provider: Config.AiProvider) ?*const Descriptor {
    for (registry) |d| if (d.provider == provider) return d;
    return null;
}

// --- On-disk token store: <data_dir>/auth.json, a JSON map keyed by descriptor id ---
// The `*At` variants take an explicit dir (unit-testable); the public wrappers
// resolve the app data dir themselves so callers need not thread it.

const StoredToken = struct {
    access: []const u8,
    refresh: []const u8,
    expires_at_ms: i64,
    account_id: ?[]const u8 = null,
};

fn storePath(arena: std.mem.Allocator, dir: []const u8) ![:0]const u8 {
    return std.fs.path.joinZ(arena, &.{ dir, "auth.json" });
}

fn storeLoadAt(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) !?TokenSet {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try storePath(a, dir);
    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, a, .limited(64 * 1024)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(StoredToken), a, data, .{ .ignore_unknown_fields = true }) catch return null;
    const t = parsed.map.get(id) orelse return null;
    return try TokenSet.dup(allocator, t.access, t.refresh, t.expires_at_ms, t.account_id);
}

fn storeSaveAt(dir: []const u8, id: []const u8, tokens: TokenSet) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try storePath(a, dir);

    var map: std.json.ArrayHashMap(StoredToken) = .{};
    if (std.Io.Dir.cwd().readFileAlloc(lp.io, path, a, .limited(64 * 1024))) |data| {
        map = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(StoredToken), a, data, .{ .ignore_unknown_fields = true }) catch .{};
    } else |_| {}
    try map.map.put(a, id, .{
        .access = tokens.access_token,
        .refresh = tokens.refresh_token,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = tokens.account_id,
    });

    var buf: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(map, .{}, &buf.writer);
    try std.Io.Dir.cwd().writeFile(lp.io, .{ .sub_path = path, .data = buf.written() });
    // Secrets file: owner read/write only.
    _ = std.c.chmod(path.ptr, 0o600);
}

fn storeDeleteAt(dir: []const u8, id: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = storePath(a, dir) catch return;
    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, a, .limited(64 * 1024)) catch return;
    var parsed = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(StoredToken), a, data, .{ .ignore_unknown_fields = true }) catch return;
    _ = parsed.map.swapRemove(id);
    var buf: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(parsed, .{}, &buf.writer) catch return;
    std.Io.Dir.cwd().writeFile(lp.io, .{ .sub_path = path, .data = buf.written() }) catch return;
    _ = std.c.chmod(path.ptr, 0o600);
}

/// Load the stored token for `id`, or null when absent/unreadable/no data dir.
pub fn storeLoad(allocator: std.mem.Allocator, id: []const u8) !?TokenSet {
    var da: std.heap.ArenaAllocator = .init(allocator);
    defer da.deinit();
    const dir = dataDir(da.allocator()) orelse return null;
    return storeLoadAt(allocator, dir, id);
}

pub fn storeSave(id: []const u8, tokens: TokenSet) !void {
    var da: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer da.deinit();
    const dir = dataDir(da.allocator()) orelse return error.NoDataDir;
    return storeSaveAt(dir, id, tokens);
}

pub fn storeDelete(id: []const u8) void {
    var da: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer da.deinit();
    const dir = dataDir(da.allocator()) orelse return;
    storeDeleteAt(dir, id);
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
    /// The immediately-prior token, kept alive one refresh cycle so a client
    /// still pointing at it (until `setApiKey`) never dereferences freed memory.
    previous: ?TokenSet = null,

    /// When the access token is within `refresh_skew_ms` of expiry, exchange the
    /// refresh token for a new one, persist it, and return the new access token
    /// (owned by the session). Null when still fresh. The caller must repoint its
    /// client before its next request; the old buffer stays valid until the
    /// following `ensureFresh`/`deinit`.
    pub fn ensureFresh(self: *Session) !?[:0]const u8 {
        const now = nowMs();
        if (self.tokens.expires_at_ms - now > refresh_skew_ms) return null;

        const fresh = self.descriptor.refreshFn(self.allocator, self.descriptor, self.tokens.refresh_token) catch |err| {
            // A transient refresh failure while the token is still valid is not fatal.
            if (self.tokens.expires_at_ms > now) return null;
            return err;
        };
        storeSave(self.descriptor.id, fresh) catch {};

        if (self.previous) |p| p.deinit(self.allocator);
        self.previous = self.tokens;
        self.tokens = fresh;
        return self.tokens.access_token;
    }

    pub fn deinit(self: *Session) void {
        self.tokens.deinit(self.allocator);
        if (self.previous) |p| p.deinit(self.allocator);
        self.previous = null;
    }
};

/// Load a stored session for `provider`, or null when the user hasn't logged in.
pub fn sessionFor(allocator: std.mem.Allocator, provider: Config.AiProvider) !?Session {
    const desc = descriptorFor(provider) orelse return null;
    const tokens = (try storeLoad(allocator, desc.id)) orelse return null;
    return .{ .allocator = allocator, .descriptor = desc, .tokens = tokens };
}

/// Run the interactive login and persist the result, returning a live session.
pub fn login(allocator: std.mem.Allocator, desc: *const Descriptor) !Session {
    const tokens = try desc.loginFn(allocator, desc);
    storeSave(desc.id, tokens) catch {};
    return .{ .allocator = allocator, .descriptor = desc, .tokens = tokens };
}

/// Is a usable (present, not hard-expired) stored token available for `provider`?
/// Lets the picker offer the subscription without an API-key env var.
pub fn subscriptionAvailable(provider: Config.AiProvider) bool {
    const desc = descriptorFor(provider) orelse return false;
    const tokens = (storeLoad(std.heap.page_allocator, desc.id) catch return false) orelse return false;
    defer tokens.deinit(std.heap.page_allocator);
    return tokens.expires_at_ms == 0 or tokens.expires_at_ms > nowMs();
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(lp.io, ".", a);
    defer a.free(dir);

    const t = try TokenSet.dup(a, "acc-1", "ref-1", 999, "acct-9");
    defer t.deinit(a);
    try storeSaveAt(dir, "codex", t);

    const loaded = (try storeLoadAt(a, dir, "codex")).?;
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("acc-1", loaded.access_token);
    try std.testing.expectEqualStrings("ref-1", loaded.refresh_token);
    try std.testing.expectEqualStrings("acct-9", loaded.account_id.?);
    try std.testing.expectEqual(@as(i64, 999), loaded.expires_at_ms);

    storeDeleteAt(dir, "codex");
    try std.testing.expectEqual(@as(?TokenSet, null), try storeLoadAt(a, dir, "codex"));
}

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

//! Provider-agnostic subscription (OAuth bearer) auth for the agent. v1 imports
//! the token a subscription CLI already maintains on disk — Claude Code for
//! `.anthropic` — and re-reads it on expiry, so the agent never calls the OAuth
//! token endpoint and cannot disturb that CLI's own login. The `Descriptor`'s
//! login-endpoint fields are the seam for a future own-OAuth login flow.

const std = @import("std");
const lp = @import("lightpanda");
const Config = lp.Config;
const anthropic = @import("anthropic.zig");

/// Wall-clock ms since the Unix epoch.
pub fn nowMs() i64 {
    return std.Io.Clock.now(.real, lp.io).toMilliseconds();
}

/// An OAuth credential set. `refresh_token`/`expires_at_ms` back expiry handling
/// (and the deferred refresh grant).
pub const TokenSet = struct {
    access_token: [:0]const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,

    pub fn dup(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, expires_at_ms: i64) !TokenSet {
        const a = try allocator.dupeZ(u8, access);
        errdefer allocator.free(a);
        const r = try allocator.dupe(u8, refresh);
        return .{ .access_token = a, .refresh_token = r, .expires_at_ms = expires_at_ms };
    }

    pub fn deinit(self: TokenSet, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

/// Static per-provider OAuth configuration. Adding a provider is a data addition
/// here plus an `importFn`. The login-endpoint fields are the seam for the
/// deferred own-OAuth login flow and are unused in v1.
pub const Descriptor = struct {
    provider: Config.AiProvider,
    id: []const u8,
    /// Human label for the credential, e.g. "Claude subscription".
    label: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    /// Import a subscription token another CLI already maintains on disk.
    importFn: ?*const fn (std.mem.Allocator) anyerror!?TokenSet = null,
};

pub const registry = [_]*const Descriptor{&anthropic.descriptor};

pub fn descriptorFor(provider: Config.AiProvider) ?*const Descriptor {
    for (registry) |d| if (d.provider == provider) return d;
    return null;
}

/// Proactive-refresh margin: re-check the source once the token is within this
/// window of expiry, so a turn never starts on a token about to lapse.
const refresh_skew_ms: i64 = 5 * std.time.ms_per_min;

/// A live subscription credential for one provider. Owns its `TokenSet`; the AI
/// client borrows `tokens.access_token`, so the session must outlive the client.
pub const Session = struct {
    allocator: std.mem.Allocator,
    descriptor: *const Descriptor,
    tokens: TokenSet,
    /// The immediately-prior token, kept alive one refresh cycle so a client
    /// still pointing at it (until `setApiKey`) never dereferences freed memory.
    previous: ?TokenSet = null,

    /// When the access token is within `refresh_skew_ms` of expiry, re-import
    /// from the source and, if the source has a newer token, adopt it and return
    /// the new access token (owned by the session). Returns null when nothing
    /// changed. The caller must repoint its client with the returned token
    /// before its next request; the old buffer stays valid until the following
    /// `ensureFresh`/`deinit`. Errors `SubscriptionTokenExpired` when the token
    /// has lapsed and the source has no fresher one.
    pub fn ensureFresh(self: *Session) !?[:0]const u8 {
        const now = nowMs();
        if (self.tokens.expires_at_ms - now > refresh_skew_ms) return null;

        const importFn = self.descriptor.importFn orelse return self.staleResult(now);
        const fresh = (try importFn(self.allocator)) orelse return self.staleResult(now);
        // The source (e.g. Claude Code) hasn't refreshed yet.
        if (fresh.expires_at_ms <= self.tokens.expires_at_ms) {
            fresh.deinit(self.allocator);
            return self.staleResult(now);
        }

        if (self.previous) |p| p.deinit(self.allocator);
        self.previous = self.tokens;
        self.tokens = fresh;
        return self.tokens.access_token;
    }

    fn staleResult(self: *Session, now: i64) error{SubscriptionTokenExpired}!?[:0]const u8 {
        return if (self.tokens.expires_at_ms > now) null else error.SubscriptionTokenExpired;
    }

    pub fn deinit(self: *Session) void {
        self.tokens.deinit(self.allocator);
        if (self.previous) |p| p.deinit(self.allocator);
        self.previous = null;
    }
};

/// Build a bearer session for `provider` from an available subscription
/// credential, or null when none is importable.
pub fn sessionFor(allocator: std.mem.Allocator, provider: Config.AiProvider) !?Session {
    const desc = descriptorFor(provider) orelse return null;
    const importFn = desc.importFn orelse return null;
    const tokens = (try importFn(allocator)) orelse return null;
    return .{ .allocator = allocator, .descriptor = desc, .tokens = tokens };
}

/// Process-lifetime memo for `subscriptionAvailable`: the credential file is
/// probed several times across a single startup resolution, and it doesn't
/// change under us there (runtime `/provider` re-import goes through `sessionFor`,
/// which always reads fresh).
var availability_cache: std.enums.EnumArray(Config.AiProvider, ?bool) = .initFill(null);

/// Is a usable (present, not hard-expired) subscription token importable for
/// `provider`? Lets the picker offer a subscription without its API-key env var,
/// and not offer it when no credential exists.
pub fn subscriptionAvailable(provider: Config.AiProvider) bool {
    if (availability_cache.get(provider)) |cached| return cached;
    const result = probeSubscription(provider);
    availability_cache.set(provider, result);
    return result;
}

fn probeSubscription(provider: Config.AiProvider) bool {
    const desc = descriptorFor(provider) orelse return false;
    const importFn = desc.importFn orelse return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const tokens = (importFn(arena.allocator()) catch return false) orelse return false;
    // expires_at_ms == 0 means "unknown"; let a live request be the judge.
    return tokens.expires_at_ms == 0 or tokens.expires_at_ms > nowMs();
}

test "TokenSet dup/deinit round-trips and is leak-free" {
    const a = std.testing.allocator;
    const t = try TokenSet.dup(a, "acc", "ref", 123);
    defer t.deinit(a);
    try std.testing.expectEqualStrings("acc", t.access_token);
    try std.testing.expectEqualStrings("ref", t.refresh_token);
    try std.testing.expectEqual(@as(i64, 123), t.expires_at_ms);
}

test "descriptorFor resolves anthropic, null for a non-OAuth provider" {
    try std.testing.expect(descriptorFor(.anthropic) != null);
    try std.testing.expectEqual(@as(?*const Descriptor, null), descriptorFor(.openai));
}

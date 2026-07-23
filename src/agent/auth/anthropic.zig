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

//! Anthropic subscription-auth descriptor plus the Claude Code credential
//! importer. v1 reuses the OAuth token Claude Code already maintains at
//! `$HOME/.claude/.credentials.json`; the login/refresh-endpoint fields on the
//! descriptor are the seam for the deferred own-OAuth flow and are unused today.

const std = @import("std");
const lp = @import("lightpanda");
const auth = @import("auth.zig");

pub const descriptor: auth.Descriptor = .{
    .provider = .anthropic,
    .id = "anthropic",
    .label = "Claude subscription",
    .authorize_url = "https://claude.ai/oauth/authorize",
    .token_url = "https://console.anthropic.com/v1/oauth/token",
    .client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    .redirect_uri = "https://console.anthropic.com/oauth/code/callback",
    .scope = "org:create_api_key user:profile user:inference",
    .importFn = importClaudeCode,
};

/// Read Claude Code's OAuth credentials from `$HOME/.claude/.credentials.json`.
/// Returns null when the file is absent, unreadable, or malformed (the caller
/// falls back to API-key auth). Tokens are duped into `allocator`.
pub fn importClaudeCode(allocator: std.mem.Allocator) !?auth.TokenSet {
    const home = std.c.getenv("HOME") orelse return null;
    const path = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".claude", ".credentials.json" });
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(lp.io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(data);

    const Shape = struct {
        claudeAiOauth: ?struct {
            accessToken: []const u8,
            refreshToken: []const u8 = "",
            expiresAt: i64 = 0,
        } = null,
    };
    const parsed = std.json.parseFromSlice(Shape, allocator, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const oauth = parsed.value.claudeAiOauth orelse return null;
    if (oauth.accessToken.len == 0) return null;
    return try auth.TokenSet.dup(allocator, oauth.accessToken, oauth.refreshToken, oauth.expiresAt);
}

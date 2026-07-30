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

//! OpenAI Codex (ChatGPT subscription) OAuth. Uses the device-code flow (no
//! local callback server): request a user code, the user enters it at the verify
//! URL, we poll for the authorization code, then exchange it for tokens. The
//! `ChatGPT-Account-Id` sent on every API request is derived from the OAuth JWT.
//! Constants mirror the official Codex CLI / opencode.

const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;
const zenai = @import("zenai");
const auth = @import("auth.zig");

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const issuer = "https://auth.openai.com";
const token_url = issuer ++ "/oauth/token";
const device_code_url = issuer ++ "/api/accounts/deviceauth/usercode";
const device_token_url = issuer ++ "/api/accounts/deviceauth/token";
const verify_url = issuer ++ "/codex/device";
/// Redirect URI used only in the device-flow token exchange body (never hit).
const device_redirect_uri = issuer ++ "/deviceauth/callback";
const user_agent = "lightpanda";
const poll_margin_ms: u64 = 3000;
const cancel_slice_ms: u64 = 200;

pub const descriptor: auth.Descriptor = .{
    .provider = .codex,
    .models_dev_id = "openai",
    .label = "ChatGPT subscription",
    .loginFn = deviceLogin,
    .refreshFn = refreshGrant,
};

// --- JWT account-id extraction (pure) ---

/// Extract the ChatGPT account id from an OAuth JWT (id_token preferred, else
/// access_token). Probes `chatgpt_account_id`, then
/// `["https://api.openai.com/auth"].chatgpt_account_id`, then
/// `organizations[0].id`. Returns a slice owned by `arena`, or null.
pub fn accountIdFromJwt(arena: std.mem.Allocator, token: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return null;
    const payload_b64 = it.next() orelse return null;

    const dec = std.base64.url_safe_no_pad.Decoder;
    const len = dec.calcSizeForSlice(payload_b64) catch return null;
    const buf = arena.alloc(u8, len) catch return null;
    dec.decode(buf, payload_b64) catch return null;

    const claims = std.json.parseFromSliceLeaky(std.json.Value, arena, buf, .{}) catch return null;
    const obj = switch (claims) {
        .object => |o| o,
        else => return null,
    };
    if (stringField(obj, "chatgpt_account_id")) |v| return v;
    if (obj.get("https://api.openai.com/auth")) |a| if (a == .object) {
        if (stringField(a.object, "chatgpt_account_id")) |v| return v;
    };
    if (obj.get("organizations")) |orgs| if (orgs == .array and orgs.array.items.len > 0) {
        const first = orgs.array.items[0];
        if (first == .object) if (stringField(first.object, "id")) |v| return v;
    };
    return null;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// --- Request-body builders (pure) ---

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8 = "",
    id_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
};

/// Parse an OAuth token response into a `TokenSet`, deriving `account_id` from
/// the JWTs and computing an absolute expiry.
fn parseTokenResponse(allocator: std.mem.Allocator, body: []const u8) !auth.TokenSet {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try std.json.parseFromSliceLeaky(TokenResponse, a, body, .{ .ignore_unknown_fields = true });
    const account_id = (if (tr.id_token) |t| accountIdFromJwt(a, t) else null) orelse
        accountIdFromJwt(a, tr.access_token);
    const expires_at = auth.nowMs() + (tr.expires_in orelse 3600) * std.time.ms_per_s;
    return auth.TokenSet.dup(allocator, tr.access_token, tr.refresh_token, expires_at, account_id);
}

fn refreshBody(arena: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "grant_type=refresh_token&client_id=" ++ client_id ++ "&refresh_token={s}", .{
        try lp.URL.percentEncodeSegment(arena, refresh_token, .component),
    });
}

fn exchangeBody(arena: std.mem.Allocator, code: []const u8, code_verifier: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "grant_type=authorization_code&client_id=" ++ client_id ++
        "&redirect_uri=" ++ device_redirect_uri ++ "&code={s}&code_verifier={s}", .{
        try lp.URL.percentEncodeSegment(arena, code, .component),
        try lp.URL.percentEncodeSegment(arena, code_verifier, .component),
    });
}

// --- Device-code flow ---

const DeviceCode = struct {
    device_auth_id: []const u8,
    user_code: []const u8,
    /// Seconds between polls. The spec says number; OpenAI returns a string;
    /// std.json int parsing accepts both.
    interval: u32 = 5,
};

const DeviceToken = struct {
    authorization_code: []const u8,
    code_verifier: []const u8,
};

/// Sleep in short slices, polling `interrupt` between them: the REPL's Ctrl-C
/// only fires the interrupt (it never kills the process).
fn waitCancellable(ms: u64, interrupt: ?*zenai.http.Interrupt) error{LoginCancelled}!void {
    var remaining_ms = ms;
    while (remaining_ms > 0) {
        if (interrupt) |it| if (it.isFired()) return error.LoginCancelled;
        const slice_ms = @min(remaining_ms, cancel_slice_ms);
        lp.io.sleep(.fromMilliseconds(@intCast(slice_ms)), .awake) catch {};
        remaining_ms -= slice_ms;
    }
}

fn deviceLogin(allocator: std.mem.Allocator, interrupt: ?*zenai.http.Interrupt) !auth.TokenSet {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code_res = try post(a, interrupt, device_code_url, "application/json", "{\"client_id\":\"" ++ client_id ++ "\"}");
    if (code_res.status != .ok) {
        log.warn(.app, "codex device-code request failed", .{ .status = @intFromEnum(code_res.status), .body = code_res.body });
        return error.DeviceCodeRequestFailed;
    }
    const dc = try std.json.parseFromSliceLeaky(DeviceCode, a, code_res.body, .{ .ignore_unknown_fields = true });
    const interval_ms: u64 = @as(u64, dc.interval) * std.time.ms_per_s;

    std.debug.print(
        "\nTo authorize Lightpanda with your ChatGPT subscription:\n  1. Open {s}\n  2. Enter the code: {s}\n\nWaiting for authorization...\n",
        .{ verify_url, dc.user_code },
    );

    const poll_body = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(
        .{ .device_auth_id = dc.device_auth_id, .user_code = dc.user_code },
        .{},
    )});
    const dt: DeviceToken = while (true) {
        try waitCancellable(interval_ms + poll_margin_ms, interrupt);
        const res = try post(a, interrupt, device_token_url, "application/json", poll_body);
        switch (res.status) {
            .ok => break try std.json.parseFromSliceLeaky(DeviceToken, a, res.body, .{ .ignore_unknown_fields = true }),
            // Still pending — the user hasn't finished authorizing.
            .forbidden, .not_found => continue,
            else => {
                log.warn(.app, "codex device-auth poll failed", .{ .status = @intFromEnum(res.status), .body = res.body });
                return error.DeviceAuthFailed;
            },
        }
    };

    const exchange = try exchangeBody(a, dt.authorization_code, dt.code_verifier);
    const tok_res = try post(a, interrupt, token_url, "application/x-www-form-urlencoded", exchange);
    if (tok_res.status != .ok) {
        log.warn(.app, "codex token exchange failed", .{ .status = @intFromEnum(tok_res.status), .body = tok_res.body });
        return error.TokenExchangeFailed;
    }
    return parseTokenResponse(allocator, tok_res.body);
}

fn refreshGrant(allocator: std.mem.Allocator, refresh_token: []const u8) !auth.TokenSet {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try refreshBody(a, refresh_token);
    const res = try post(a, null, token_url, "application/x-www-form-urlencoded", body);
    if (res.status != .ok) {
        log.warn(.app, "codex token refresh failed", .{ .status = @intFromEnum(res.status), .body = res.body });
        return error.RefreshFailed;
    }
    return parseTokenResponse(allocator, res.body);
}

const PostResult = struct { status: std.http.Status, body: []u8 };

/// One-shot POST. Firing `interrupt` aborts an in-flight exchange and surfaces
/// `error.LoginCancelled` instead of the read error it caused.
fn post(arena: std.mem.Allocator, interrupt: ?*zenai.http.Interrupt, url: []const u8, content_type: []const u8, body: []const u8) !PostResult {
    var client: std.http.Client = .{ .allocator = arena, .io = lp.io };
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(arena);
    const status = zenai.http.fetchInterruptible(arena, &client, .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = content_type }, .user_agent = .{ .override = user_agent } },
    }, &out.writer, interrupt) catch |err| {
        if (interrupt) |it| if (it.isFired()) return error.LoginCancelled;
        return err;
    };
    return .{ .status = status, .body = out.written() };
}

// --- Tests (pure paths) ---

fn makeJwt(arena: std.mem.Allocator, payload_json: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const p = try arena.alloc(u8, enc.calcSize(payload_json.len));
    _ = enc.encode(p, payload_json);
    return std.fmt.allocPrint(arena, "aGVhZGVy.{s}.c2ln", .{p});
}

test "accountIdFromJwt: top-level chatgpt_account_id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jwt = try makeJwt(a, "{\"chatgpt_account_id\":\"acct-top\"}");
    try std.testing.expectEqualStrings("acct-top", accountIdFromJwt(a, jwt).?);
}

test "accountIdFromJwt: nested auth namespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jwt = try makeJwt(a, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-ns\"}}");
    try std.testing.expectEqualStrings("acct-ns", accountIdFromJwt(a, jwt).?);
}

test "accountIdFromJwt: organizations fallback, and null when absent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jwt = try makeJwt(a, "{\"organizations\":[{\"id\":\"org-1\"}]}");
    try std.testing.expectEqualStrings("org-1", accountIdFromJwt(a, jwt).?);
    const none = try makeJwt(a, "{\"sub\":\"x\"}");
    try std.testing.expectEqual(@as(?[]const u8, null), accountIdFromJwt(a, none));
    try std.testing.expectEqual(@as(?[]const u8, null), accountIdFromJwt(a, "not-a-jwt"));
}

test "refreshBody / exchangeBody percent-encode values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rb = try refreshBody(a, "tok/with+special");
    try std.testing.expect(std.mem.find(u8, rb, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.find(u8, rb, "client_id=" ++ client_id) != null);
    try std.testing.expect(std.mem.find(u8, rb, "tok%2Fwith%2Bspecial") != null);
    const eb = try exchangeBody(a, "the code", "verifier");
    try std.testing.expect(std.mem.find(u8, eb, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.find(u8, eb, "code=the%20code") != null);
}

test "parseTokenResponse derives account id and absolute expiry" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jwt = try makeJwt(a, "{\"chatgpt_account_id\":\"acct-x\"}");
    const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"acc\",\"refresh_token\":\"ref\",\"id_token\":\"{s}\",\"expires_in\":3600}}", .{jwt});
    const tokens = try parseTokenResponse(std.testing.allocator, body);
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("acc", tokens.access_token);
    try std.testing.expectEqualStrings("ref", tokens.refresh_token);
    try std.testing.expectEqualStrings("acct-x", tokens.account_id.?);
    try std.testing.expect(tokens.expires_at_ms > auth.nowMs());
}

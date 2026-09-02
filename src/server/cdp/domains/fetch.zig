// Copyright (C) 2023-2025    Lightpanda (Selecy SAS)
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

const std = @import("std");
const lp = @import("lightpanda");

const http = @import("../../../network/http.zig");
const Notification = @import("../../../Notification.zig");
const HttpClient = @import("../../../network/HttpClient.zig");

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const network = @import("network.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        disable,
        enable,
        continueRequest,
        failRequest,
        fulfillRequest,
        continueWithAuth,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .disable => return disable(cmd),
        .enable => return enable(cmd),
        .continueRequest => return continueRequest(cmd),
        .continueWithAuth => return continueWithAuth(cmd),
        .failRequest => return failRequest(cmd),
        .fulfillRequest => return fulfillRequest(cmd),
    }
}

pub const RequestPattern = struct {
    // Wildcards ('*' -> zero or more, '?' -> exactly one) are allowed.
    // Escape character is backslash. Omitting is equivalent to "*".
    urlPattern: []const u8 = "*",
    resourceType: ?ResourceType = null,
    requestStage: RequestStage = .Request,
};
const ResourceType = enum {
    Document,
    Stylesheet,
    Image,
    Media,
    Font,
    Script,
    TextTrack,
    XHR,
    Fetch,
    Prefetch,
    EventSource,
    WebSocket,
    Manifest,
    SignedExchange,
    Ping,
    CSPViolationReport,
    Preflight,
    FedCM,
    Other,
};
const RequestStage = enum {
    Request,
    Response,
};

const EnableParam = struct {
    // null (omitted) means every request; an explicit empty list means none.
    patterns: ?[]RequestPattern = null,
    handleAuthRequests: bool = false,
};
const ErrorReason = enum {
    Failed,
    Aborted,
    TimedOut,
    AccessDenied,
    ConnectionClosed,
    ConnectionReset,
    ConnectionRefused,
    ConnectionAborted,
    ConnectionFailed,
    NameNotResolved,
    InternetDisconnected,
    AddressUnreachable,
    BlockedByClient,
    BlockedByResponse,
};

fn commandSessionId(cmd: *CDP.Command, bc: *CDP.BrowserContext) ![]const u8 {
    if (cmd.input.session_id) |session_id| {
        return cmd.cdp.resolveSessionId(session_id) orelse error.UnknownSessionId;
    }
    return bc.session_id orelse error.UnknownSessionId;
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.fetchDisableForSession(try commandSessionId(cmd, bc));
    return cmd.sendResult(null, .{});
}

fn enable(cmd: *CDP.Command) !void {
    const params = (try cmd.params(EnableParam)) orelse EnableParam{};
    if (params.patterns) |patterns| {
        if (patterns.len == 0 and params.handleAuthRequests) {
            return cmd.sendError(-32602, "Can't specify empty patterns with handleAuth set", .{});
        }
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.fetchEnable(params.patterns, params.handleAuthRequests, try commandSessionId(cmd, bc));
    return cmd.sendResult(null, .{});
}

pub fn requestIntercept(arena: Allocator, bc: *CDP.BrowserContext, intercept: *const Notification.RequestIntercept) !void {
    // The session that enabled Fetch owns its interception events.
    const session_id = bc.fetch_session_id orelse return;

    const transfer = intercept.transfer;
    if (!bc.intercept_state.matches(transfer.req.url, transfer.req.resource_type)) {
        // Leaves wait_for_interception false: the request proceeds untouched.
        return;
    }

    // We keep it around to wait for modifications to the request.
    // TODO: What to do when receiving replies for a previous frame's requests?

    const intercept_id = try bc.intercept_state.put(transfer.id);
    errdefer _ = bc.intercept_state.remove(intercept_id);

    try bc.cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = &id.toInterceptId(intercept_id),
        .frameId = &id.toFrameId(transfer.req.frame_id),
        .request = network.RequestWriter.init(arena, transfer, bc.network_limits.post_data),
        .resourceType = transfer.req.resource_type.string(),
        .networkId = &id.toRequestId(transfer), // matches the Network REQ-ID
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request intercept", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.req.url,
    });
    // Await either continueRequest, failRequest or fulfillRequest

    intercept.wait_for_interception.* = true;
}

fn continueRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // INT-{d}"
        url: ?[]const u8 = null,
        method: ?[]const u8 = null,
        postData: ?[]const u8 = null,
        headers: ?[]const http.Header = null,
        interceptResponse: bool = false,
    })) orelse return error.InvalidParams;

    if (params.interceptResponse) {
        return error.NotImplemented;
    }

    const client = &bc.cdp.browser.http_client;
    var intercept_state = &bc.intercept_state;
    const intercept_id = try idFromRequestId(params.requestId);

    const transfer_id = intercept_state.remove(intercept_id) orelse return error.RequestNotFound;
    // Transfer may have been destroyed out-of-band between pause and now
    // (e.g. frame shutdown). Treat as a no-op rather than an error — the CDP
    // client's view of "this request still exists" is just stale.
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "continue" });
        return cmd.sendResult(null, .{});
    };

    log.debug(.cdp, "request intercept", .{
        .state = "continue",
        .id = transfer.id,
        .url = transfer.req.url,
        .new_url = params.url,
    });

    const arena = transfer.arena;
    const request = &transfer.req;
    // Update the request with the new parameters
    if (params.url) |url| {
        request.url = try arena.dupeZ(u8, url);
    }
    if (params.method) |method| {
        request.method = std.meta.stringToEnum(http.Method, method) orelse return error.InvalidParams;
    }

    if (params.headers) |headers| {
        try transfer.replaceRequestHeaders(headers);
    }

    if (params.postData) |b| {
        const decoder = std.base64.standard.Decoder;
        const body = try arena.alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(body, b);
        request.body = body;
    }

    try client.continueIntercepted(transfer);
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Fetch/#type-AuthChallengeResponse
const AuthChallengeResponse = enum {
    Default,
    CancelAuth,
    ProvideCredentials,
};

fn continueWithAuth(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        authChallengeResponse: struct {
            response: AuthChallengeResponse,
            username: []const u8 = "",
            password: []const u8 = "",
        },
    })) orelse return error.InvalidParams;

    const client = &bc.cdp.browser.http_client;
    var intercept_state = &bc.intercept_state;
    const intercept_id = try idFromRequestId(params.requestId);

    const transfer_id = intercept_state.remove(intercept_id) orelse return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "auth" });
        return cmd.sendResult(null, .{});
    };

    log.debug(.cdp, "request intercept", .{
        .state = "continue with auth",
        .id = transfer.id,
        .response = params.authChallengeResponse.response,
    });

    if (params.authChallengeResponse.response != .ProvideCredentials) {
        transfer.abortAuthChallenge();
        return cmd.sendResult(null, .{});
    }

    {
        // The transfer is still parked here; if building the credentials
        // fails, release it. Scoped so the errdefer does NOT cover
        // continueTransfer (which owns its failures).
        errdefer transfer.abortAuthChallenge();
        transfer.updateCredentials(try std.fmt.allocPrintSentinel(
            transfer.arena.allocator(),
            "{s}:{s}",
            .{
                params.authChallengeResponse.username,
                params.authChallengeResponse.password,
            },
            0,
        ));
    }

    try client.continueTransfer(transfer);
    return cmd.sendResult(null, .{});
}

fn fulfillRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        responseCode: u16,
        responseHeaders: ?[]const http.Header = null,
        binaryResponseHeaders: ?[]const u8 = null,
        body: ?[]const u8 = null,
        responsePhrase: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.binaryResponseHeaders != null) {
        log.warn(.not_implemented, "Fetch.fulfillRequest", .{ .param = "binaryResponseHeaders" });
        return error.NotImplemented;
    }

    const client = &bc.cdp.browser.http_client;
    var intercept_state = &bc.intercept_state;
    const intercept_id = try idFromRequestId(params.requestId);

    const transfer_id = intercept_state.remove(intercept_id) orelse return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "fulfill" });
        return cmd.sendResult(null, .{});
    };

    log.debug(.cdp, "request intercept", .{
        .state = "fulfilled",
        .id = transfer.id,
        .url = transfer.req.url,
        .status = params.responseCode,
        .body = params.body != null,
    });

    var body: ?[]const u8 = null;
    if (params.body) |b| {
        const decoder = std.base64.standard.Decoder;
        const buf = try transfer.arena.alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(buf, b);
        body = buf;
    }

    try client.fulfillIntercepted(transfer, params.responseCode, params.responseHeaders orelse &.{}, body);
    return cmd.sendResult(null, .{});
}

fn failRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        errorReason: ErrorReason,
    })) orelse return error.InvalidParams;

    const client = &bc.cdp.browser.http_client;
    var intercept_state = &bc.intercept_state;
    const intercept_id = try idFromRequestId(params.requestId);

    const transfer_id = intercept_state.remove(intercept_id) orelse return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "fail" });
        return cmd.sendResult(null, .{});
    };

    // The client is cancelling the request: consumers see it as a cancel
    // (XHR fires abort, not error), like any other Transfer.cancel().
    defer transfer.abortParked(error.TransferCanceled);

    log.info(.cdp, "request intercept", .{
        .state = "fail",
        .id = transfer.id,
        .url = transfer.req.url,
        .reason = params.errorReason,
    });
    return cmd.sendResult(null, .{});
}

pub fn requestAuthRequired(arena: Allocator, bc: *CDP.BrowserContext, intercept: *const Notification.RequestAuthRequired) !void {
    const session_id = bc.fetch_session_id orelse return;

    // Auth challenges are only surfaced for requests the patterns select.
    const transfer = intercept.transfer;
    if (!bc.intercept_state.matches(transfer.req.url, transfer.req.resource_type)) {
        return;
    }

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous frame's requests?

    const intercept_id = try bc.intercept_state.put(transfer.id);
    errdefer _ = bc.intercept_state.remove(intercept_id);
    const request = &transfer.req;

    const challenge = transfer._auth_challenge orelse return error.NullAuthChallenge;

    try bc.cdp.sendEvent("Fetch.authRequired", .{
        .requestId = &id.toInterceptId(intercept_id),
        .frameId = &id.toFrameId(request.frame_id),
        .request = network.RequestWriter.init(arena, transfer, bc.network_limits.post_data),
        .resourceType = request.resource_type.string(),
        .authChallenge = .{
            .origin = "", // TODO get origin, could be the proxy address for example.
            .source = if (challenge.source) |s| (if (s == .server) "Server" else "Proxy") else "",
            .scheme = if (challenge.scheme) |s| (if (s == .digest) "digest" else "basic") else "",
            .realm = challenge.realm orelse "",
        },
        .networkId = &id.toRequestId(transfer),
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request auth required", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.req.url,
    });
    // Await continueWithAuth

    intercept.wait_for_interception.* = true;
}

// Get u32 from requestId which is formatted as: "INT-{d}"
fn idFromRequestId(request_id: []const u8) !u32 {
    if (!std.mem.startsWith(u8, request_id, "INT-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u32, request_id[4..], 10) catch return error.InvalidParams;
}

// Stored in CDP. Holds the `Fetch.enable` patterns and maps intercept ids to
// *transfer ids* (not *Transfer pointers) of paused transfers waiting for CDP
// continueRequest/fulfillRequest/failRequest/continueWithAuth. Anyone resolving
// an entry must look the transfer up via `Client.findTransfer(id)` — if the
// transfer has been destroyed out-of-band (e.g. frame shutdown), the lookup
// returns null.
pub const InterceptState = struct {
    allocator: Allocator,
    next_id: u32 = 1,
    waiting: std.AutoArrayHashMapUnmanaged(u32, u32),
    patterns: []const Pattern = &.{},

    const Pattern = struct {
        url: []const u8,
        resource_type: ?ResourceType,
    };

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = .empty,
            .allocator = allocator,
        };
    }

    pub fn put(self: *InterceptState, transfer_id: u32) !u32 {
        const intercept_id = self.next_id;
        try self.waiting.put(self.allocator, intercept_id, transfer_id);
        self.next_id +%= 1;
        return intercept_id;
    }

    // Returns the transfer id if the intercept id was present and removed.
    pub fn remove(self: *InterceptState, intercept_id: u32) ?u32 {
        const entry = self.waiting.fetchSwapRemove(intercept_id) orelse return null;
        return entry.value;
    }

    pub fn deinit(self: *InterceptState) void {
        self.clearPatterns();
        self.waiting.deinit(self.allocator);
    }

    pub fn pendingIntercepts(self: *const InterceptState) []u32 {
        return self.waiting.values();
    }

    pub fn setPatterns(self: *InterceptState, patterns: ?[]const RequestPattern) !void {
        self.clearPatterns();

        var has_response_stage = false;
        const source: []const RequestPattern = patterns orelse &.{.{}};

        var count: usize = 0;
        for (source) |pattern| {
            if (pattern.requestStage == .Response) {
                has_response_stage = true;
                continue;
            }
            count += 1;
        }

        if (has_response_stage) {
            log.warn(.not_implemented, "Fetch.enable", .{ .params = "requestStage=Response" });
        }

        const owned = try self.allocator.alloc(Pattern, count);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |pattern| {
                self.allocator.free(pattern.url);
            }
            self.allocator.free(owned);
        }
        for (source) |pattern| {
            if (pattern.requestStage != .Request) {
                continue;
            }
            owned[initialized] = .{
                .url = try self.allocator.dupe(u8, pattern.urlPattern),
                .resource_type = pattern.resourceType,
            };
            initialized += 1;
        }
        self.patterns = owned;
    }

    pub fn clearPatterns(self: *InterceptState) void {
        for (self.patterns) |pattern| {
            self.allocator.free(pattern.url);
        }
        self.allocator.free(self.patterns);
        self.patterns = &.{};
    }

    pub fn matches(self: *const InterceptState, url: []const u8, resource_type: HttpClient.Request.ResourceType) bool {
        for (self.patterns) |pattern| {
            if (pattern.resource_type) |rt| {
                if (rt != cdpResourceType(resource_type)) {
                    continue;
                }
            }
            if (wildcardMatch(pattern.url, url)) {
                return true;
            }
        }
        return false;
    }

    fn cdpResourceType(resource_type: HttpClient.Request.ResourceType) ResourceType {
        return switch (resource_type) {
            .document => .Document,
            .xhr => .XHR,
            .script, .worker => .Script,
            .fetch => .Fetch,
            .stylesheet => .Stylesheet,
            .eventsource => .EventSource,
            .image => .Image,
        };
    }

    // RequestPattern.urlPattern semantics: '*' matches zero or more characters,
    // '?' exactly one, '\' escapes the next character.
    // https://research.swtch.com/glob
    fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
        var value_index: usize = 0;
        var pattern_index: usize = 0;
        // Position just past the most recent '*', and the value position it was
        // matched against; on a mismatch we retry from there with the star
        // consuming one more character.
        var star_index: ?usize = null;
        var star_value_index: usize = 0;

        while (value_index < value.len) {
            if (pattern_index < pattern.len) {
                switch (pattern[pattern_index]) {
                    '*' => {
                        pattern_index += 1;
                        star_index = pattern_index;
                        star_value_index = value_index;
                        continue;
                    },
                    '?' => {
                        pattern_index += 1;
                        value_index += 1;
                        continue;
                    },
                    else => |c| {
                        var literal = c;
                        var advance: usize = 1;
                        if (c == '\\' and pattern_index + 1 < pattern.len) {
                            literal = pattern[pattern_index + 1];
                            advance = 2;
                        }
                        if (literal == value[value_index]) {
                            pattern_index += advance;
                            value_index += 1;
                            continue;
                        }
                    },
                }
            }

            const star = star_index orelse return false;
            pattern_index = star;
            star_value_index += 1;
            value_index = star_value_index;
        }

        while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            pattern_index += 1;
        }
        return pattern_index == pattern.len;
    }
};

const testing = @import("../testing.zig");
test "cdp.Fetch: interception events belong to the enabling session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });
    try bc.attached_sessions.append(bc.arena, .{
        .id = "SID-AUX",
        .parent_id = null,
    });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Fetch.enable",
        .sessionId = "SID-AUX",
    });
    try testing.expect(std.mem.eql(u8, "SID-AUX", bc.fetch_session_id.?));
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = "SID-AUX" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Fetch.disable",
        .sessionId = "SID-PRIMARY",
    });
    try testing.expect(std.mem.eql(u8, "SID-AUX", bc.fetch_session_id.?));

    try ctx.processMessage(.{
        .id = 3,
        .method = "Fetch.disable",
        .sessionId = "SID-AUX",
    });
    try testing.expectEqual(null, bc.fetch_session_id);
}

test "cdp.Fetch: InterceptState issues a fresh id per pause" {
    var state = try InterceptState.init(testing.allocator);
    defer state.deinit();

    const first = try state.put(7);
    const second = try state.put(7);
    try testing.expectEqual(false, first == second);
    try testing.expectEqual(2, state.pendingIntercepts().len);
    try testing.expectEqual(7, state.pendingIntercepts()[0]);

    try testing.expectEqual(7, state.remove(first).?);
    try testing.expectEqual(null, state.remove(first));
    try testing.expectEqual(7, state.remove(second).?);
    try testing.expectEqual(null, state.remove(second));
}

test "cdp.Fetch: wildcardMatch" {
    // exact, case-sensitive
    try testing.expect(InterceptState.wildcardMatch("http://h/a/b", "http://h/a/b"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/a/b", "http://h/a/bc"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/a/b", "http://H/a/b"));

    // '*' = zero or more
    try testing.expect(InterceptState.wildcardMatch("*", ""));
    try testing.expect(InterceptState.wildcardMatch("*", "http://h/"));
    try testing.expect(InterceptState.wildcardMatch("**a", "a"));
    try testing.expect(InterceptState.wildcardMatch("a*", "a"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("a*", ""));
    try testing.expect(InterceptState.wildcardMatch("*://*/api/*", "http://127.0.0.1:18086/api/get?pageSize=1"));
    try testing.expect(InterceptState.wildcardMatch("*://*/api/*", "http://127.0.0.1:18086/api/post"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("*://*/api/*", "http://127.0.0.1:18086/"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("*://*/api/*", "http://127.0.0.1:18086/apiary"));
    try testing.expect(InterceptState.wildcardMatch("*api*", "http://h/api/x"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("*api*", "http://h/index.html"));
    // backtracking past a greedy star
    try testing.expect(InterceptState.wildcardMatch("*a*b?c", "xxaxxbYc"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("*a*b?c", "xxaxxbc"));

    // '?' = exactly one
    try testing.expect(InterceptState.wildcardMatch("http://h/?.json", "http://h/a.json"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/?.json", "http://h/ab.json"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/?.json", "http://h/.json"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("a?", "a"));

    // '\' escapes the next character; a trailing '\' is literal
    try testing.expect(InterceptState.wildcardMatch("http://h/a\\?b=1", "http://h/a?b=1"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/a\\?b=1", "http://h/aXb=1"));
    try testing.expect(InterceptState.wildcardMatch("http://h/\\*", "http://h/*"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("http://h/\\*", "http://h/x"));
    try testing.expect(InterceptState.wildcardMatch("*\\\\", "a\\"));
    try testing.expect(InterceptState.wildcardMatch("abc\\", "abc\\"));
    try testing.expectEqual(false, InterceptState.wildcardMatch("abc\\", "abc"));
}

test "cdp.Fetch: InterceptState patterns" {
    testing.expectLog(&.{.not_implemented});

    var state = try InterceptState.init(testing.allocator);
    defer state.deinit();

    // disabled: nothing is paused
    try testing.expectEqual(false, state.matches("http://h/", .document));

    // omitted patterns = every request
    try state.setPatterns(null);
    try testing.expect(state.matches("http://h/", .document));
    try testing.expect(state.matches("http://h/x.js", .script));

    // an explicit empty list = no request
    try state.setPatterns(&.{});
    try testing.expectEqual(false, state.matches("http://h/", .document));

    try state.setPatterns(&.{
        .{ .urlPattern = "*/api/*", .resourceType = .XHR },
        .{ .urlPattern = "*.css", .requestStage = .Response },
    });
    try testing.expectEqual(1, state.patterns.len);
    try testing.expect(state.matches("http://h/api/x", .xhr));
    try testing.expectEqual(false, state.matches("http://h/api/x", .fetch));
    try testing.expectEqual(false, state.matches("http://h/other", .xhr));
    // Response-stage entries are dropped
    try testing.expectEqual(false, state.matches("http://h/a.css", .stylesheet));

    state.clearPatterns();
    try testing.expectEqual(false, state.matches("http://h/api/x", .xhr));
}

test "cdp.Fetch: enable compiles patterns, disable clears them" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .session_id = "SID-P",
        .target_id = "TID-000000000B".*,
    });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Fetch.enable",
        .params = .{ .patterns = .{
            .{ .urlPattern = "*/json/*", .resourceType = "Fetch" },
            .{ .urlPattern = "http://h/exact" },
        } },
        .sessionId = "SID-P",
    });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = "SID-P" });
    try testing.expectEqual(2, bc.intercept_state.patterns.len);
    try testing.expect(bc.intercept_state.matches("http://h/json/a", .fetch));
    try testing.expectEqual(false, bc.intercept_state.matches("http://h/json/a", .xhr));
    try testing.expect(bc.intercept_state.matches("http://h/exact", .xhr));
    try testing.expectEqual(false, bc.intercept_state.matches("http://h/", .document));

    // re-enable without patterns = catch-all
    try ctx.processMessage(.{ .id = 2, .method = "Fetch.enable", .sessionId = "SID-P" });
    try ctx.expectSentResult(null, .{ .id = 2, .session_id = "SID-P" });
    try testing.expect(bc.intercept_state.matches("http://h/", .document));

    // explicit empty list = pause nothing; rejected when auth handling is on
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.enable", .params = .{ .patterns = .{} }, .sessionId = "SID-P" });
    try ctx.expectSentResult(null, .{ .id = 3, .session_id = "SID-P" });
    try testing.expectEqual(false, bc.intercept_state.matches("http://h/", .document));
    try ctx.processMessage(.{ .id = 4, .method = "Fetch.enable", .params = .{ .patterns = .{}, .handleAuthRequests = true }, .sessionId = "SID-P" });
    try ctx.expectSentError(-32602, "Can't specify empty patterns with handleAuth set", .{ .id = 4 });

    try ctx.processMessage(.{ .id = 5, .method = "Fetch.disable", .sessionId = "SID-P" });
    try testing.expectEqual(0, bc.intercept_state.patterns.len);
    try testing.expectEqual(false, bc.intercept_state.matches("http://h/", .document));
}

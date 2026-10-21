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
const SafeString = @import("../SafeString.zig");

const network = @import("network.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        disable,
        enable,
        continueRequest,
        continueResponse,
        failRequest,
        fulfillRequest,
        continueWithAuth,
        getResponseBody,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .disable => return disable(cmd),
        .enable => return enable(cmd),
        .continueRequest => return continueRequest(cmd),
        .continueResponse => return continueResponse(cmd),
        .getResponseBody => return getResponseBody(cmd),
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
    if (!bc.intercept_state.matches(.Request, transfer.req.url, transfer.req.resource_type)) {
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
        .resourceType = fetchResourceType(transfer.req.resource_type),
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

pub fn responseIntercept(arena: Allocator, bc: *CDP.BrowserContext, intercept: *const Notification.ResponseIntercept) !void {
    const session_id = bc.fetch_session_id orelse return;

    const transfer = intercept.transfer;
    // continueRequest's interceptResponse overrides the patterns for this hop.
    const pause = transfer._intercept_response orelse bc.intercept_state.matches(.Response, transfer.req.url, transfer.req.resource_type);
    if (pause == false) {
        // Leaves wait_for_interception false: the response is delivered untouched.
        return;
    }

    const intercept_id = try bc.intercept_state.put(transfer.id);
    errdefer _ = bc.intercept_state.remove(intercept_id);

    // The stage is told by the fields present: a network failure carries
    // responseErrorReason, a response (final or redirect) its status and headers.
    switch (transfer._response_pause) {
        .failed => |failure| try bc.cdp.sendEvent("Fetch.requestPaused", .{
            .requestId = &id.toInterceptId(intercept_id),
            .frameId = &id.toFrameId(transfer.req.frame_id),
            .request = network.RequestWriter.init(arena, transfer, bc.network_limits.post_data),
            .resourceType = fetchResourceType(transfer.req.resource_type),
            .responseErrorReason = cdpErrorReason(failure.err),
            .networkId = &id.toRequestId(transfer), // matches the Network REQ-ID
        }, .{ .session_id = session_id }),
        .final, .cached, .redirect => {
            const head = transfer.res.header orelse return error.MissingResponseHead;
            try bc.cdp.sendEvent("Fetch.requestPaused", .{
                .requestId = &id.toInterceptId(intercept_id),
                .frameId = &id.toFrameId(transfer.req.frame_id),
                .request = network.RequestWriter.init(arena, transfer, bc.network_limits.post_data),
                .resourceType = fetchResourceType(transfer.req.resource_type),
                .responseStatusCode = head.status,
                .responseStatusText = SafeString.wrap(transfer.statusText() orelse ""),
                .responseHeaders = HeaderEntriesWriter{ .headers = transfer.responseHeaders() },
                .networkId = &id.toRequestId(transfer), // matches the Network REQ-ID
            }, .{ .session_id = session_id });
        },
    }

    log.debug(.cdp, "response intercept", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.req.url,
        .pause = std.meta.activeTag(transfer._response_pause),
    });
    // Await continueResponse, continueRequest, fulfillRequest or failRequest

    intercept.wait_for_interception.* = true;
}

// A Fetch.HeaderEntry array. Names and values are the server's octets, which
// need not be UTF-8: SafeString keeps them strings.
const HeaderEntriesWriter = struct {
    headers: []const http.Header,

    pub fn jsonStringify(self: *const HeaderEntriesWriter, jws: anytype) !void {
        try jws.beginArray();
        for (self.headers) |hdr| {
            try jws.beginObject();
            try jws.objectField("name");
            try jws.write(SafeString.wrap(hdr.name));
            try jws.objectField("value");
            try jws.write(SafeString.wrap(hdr.value));
            try jws.endObject();
        }
        try jws.endArray();
    }
};

// The transfer a response-stage intercept id holds, left in the intercept
// state. Null when the id is unknown, the transfer is gone, or the pause is
// not at the response stage.
fn pausedResponse(bc: *CDP.BrowserContext, request_id: []const u8) !?*HttpClient.Transfer {
    const intercept_id = try idFromRequestId(request_id);
    const transfer_id = bc.intercept_state.get(intercept_id) orelse return null;
    const transfer = bc.cdp.browser.http_client.findTransfer(transfer_id) orelse return null;
    if (transfer.state != .parked or transfer.state.parked != .intercept_response) {
        return null;
    }
    return transfer;
}

fn continueResponse(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        responseCode: ?u16 = null,
        responsePhrase: ?[]const u8 = null,
        responseHeaders: ?[]const http.Header = null,
        binaryResponseHeaders: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.responseCode != null or params.responsePhrase != null or params.responseHeaders != null or params.binaryResponseHeaders != null) {
        log.debug(.not_implemented, "Fetch.continueResponse", .{ .params = "response overrides" });
        return error.NotImplemented;
    }

    const transfer = (try pausedResponse(bc, params.requestId)) orelse {
        return cmd.sendError(-32000, "Invalid InterceptionId.", .{});
    };
    _ = bc.intercept_state.remove(try idFromRequestId(params.requestId));

    log.debug(.cdp, "response intercept", .{
        .state = "continue",
        .id = transfer.id,
        .url = transfer.req.url,
    });

    try bc.cdp.browser.http_client.continueInterceptedResponse(transfer);
    return cmd.sendResult(null, .{});
}

fn getResponseBody(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
    })) orelse return error.InvalidParams;

    const no_body = "Can only get response body on requests captured after headers received.";
    const transfer = (try pausedResponse(bc, params.requestId)) orelse {
        return cmd.sendError(-32000, no_body, .{});
    };
    const body = switch (transfer._response_pause) {
        .final => transfer.res.buffer.items,
        .cached => |cached| cached,
        .redirect, .failed => return cmd.sendError(-32000, no_body, .{}),
    };
    // Like Chrome, always base64, whatever the body is.
    return cmd.sendResult(.{
        .body = network.Base64Body{ .data = body },
        .base64Encoded = true,
    }, .{ .size_hint = std.base64.standard.Encoder.calcSize(body.len) });
}

fn continueRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // INT-{d}"
        url: ?[]const u8 = null,
        method: ?[]const u8 = null,
        postData: ?[]const u8 = null,
        headers: ?[]const http.Header = null,
        interceptResponse: ?bool = null,
    })) orelse return error.InvalidParams;

    if (try pausedResponse(bc, params.requestId)) |transfer| {
        // The request has already been sent: like Chrome, its overrides are
        // ignored, except that a url on a redirect replaces its Location.
        if (params.url) |url| switch (transfer._response_pause) {
            .redirect => transfer._response_pause = .{ .redirect = try transfer.arena.dupe(u8, url) },
            else => {},
        };
        _ = bc.intercept_state.remove(try idFromRequestId(params.requestId));
        try bc.cdp.browser.http_client.continueInterceptedResponse(transfer);
        return cmd.sendResult(null, .{});
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
        request.url = try arena.dupeSentinel(u8, url, 0);
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

    if (params.interceptResponse) |intercept_response| {
        transfer._intercept_response = intercept_response;
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

    const transfer_id = intercept_state.get(intercept_id) orelse return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        _ = intercept_state.remove(intercept_id);
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "auth" });
        return cmd.sendResult(null, .{});
    };
    // Only an authRequired pause can be answered with continueWithAuth: a
    // request- or response-stage pause stays paused, as in Chrome.
    if (transfer.state != .parked or transfer.state.parked != .intercept_auth) {
        return cmd.sendError(-32000, "Invalid InterceptionId.", .{});
    }
    _ = intercept_state.remove(intercept_id);

    log.debug(.cdp, "request intercept", .{
        .state = "continue with auth",
        .id = transfer.id,
        .response = params.authChallengeResponse.response,
    });

    if (params.authChallengeResponse.response != .ProvideCredentials) {
        // Like Chrome: give up on the challenge and let the page see the
        // 401/407 that raised it.
        try client.cancelAuthChallenge(transfer);
        return cmd.sendResult(null, .{});
    }

    {
        // The transfer is still parked here; if building the credentials
        // fails, release it. Scoped so the errdefer does NOT cover
        // continueTransfer (which owns its failures).
        errdefer transfer.abortAuthChallenge();
        transfer.updateCredentials(try transfer.arena.allocator().printSentinel(
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
        log.debug(.not_implemented, "Fetch.fulfillRequest", .{ .param = "binaryResponseHeaders" });
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
        errorReason: network.ErrorReason,
    })) orelse return error.InvalidParams;

    const client = &bc.cdp.browser.http_client;
    var intercept_state = &bc.intercept_state;
    const intercept_id = try idFromRequestId(params.requestId);

    const transfer_id = intercept_state.remove(intercept_id) orelse return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "fail" });
        return cmd.sendResult(null, .{});
    };

    defer transfer.abortParked(params.errorReason.toError());

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
    if (!bc.intercept_state.matches(.Request, transfer.req.url, transfer.req.resource_type)) {
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
        .resourceType = fetchResourceType(request.resource_type),
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

// The CDP Network.ErrorReason for a network failure paused at the response
// stage. Failed is CDP's own generic reason, for failures it has no narrower
// value for (TLS, protocol and size errors among them).
fn cdpErrorReason(err: anyerror) network.ErrorReason {
    return switch (err) {
        error.OperationTimedout => .TimedOut,
        error.CouldntResolveHost, error.CouldntResolveProxy => .NameNotResolved,
        error.CouldntConnect => .ConnectionFailed,
        error.GotNothing => .ConnectionClosed,
        error.SendError, error.RecvError => .ConnectionReset,
        else => .Failed,
    };
}

fn fetchResourceType(resource_type: HttpClient.Request.ResourceType) []const u8 {
    return @tagName(InterceptState.cdpResourceType(resource_type));
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
        stage: RequestStage,
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

    // The transfer id an intercept id holds, leaving the entry in place.
    pub fn get(self: *const InterceptState, intercept_id: u32) ?u32 {
        return self.waiting.get(intercept_id);
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

        const source: []const RequestPattern = patterns orelse &.{.{}};

        const owned = try self.allocator.alloc(Pattern, source.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |pattern| {
                self.allocator.free(pattern.url);
            }
            self.allocator.free(owned);
        }
        for (source) |pattern| {
            owned[initialized] = .{
                .url = try self.allocator.dupe(u8, pattern.urlPattern),
                .resource_type = pattern.resourceType,
                .stage = pattern.requestStage,
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

    pub fn matches(self: *const InterceptState, stage: RequestStage, url: []const u8, resource_type: HttpClient.Request.ResourceType) bool {
        for (self.patterns) |pattern| {
            if (pattern.stage != stage) {
                continue;
            }
            if (pattern.resource_type) |rt| {
                const wanted: ResourceType = switch (rt) {
                    .Fetch, .EventSource => .XHR,
                    else => rt,
                };
                if (wanted != cdpResourceType(resource_type)) {
                    continue;
                }
            }
            if (wildcardMatch(pattern.url, url)) {
                return true;
            }
        }
        return false;
    }

    // Unlike the Network domain, Chrome's Fetch domain doesn't tell XHR,
    // fetch() and EventSource apart (they are all Blink's kXhr): they pause as
    // XHR, and a pattern for any one of the three matches all of them.
    fn cdpResourceType(resource_type: HttpClient.Request.ResourceType) ResourceType {
        return switch (resource_type) {
            .document => .Document,
            .xhr, .fetch, .eventsource => .XHR,
            .script, .worker => .Script,
            .stylesheet => .Stylesheet,
            .image => .Image,
            .text_track => .TextTrack,
            .beacon => .Ping,
            .download => .Other,
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
const repeat = @import("../../../string.zig").repeat;
test "cdp.Fetch: interception events belong to the enabling session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });
    _ = try bc.attachSession("SID-AUX", null);

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
    var state = try InterceptState.init(testing.allocator);
    defer state.deinit();

    // disabled: nothing is paused
    try testing.expectEqual(false, state.matches(.Request, "http://h/", .document));

    // omitted patterns = every request
    try state.setPatterns(null);
    try testing.expect(state.matches(.Request, "http://h/", .document));
    try testing.expect(state.matches(.Request, "http://h/x.js", .script));

    // an explicit empty list = no request
    try state.setPatterns(&.{});
    try testing.expectEqual(false, state.matches(.Request, "http://h/", .document));

    try state.setPatterns(&.{
        .{ .urlPattern = "*/api/*", .resourceType = .XHR },
        .{ .urlPattern = "*.css", .requestStage = .Response },
    });
    try testing.expectEqual(2, state.patterns.len);
    try testing.expect(state.matches(.Request, "http://h/api/x", .xhr));
    // Like Chrome, XHR also covers fetch() and EventSource
    try testing.expect(state.matches(.Request, "http://h/api/x", .fetch));
    try testing.expect(state.matches(.Request, "http://h/api/x", .eventsource));
    try testing.expectEqual(false, state.matches(.Request, "http://h/api/x", .script));
    try testing.expectEqual(false, state.matches(.Request, "http://h/other", .xhr));
    // A pattern pauses only at its own stage
    try testing.expect(state.matches(.Response, "http://h/a.css", .stylesheet));
    try testing.expectEqual(false, state.matches(.Request, "http://h/a.css", .stylesheet));
    try testing.expectEqual(false, state.matches(.Response, "http://h/api/x", .xhr));

    state.clearPatterns();
    try testing.expectEqual(false, state.matches(.Request, "http://h/api/x", .xhr));
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
    try testing.expect(bc.intercept_state.matches(.Request, "http://h/json/a", .fetch));
    try testing.expect(bc.intercept_state.matches(.Request, "http://h/json/a", .xhr));
    try testing.expectEqual(false, bc.intercept_state.matches(.Request, "http://h/json/a", .script));
    try testing.expect(bc.intercept_state.matches(.Request, "http://h/exact", .xhr));
    try testing.expectEqual(false, bc.intercept_state.matches(.Request, "http://h/", .document));

    // re-enable without patterns = catch-all
    try ctx.processMessage(.{ .id = 2, .method = "Fetch.enable", .sessionId = "SID-P" });
    try ctx.expectSentResult(null, .{ .id = 2, .session_id = "SID-P" });
    try testing.expect(bc.intercept_state.matches(.Request, "http://h/", .document));

    // explicit empty list = pause nothing; rejected when auth handling is on
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.enable", .params = .{ .patterns = .{} }, .sessionId = "SID-P" });
    try ctx.expectSentResult(null, .{ .id = 3, .session_id = "SID-P" });
    try testing.expectEqual(false, bc.intercept_state.matches(.Request, "http://h/", .document));
    try ctx.processMessage(.{ .id = 4, .method = "Fetch.enable", .params = .{ .patterns = .{}, .handleAuthRequests = true }, .sessionId = "SID-P" });
    try ctx.expectSentError(-32602, "Can't specify empty patterns with handleAuth set", .{ .id = 4 });

    try ctx.processMessage(.{ .id = 5, .method = "Fetch.disable", .sessionId = "SID-P" });
    try testing.expectEqual(0, bc.intercept_state.patterns.len);
    try testing.expectEqual(false, bc.intercept_state.matches(.Request, "http://h/", .document));
}

// Response-stage tests drive real requests against the test server and read
// the outcome through the request's own callbacks.
const ResponseStageProbe = struct {
    streaming: bool = false,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,
    done: bool = false,
    err: ?anyerror = null,

    fn deinit(self: *ResponseStageProbe) void {
        self.body.deinit(testing.allocator);
    }

    fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
        const self: *ResponseStageProbe = @ptrCast(@alignCast(transfer.req.ctx));
        self.status = transfer.responseStatus() orelse 0;
        return .proceed;
    }

    fn dataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
        const self: *ResponseStageProbe = @ptrCast(@alignCast(transfer.req.ctx));
        try self.body.appendSlice(testing.allocator, data);
    }

    fn doneCallback(raw: *anyopaque) !void {
        const self: *ResponseStageProbe = @ptrCast(@alignCast(raw));
        self.done = true;
    }

    fn errorCallback(raw: *anyopaque, err: anyerror) void {
        const self: *ResponseStageProbe = @ptrCast(@alignCast(raw));
        self.err = err;
    }

    fn start(self: *ResponseStageProbe, bc: *CDP.BrowserContext, url: [:0]const u8) !void {
        const page = try bc.session.createPage();
        try bc.cdp.browser.http_client.request(.{
            .frame_id = page.frame_id,
            .loader_id = 7,
            .method = .GET,
            .url = url,
            .origin = bc.security_origin,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .script,
            .streaming = self.streaming,
            .notification = bc.session.notification,
            .ctx = self,
            .header_callback = headerCallback,
            .data_callback = dataCallback,
            .done_callback = doneCallback,
            .error_callback = errorCallback,
            .shutdown_callback = HttpClient.noopShutdown,
        }, null);
    }

    // Ticks the client until `count` transfers are parked for interception.
    fn tickUntilPaused(bc: *CDP.BrowserContext, count: usize) !void {
        const client = &bc.cdp.browser.http_client;
        for (0..100) |_| {
            if (client.intercepted >= count) return;
            _ = try client.tick(20);
        }
        return error.NeverPaused;
    }

    // Ticks the client until the request's done or error callback has run.
    fn tickUntilSettled(self: *const ResponseStageProbe, bc: *CDP.BrowserContext) !void {
        const client = &bc.cdp.browser.http_client;
        for (0..100) |_| {
            if (self.done or self.err != null) return;
            _ = try client.tick(20);
        }
        return error.NeverSettled;
    }
};

// The params of the Fetch.requestPaused event carrying `request_id`.
fn sentPausedParams(ctx: anytype, request_id: []const u8) !std.json.ObjectMap {
    for (ctx.received.items) |message| {
        const method = message.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "Fetch.requestPaused")) continue;
        const params = message.object.get("params").?.object;
        if (std.mem.eql(u8, params.get("requestId").?.string, request_id)) return params;
    }
    return error.PausedEventNotSent;
}

fn enableResponseStage(ctx: anytype) !void {
    try ctx.processMessage(.{
        .id = 1,
        .method = "Fetch.enable",
        .params = .{ .patterns = .{.{ .urlPattern = "*", .requestStage = "Response" }} },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
}

test "cdp.Fetch: response stage pauses a final response and continueResponse delivers it" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
        .resourceType = "Script",
        .responseStatusCode = 200,
    }, .{ .session_id = "SID-RS" });
    const paused = try sentPausedParams(&ctx, "INT-0000000001");
    try testing.expectEqual(null, paused.get("responseErrorReason"));
    var has_content_type = false;
    for (paused.get("responseHeaders").?.array.items) |header| {
        if (std.mem.eql(u8, header.object.get("name").?.string, "content-type")) {
            has_content_type = std.mem.eql(u8, header.object.get("value").?.string, "text/html; charset=utf-8");
        }
    }
    try testing.expect(has_content_type);

    // Paused means not delivered: the consumer has seen nothing yet.
    try testing.expectEqual(false, probe.done);
    try testing.expectEqual(0, probe.body.items.len);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.getResponseBody", .params = .{ .requestId = "INT-0000000001" } });
    // repeat("1234567890", 10), base64 like Chrome even for text
    try ctx.expectSentResult(.{ .body = "MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MA==", .base64Encoded = true }, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 3 });

    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expect(probe.done);
    try testing.expectEqualSlices(u8, repeat("1234567890", 10), probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage reports a non-UTF-8 status text and headers as strings" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/latin1_response");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    // Latin-1 is transcoded to UTF-8, not written as an array of numbers.
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .responseStatusCode = 200,
        .responseStatusText = "Caf\xC3\xA9",
    }, .{ .session_id = "SID-RS" });
    var latin1_value: ?[]const u8 = null;
    var latin1_name = false;
    for ((try sentPausedParams(&ctx, "INT-0000000001")).get("responseHeaders").?.array.items) |header| {
        const name = header.object.get("name").?;
        const value = header.object.get("value").?;
        try testing.expect(name == .string and value == .string);
        if (std.mem.eql(u8, name.string, "x-latin1")) latin1_value = value.string;
        if (std.mem.eql(u8, name.string, "x-caf\xC3\xA9")) latin1_name = true;
    }
    try testing.expectEqualSlices(u8, "La\xC2\xA0Paz", latin1_value.?);
    try testing.expect(latin1_name);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, "latin1", probe.body.items);
}

test "cdp.Fetch: response stage failRequest fails the request without delivering it" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.failRequest", .params = .{ .requestId = "INT-0000000001", .errorReason = "Aborted" } });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try probe.tickUntilSettled(bc);
    try testing.expectEqual(error.TransferCanceled, probe.err.?);
    try testing.expectEqual(false, probe.done);
    try testing.expectEqual(0, probe.body.items.len);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage fulfillRequest replaces the response" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Fetch.fulfillRequest",
        .params = .{
            .requestId = "INT-0000000001",
            .responseCode = 200,
            .responseHeaders = &[_]http.Header{.{ .name = "content-type", .value = "text/plain" }},
            .body = "ZnVsZmlsbGVk", // "fulfilled"
        },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, "fulfilled", probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage getResponseBody returns a binary body byte-exact" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/images/small.png");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    // The bytes the test server sends for /images/small.png.
    var png: [1024]u8 = undefined;
    @memset(&png, 'x');
    @memcpy(png[0..24], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x40\x00\x00\x00\xf0");
    var encoded: [std.base64.standard.Encoder.calcSize(png.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &png);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.getResponseBody", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(.{ .body = &encoded, .base64Encoded = true }, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqualSlices(u8, &png, probe.body.items);
}

test "cdp.Fetch: response stage pauses a redirect response, then the response it leads to" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/redirect");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .request = .{ .url = "http://127.0.0.1:9582/xhr/redirect" },
        .responseStatusCode = 302,
    }, .{ .session_id = "SID-RS" });
    var location: ?[]const u8 = null;
    for ((try sentPausedParams(&ctx, "INT-0000000001")).get("responseHeaders").?.array.items) |header| {
        if (std.mem.eql(u8, header.object.get("name").?.string, "location")) {
            location = header.object.get("value").?.string;
        }
    }
    try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/xhr", location.?);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.getResponseBody", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentError(-32000, "Can only get response body on requests captured after headers received.", .{ .id = 2 });

    // Releasing the redirect follows it; the redirected request's response pauses in turn.
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
        .responseStatusCode = 200,
    }, .{ .session_id = "SID-RS" });

    try ctx.processMessage(.{ .id = 4, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, repeat("1234567890", 10), probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage continueRequest ignores request overrides, but a url replaces a redirect's Location" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/redirect");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{
        .requestId = "INT-0000000001",
        .url = "http://127.0.0.1:9582/images/small.png",
        .method = "POST",
    } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .request = .{ .url = "http://127.0.0.1:9582/images/small.png", .method = "GET" },
    }, .{ .session_id = "SID-RS" });

    // Not a redirect: the url is ignored, like the rest.
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueRequest", .params = .{
        .requestId = "INT-0000000002",
        .url = "http://127.0.0.1:9582/xhr",
    } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqual(1024, probe.body.items.len);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: continueRequest interceptResponse pauses the response without a Response pattern" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try ctx.processMessage(.{ .id = 1, .method = "Fetch.enable", .params = .{ .patterns = .{.{ .urlPattern = "*" }} } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001", .interceptResponse = true } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
        .responseStatusCode = 200,
    }, .{ .session_id = "SID-RS" });
    try testing.expectEqual(false, probe.done);

    try ctx.processMessage(.{ .id = 3, .method = "Fetch.getResponseBody", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(.{ .body = "MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MA==", .base64Encoded = true }, .{ .id = 3 });

    try ctx.processMessage(.{ .id = 4, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, repeat("1234567890", 10), probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: continueRequest interceptResponse covers one hop, its redirect included" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try ctx.processMessage(.{ .id = 1, .method = "Fetch.enable", .params = .{ .patterns = .{.{ .urlPattern = "*" }} } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/redirect");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001", .interceptResponse = true } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .request = .{ .url = "http://127.0.0.1:9582/xhr/redirect" },
        .responseStatusCode = 302,
    }, .{ .session_id = "SID-RS" });

    // Following the redirect starts a new hop: its request pauses, and
    // without a new interceptResponse its response does not.
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000003",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
    }, .{ .session_id = "SID-RS" });
    try testing.expectEqual(null, (try sentPausedParams(&ctx, "INT-0000000003")).get("responseStatusCode"));

    try ctx.processMessage(.{ .id = 4, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000003" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, repeat("1234567890", 10), probe.body.items);
    try testing.expectEqual(error.PausedEventNotSent, sentPausedParams(&ctx, "INT-0000000004"));
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: continueRequest interceptResponse false skips a matching Response pattern" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try ctx.processMessage(.{ .id = 1, .method = "Fetch.enable", .params = .{ .patterns = .{
        .{ .urlPattern = "*" },
        .{ .urlPattern = "*", .requestStage = "Response" },
    } } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001", .interceptResponse = false } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqualSlices(u8, repeat("1234567890", 10), probe.body.items);
    try testing.expectEqual(error.PausedEventNotSent, sentPausedParams(&ctx, "INT-0000000002"));
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage pauses a network failure with responseErrorReason" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    // Nothing listens on port 1: the connection is refused.
    try probe.start(bc, "http://127.0.0.1:1/");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .request = .{ .url = "http://127.0.0.1:1/" },
        .responseErrorReason = "ConnectionFailed",
    }, .{ .session_id = "SID-RS" });
    const paused = try sentPausedParams(&ctx, "INT-0000000001");
    try testing.expectEqual(null, paused.get("responseStatusCode"));
    try testing.expectEqual(null, paused.get("responseHeaders"));

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.getResponseBody", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentError(-32000, "Can only get response body on requests captured after headers received.", .{ .id = 2 });

    // Releasing it unchanged reports the original failure.
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueResponse", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(error.CouldntConnect, probe.err.?);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: response stage does not pause a stream it already delivered" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{ .streaming = true };
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/sse/simple");
    try probe.tickUntilSettled(bc);

    try testing.expectEqual(null, probe.err);
    try testing.expectEqual(73, probe.body.items.len);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
    try testing.expectEqual(error.PausedEventNotSent, sentPausedParams(&ctx, "INT-0000000001"));
}

test "cdp.Fetch: closing the browser context releases a response-stage pause" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RS", .session_id = "SID-RS" });
    try enableResponseStage(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    // Never released by CDP: disposing the context must abort it, and the
    // testing allocator fails the test if anything it held leaks.
    ctx.cdp().disposeBrowserContext();
    try testing.expectEqual(false, probe.done);
}

fn enableAuthHandling(ctx: anytype) !void {
    try ctx.processMessage(.{
        .id = 1,
        .method = "Fetch.enable",
        .params = .{ .patterns = .{.{ .urlPattern = "*" }}, .handleAuthRequests = true },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
}

fn sentEventCount(ctx: anytype, method: []const u8) usize {
    var count: usize = 0;
    for (ctx.received.items) |message| {
        const m = message.object.get("method") orelse continue;
        if (std.mem.eql(u8, m.string, method)) count += 1;
    }
    return count;
}

test "cdp.Fetch: a 401 without WWW-Authenticate is delivered, not an auth challenge" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-AU", .session_id = "SID-AU" });
    try enableAuthHandling(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/status/401");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expect(probe.done);
    try testing.expectEqual(401, probe.status);
    try testing.expectEqual(0, sentEventCount(&ctx, "Fetch.authRequired"));
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

fn expectAuthDeclinedDeliversResponse(response: []const u8) !void {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-AU", .session_id = "SID-AU" });
    try enableAuthHandling(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/401");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.expectSentEvent("Fetch.authRequired", .{
        .requestId = "INT-0000000002",
        .request = .{ .url = "http://127.0.0.1:9582/xhr/401" },
        .authChallenge = .{ .source = "Server", .scheme = "basic" },
    }, .{ .session_id = "SID-AU" });
    try testing.expectEqual(false, probe.done);

    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueWithAuth", .params = .{
        .requestId = "INT-0000000002",
        .authChallengeResponse = .{ .response = response },
    } });
    try ctx.expectSentResult(null, .{ .id = 3 });

    // Like Chrome, declining the challenge delivers the original response.
    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expect(probe.done);
    try testing.expectEqual(401, probe.status);
    try testing.expectEqualSlices(u8, "No", probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: continueWithAuth Default delivers the 401" {
    try expectAuthDeclinedDeliversResponse("Default");
}

test "cdp.Fetch: continueWithAuth CancelAuth delivers the 401" {
    try expectAuthDeclinedDeliversResponse("CancelAuth");
}

test "cdp.Fetch: continueWithAuth ProvideCredentials retries, a declined retry delivers the 401" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-AU", .session_id = "SID-AU" });
    try enableAuthHandling(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/401");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    // The test server rejects any credentials: the retry is challenged again.
    try ctx.processMessage(.{ .id = 3, .method = "Fetch.continueWithAuth", .params = .{
        .requestId = "INT-0000000002",
        .authChallengeResponse = .{ .response = "ProvideCredentials", .username = "u", .password = "p" },
    } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.authRequired", .{ .requestId = "INT-0000000003" }, .{ .session_id = "SID-AU" });

    try ctx.processMessage(.{ .id = 4, .method = "Fetch.continueWithAuth", .params = .{
        .requestId = "INT-0000000003",
        .authChallengeResponse = .{ .response = "CancelAuth" },
    } });
    try ctx.expectSentResult(null, .{ .id = 4 });

    try probe.tickUntilSettled(bc);
    try testing.expectEqual(null, probe.err);
    try testing.expect(probe.done);
    try testing.expectEqual(401, probe.status);
    try testing.expectEqualSlices(u8, "No", probe.body.items);
    try testing.expectEqual(0, bc.cdp.browser.http_client.intercepted);
}

test "cdp.Fetch: continueWithAuth on a request-stage pause is rejected and keeps the pause" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-AU", .session_id = "SID-AU" });
    try enableAuthHandling(&ctx);

    var probe: ResponseStageProbe = .{};
    defer probe.deinit();
    try probe.start(bc, "http://127.0.0.1:9582/xhr/401");
    try ResponseStageProbe.tickUntilPaused(bc, 1);

    for ([_][]const u8{ "CancelAuth", "ProvideCredentials" }, 2..) |response, cmd_id| {
        try ctx.processMessage(.{ .id = cmd_id, .method = "Fetch.continueWithAuth", .params = .{
            .requestId = "INT-0000000001",
            .authChallengeResponse = .{ .response = response },
        } });
        try ctx.expectSentError(-32000, "Invalid InterceptionId.", .{ .id = cmd_id });
    }
    try testing.expectEqual(false, probe.done);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqual(1, bc.cdp.browser.http_client.intercepted);

    // Still paused at the request stage: continueRequest resumes it.
    try ctx.processMessage(.{ .id = 4, .method = "Fetch.continueRequest", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ResponseStageProbe.tickUntilPaused(bc, 1);
    try ctx.expectSentEvent("Fetch.authRequired", .{ .requestId = "INT-0000000002" }, .{ .session_id = "SID-AU" });

    try ctx.processMessage(.{ .id = 5, .method = "Fetch.continueWithAuth", .params = .{
        .requestId = "INT-0000000002",
        .authChallengeResponse = .{ .response = "Default" },
    } });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try probe.tickUntilSettled(bc);
    try testing.expect(probe.done);
    try testing.expectEqual(401, probe.status);
}

test "cdp.Fetch: cdpErrorReason" {
    try testing.expectEqual(network.ErrorReason.TimedOut, cdpErrorReason(error.OperationTimedout));
    try testing.expectEqual(network.ErrorReason.NameNotResolved, cdpErrorReason(error.CouldntResolveHost));
    try testing.expectEqual(network.ErrorReason.NameNotResolved, cdpErrorReason(error.CouldntResolveProxy));
    try testing.expectEqual(network.ErrorReason.ConnectionFailed, cdpErrorReason(error.CouldntConnect));
    try testing.expectEqual(network.ErrorReason.ConnectionClosed, cdpErrorReason(error.GotNothing));
    try testing.expectEqual(network.ErrorReason.ConnectionReset, cdpErrorReason(error.RecvError));
    try testing.expectEqual(network.ErrorReason.ConnectionReset, cdpErrorReason(error.SendError));
    try testing.expectEqual(network.ErrorReason.Failed, cdpErrorReason(error.SslConnectError));
}

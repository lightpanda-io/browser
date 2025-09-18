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
const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const network = @import("network.zig");

const Http = @import("../../http/Http.zig");
const Notification = @import("../../notification.zig").Notification;

pub fn processMessage(cmd: anytype) !void {
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

// Stored in CDP
pub const InterceptState = struct {
    allocator: Allocator,
    waiting: std.AutoArrayHashMapUnmanaged(u64, *Http.Transfer),

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = .empty,
            .allocator = allocator,
        };
    }

    pub fn empty(self: *const InterceptState) bool {
        return self.waiting.count() == 0;
    }

    pub fn put(self: *InterceptState, transfer: *Http.Transfer) !void {
        return self.waiting.put(self.allocator, transfer.id, transfer);
    }

    pub fn remove(self: *InterceptState, id: u64) ?*Http.Transfer {
        const entry = self.waiting.fetchSwapRemove(id) orelse return null;
        return entry.value;
    }

    pub fn deinit(self: *InterceptState) void {
        self.waiting.deinit(self.allocator);
    }

    pub fn pendingTransfers(self: *const InterceptState) []*Http.Transfer {
        return self.waiting.values();
    }
};

const RequestPattern = struct {
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
    patterns: []RequestPattern = &.{},
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

fn disable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.fetchDisable();
    return cmd.sendResult(null, .{});
}

fn enable(cmd: anytype) !void {
    const params = (try cmd.params(EnableParam)) orelse EnableParam{};
    if (!arePatternsSupported(params.patterns)) {
        log.warn(.cdp, "not implemented", .{ .feature = "Fetch.enable advanced patterns are not" });
        return cmd.sendResult(null, .{});
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.fetchEnable(params.handleAuthRequests);

    return cmd.sendResult(null, .{});
}

fn arePatternsSupported(patterns: []RequestPattern) bool {
    if (patterns.len == 0) {
        return true;
    }
    if (patterns.len > 1) {
        return false;
    }

    // While we don't support patterns, yet, both Playwright and Puppeteer send
    // a default pattern which happens to be what we support:
    // [{"urlPattern":"*","requestStage":"Request"}]
    // So, rather than erroring on this case because we don't support patterns,
    // we'll allow it, because this pattern is how it works as-is.
    const pattern = patterns[0];
    if (!std.mem.eql(u8, pattern.urlPattern, "*")) {
        return false;
    }
    if (pattern.resourceType != null) {
        return false;
    }
    if (pattern.requestStage != .Request) {
        return false;
    }
    return true;
}

pub fn requestIntercept(arena: Allocator, bc: anytype, intercept: *const Notification.RequestIntercept) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const target_id = bc.target_id orelse unreachable;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(transfer);

    try bc.cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = try std.fmt.allocPrint(arena, "INTERCEPT-{d}", .{transfer.id}),
        .request = network.TransferAsRequestWriter.init(transfer),
        .frameId = target_id,
        .resourceType = switch (transfer.req.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
        .networkId = try std.fmt.allocPrint(arena, "REQ-{d}", .{transfer.id}),
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request intercept", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.uri,
    });
    // Await either continueRequest, failRequest or fulfillRequest

    intercept.wait_for_interception.* = true;
}

fn continueRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        url: ?[]const u8 = null,
        method: ?[]const u8 = null,
        postData: ?[]const u8 = null,
        headers: ?[]const Http.Header = null,
        interceptResponse: bool = false,
    })) orelse return error.InvalidParams;

    if (params.interceptResponse) {
        return error.NotImplemented;
    }

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "continue",
        .id = transfer.id,
        .url = transfer.uri,
        .new_url = params.url,
    });

    const arena = transfer.arena.allocator();
    // Update the request with the new parameters
    if (params.url) |url| {
        try transfer.updateURL(try arena.dupeZ(u8, url));
    }
    if (params.method) |method| {
        transfer.req.method = std.meta.stringToEnum(Http.Method, method) orelse return error.InvalidParams;
    }

    if (params.headers) |headers| {
        // Not obvious, but cmd.arena is safe here, since the headers will get
        // duped by libcurl. transfer.arena is more obvious/safe, but cmd.arena
        // is more efficient (it's re-used)
        try transfer.replaceRequestHeaders(cmd.arena, headers);
    }

    if (params.postData) |b| {
        const decoder = std.base64.standard.Decoder;
        const body = try arena.alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(body, b);
        transfer.req.body = body;
    }

    try bc.cdp.browser.http_client.continueTransfer(transfer);
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Fetch/#type-AuthChallengeResponse
const AuthChallengeResponse = enum {
    Default,
    CancelAuth,
    ProvideCredentials,
};

fn continueWithAuth(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        authChallengeResponse: struct {
            response: AuthChallengeResponse,
            username: []const u8 = "",
            password: []const u8 = "",
        },
    })) orelse return error.InvalidParams;

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "continue with auth",
        .id = transfer.id,
        .response = params.authChallengeResponse.response,
    });

    if (params.authChallengeResponse.response != .ProvideCredentials) {
        transfer.abortAuthChallenge();
        return cmd.sendResult(null, .{});
    }

    // cancel the request, deinit the transfer on error.
    errdefer transfer.abortAuthChallenge();

    // restart the request with the provided credentials.
    const arena = transfer.arena.allocator();
    transfer.updateCredentials(
        try std.fmt.allocPrintSentinel(arena, "{s}:{s}", .{
            params.authChallengeResponse.username,
            params.authChallengeResponse.password,
        }, 0),
    );

    transfer.reset();
    try bc.cdp.browser.http_client.continueTransfer(transfer);
    return cmd.sendResult(null, .{});
}

fn fulfillRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        responseCode: u16,
        responseHeaders: ?[]const Http.Header = null,
        binaryResponseHeaders: ?[]const u8 = null,
        body: ?[]const u8 = null,
        responsePhrase: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.binaryResponseHeaders != null) {
        log.warn(.cdp, "not implemented", .{ .feature = "Fetch.fulfillRequest binaryResponseHeade" });
        return error.NotImplemented;
    }

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "fulfilled",
        .id = transfer.id,
        .url = transfer.uri,
        .status = params.responseCode,
        .body = params.body != null,
    });

    var body: ?[]const u8 = null;
    if (params.body) |b| {
        const decoder = std.base64.standard.Decoder;
        const buf = try transfer.arena.allocator().alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(buf, b);
        body = buf;
    }

    try bc.cdp.browser.http_client.fulfillTransfer(transfer, params.responseCode, params.responseHeaders orelse &.{}, body);

    return cmd.sendResult(null, .{});
}

fn failRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        errorReason: ErrorReason,
    })) orelse return error.InvalidParams;

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);

    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;
    defer bc.cdp.browser.http_client.abortTransfer(transfer);

    log.info(.cdp, "request intercept", .{
        .state = "fail",
        .id = request_id,
        .url = transfer.uri,
        .reason = params.errorReason,
    });
    return cmd.sendResult(null, .{});
}

pub fn requestAuthRequired(arena: Allocator, bc: anytype, intercept: *const Notification.RequestAuthRequired) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const target_id = bc.target_id orelse unreachable;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(transfer);

    const challenge = transfer._auth_challenge orelse return error.NullAuthChallenge;

    try bc.cdp.sendEvent("Fetch.authRequired", .{
        .requestId = try std.fmt.allocPrint(arena, "INTERCEPT-{d}", .{transfer.id}),
        .request = network.TransferAsRequestWriter.init(transfer),
        .frameId = target_id,
        .resourceType = switch (transfer.req.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
        .authChallenge = .{
            .source = if (challenge.source == .server) "Server" else "Proxy",
            .origin = "", // TODO get origin, could be the proxy address for example.
            .scheme = if (challenge.scheme == .digest) "digest" else "basic",
            .realm = challenge.realm,
        },
        .networkId = try std.fmt.allocPrint(arena, "REQ-{d}", .{transfer.id}),
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request auth required", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.uri,
    });
    // Await continueWithAuth

    intercept.wait_for_interception.* = true;
}

// Get u64 from requestId which is formatted as: "INTERCEPT-{d}"
fn idFromRequestId(request_id: []const u8) !u64 {
    if (!std.mem.startsWith(u8, request_id, "INTERCEPT-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u64, request_id[10..], 10) catch return error.InvalidParams;
}

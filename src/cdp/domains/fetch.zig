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

const HttpClient = @import("../../browser/HttpClient.zig");
const http = @import("../../network/http.zig");
const Notification = @import("../../Notification.zig");

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

// Stored in CDP. Holds *transfer ids* (not *Transfer pointers) of paused
// transfers waiting for CDP continueRequest/fulfillRequest/failRequest/
// continueWithAuth. Anyone resolving an entry must look the transfer up via
// `Client.findTransfer(id)` — if the transfer has been destroyed out-of-band
// (e.g. frame shutdown), the lookup returns null and the CDP command should
// no-op rather than UAF.
pub const InterceptState = struct {
    allocator: Allocator,
    waiting: std.AutoArrayHashMapUnmanaged(u32, void),

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = .empty,
            .allocator = allocator,
        };
    }

    pub fn empty(self: *const InterceptState) bool {
        return self.waiting.count() == 0;
    }

    pub fn put(self: *InterceptState, transfer_id: u32) !void {
        return self.waiting.put(self.allocator, transfer_id, {});
    }

    // Returns true if the id was present and removed, false otherwise.
    pub fn remove(self: *InterceptState, transfer_id: u32) bool {
        return self.waiting.swapRemove(transfer_id);
    }

    pub fn deinit(self: *InterceptState) void {
        self.waiting.deinit(self.allocator);
    }

    pub fn pendingIntercepts(self: *const InterceptState) []u32 {
        return self.waiting.keys();
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

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.fetchDisable();
    return cmd.sendResult(null, .{});
}

fn enable(cmd: *CDP.Command) !void {
    const params = (try cmd.params(EnableParam)) orelse EnableParam{};
    if (!arePatternsSupported(params.patterns)) {
        log.warn(.not_implemented, "Fetch.enable", .{ .params = "pattern" });
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

pub fn requestIntercept(bc: *CDP.BrowserContext, intercept: *const Notification.RequestIntercept) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    // We keep it around to wait for modifications to the request.
    // TODO: What to do when receiving replies for a previous frame's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(transfer.id);

    try bc.cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = &id.toInterceptId(transfer.id),
        .frameId = &id.toFrameId(transfer.req.frame_id),
        .request = network.RequestWriter.init(transfer),
        .resourceType = switch (transfer.req.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
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
    const transfer_id = try idFromRequestId(params.requestId);

    if (!intercept_state.remove(transfer_id)) return error.RequestNotFound;
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
        request.headers.deinit();

        var buf: std.ArrayList(u8) = .empty;
        var new_headers = try bc.cdp.browser.http_client.newHeaders();
        for (headers) |hdr| {
            defer buf.clearRetainingCapacity();
            try std.fmt.format(buf.writer(cmd.arena), "{s}: {s}", .{ hdr.name, hdr.value });
            try buf.append(cmd.arena, 0);
            try new_headers.add(buf.items[0 .. buf.items.len - 1 :0]);
        }
        request.headers = new_headers;
    }

    if (params.postData) |b| {
        const decoder = std.base64.standard.Decoder;
        const body = try arena.alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(body, b);
        request.body = body;
    }

    try client.interception_layer.continueRequest(transfer);
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
    const transfer_id = try idFromRequestId(params.requestId);

    if (!intercept_state.remove(transfer_id)) return error.RequestNotFound;
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

    // TODO: double-decrement of interception_layer.intercepted if
    // continueTransfer fails: continueTransfer decrements unconditionally,
    // and the errdefer below decrements again via abortAuthChallenge.
    // Worse: if continueTransfer's failure path destroys the transfer
    // (start_callback fail in makeRequest), this errdefer hits a freed
    // transfer. Pre-existing; needs makeRequest failure-semantics cleanup.
    errdefer transfer.abortAuthChallenge();

    transfer.updateCredentials(try std.fmt.allocPrintSentinel(
        transfer.arena,
        "{s}:{s}",
        .{
            params.authChallengeResponse.username,
            params.authChallengeResponse.password,
        },
        0,
    ));

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
    const transfer_id = try idFromRequestId(params.requestId);

    if (!intercept_state.remove(transfer_id)) return error.RequestNotFound;
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

    try client.interception_layer.fulfillRequest(transfer, params.responseCode, params.responseHeaders orelse &.{}, body);
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
    const transfer_id = try idFromRequestId(params.requestId);

    if (!intercept_state.remove(transfer_id)) return error.RequestNotFound;
    const transfer = client.findTransfer(transfer_id) orelse {
        log.debug(.cdp, "intercept lookup miss", .{ .id = transfer_id, .op = "fail" });
        return cmd.sendResult(null, .{});
    };

    defer client.interception_layer.abortRequest(transfer);

    log.info(.cdp, "request intercept", .{
        .state = "fail",
        .id = transfer.id,
        .url = transfer.req.url,
        .reason = params.errorReason,
    });
    return cmd.sendResult(null, .{});
}

pub fn requestAuthRequired(bc: *CDP.BrowserContext, intercept: *const Notification.RequestAuthRequired) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous frame's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(transfer.id);
    const request = &transfer.req;

    const challenge = transfer._auth_challenge orelse return error.NullAuthChallenge;

    try bc.cdp.sendEvent("Fetch.authRequired", .{
        .requestId = &id.toInterceptId(transfer.id),
        .frameId = &id.toFrameId(request.frame_id),
        .request = network.RequestWriter.init(transfer),
        .resourceType = switch (request.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
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

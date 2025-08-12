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
const Notification = @import("../../notification.zig").Notification;
const log = @import("../../log.zig");
const Request = @import("../../http/Client.zig").Request;
const Method = @import("../../http/Client.zig").Method;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        disable,
        enable,
        continueRequest,
        failRequest,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .disable => return disable(cmd),
        .enable => return enable(cmd),
        .continueRequest => return continueRequest(cmd),
        .failRequest => return failRequest(cmd),
    }
}

// Stored in CDP
pub const InterceptState = struct {
    const Self = @This();
    waiting: std.AutoArrayHashMap(u64, Request),

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = std.AutoArrayHashMap(u64, Request).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.waiting.deinit();
    }
};

const RequestPattern = struct {
    urlPattern: []const u8 = "*", // Wildcards ('*' -> zero or more, '?' -> exactly one) are allowed. Escape character is backslash. Omitting is equivalent to "*".
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
    if (params.patterns.len != 0) log.warn(.cdp, "Fetch.enable No patterns yet", .{});
    if (params.handleAuthRequests) log.warn(.cdp, "Fetch.enable No auth yet", .{});

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.fetchEnable();

    return cmd.sendResult(null, .{});
}

pub fn requestPaused(arena: Allocator, bc: anytype, intercept: *const Notification.RequestIntercept) !void {
    var cdp = bc.cdp;

    // unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    try cdp.intercept_state.waiting.put(intercept.request.id.?, intercept.request.*);

    // NOTE: .request data preparation is duped from network.zig
    const full_request_url = try std.Uri.parse(intercept.request.url);
    const request_url = try @import("network.zig").urlToString(arena, &full_request_url, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
    });
    const request_fragment = try @import("network.zig").urlToString(arena, &full_request_url, .{
        .fragment = true,
    });
    const headers = try intercept.request.headers.asHashMap(arena);
    // End of duped code

    try cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = try std.fmt.allocPrint(arena, "INTERCEPT-{d}", .{intercept.request.id.?}),
        .request = .{
            .url = request_url,
            .urlFragment = request_fragment,
            .method = @tagName(intercept.request.method),
            .hasPostData = intercept.request.body != null,
            .headers = std.json.ArrayHashMap([]const u8){ .map = headers },
        },
        .frameId = target_id,
        .resourceType = ResourceType.Document, //  TODO!
        .networkId = try std.fmt.allocPrint(arena, "REQ-{d}", .{intercept.request.id.?}),
    }, .{ .session_id = session_id });

    // Await either continueRequest, failRequest or fulfillRequest
    intercept.wait_for_interception.* = true;
}

const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

fn continueRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        url: ?[]const u8 = null,
        method: ?[]const u8 = null,
        postData: ?[]const u8 = null,
        headers: ?[]const HeaderEntry = null,
        interceptResponse: bool = false,
    })) orelse return error.InvalidParams;
    if (params.postData != null or params.headers != null or params.interceptResponse) return error.NotYetImplementedParams;

    const request_id = try idFromRequestId(params.requestId);
    var waiting_request = (bc.cdp.intercept_state.waiting.fetchSwapRemove(request_id) orelse return error.RequestNotFound).value;

    // Update the request with the new parameters
    if (params.url) |url| {
        // The request url must be modified in a way that's not observable by page. So page.url is not updated.
        waiting_request.url = try bc.cdp.browser.page_arena.allocator().dupeZ(u8, url);
    }
    if (params.method) |method| {
        waiting_request.method = std.meta.stringToEnum(Method, method) orelse return error.InvalidParams;
    }

    log.info(.cdp, "Request continued by intercept", .{ .id = params.requestId });
    try bc.cdp.browser.http_client.request(waiting_request);

    return cmd.sendResult(null, .{});
}

fn failRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    var state = &bc.cdp.intercept_state;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        errorReason: ErrorReason,
    })) orelse return error.InvalidParams;

    const request_id = try idFromRequestId(params.requestId);
    if (state.waiting.fetchSwapRemove(request_id) == null) return error.RequestNotFound;

    log.info(.cdp, "Request aborted by intercept", .{ .reason = params.errorReason });
    return cmd.sendResult(null, .{});
}

// Get u64 from requestId which is formatted as: "INTERCEPT-{d}"
fn idFromRequestId(request_id: []const u8) !u64 {
    if (!std.mem.startsWith(u8, request_id, "INTERCEPT-")) return error.InvalidParams;
    return std.fmt.parseInt(u64, request_id[10..], 10) catch return error.InvalidParams;
}

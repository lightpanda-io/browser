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

const Method = @import("../../http/Client.zig").Method;
const Transfer = @import("../../http/Client.zig").Transfer;
const Notification = @import("../../notification.zig").Notification;

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
    allocator: Allocator,
    waiting: std.AutoArrayHashMapUnmanaged(u64, *Transfer),

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = .empty,
            .allocator = allocator,
        };
    }

    pub fn empty(self: *const InterceptState) bool {
        return self.waiting.count() == 0;
    }

    pub fn put(self: *InterceptState, transfer: *Transfer) !void {
        return self.waiting.put(self.allocator, transfer.id, transfer);
    }

    pub fn remove(self: *InterceptState, id: u64) ?*Transfer {
        const entry = self.waiting.fetchSwapRemove(id) orelse return null;
        return entry.value;
    }

    pub fn deinit(self: *InterceptState) void {
        self.waiting.deinit(self.allocator);
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
    if (params.patterns.len != 0) {
        log.warn(.cdp, "not implemented", .{ .feature = "Fetch.enable No patterns yet" });
    }
    if (params.handleAuthRequests) {
        log.warn(.cdp, "not implemented", .{ .feature = "Fetch.enable No auth yet" });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.fetchEnable();

    return cmd.sendResult(null, .{});
}

pub fn requestIntercept(arena: Allocator, bc: anytype, intercept: *const Notification.RequestIntercept) !void {
    var cdp = bc.cdp;

    // unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;
    const page = bc.session.currentPage() orelse unreachable;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    const transfer = intercept.transfer;
    try cdp.intercept_state.put(transfer);

    try cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = try std.fmt.allocPrint(arena, "INTERCEPT-{d}", .{transfer.id}),
        .request = network.TransferAsRequestWriter.init(transfer),
        .frameId = target_id,
        .resourceType = ResourceType.Document, //  TODO!
        .networkId = try std.fmt.allocPrint(arena, "REQ-{d}", .{transfer.id}),
    }, .{ .session_id = session_id });

    // Await either continueRequest, failRequest or fulfillRequest

    intercept.wait_for_interception.* = true;
    page.request_intercepted = true;
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

    if (params.postData != null or params.headers != null or params.interceptResponse) {
        return error.NotYetImplementedParams;
    }

    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    var intercept_state = &bc.cdp.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    // Update the request with the new parameters
    if (params.url) |url| {
        // The request url must be modified in a way that's not observable by page.
        // So page.url is not updated.
        try transfer.updateURL(try page.arena.dupeZ(u8, url));
    }
    if (params.method) |method| {
        transfer.req.method = std.meta.stringToEnum(Method, method) orelse return error.InvalidParams;
    }

    log.info(.cdp, "Request continued by intercept", .{
        .id = params.requestId,
        .url = transfer.uri,
    });
    try bc.cdp.browser.http_client.process(transfer);

    if (intercept_state.empty()) {
        page.request_intercepted = false;
    }

    return cmd.sendResult(null, .{});
}

fn failRequest(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INTERCEPT-{d}"
        errorReason: ErrorReason,
    })) orelse return error.InvalidParams;

    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    var intercept_state = &bc.cdp.intercept_state;
    const request_id = try idFromRequestId(params.requestId);

    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;
    transfer.abort();

    if (intercept_state.empty()) {
        page.request_intercepted = false;
    }

    log.info(.cdp, "Request aborted by intercept", .{ .reason = params.errorReason });
    return cmd.sendResult(null, .{});
}

// Get u64 from requestId which is formatted as: "INTERCEPT-{d}"
fn idFromRequestId(request_id: []const u8) !u64 {
    if (!std.mem.startsWith(u8, request_id, "INTERCEPT-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u64, request_id[10..], 10) catch return error.InvalidParams;
}

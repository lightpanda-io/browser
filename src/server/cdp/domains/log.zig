// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");
const SafeString = @import("../SafeString.zig");
const Notification = @import("../../../Notification.zig");
const Transfer = @import("../../../network/HttpClient.zig").Transfer;
const network = @import("network.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
    }
}

// The Log domain is per session, as in Chrome: entries go to the sessions
// that enabled it. Without a page target there is nothing to report.
fn attachedSession(cmd: *CDP.Command) ?*CDP.BrowserContext.AttachedSession {
    const bc = cmd.browser_context orelse return null;
    const session_id = cmd.input.session_id orelse bc.session_id orelse return null;
    return bc.attached_sessions.get(session_id);
}

fn enable(cmd: *CDP.Command) !void {
    if (attachedSession(cmd)) |attached| {
        try attached.bc.logEnable(attached);
    }
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    if (attachedSession(cmd)) |attached| {
        attached.bc.logDisable(attached);
    }
    return cmd.sendResult(null, .{});
}

const Entry = struct {
    source: []const u8 = "network",
    level: []const u8 = "error",
    // The status text comes from the wire.
    text: SafeString,
    // Runtime.Timestamp: milliseconds since the epoch.
    timestamp: u64,
    url: []const u8,
    networkRequestId: []const u8,
};

fn send(bc: *CDP.BrowserContext, session_id: []const u8, transfer: *const Transfer, text: []const u8, url: []const u8) !void {
    return bc.cdp.sendEvent("Log.entryAdded", .{ .entry = Entry{
        .text = .wrap(text),
        .timestamp = lp.datetime.milliTimestamp(.real),
        .url = url,
        .networkRequestId = &id.toRequestId(transfer),
    } }, .{ .session_id = session_id });
}

// A response with an error status, reported when it arrives, as Chrome's
// FrameConsole::ReportResourceResponseReceived does. That includes a
// document's: the error page the server sent is what the frame shows.
// The status text is the server's, empty when it sent none (HTTP/2).
pub fn httpResponseHeaderDone(arena: Allocator, bc: *CDP.BrowserContext, session_id: []const u8, msg: *const Notification.ResponseHeaderDone) !void {
    const transfer = msg.transfer;
    if (transfer.req.internal) {
        return;
    }
    const status = transfer.responseStatus() orelse return;
    if (status < 400) {
        return;
    }
    const text = try std.fmt.allocPrint(
        arena,
        "Failed to load resource: the server responded with a status of {d} ({s})",
        .{ status, transfer.statusText() orelse "" },
    );
    const url = if (transfer.res.header) |header| std.mem.span(header.url) else transfer.req.url;
    return send(bc, session_id, transfer, text, url);
}

// A request that failed, as Chrome's FrameConsole::DidFailLoading reports it.
pub fn httpRequestFail(arena: Allocator, bc: *CDP.BrowserContext, session_id: []const u8, msg: *const Notification.RequestFail) !void {
    const transfer = msg.transfer;
    if (transfer.req.internal) {
        return;
    }
    // A navigation that fails shows an error page; Chrome logs nothing for it.
    if (transfer.req.resource_type == .document) {
        return;
    }
    // A completion callback that fails once the response was delivered is
    // not a load failure.
    if (transfer._outcome_delivered) {
        return;
    }
    if (isCancellation(msg.err)) {
        return;
    }
    const text = try std.fmt.allocPrint(arena, "Failed to load resource: {s}", .{netError(msg.err)});
    return send(bc, session_id, transfer, text, transfer.req.url);
}

// Chrome logs nothing for net::ERR_ABORTED: a request stopped by the page,
// its consumer or the teardown of its frame. error.Abort is a consumer
// turning the response down (a script loader refusing an error status,
// already reported with its status).
fn isCancellation(err: anyerror) bool {
    return switch (err) {
        error.TransferCanceled,
        error.Abort,
        error.AbortedByCallback,
        error.AbortAuthChallenge,
        error.SyncWaitInterrupted,
        error.Shutdown,
        error.ClientDisconnect,
        error.ClientDisconnected,
        => true,
        else => false,
    };
}

// Chrome's net error for a transfer error. libcurl folds some of Chrome's
// causes into one code: CouldntConnect is also an unreachable host.
fn netError(err: anyerror) []const u8 {
    return switch (err) {
        error.CouldntConnect => "net::ERR_CONNECTION_REFUSED",
        error.CouldntResolveHost => "net::ERR_NAME_NOT_RESOLVED",
        error.CouldntResolveProxy => "net::ERR_PROXY_CONNECTION_FAILED",
        error.RecvError, error.SendError => "net::ERR_CONNECTION_RESET",
        error.GotNothing => "net::ERR_EMPTY_RESPONSE",
        error.TooManyRedirects => "net::ERR_TOO_MANY_REDIRECTS",
        error.UrlMalformat => "net::ERR_INVALID_URL",
        error.UnsupportedProtocol => "net::ERR_UNKNOWN_URL_SCHEME",
        error.BadContentEncoding => "net::ERR_CONTENT_DECODING_FAILED",
        error.SslConnectError, error.UseSslFailed => "net::ERR_SSL_PROTOCOL_ERROR",
        error.PeerFailedVerification,
        error.SslCertproblem,
        error.SslCacertBadfile,
        error.SslIssuerError,
        error.SslInvalidcertstatus,
        => "net::ERR_CERT_AUTHORITY_INVALID",
        error.SslPinnedpubkeynotmatch => "net::ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN",
        error.UrlBlocked, error.RobotsBlocked => "net::ERR_BLOCKED_BY_CLIENT",
        else => {
            // Fetch.failRequest's reasons, and the timeout.
            const text = network.errorText(err);
            return if (std.mem.startsWith(u8, text, "net::")) text else "net::ERR_FAILED";
        },
    };
}

const testing = @import("../testing.zig");

const fixtures = "http://127.0.0.1:9582/src/browser/tests/cdp/";

test "cdp.log: netError" {
    try testing.expectEqualSlices(u8, "net::ERR_CONNECTION_REFUSED", netError(error.CouldntConnect));
    try testing.expectEqualSlices(u8, "net::ERR_TIMED_OUT", netError(error.OperationTimedout));
    try testing.expectEqualSlices(u8, "net::ERR_BLOCKED_BY_CLIENT", netError(error.UrlBlocked));
    try testing.expectEqualSlices(u8, "net::ERR_ACCESS_DENIED", netError(network.ErrorReason.AccessDenied.toError()));
    try testing.expectEqualSlices(u8, "net::ERR_FAILED", netError(error.SomethingElse));
}

// The entries of the Log.entryAdded events the client received on `session_id`.
fn sentEntries(ctx: *testing.TestContext, session_id: []const u8) ![]const std.json.ObjectMap {
    var entries: std.ArrayList(std.json.ObjectMap) = .empty;
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        if (msg != .object) continue;
        const method = msg.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "Log.entryAdded")) continue;
        const sid = msg.object.get("sessionId") orelse continue;
        if (sid != .string or !std.mem.eql(u8, sid.string, session_id)) continue;
        const entry = msg.object.get("params").?.object.get("entry").?.object;
        try entries.append(testing.arena_allocator, entry);
    }
    return entries.items;
}

// The requestId Network.requestWillBeSent gave the request for `url`.
fn requestIdFor(ctx: *testing.TestContext, url: []const u8) ![]const u8 {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        if (msg != .object) continue;
        const method = msg.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "Network.requestWillBeSent")) continue;
        const params = msg.object.get("params").?.object;
        const request_url = params.get("request").?.object.get("url").?.string;
        if (std.mem.eql(u8, request_url, url)) {
            return params.get("requestId").?.string;
        }
    }
    return error.RequestNotFound;
}

// Checks the one entry for `url` among `entries`: the sub-resources load in
// parallel, so the entries can come in any order.
fn expectEntry(entries: []const std.json.ObjectMap, text: []const u8, url: []const u8, request_id: []const u8) !void {
    var found: ?std.json.ObjectMap = null;
    for (entries) |e| {
        if (std.mem.eql(u8, e.get("url").?.string, url)) {
            try testing.expect(found == null);
            found = e;
        }
    }
    const entry = found orelse return error.EntryNotFound;
    try testing.expectEqualSlices(u8, "network", entry.get("source").?.string);
    try testing.expectEqualSlices(u8, "error", entry.get("level").?.string);
    try testing.expectEqualSlices(u8, text, entry.get("text").?.string);
    try testing.expectEqualSlices(u8, request_id, entry.get("networkRequestId").?.string);
    try testing.expect(entry.get("timestamp").? == .integer);
}

test "cdp.log: sub-resources with an error status or a network error" {
    testing.silenceLog(&.{ .http, .js, .frame });
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
    try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
    try ctx.processMessage(.{ .id = 2, .method = "Log.enable" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const page = try bc.session.createPage();
    try page.navigate(fixtures ++ "log_subresources.html", .{});
    try testing.waitForPage(bc);

    const entries = try sentEntries(&ctx, "SID-LOG");
    try testing.expectEqual(3, entries.len);

    const not_found = "http://127.0.0.1:9582/status/404";
    try expectEntry(
        entries,
        "Failed to load resource: the server responded with a status of 404 (Not Found)",
        not_found,
        try requestIdFor(&ctx, not_found),
    );

    // The server's own reason phrase, not the standard one.
    const reason = "http://127.0.0.1:9582/xhr/reason";
    try expectEntry(
        entries,
        "Failed to load resource: the server responded with a status of 503 (HOUSTON WE HAVE A)",
        reason,
        try requestIdFor(&ctx, reason),
    );

    const refused = "http://127.0.0.1:2/refused.js";
    try expectEntry(
        entries,
        "Failed to load resource: net::ERR_CONNECTION_REFUSED",
        refused,
        try requestIdFor(&ctx, refused),
    );
}

test "cdp.log: a document with an error status, not a failed navigation" {
    testing.silenceLog(&.{ .http, .js, .frame });
    {
        var ctx = try testing.context();
        defer ctx.deinit();
        const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
        try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
        try ctx.processMessage(.{ .id = 2, .method = "Log.enable" });

        const url = "http://127.0.0.1:9582/status/404";
        const page = try bc.session.createPage();
        try page.navigate(url, .{});
        try testing.waitForPage(bc);

        const entries = try sentEntries(&ctx, "SID-LOG");
        try testing.expectEqual(1, entries.len);
        try expectEntry(
            entries,
            "Failed to load resource: the server responded with a status of 404 (Not Found)",
            url,
            try requestIdFor(&ctx, url),
        );
    }
    {
        var ctx = try testing.context();
        defer ctx.deinit();
        const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
        try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
        try ctx.processMessage(.{ .id = 2, .method = "Log.enable" });

        const page = try bc.session.createPage();
        try page.navigate("http://127.0.0.1:2/", .{});
        try testing.waitForPage(bc);

        // The navigation did fail, and Chrome shows its error page without
        // an entry.
        try ctx.expectSentEvent("Network.loadingFailed", .{ .canceled = false }, .{ .session_id = "SID-LOG" });
        try testing.expectEqual(0, (try sentEntries(&ctx, "SID-LOG")).len);
    }
}

test "cdp.log: a canceled request produces no entry" {
    testing.silenceLog(&.{ .http, .js, .frame });
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
    try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
    try ctx.processMessage(.{ .id = 2, .method = "Log.enable" });

    const page = try bc.session.createPage();
    try page.navigate(fixtures ++ "log_canceled.html", .{});
    try testing.waitForPage(bc);

    try ctx.expectSentEvent("Network.loadingFailed", .{
        .requestId = try requestIdFor(&ctx, "http://127.0.0.1:9582/xhr/slow"),
        .errorText = "net::ERR_ABORTED",
        .canceled = true,
    }, .{ .session_id = "SID-LOG" });
    try testing.expectEqual(0, (try sentEntries(&ctx, "SID-LOG")).len);
}

test "cdp.log: nothing while the domain is disabled" {
    testing.silenceLog(&.{ .http, .js, .frame });
    {
        // never enabled
        var ctx = try testing.context();
        defer ctx.deinit();
        const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
        try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });

        const page = try bc.session.createPage();
        try page.navigate(fixtures ++ "log_subresources.html", .{});
        try testing.waitForPage(bc);

        try ctx.expectSentEvent("Network.responseReceived", .{ .response = .{ .status = 404 } }, .{ .session_id = "SID-LOG" });
        try testing.expectEqual(0, (try sentEntries(&ctx, "SID-LOG")).len);
    }
    {
        // enabled, then disabled
        var ctx = try testing.context();
        defer ctx.deinit();
        const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
        try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
        try ctx.processMessage(.{ .id = 2, .method = "Log.enable" });
        try ctx.processMessage(.{ .id = 3, .method = "Log.disable" });
        try ctx.expectSentResult(null, .{ .id = 3 });

        const page = try bc.session.createPage();
        try page.navigate(fixtures ++ "log_subresources.html", .{});
        try testing.waitForPage(bc);

        try ctx.expectSentEvent("Network.responseReceived", .{ .response = .{ .status = 404 } }, .{ .session_id = "SID-LOG" });
        try testing.expectEqual(0, (try sentEntries(&ctx, "SID-LOG")).len);
    }
}

test "cdp.log: entries go to the sessions that enabled the domain" {
    testing.silenceLog(&.{ .http, .js, .frame });
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-LOG", .target_id = "FID-0000000LOG".*, .session_id = "SID-LOG" });
    _ = try bc.attachSession("SID-AUX", null);
    try ctx.processMessage(.{ .id = 1, .method = "Log.enable", .sessionId = "SID-AUX" });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = "SID-AUX" });

    const page = try bc.session.createPage();
    try page.navigate(fixtures ++ "log_subresources.html", .{});
    try testing.waitForPage(bc);

    try testing.expectEqual(3, (try sentEntries(&ctx, "SID-AUX")).len);
    try testing.expectEqual(0, (try sentEntries(&ctx, "SID-LOG")).len);
}

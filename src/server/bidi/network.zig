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

// The network module: events about the requests a page makes.
// https://w3c.github.io/webdriver-bidi/#module-network

const std = @import("std");
const lp = @import("lightpanda");

const Notification = @import("../../Notification.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const Cookie = @import("../../browser/webapi/storage/Cookie.zig");

const BiDi = @import("BiDi.zig");
const storage = @import("storage.zig");

const Transfer = HttpClient.Transfer;

pub fn processMessage(cmd: *BiDi.Command, action: []const u8) !void {
    _ = cmd;
    _ = action;
    // No commands yet.
    return error.UnknownCommand;
}

pub fn registerNotifications(bidi: *BiDi) !void {
    try bidi.notification.register(.http_request_start, bidi, onHttpRequestStart);
    try bidi.notification.register(.http_response_header_done, bidi, onHttpResponseHeaderDone);
    try bidi.notification.register(.http_request_done, bidi, onHttpRequestDone);
}

fn onHttpRequestStart(ptr: *anyopaque, msg: *const Notification.RequestStart) !void {
    const bidi: *BiDi = @ptrCast(@alignCast(ptr));
    const transfer = msg.transfer;

    // A redirect keeps the same transfer. The response of the previous hop
    // (the 3xx) is still on it, and is never delivered: report it here,
    // before the request of the next hop.
    //
    // TODO: the 3xx events report the wrong request. By now
    // applyRedirectTarget has already changed the request for the next hop:
    // the method can be GET, the body null, some headers are removed, and
    // the cookies are the ones for the new url. Only the url is fixed (see
    // Hop.redirect). Send these two events from the redirect `.follow` branch
    // of HttpClient.processOneMessage instead, after materializeResponse and
    // before followRedirect, while the request still describes the 3xx hop.
    // Make sure CDP doesn't get those events for a 3xx: it reports the
    // redirect in Network.requestWillBeSent's redirectResponse.
    if (msg.redirect_response) {
        try sendResponseEvent(bidi, "network.responseStarted", transfer, .redirect, .started);
        try sendResponseEvent(bidi, "network.responseCompleted", transfer, .redirect, .completed);
    }

    const method = "network.beforeRequestSent";
    if (!bidi.subscribed(method)) {
        return;
    }
    // The spec's "get the initiator" no longer sets anything, so the event
    // has no `initiator`.
    return bidi.sendEvent(method, BaseParameters{ .bidi = bidi, .transfer = transfer });
}

// Sent when the response is delivered. Lightpanda has the whole body by
// then (unless the response is streamed), but the spec's sizes are only
// known at responseCompleted, so they are reported there.
fn onHttpResponseHeaderDone(ptr: *anyopaque, msg: *const Notification.ResponseHeaderDone) !void {
    const bidi: *BiDi = @ptrCast(@alignCast(ptr));
    return sendResponseEvent(bidi, "network.responseStarted", msg.transfer, .current, .started);
}

fn onHttpRequestDone(ptr: *anyopaque, msg: *const Notification.RequestDone) !void {
    const bidi: *BiDi = @ptrCast(@alignCast(ptr));
    return sendResponseEvent(bidi, "network.responseCompleted", msg.transfer, .current, .completed);
}

fn sendResponseEvent(bidi: *BiDi, comptime method: []const u8, transfer: *Transfer, hop: Hop, phase: ResponseData.Phase) !void {
    if (!bidi.subscribed(method)) {
        return;
    }
    return bidi.sendEvent(method, BaseParameters{
        .bidi = bidi,
        .transfer = transfer,
        .hop = hop,
        .response = .{ .transfer = transfer, .phase = phase },
    });
}

// Which hop of the transfer an event is about.
const Hop = enum {
    // The request the transfer is on now.
    current,
    // The redirect the transfer just followed. req.url is already the
    // redirect target and _redirect_count is already incremented, but the
    // 3xx response is still on the transfer.
    redirect,
};

// network.BaseParameters, the fields every network event has, plus the
// `response` of the response events.
const BaseParameters = struct {
    bidi: *const BiDi,
    transfer: *Transfer,
    hop: Hop = .current,
    response: ?ResponseData = null,

    pub fn jsonStringify(self: *const BaseParameters, jws: anytype) !void {
        const bidi = self.bidi;
        const transfer = self.transfer;
        const req = &transfer.req;

        // Child frames have no BiDi context of their own yet: their requests
        // are reported on the top-level context.
        const ctx: ?*const @import("browsing_context.zig").Context = blk: {
            const c = &(bidi.browsing_context orelse break :blk null);
            const root = if (req.root_frame_id != 0) req.root_frame_id else req.document_frame_id orelse req.frame_id;
            break :blk if (c.frame_id == root) c else null;
        };

        try jws.beginObject();
        try jws.objectField("context");
        try jws.write(if (ctx) |c| &c.id else null);

        try jws.objectField("isBlocked");
        try jws.write(false);

        // Only the request that loads the top-level document belongs to a
        // navigation.
        try jws.objectField("navigation");
        if (ctx != null and req.resource_type == .document and req.frame_id == ctx.?.frame_id) {
            try jws.write(&ctx.?.navigation_id);
        } else {
            try jws.write(null);
        }

        try jws.objectField("redirectCount");
        try jws.write(switch (self.hop) {
            .current => transfer._redirect_count,
            .redirect => transfer._redirect_count - 1,
        });

        try jws.objectField("request");
        try jws.write(RequestData{
            .transfer = transfer,
            .url = switch (self.hop) {
                .current => null,
                .redirect => responseUrl(transfer),
            },
            // Whether to report the request's cookies, in `cookies` and in the
            // Cookie header. The response events don't: we read the jar when we
            // send the event, and by then it has the response's Set-Cookie.
            // TODO: keep the exact Cookie header sent on the transfer and report it.
            .req_cookies = self.response == null,
        });

        if (self.response) |*response| {
            try jws.objectField("response");
            try jws.write(response);
        }

        try jws.objectField("timestamp");
        try jws.write(lp.datetime.milliTimestamp(.real));

        try jws.objectField("userContext");
        try jws.write(if (ctx != null) bidi.user_context.id() else null);
        try jws.endObject();
    }
};

// network.RequestData
const RequestData = struct {
    transfer: *Transfer,
    // The url of a redirect hop: req.url is already the redirect target.
    url: ?[]const u8 = null,
    req_cookies: bool,

    pub fn jsonStringify(self: *const RequestData, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const RequestData, jws: anytype) !void {
        const transfer = self.transfer;
        const req = &transfer.req;
        const arena = transfer.arena.allocator();

        try jws.beginObject();
        try jws.objectField("request");
        try jws.print("\"{d}\"", .{transfer.id});

        try jws.objectField("url");
        try jws.write(self.url orelse req.url);

        try jws.objectField("method");
        try jws.write(@tagName(req.method));

        var headers_size: usize = 0;
        try jws.objectField("headers");
        try jws.beginArray();
        for (transfer.req_headers.items) |hdr| {
            try jws.write(Header{ .name = hdr.name, .value = hdr.value });
            headers_size += Header.size(hdr.name, hdr.value);
        }

        if (self.req_cookies) {
            // The jar adds the Cookie header when the request goes out, so it
            // isn't in req_headers yet.
            const cookie_header = try transfer.getCookieString(arena);

            if (cookie_header) |value| {
                try jws.write(Header{ .name = "Cookie", .value = value });
                headers_size += Header.size("Cookie", value);
            }
        }
        try jws.endArray();

        try jws.objectField("cookies");
        try jws.beginArray();
        if (self.req_cookies) {
            try transfer.forEachCookie(jws, struct {
                fn write(w: @TypeOf(jws), cookie: *const Cookie) !void {
                    try w.write(storage.BiDiCookie{ .cookie = cookie });
                }
            }.write);
        }
        try jws.endArray();

        try jws.objectField("headersSize");
        try jws.write(headers_size);

        try jws.objectField("bodySize");
        try jws.write(if (req.body) |body| body.len else null);

        try jws.objectField("destination");
        try jws.write(destination(req.resource_type));

        try jws.objectField("initiatorType");
        try jws.write(initiatorType(req.resource_type));

        // Lightpanda doesn't keep fetch timings: every field is 0.
        try jws.objectField("timings");
        try jws.write(FetchTimingInfo{});
        try jws.endObject();
    }
};

// network.Header: the value is a network.BytesValue.
const Header = struct {
    name: []const u8,
    value: []const u8,

    // As written on the wire: "name: value\r\n".
    fn size(name: []const u8, value: []const u8) usize {
        return name.len + 2 + value.len + 2;
    }

    pub fn jsonStringify(self: Header, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("value");
        try writeBytesValue(jws, self.value);
        try jws.endObject();
    }
};

// network.ResponseData
const ResponseData = struct {
    transfer: *Transfer,
    phase: Phase,

    const Phase = enum { started, completed };

    pub fn jsonStringify(self: *const ResponseData, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const ResponseData, jws: anytype) !void {
        const transfer = self.transfer;
        const url = responseUrl(transfer);

        var headers_size: usize = 0;
        for (transfer.responseHeaders()) |hdr| {
            headers_size += Header.size(hdr.name, hdr.value);
        }

        try jws.beginObject();
        try jws.objectField("url");
        try jws.write(url);

        try jws.objectField("protocol");
        try writeProtocol(jws, transfer, url);

        try jws.objectField("status");
        try jws.write(transfer.responseStatus() orelse 0);

        try jws.objectField("statusText");
        try jws.write(transfer.statusText() orelse "");

        try jws.objectField("fromCache");
        try jws.write(transfer._from_cache);

        try jws.objectField("headers");
        try jws.beginArray();
        for (transfer.responseHeaders()) |hdr| {
            try jws.write(Header{ .name = hdr.name, .value = hdr.value });
        }
        try jws.endArray();

        try jws.objectField("mimeType");
        try jws.write(try mimeEssence(transfer.arena.allocator(), transfer.contentType() orelse ""));

        try jws.objectField("headersSize");
        try jws.write(headers_size);

        // The sizes are known once the body is read: at responseStarted,
        // only the headers count.
        switch (self.phase) {
            .started => {
                try jws.objectField("bytesReceived");
                try jws.write(headers_size);
                try jws.objectField("bodySize");
                try jws.write(null);
                try jws.objectField("content");
                try jws.write(.{ .size = 0 });
            },
            .completed => {
                const timing = &transfer._timing;
                try jws.objectField("bytesReceived");
                try jws.write(transfer._encoded_data_length);
                // A cached response wasn't transmitted: its encoded size is
                // its decoded size, as in the resource timing entry.
                try jws.objectField("bodySize");
                try jws.write(if (transfer._from_cache) timing.decoded_body_size else timing.encoded_body_size);
                try jws.objectField("content");
                try jws.write(.{ .size = timing.decoded_body_size });
            },
        }
        try jws.endObject();
    }
};

// The url the response came from. After a redirect, req.url is already the
// redirect target, but the response head still has the url of its hop.
fn responseUrl(transfer: *Transfer) []const u8 {
    if (transfer.res.header) |header| {
        return std.mem.span(header.url);
    }
    return transfer.req.url;
}

// The spec's "get the protocol": the ALPN protocol, else the url's scheme.
fn writeProtocol(jws: anytype, transfer: *const Transfer, url: []const u8) !void {
    const protocol = transfer._timing.protocol;
    if (protocol.len > 0) {
        return jws.write(protocol);
    }
    const i = std.mem.findScalar(u8, url, ':') orelse return jws.write("");
    return jws.write(url[0..i]);
}

// The MIME type's essence: "type/subtype" in lowercase, without parameters.
fn mimeEssence(arena: std.mem.Allocator, content_type: []const u8) ![]const u8 {
    const end = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    const essence = std.mem.trim(u8, content_type[0..end], " \t");
    return std.ascii.allocLowerString(arena, essence);
}

// network.BytesValue: a string when the bytes are UTF-8, base64 otherwise.
fn writeBytesValue(jws: anytype, bytes: []const u8) !void {
    try jws.beginObject();
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try jws.objectField("type");
        try jws.write("string");
        try jws.objectField("value");
        try jws.write(bytes);
    } else {
        try jws.objectField("type");
        try jws.write("base64");
        try jws.objectField("value");
        try jws.print("\"{b64}\"", .{bytes});
    }
    try jws.endObject();
}

// network.FetchTimingInfo
const FetchTimingInfo = struct {
    timeOrigin: f64 = 0,
    requestTime: f64 = 0,
    redirectStart: f64 = 0,
    redirectEnd: f64 = 0,
    fetchStart: f64 = 0,
    dnsStart: f64 = 0,
    dnsEnd: f64 = 0,
    connectStart: f64 = 0,
    connectEnd: f64 = 0,
    tlsStart: f64 = 0,
    requestStart: f64 = 0,
    responseStart: f64 = 0,
    responseEnd: f64 = 0,
};

// The Fetch spec's request destination.
// https://fetch.spec.whatwg.org/#concept-request-destination
fn destination(resource_type: HttpClient.Request.ResourceType) []const u8 {
    return switch (resource_type) {
        .document => "document",
        .script => "script",
        .stylesheet => "style",
        .image => "image",
        .text_track => "track",
        .worker => "worker",
        .xhr, .fetch, .eventsource, .beacon, .download => "",
    };
}

// The Fetch spec's request initiator type, null for a navigation.
// https://fetch.spec.whatwg.org/#request-initiator-type
fn initiatorType(resource_type: HttpClient.Request.ResourceType) ?[]const u8 {
    return switch (resource_type) {
        .document, .download => null,
        .xhr => "xmlhttprequest",
        .fetch => "fetch",
        .beacon => "beacon",
        .script => "script",
        .stylesheet => "link",
        .image => "img",
        .text_track => "track",
        .worker, .eventsource => "other",
    };
}

const testing = @import("testing.zig");
test "bidi.network: beforeRequestSent" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{});
    try ctx.processMessage(.{ .id = 1, .method = "session.subscribe", .params = .{ .events = .{"network.beforeRequestSent"} } });
    try navigate(&ctx, context_id, "bidi/network.html");
    const navigation = &ctx.bidi().browsing_context.?.navigation_id;

    // The document request belongs to the navigation.
    try ctx.expectSentEvent("network.beforeRequestSent", .{
        .context = context_id,
        .isBlocked = false,
        .navigation = navigation,
        .redirectCount = 0,
        .userContext = "default",
        .request = .{
            .url = testing.test_server ++ "bidi/network.html",
            .method = "GET",
            .destination = "document",
        },
    });
    const document_request = (try findEvent(&ctx, "network.beforeRequestSent", "bidi/network.html")).object.get("request").?.object;
    try testing.expect(document_request.get("initiatorType").? == .null);
    try testing.expect(document_request.get("bodySize").? == .null);
    try testing.expectEqual(0, document_request.get("cookies").?.array.items.len);
    try testing.expectEqual(13, document_request.get("timings").?.object.count());

    // A subresource doesn't.
    try ctx.expectSentEvent("network.beforeRequestSent", .{
        .context = context_id,
        .request = .{
            .url = testing.test_server ++ "bidi/network.js",
            .destination = "script",
            .initiatorType = "script",
        },
    });
    const script_event = try findEvent(&ctx, "network.beforeRequestSent", "bidi/network.js");
    try testing.expect(script_event.object.get("navigation").? == .null);
}

test "bidi.network: beforeRequestSent cookies and body" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{});
    try ctx.processMessage(.{ .id = 1, .method = "session.subscribe", .params = .{ .events = .{"network"} } });
    try ctx.processMessage(.{ .id = 2, .method = "storage.setCookie", .params = .{
        .cookie = .{ .name = "c1", .value = .{ .type = "string", .value = "v1" }, .domain = "127.0.0.1" },
    } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try navigate(&ctx, context_id, "bidi/network_post.html");

    try ctx.expectSentEvent("network.beforeRequestSent", .{
        .context = context_id,
        .request = .{
            .url = "http://127.0.0.1:9582/xhr",
            .method = "POST",
            .bodySize = 5,
            .destination = "",
            .initiatorType = "fetch",
        },
    });

    const request = (try findEvent(&ctx, "network.beforeRequestSent", "/xhr")).object.get("request").?.object;
    const cookies = request.get("cookies").?.array.items;
    try testing.expectEqual(1, cookies.len);
    try testing.expectEqual(true, std.mem.eql(u8, cookies[0].object.get("name").?.string, "c1"));
    try testing.expectEqual(true, std.mem.eql(u8, cookies[0].object.get("value").?.object.get("value").?.string, "v1"));

    var found = false;
    for (request.get("headers").?.array.items) |header| {
        if (!std.mem.eql(u8, header.object.get("name").?.string, "Cookie")) continue;
        try testing.expectEqual(true, std.mem.eql(u8, header.object.get("value").?.object.get("value").?.string, "c1=v1"));
        found = true;
    }
    try testing.expect(found);
    try testing.expect(request.get("headersSize").?.integer > 0);
}

test "bidi.network: responseStarted and responseCompleted" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{});
    try ctx.processMessage(.{ .id = 1, .method = "session.subscribe", .params = .{ .events = .{"network"} } });
    try navigate(&ctx, context_id, "bidi/network.html");
    const navigation = &ctx.bidi().browsing_context.?.navigation_id;
    const url = testing.test_server ++ "bidi/network.html";

    try ctx.expectSentEvent("network.responseStarted", .{
        .context = context_id,
        .isBlocked = false,
        .navigation = navigation,
        .redirectCount = 0,
        .request = .{ .url = url, .method = "GET" },
        .response = .{
            .url = url,
            .protocol = "http/1.1",
            .status = 200,
            .fromCache = false,
            .mimeType = "text/html",
            .content = .{ .size = 0 },
        },
    });
    try ctx.expectSentEvent("network.responseCompleted", .{
        .context = context_id,
        .navigation = navigation,
        .request = .{ .url = url },
        .response = .{ .url = url, .status = 200 },
    });

    const started = (try findEvent(&ctx, "network.responseStarted", "bidi/network.html")).object;
    try testing.expect(started.get("response").?.object.get("bodySize").? == .null);

    const completed = (try findEvent(&ctx, "network.responseCompleted", "bidi/network.html")).object;
    const response = completed.get("response").?.object;
    try testing.expect(response.get("bodySize").?.integer > 0);
    try testing.expect(response.get("bytesReceived").?.integer > response.get("bodySize").?.integer);
    try testing.expect(response.get("headersSize").?.integer > 0);
    try testing.expect(response.get("content").?.object.get("size").?.integer > 0);
    try testing.expect(response.get("headers").?.array.items.len > 0);

    // The three events of one request share its id, in order.
    const events = try networkEvents(&ctx, "bidi/network.html");
    try testing.expectEqual(3, events.len);
    try std.testing.expectEqualStrings("network.beforeRequestSent", events[0].method);
    try std.testing.expectEqualStrings("network.responseStarted", events[1].method);
    try std.testing.expectEqualStrings("network.responseCompleted", events[2].method);
    for (events[1..]) |e| {
        try std.testing.expectEqualStrings(events[0].request_id, e.request_id);
    }

    // The script's response is not tied to the navigation.
    const script = (try findEvent(&ctx, "network.responseCompleted", "bidi/network.js")).object;
    try testing.expect(script.get("navigation").? == .null);
}

test "bidi.network: redirect" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const context_id = try ctx.createContext(.{});
    try ctx.processMessage(.{ .id = 1, .method = "session.subscribe", .params = .{ .events = .{"network"} } });
    const from = "http://127.0.0.1:9582/redirect-no-fragment";
    const to = "http://127.0.0.1:9582/redirect-target";
    try navigateUrl(&ctx, context_id, from);

    // The 3xx hop: its request and its response, with redirectCount 0.
    try ctx.expectSentEvent("network.responseCompleted", .{
        .context = context_id,
        .redirectCount = 0,
        .request = .{ .url = from },
        .response = .{ .url = from, .status = 302 },
    });
    // The next hop: redirectCount 1.
    try ctx.expectSentEvent("network.beforeRequestSent", .{
        .context = context_id,
        .redirectCount = 1,
        .request = .{ .url = to },
    });
    try ctx.expectSentEvent("network.responseCompleted", .{
        .context = context_id,
        .redirectCount = 1,
        .request = .{ .url = to },
        .response = .{ .url = to, .status = 200, .mimeType = "text/html" },
    });

    // One request id for both hops, events in order.
    const events = try networkEvents(&ctx, "");
    const expected = [_]struct { []const u8, []const u8 }{
        .{ "network.beforeRequestSent", from },
        .{ "network.responseStarted", from },
        .{ "network.responseCompleted", from },
        .{ "network.beforeRequestSent", to },
        .{ "network.responseStarted", to },
        .{ "network.responseCompleted", to },
    };
    try testing.expectEqual(expected.len, events.len);
    for (expected, events) |exp, e| {
        try std.testing.expectEqualStrings(exp[0], e.method);
        try std.testing.expectEqualStrings(exp[1], e.url);
        try std.testing.expectEqualStrings(events[0].request_id, e.request_id);
    }
}

test "bidi.network: no event without a subscription" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.createContext(.{ .url = "bidi/network.html" });
    try testing.expectError(error.EventNotFound, findEvent(&ctx, "network.beforeRequestSent", "bidi/network.html"));
}

test "bidi.network: unknown command" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.startSession();
    try ctx.processMessage(.{ .id = 1, .method = "network.nope", .params = .{} });
    try ctx.expectSentError("unknown command", "network.nope", .{ .id = 1 });
}

// Navigates to a fixture under testing.test_server.
fn navigate(ctx: *testing.TestContext, context_id: []const u8, path: []const u8) !void {
    return navigateUrl(ctx, context_id, try testing.arena.print(testing.test_server ++ "{s}", .{path}));
}

fn navigateUrl(ctx: *testing.TestContext, context_id: []const u8, url: []const u8) !void {
    try ctx.processMessage(.{
        .id = 100,
        .method = "browsingContext.navigate",
        .params = .{ .context = context_id, .url = url, .wait = "none" },
    });
    try ctx.wait();
}

const NetworkEvent = struct {
    method: []const u8,
    url: []const u8,
    request_id: []const u8,
};

// The network events whose request url ends with `suffix`, in the order they
// were sent.
fn networkEvents(ctx: *testing.TestContext, suffix: []const u8) ![]const NetworkEvent {
    try ctx.read();
    var events: std.ArrayList(NetworkEvent) = .empty;
    for (ctx.received.items) |msg| {
        const m = msg.object.get("method") orelse continue;
        if (!std.mem.startsWith(u8, m.string, "network.")) continue;
        const request = msg.object.get("params").?.object.get("request").?.object;
        const url = request.get("url").?.string;
        if (!std.mem.endsWith(u8, url, suffix)) continue;
        try events.append(testing.arena, .{
            .method = m.string,
            .url = url,
            .request_id = request.get("request").?.string,
        });
    }
    return events.items;
}

// The params of the first `method` event whose request url ends with `suffix`.
fn findEvent(ctx: *testing.TestContext, method: []const u8, suffix: []const u8) !std.json.Value {
    try ctx.read();
    for (ctx.received.items) |msg| {
        const m = msg.object.get("method") orelse continue;
        if (!std.mem.eql(u8, m.string, method)) continue;
        const params = msg.object.get("params").?;
        const url = params.object.get("request").?.object.get("url").?.string;
        if (std.mem.endsWith(u8, url, suffix)) return params;
    }
    return error.EventNotFound;
}

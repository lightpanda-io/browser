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
}

fn onHttpRequestStart(ptr: *anyopaque, msg: *const Notification.RequestStart) !void {
    const bidi: *BiDi = @ptrCast(@alignCast(ptr));
    const method = "network.beforeRequestSent";
    if (!bidi.subscribed(method)) {
        return;
    }
    // The spec's "get the initiator" no longer sets anything, so the event
    // has no `initiator`.
    return bidi.sendEvent(method, BaseParameters.init(bidi, msg.transfer));
}

// network.BaseParameters, the fields every network event has.
const BaseParameters = struct {
    bidi: *const BiDi,
    transfer: *Transfer,

    fn init(bidi: *const BiDi, transfer: *Transfer) BaseParameters {
        return .{ .bidi = bidi, .transfer = transfer };
    }

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
        try jws.write(transfer._redirect_count);

        try jws.objectField("request");
        try jws.write(RequestData{ .transfer = transfer });

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

    pub fn jsonStringify(self: *const RequestData, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const RequestData, jws: anytype) !void {
        const transfer = self.transfer;
        const req = &transfer.req;
        const arena = transfer.arena.allocator();

        // The jar adds the Cookie header when the request goes out, so it
        // isn't in req_headers yet.
        const cookie_header = try transfer.getCookieString(arena);

        try jws.beginObject();
        try jws.objectField("request");
        try jws.print("\"{d}\"", .{transfer.id});

        try jws.objectField("url");
        try jws.write(req.url);

        try jws.objectField("method");
        try jws.write(@tagName(req.method));

        var headers_size: usize = 0;
        try jws.objectField("headers");
        try jws.beginArray();
        for (transfer.req_headers.items) |hdr| {
            try jws.write(Header{ .name = hdr.name, .value = hdr.value });
            headers_size += Header.size(hdr.name, hdr.value);
        }
        if (cookie_header) |value| {
            try jws.write(Header{ .name = "Cookie", .value = value });
            headers_size += Header.size("Cookie", value);
        }
        try jws.endArray();

        try jws.objectField("cookies");
        try jws.beginArray();
        try transfer.forEachCookie(jws, struct {
            fn write(w: @TypeOf(jws), cookie: *const Cookie) !void {
                try w.write(storage.BiDiCookie{ .cookie = cookie });
            }
        }.write);
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

fn navigate(ctx: *testing.TestContext, context_id: []const u8, url: []const u8) !void {
    try ctx.processMessage(.{
        .id = 100,
        .method = "browsingContext.navigate",
        .params = .{
            .context = context_id,
            .url = try testing.arena.print(testing.test_server ++ "{s}", .{url}),
            .wait = "none",
        },
    });
    try ctx.wait();
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

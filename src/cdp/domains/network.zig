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
const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const CdpStorage = @import("storage.zig");
const Transfer = @import("../../http/Client.zig").Transfer;
const Notification = @import("../../notification.zig").Notification;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        setCacheDisabled,
        setExtraHTTPHeaders,
        setUserAgentOverride,
        deleteCookies,
        clearBrowserCookies,
        setCookie,
        setCookies,
        getCookies,
        getResponseBody,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .setCacheDisabled => return cmd.sendResult(null, .{}),
        .setUserAgentOverride => return cmd.sendResult(null, .{}),
        .setExtraHTTPHeaders => return setExtraHTTPHeaders(cmd),
        .deleteCookies => return deleteCookies(cmd),
        .clearBrowserCookies => return clearBrowserCookies(cmd),
        .setCookie => return setCookie(cmd),
        .setCookies => return setCookies(cmd),
        .getCookies => return getCookies(cmd),
        .getResponseBody => return getResponseBody(cmd),
    }
}

const Response = struct {
    status: u16,
    headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    // These may not be complete yet, but we only tell the client
    // Network.responseReceived when all the headers are in.
    // Later should store body as well to support getResponseBody which should
    // only work once Network.loadingFinished is sent but the body itself would
    // be loaded with each chunks as Network.dataReceiveds are coming in.
};

fn enable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.networkEnable();
    return cmd.sendResult(null, .{});
}

fn disable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.networkDisable();
    return cmd.sendResult(null, .{});
}

fn setExtraHTTPHeaders(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        headers: std.json.ArrayHashMap([]const u8),
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // Copy the headers onto the browser context arena
    const arena = bc.arena;
    const extra_headers = &bc.extra_headers;

    extra_headers.clearRetainingCapacity();
    try extra_headers.ensureTotalCapacity(arena, params.headers.map.count());
    var it = params.headers.map.iterator();
    while (it.next()) |header| {
        const header_string = try std.fmt.allocPrintZ(arena, "{s}: {s}", .{ header.key_ptr.*, header.value_ptr.* });
        extra_headers.appendAssumeCapacity(header_string);
    }

    return cmd.sendResult(null, .{});
}

const Cookie = @import("../../browser/storage/storage.zig").Cookie;

// Only matches the cookie on provided parameters
fn cookieMatches(cookie: *const Cookie, name: []const u8, domain: ?[]const u8, path: ?[]const u8) bool {
    if (!std.mem.eql(u8, cookie.name, name)) return false;

    if (domain) |domain_| {
        const c_no_dot = if (std.mem.startsWith(u8, cookie.domain, ".")) cookie.domain[1..] else cookie.domain;
        const d_no_dot = if (std.mem.startsWith(u8, domain_, ".")) domain_[1..] else domain_;
        if (!std.mem.eql(u8, c_no_dot, d_no_dot)) return false;
    }
    if (path) |path_| {
        if (!std.mem.eql(u8, cookie.path, path_)) return false;
    }
    return true;
}

fn deleteCookies(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        name: []const u8,
        url: ?[]const u8 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        partitionKey: ?CdpStorage.CookiePartitionKey = null,
    })) orelse return error.InvalidParams;
    if (params.partitionKey != null) return error.NotImplemented;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const cookies = &bc.session.cookie_jar.cookies;

    const uri = if (params.url) |url| std.Uri.parse(url) catch return error.InvalidParams else null;
    const uri_ptr = if (uri) |u| &u else null;

    var index = cookies.items.len;
    while (index > 0) {
        index -= 1;
        const cookie = &cookies.items[index];
        const domain = try Cookie.parseDomain(cmd.arena, uri_ptr, params.domain);
        const path = try Cookie.parsePath(cmd.arena, uri_ptr, params.path);

        // We do not want to use Cookie.appliesTo here. As a Cookie with a shorter path would match.
        // Similar to deduplicating with areCookiesEqual, except domain and path are optional.
        if (cookieMatches(cookie, params.name, domain, path)) {
            cookies.swapRemove(index).deinit();
        }
    }
    return cmd.sendResult(null, .{});
}

fn clearBrowserCookies(cmd: anytype) !void {
    if (try cmd.params(struct {}) != null) return error.InvalidParams;
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.session.cookie_jar.clearRetainingCapacity();
    return cmd.sendResult(null, .{});
}

fn setCookie(cmd: anytype) !void {
    const params = (try cmd.params(
        CdpStorage.CdpCookie,
    )) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try CdpStorage.setCdpCookie(&bc.session.cookie_jar, params);

    try cmd.sendResult(.{ .success = true }, .{});
}

fn setCookies(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        cookies: []const CdpStorage.CdpCookie,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    for (params.cookies) |param| {
        try CdpStorage.setCdpCookie(&bc.session.cookie_jar, param);
    }

    try cmd.sendResult(null, .{});
}

const GetCookiesParam = struct { urls: ?[]const []const u8 = null };
fn getCookies(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(GetCookiesParam)) orelse GetCookiesParam{};

    // If not specified, use the URLs of the page and all of its subframes. TODO subframes
    const page_url = if (bc.session.page) |*page| page.url.raw else null; // @speed: avoid repasing the URL
    const param_urls = params.urls orelse &[_][]const u8{page_url orelse return error.InvalidParams};

    var urls = try std.ArrayListUnmanaged(CdpStorage.PreparedUri).initCapacity(cmd.arena, param_urls.len);
    for (param_urls) |url| {
        const uri = std.Uri.parse(url) catch return error.InvalidParams;

        urls.appendAssumeCapacity(.{
            .host = try Cookie.parseDomain(cmd.arena, &uri, null),
            .path = try Cookie.parsePath(cmd.arena, &uri, null),
            .secure = std.mem.eql(u8, uri.scheme, "https"),
        });
    }

    var jar = &bc.session.cookie_jar;
    jar.removeExpired(null);
    const writer = CdpStorage.CookieWriter{ .cookies = jar.cookies.items, .urls = urls.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn getResponseBody(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        requestId: []const u8, // "REQ-{d}"
    })) orelse return error.InvalidParams;

    _ = params;

    try cmd.sendResult(.{
        .body = "TODO",
        .base64Encoded = false,
    }, .{});
}

pub fn httpRequestFail(arena: Allocator, bc: anytype, data: *const Notification.RequestFail) !void {
    // It's possible that the request failed because we aborted when the client
    // sent Target.closeTarget. In that case, bc.session_id will be cleared
    // already, and we can skip sending these messages to the client.
    const session_id = bc.session_id orelse return;

    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.loadingFailed", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{data.transfer.id}),
        // Seems to be what chrome answers with. I assume it depends on the type of error?
        .type = "Ping",
        .errorText = data.err,
        .canceled = false,
    }, .{ .session_id = session_id });
}

pub fn httpRequestStart(arena: Allocator, bc: anytype, data: *const Notification.RequestStart) !void {
    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;

    // all unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;
    const page = bc.session.currentPage() orelse unreachable;

    // Modify request with extra CDP headers
    for (bc.extra_headers.items) |extra| {
        try data.transfer.req.headers.add(extra);
    }

    const transfer = data.transfer;
    // We're missing a bunch of fields, but, for now, this seems like enough
    try cdp.sendEvent("Network.requestWillBeSent", .{ .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{transfer.id}), .frameId = target_id, .loaderId = bc.loader_id, .documentUrl = DocumentUrlWriter.init(&page.url.uri), .request = TransferAsRequestWriter.init(transfer) }, .{ .session_id = session_id });
}

pub fn httpHeadersDone(arena: Allocator, bc: anytype, data: *const Notification.ResponseHeadersDone) !void {
    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;

    // all unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;

    // We're missing a bunch of fields, but, for now, this seems like enough
    try cdp.sendEvent("Network.responseReceived", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{data.transfer.id}),
        .loaderId = bc.loader_id,
        .frameId = target_id,
        .response = TransferAsResponseWriter.init(data.transfer),
    }, .{ .session_id = session_id });
}

pub fn httpRequestDone(arena: Allocator, bc: anytype, data: *const Notification.RequestDone) !void {
    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;

    // all unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;

    try cdp.sendEvent("Network.loadingFinished", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{data.transfer.id}),
        .encodedDataLength = data.transfer.bytes_received,
    }, .{ .session_id = session_id });
}

pub const TransferAsRequestWriter = struct {
    transfer: *Transfer,

    pub fn init(transfer: *Transfer) TransferAsRequestWriter {
        return .{
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const TransferAsRequestWriter, writer: anytype) !void {
        const stream = writer.stream;
        const transfer = self.transfer;

        try writer.beginObject();
        {
            try writer.objectField("url");
            try writer.beginWriteRaw();
            try stream.writeByte('\"');
            try transfer.uri.writeToStream(.{
                .scheme = true,
                .authentication = true,
                .authority = true,
                .path = true,
                .query = true,
            }, stream);
            try stream.writeByte('\"');
            writer.endWriteRaw();
        }

        {
            if (transfer.uri.fragment) |frag| {
                try writer.objectField("urlFragment");
                try writer.beginWriteRaw();
                try stream.writeAll("\"#");
                try stream.writeAll(frag.percent_encoded);
                try stream.writeByte('\"');
                writer.endWriteRaw();
            }
        }

        {
            try writer.objectField("method");
            try writer.write(@tagName(transfer.req.method));
        }

        {
            try writer.objectField("hasPostData");
            try writer.write(transfer.req.body != null);
        }

        {
            try writer.objectField("headers");
            try writer.beginObject();
            var it = transfer.req.headers.iterator();
            while (it.next()) |hdr| {
                try writer.objectField(hdr.name);
                try writer.write(hdr.value);
            }
            try writer.endObject();
        }
        try writer.endObject();
    }
};

const TransferAsResponseWriter = struct {
    transfer: *Transfer,

    fn init(transfer: *Transfer) TransferAsResponseWriter {
        return .{
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const TransferAsResponseWriter, writer: anytype) !void {
        const stream = writer.stream;
        const transfer = self.transfer;

        try writer.beginObject();
        {
            try writer.objectField("url");
            try writer.beginWriteRaw();
            try stream.writeByte('\"');
            try transfer.uri.writeToStream(.{
                .scheme = true,
                .authentication = true,
                .authority = true,
                .path = true,
                .query = true,
            }, stream);
            try stream.writeByte('\"');
            writer.endWriteRaw();
        }

        if (transfer.response_header) |*rh| {
            // it should not be possible for this to be false, but I'm not
            // feeling brave today.
            const status = rh.status;
            try writer.objectField("status");
            try writer.write(status);

            try writer.objectField("statusText");
            try writer.write(@as(std.http.Status, @enumFromInt(status)).phrase() orelse "Unknown");
        }

        {
            try writer.objectField("headers");
            try writer.beginObject();
            var it = transfer.responseHeaderIterator();
            while (it.next()) |hdr| {
                try writer.objectField(hdr.name);
                try writer.write(hdr.value);
            }
            try writer.endObject();
        }
        try writer.endObject();
    }
};

const DocumentUrlWriter = struct {
    uri: *std.Uri,

    fn init(uri: *std.Uri) DocumentUrlWriter {
        return .{
            .uri = uri,
        };
    }

    pub fn jsonStringify(self: *const DocumentUrlWriter, writer: anytype) !void {
        const stream = writer.stream;

        try writer.beginWriteRaw();
        try stream.writeByte('\"');
        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = true,
            .query = true,
        }, stream);
        try stream.writeByte('\"');
        writer.endWriteRaw();
    }
};

const testing = @import("../testing.zig");
test "cdp.network setExtraHTTPHeaders" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "NID-A", .session_id = "NESI-A" });
    // try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about/blank" } });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .foo = "bar" } },
    });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .food = "bars" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.extra_headers.items.len, 1);
}

test "cdp.Network: cookies" {
    const ResCookie = CdpStorage.ResCookie;
    const CdpCookie = CdpStorage.CdpCookie;

    var ctx = testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-S" });

    // Initially empty
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getCookies",
        .params = .{ .urls = &[_][]const u8{"https://example.com/pancakes"} },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 3 });

    // Has cookies after setting them
    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.setCookie",
        .params = CdpCookie{ .name = "test3", .value = "valuenot3", .url = "https://car.example.com/defnotpancakes" },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Network.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "test3", .value = "value3", .url = "https://car.example.com/pan/cakes" },
                .{ .name = "test4", .value = "value4", .domain = "example.com", .path = "/mango" },
            },
        },
    });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try ctx.processMessage(.{
        .id = 6,
        .method = "Network.getCookies",
        .params = .{ .urls = &[_][]const u8{"https://car.example.com/pan/cakes"} },
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "test3", .value = "value3", .domain = "car.example.com", .path = "/", .secure = true }, // No Pancakes!
        },
    }, .{ .id = 6 });

    // deleteCookies
    try ctx.processMessage(.{
        .id = 7,
        .method = "Network.deleteCookies",
        .params = .{ .name = "test3", .domain = "car.example.com" },
    });
    try ctx.expectSentResult(null, .{ .id = 7 });
    try ctx.processMessage(.{
        .id = 8,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    // Just the untouched test4 should be in the result
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{.{ .name = "test4", .value = "value4", .domain = ".example.com", .path = "/mango" }} }, .{ .id = 8 });

    // Empty after clearBrowserCookies
    try ctx.processMessage(.{
        .id = 9,
        .method = "Network.clearBrowserCookies",
    });
    try ctx.expectSentResult(null, .{ .id = 9 });
    try ctx.processMessage(.{
        .id = 10,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 10 });
}

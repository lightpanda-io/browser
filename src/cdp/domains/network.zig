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
const Allocator = std.mem.Allocator;

const CdpStorage = @import("storage.zig");

const id = @import("../id.zig");
const URL = @import("../../browser/URL.zig");
const Transfer = @import("../../http/Client.zig").Transfer;
const Notification = @import("../../Notification.zig");
const Mime = @import("../../browser/Mime.zig");

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
        const header_string = try std.fmt.allocPrintSentinel(arena, "{s}: {s}", .{ header.key_ptr.*, header.value_ptr.* }, 0);
        extra_headers.appendAssumeCapacity(header_string);
    }

    return cmd.sendResult(null, .{});
}

const Cookie = @import("../../browser/webapi/storage/storage.zig").Cookie;

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
        url: ?[:0]const u8 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        partitionKey: ?CdpStorage.CookiePartitionKey = null,
    })) orelse return error.InvalidParams;
    if (params.partitionKey != null) return error.NotImplemented;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const cookies = &bc.session.cookie_jar.cookies;

    var index = cookies.items.len;
    while (index > 0) {
        index -= 1;
        const cookie = &cookies.items[index];
        const domain = try Cookie.parseDomain(cmd.arena, params.url, params.domain);
        const path = try Cookie.parsePath(cmd.arena, params.url, params.path);

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

const GetCookiesParam = struct {
    urls: ?[]const [:0]const u8 = null,
};
fn getCookies(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(GetCookiesParam)) orelse GetCookiesParam{};

    // If not specified, use the URLs of the page and all of its subframes. TODO subframes
    const page_url = if (bc.session.page) |page| page.url else null;
    const param_urls = params.urls orelse &[_][:0]const u8{page_url orelse return error.InvalidParams};

    var urls = try std.ArrayList(CdpStorage.PreparedUri).initCapacity(cmd.arena, param_urls.len);
    for (param_urls) |url| {
        urls.appendAssumeCapacity(.{
            .host = try Cookie.parseDomain(cmd.arena, url, null),
            .path = try Cookie.parsePath(cmd.arena, url, null),
            .secure = URL.isHTTPS(url),
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

    const request_id = try idFromRequestId(params.requestId);
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const buf = bc.captured_responses.getPtr(request_id) orelse return error.RequestNotFound;

    try cmd.sendResult(.{
        .body = buf.items,
        .base64Encoded = false,
    }, .{});
}

pub fn httpRequestFail(bc: anytype, msg: *const Notification.RequestFail) !void {
    // It's possible that the request failed because we aborted when the client
    // sent Target.closeTarget. In that case, bc.session_id will be cleared
    // already, and we can skip sending these messages to the client.
    const session_id = bc.session_id orelse return;

    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    lp.assert(bc.session.page != null, "CDP.network.httpRequestFail null page", .{});

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.loadingFailed", .{
        .requestId = &id.toRequestId(msg.transfer.id),
        // Seems to be what chrome answers with. I assume it depends on the type of error?
        .type = "Ping",
        .errorText = msg.err,
        .canceled = false,
    }, .{ .session_id = session_id });
}

pub fn httpRequestStart(bc: anytype, msg: *const Notification.RequestStart) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;
    const req = &transfer.req;
    const page_id = req.page_id;
    const page = bc.session.findPage(page_id) orelse return;

    // Modify request with extra CDP headers
    for (bc.extra_headers.items) |extra| {
        try req.headers.add(extra);
    }

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.requestWillBeSent", .{
        .loaderId = &id.toLoaderId(transfer.id),
        .requestId = &id.toRequestId(transfer.id),
        .frameId = &id.toFrameId(page_id),
        .type = req.resource_type.string(),
        .documentURL = page.url,
        .request = TransferAsRequestWriter.init(transfer),
        .initiator = .{ .type = "other" },
        .redirectHasExtraInfo = false, // TODO change after adding Network.requestWillBeSentExtraInfo
        .hasUserGesture = false,
    }, .{ .session_id = session_id });
}

pub fn httpResponseHeaderDone(arena: Allocator, bc: anytype, msg: *const Notification.ResponseHeaderDone) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.responseReceived", .{
        .loaderId = &id.toLoaderId(transfer.id),
        .requestId = &id.toRequestId(transfer.id),
        .frameId = &id.toFrameId(transfer.req.page_id),
        .response = TransferAsResponseWriter.init(arena, msg.transfer),
        .hasExtraInfo = false, // TODO change after adding Network.responseReceivedExtraInfo
    }, .{ .session_id = session_id });
}

pub fn httpRequestDone(bc: anytype, msg: *const Notification.RequestDone) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    const transfer = msg.transfer;
    try bc.cdp.sendEvent("Network.loadingFinished", .{
        .requestId = &id.toRequestId(transfer.id),
        .encodedDataLength = transfer.bytes_received,
    }, .{ .session_id = session_id });
}

pub const TransferAsRequestWriter = struct {
    transfer: *Transfer,

    pub fn init(transfer: *Transfer) TransferAsRequestWriter {
        return .{
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const TransferAsRequestWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }
    fn _jsonStringify(self: *const TransferAsRequestWriter, jws: anytype) !void {
        const writer = jws.writer;
        const transfer = self.transfer;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.beginWriteRaw();
            try writer.writeByte('\"');
            // #ZIGDOM shouldn't include the hash?
            try writer.writeAll(transfer.url);
            try writer.writeByte('\"');
            jws.endWriteRaw();
        }

        {
            const frag = URL.getHash(transfer.url);
            if (frag.len > 0) {
                try jws.objectField("urlFragment");
                try jws.beginWriteRaw();
                try writer.writeAll("\"#");
                try writer.writeAll(frag);
                try writer.writeByte('\"');
                jws.endWriteRaw();
            }
        }

        {
            try jws.objectField("method");
            try jws.write(@tagName(transfer.req.method));
        }

        {
            try jws.objectField("hasPostData");
            try jws.write(transfer.req.body != null);
        }

        {
            try jws.objectField("headers");
            try jws.beginObject();
            var it = transfer.req.headers.iterator();
            while (it.next()) |hdr| {
                try jws.objectField(hdr.name);
                try jws.write(hdr.value);
            }
            try jws.endObject();
        }
        try jws.endObject();
    }
};

const TransferAsResponseWriter = struct {
    arena: Allocator,
    transfer: *Transfer,

    fn init(arena: Allocator, transfer: *Transfer) TransferAsResponseWriter {
        return .{
            .arena = arena,
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const TransferAsResponseWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const TransferAsResponseWriter, jws: anytype) !void {
        const writer = jws.writer;
        const transfer = self.transfer;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.beginWriteRaw();
            try writer.writeByte('\"');
            // #ZIGDOM shouldn't include the hash?
            try writer.writeAll(transfer.url);
            try writer.writeByte('\"');
            jws.endWriteRaw();
        }

        if (transfer.response_header) |*rh| {
            // it should not be possible for this to be false, but I'm not
            // feeling brave today.
            const status = rh.status;
            try jws.objectField("status");
            try jws.write(status);

            try jws.objectField("statusText");
            try jws.write(@as(std.http.Status, @enumFromInt(status)).phrase() orelse "Unknown");
        }

        {
            const mime: Mime = blk: {
                if (transfer.response_header.?.contentType()) |ct| {
                    break :blk try Mime.parse(ct);
                }
                break :blk .unknown;
            };

            try jws.objectField("mimeType");
            try jws.write(mime.contentTypeString());
            try jws.objectField("charset");
            try jws.write(mime.charsetString());
        }

        {
            // chromedp doesn't like having duplicate header names. It's pretty
            // common to get these from a server (e.g. for Cache-Control), but
            // Chrome joins these. So we have to too.
            const arena = self.arena;
            var it = transfer.responseHeaderIterator();
            var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            while (it.next()) |hdr| {
                const gop = try map.getOrPut(arena, hdr.name);
                if (gop.found_existing) {
                    // yes, chrome joins multi-value headers with a \n
                    gop.value_ptr.* = try std.mem.join(arena, "\n", &.{ gop.value_ptr.*, hdr.value });
                } else {
                    gop.value_ptr.* = hdr.value;
                }
            }

            try jws.objectField("headers");
            try jws.write(std.json.ArrayHashMap([]const u8){ .map = map });
        }
        try jws.endObject();
    }
};

fn idFromRequestId(request_id: []const u8) !u64 {
    if (!std.mem.startsWith(u8, request_id, "REQ-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u64, request_id[4..], 10) catch return error.InvalidParams;
}

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
            .{ .name = "test3", .value = "value3", .domain = "car.example.com", .path = "/", .size = 11, .secure = true }, // No Pancakes!
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
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{.{ .name = "test4", .value = "value4", .domain = ".example.com", .path = "/mango", .size = 11 }} }, .{ .id = 8 });

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

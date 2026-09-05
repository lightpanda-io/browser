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

const Config = @import("../../../Config.zig");
const URL = @import("../../../browser/URL.zig");
const Mime = @import("../../../browser/Mime.zig");
const Notification = @import("../../../Notification.zig");

const HttpClient = @import("../../../network/HttpClient.zig");
const Cache = @import("../../../network/cache/Cache.zig");
const Transfer = @import("../../../network/HttpClient.zig").Transfer;

const CdpStorage = @import("storage.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
pub const max_post_data_size = 64 * 1024;

// Network.enable's buffer parameters.
pub const BufferLimits = struct {
    // total bytes that we'll capture before evicting older entries
    total: usize = 200 * 1000 * 1000,
    // max bytes-per-capture that we'll retain
    resource: usize = 20 * 1000 * 1000,
    post_data: usize = max_post_data_size,
};

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        setCacheDisabled,
        setBlockedURLs,
        setExtraHTTPHeaders,
        setUserAgentOverride,
        deleteCookies,
        clearBrowserCookies,
        clearBrowserCache,
        canClearBrowserCache,
        setCookie,
        setCookies,
        getCookies,
        getAllCookies,
        getResponseBody,
        getRequestPostData,
        emulateNetworkConditions,
        setBypassServiceWorker,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .setCacheDisabled => return setCacheDisabled(cmd),
        .setBlockedURLs => return setBlockedURLs(cmd),
        .setUserAgentOverride => return @import("emulation.zig").setUserAgentOverride(cmd),
        .setExtraHTTPHeaders => return setExtraHTTPHeaders(cmd),
        .deleteCookies => return deleteCookies(cmd),
        .clearBrowserCookies => return clearBrowserCookies(cmd),
        .clearBrowserCache => return clearBrowserCache(cmd),
        .canClearBrowserCache => return canClearBrowserCache(cmd),
        .setCookie => return setCookie(cmd),
        .setCookies => return setCookies(cmd),
        .getCookies => return getCookies(cmd),
        .getAllCookies => return getAllCookies(cmd),
        .getResponseBody => return getResponseBody(cmd),
        .getRequestPostData => return getRequestPostData(cmd),
        .emulateNetworkConditions => return emulateNetworkConditions(cmd),
        // There are no service workers to bypass.
        .setBypassServiceWorker => return cmd.sendResult(null, .{}),
    }
}

fn emulateNetworkConditions(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        offline: bool,
        latency: f64,
        downloadThroughput: f64,
        uploadThroughput: f64,
    })) orelse return error.InvalidParams;

    if (params.offline) {
        return cmd.sendError(-32000, "Offline emulation is not supported", .{});
    }
    // -1 disables a throughput limit.
    if (params.latency > 0 or params.downloadThroughput > 0 or params.uploadThroughput > 0) {
        log.warn(.not_implemented, "Network.emulateNetworkConditions", .{ .param = "throttling" });
    }
    return cmd.sendResult(null, .{});
}

fn enable(cmd: *CDP.Command) !void {
    const Params = struct {
        maxTotalBufferSize: ?u32 = null,
        maxResourceBufferSize: ?u32 = null,
        maxPostDataSize: ?u32 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    var limits: BufferLimits = .{};
    if (params.maxTotalBufferSize) |max| {
        limits.total = max;
    }
    if (params.maxResourceBufferSize) |max| {
        limits.resource = max;
    }
    if (params.maxPostDataSize) |max| {
        // 0 is Chrome's "no limit".
        limits.post_data = if (max == 0) std.math.maxInt(usize) else max;
    }
    try bc.networkEnable(limits);
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.networkDisable();
    return cmd.sendResult(null, .{});
}

fn setCacheDisabled(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        cacheDisabled: bool,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const client = &bc.cdp.browser.http_client;
    if (!bc.cdp.disable_set_cache_disabled) {
        client.disableCache(params.cacheDisabled);
    }
    return cmd.sendResult(null, .{});
}

fn setBlockedURLs(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        urlPatterns: []const HttpClient.BlockPattern,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.cdp.browser.http_client.setBlockedUrlPatterns(params.urlPatterns);
    return cmd.sendResult(null, .{});
}

fn setExtraHTTPHeaders(cmd: *CDP.Command) !void {
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
        const key = header.key_ptr.*;
        const value = header.value_ptr.*;

        if (Mime.isHttpToken(key) == false) {
            log.warn(.cdp, "network.setExtraHTTPHeaders", .{ .param = "header", .value = key, .info = "header name must be a non-empty HTTP token" });
            continue;
        }

        if (Mime.isHttpHeaderValue(value) == false) {
            log.warn(.cdp, "network.setExtraHTTPHeaders", .{ .param = "header", .value = key, .info = "header value must be Latin-1 text without CR, LF or NUL" });
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
            Config.validateUserAgent(value) catch |err| {
                log.warn(.cdp, "network.setExtraHTTPHeaders", .{ .param = "userAgent", .value = value, .err = err });
                continue;
            };
        }

        extra_headers.appendAssumeCapacity(.{
            .name = try arena.dupe(u8, key),
            .value = try arena.dupe(u8, value),
        });
    }

    return cmd.sendResult(null, .{});
}

const Cookie = @import("../../../browser/webapi/storage/storage.zig").Cookie;

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

fn deleteCookies(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        name: []const u8,
        url: ?[:0]const u8 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        partitionKey: ?CdpStorage.CookiePartitionKey = null,
    })) orelse return error.InvalidParams;
    // Silently ignore partitionKey since we don't support partitioned cookies (CHIPS).
    // This allows Puppeteer's frame.setCookie() to work, which sends deleteCookies
    // with partitionKey as part of its cookie-setting workflow.
    if (params.partitionKey != null) {
        log.warn(.not_implemented, "partition key", .{ .src = "deleteCookies" });
    }

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

fn clearBrowserCache(cmd: *CDP.Command) !void {
    // Network.clearBrowserCache takes no parameters per the CDP spec, but most
    // CDP clients (chrome-remote-interface, chromedp, custom websocket clients)
    // include an empty `"params":{}` object on every command for ergonomics.
    // Chrome accepts that and clears the jar; reject only on truly malformed JSON.
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const network = bc.cdp.browser.http_client.network;
    try network.cache.clear();
    return cmd.sendResult(null, .{});
}

fn canClearBrowserCache(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const network = bc.cdp.browser.http_client.network;
    return cmd.sendResult(.{ .result = network.cache.active() != null }, .{});
}

fn clearBrowserCookies(cmd: *CDP.Command) !void {
    // Network.clearBrowserCookies takes no parameters per the CDP spec, but most
    // CDP clients (chrome-remote-interface, chromedp, custom websocket clients)
    // include an empty `"params":{}` object on every command for ergonomics.
    // Chrome accepts that and clears the jar; reject only on truly malformed JSON.
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.session.cookie_jar.clearRetainingCapacity();
    return cmd.sendResult(null, .{});
}

fn setCookie(cmd: *CDP.Command) !void {
    const params = (try cmd.params(
        CdpStorage.CdpCookie,
    )) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try CdpStorage.setCdpCookie(&bc.session.cookie_jar, params);

    try cmd.sendResult(.{ .success = true }, .{});
}

fn setCookies(cmd: *CDP.Command) !void {
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
fn getCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(GetCookiesParam)) orelse GetCookiesParam{};

    // If not specified, use the URLs of the page and all of its subframes. TODO subframes
    const frame_url = if (bc.mainFrame()) |frame| frame.url else null;
    const param_urls = params.urls orelse &[_][:0]const u8{frame_url orelse return error.InvalidParams};

    var urls = try std.ArrayList(CdpStorage.PreparedUri).initCapacity(cmd.arena, param_urls.len);
    for (param_urls) |url| {
        urls.appendAssumeCapacity(CdpStorage.PreparedUri.init(url));
    }

    var jar = &bc.session.cookie_jar;
    jar.removeExpired(null);
    const writer = CdpStorage.CookieWriter{ .cookies = jar.cookies.items, .urls = urls.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn getAllCookies(cmd: *CDP.Command) !void {
    // Returns every cookie in the jar regardless of the current frame's origin.
    // Mirrors Chrome's Network.getAllCookies and Storage.getCookies (without
    // the latter's browserContextId filter, since Network commands are scoped
    // to the current browser context already).
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    var jar = &bc.session.cookie_jar;
    jar.removeExpired(null);
    const writer = CdpStorage.CookieWriter{ .cookies = jar.cookies.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn getResponseBody(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        requestId: []const u8, // "REQ-{d}" or "LID-{d}"
    })) orelse return error.InvalidParams;

    const key = try keyFromRequestId(params.requestId);
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const resp = bc.captured_responses.getPtr(key) orelse return error.RequestNotFound;
    const data = resp.data orelse {
        return cmd.sendError(-32000, "Request content was evicted from inspector cache", .{});
    };

    // must_encode trusts the declared charset; a server can declare UTF-8 and
    // still send invalid bytes.
    if (!resp.must_encode and std.unicode.utf8ValidateSlice(data.items)) {
        return cmd.sendResult(.{
            .body = data.items,
            .base64Encoded = false,
        }, .{});
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(data.items.len);
    const encoded = try cmd.arena.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data.items);

    return cmd.sendResult(.{
        .body = encoded,
        .base64Encoded = true,
    }, .{});
}

fn getRequestPostData(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        requestId: []const u8, // "REQ-{d}" or "LID-{d}"
    })) orelse return error.InvalidParams;

    const key = try keyFromRequestId(params.requestId);
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const body = bc.captured_requests.get(key) orelse return error.RequestNotFound;

    return cmd.sendResult(.{ .postData = SafeString.wrap(body) }, .{});
}

pub fn httpRequestFail(bc: *CDP.BrowserContext, msg: *const Notification.RequestFail) !void {
    // It's possible that the request failed because we aborted when the client
    // sent Target.closeTarget. In that case, bc.session_id will be cleared
    // already, and we can skip sending these messages to the client.
    const session_id = bc.session_id orelse return;

    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a frame.
    lp.assert(bc.session.hasPage(), "CDP.network.httpRequestFail null frame", .{});

    // Consumer-side cancel (stopLoading, xhr.abort, AbortController, ...):
    const canceled = msg.err == error.TransferCanceled;
    const error_text: []const u8 = if (canceled) "net::ERR_ABORTED" else @errorName(msg.err);

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.loadingFailed", .{
        .requestId = &id.toRequestId(msg.transfer),
        .timestamp = lp.datetime.timestamp(.boot),
        // Seems to be what chrome answers with. I assume it depends on the type of error?
        .type = "Ping",
        .errorText = error_text,
        .canceled = canceled,
        .blockedReason = msg.blocked_reason,
    }, .{ .session_id = session_id });
}

pub fn httpRequestStart(arena: Allocator, bc: *CDP.BrowserContext, msg: *const Notification.RequestStart) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;
    const req = &transfer.req;
    const frame_id = req.document_frame_id orelse req.frame_id;
    const frame = bc.session.findFrameByFrameId(frame_id) orelse return;

    // Modify request with extra CDP headers: the .cdp layer overrides both
    // built-in defaults and script-set headers of the same name (Chrome
    // behavior), but never a .fixed header.
    for (bc.extra_headers.items) |extra| {
        try transfer.setHeader(extra.name, extra.value, .{ .source = .cdp });
    }

    // We're missing a bunch of fields, but, for now, this eems like enough
    try bc.cdp.sendEvent("Network.requestWillBeSent", .{
        .frameId = &id.toFrameId(frame_id),
        .requestId = &id.toRequestId(transfer),
        .loaderId = &id.toLoaderId(req.loader_id),
        .type = req.resource_type.string(),
        .documentURL = frame.url,
        .request = RequestWriter.init(arena, transfer, bc.network_limits.post_data),
        .initiator = .{ .type = "other" },
        .redirectResponse = if (msg.redirect_response)
            ResponseWriter.init(arena, transfer)
        else
            null,
        .redirectHasExtraInfo = false, // TODO change after adding Network.requestWillBeSentExtraInfo
        .hasUserGesture = false,
        .timestamp = lp.datetime.timestamp(.boot),
        .wallTime = lp.datetime.timestamp(.real),
    }, .{ .session_id = session_id });
}

pub fn httpResponseHeaderDone(arena: Allocator, bc: *CDP.BrowserContext, msg: *const Notification.ResponseHeaderDone) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;
    const req = &transfer.req;

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.responseReceived", .{
        .frameId = &id.toFrameId(req.document_frame_id orelse req.frame_id),
        .requestId = &id.toRequestId(transfer),
        .loaderId = &id.toLoaderId(req.loader_id),
        .timestamp = lp.datetime.timestamp(.boot),
        .type = req.resource_type.string(),
        .response = ResponseWriter.init(arena, msg.transfer),
        .hasExtraInfo = false, // TODO change after adding Network.responseReceivedExtraInfo
    }, .{ .session_id = session_id });
}

pub fn httpRequestDone(bc: *CDP.BrowserContext, msg: *const Notification.RequestDone) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    try bc.cdp.sendEvent("Network.loadingFinished", .{
        .requestId = &id.toRequestId(msg.transfer),
        .timestamp = lp.datetime.timestamp(.boot),
        .encodedDataLength = msg.content_length,
    }, .{ .session_id = session_id });
}

pub fn httpServedFromCache(bc: *CDP.BrowserContext, msg: *const Notification.RequestServedFromCache) !void {
    const session_id = bc.session_id orelse return;
    const transfer = msg.transfer;

    try bc.cdp.sendEvent("Network.requestServedFromCache", .{
        .requestId = &id.toRequestId(transfer),
    }, .{ .session_id = session_id });
}

pub const RequestWriter = struct {
    arena: Allocator,
    transfer: *Transfer,
    max_post_data: usize,

    pub fn init(arena: Allocator, transfer: *Transfer, max_post_data: usize) RequestWriter {
        return .{
            .arena = arena,
            .transfer = transfer,
            .max_post_data = max_post_data,
        };
    }

    pub fn jsonStringify(self: *const RequestWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const RequestWriter, jws: anytype) !void {
        const transfer = self.transfer;
        const request = &transfer.req;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.write(request.url);
        }

        {
            const frag = URL.getHash(request.url);
            if (frag.len > 0) {
                try jws.objectField("urlFragment");
                try jws.write(frag);
            }
        }

        {
            try jws.objectField("method");
            try jws.write(@tagName(request.method));
        }

        {
            try jws.objectField("hasPostData");
            try jws.write(request.body != null);
        }

        if (request.body) |body| {
            if (body.len <= self.max_post_data) {
                try jws.objectField("postData");
                try jws.write(SafeString.wrap(body));

                // postDataEntries is the binary-safe representation
                // (postData is lossy for non-UTF-8 bodies).
                const encoder = std.base64.standard.Encoder;
                const encoded = try self.arena.alloc(u8, encoder.calcSize(body.len));
                try jws.objectField("postDataEntries");
                try jws.write(&[_]struct { bytes: []const u8 }{
                    .{ .bytes = encoder.encode(encoded, body) },
                });
            }
        }

        {
            try jws.objectField("initialPriority");
            try jws.write(initialPriority(request.resource_type));
        }

        {
            // TODO implement proper referrerPolicy
            try jws.objectField("referrerPolicy");
            try jws.write("unsafe-url");
        }

        {
            try jws.objectField("headers");
            try jws.beginObject();
            for (transfer.req_headers.items) |hdr| {
                try SafeString.writeObjectField(jws, hdr.name);
                try jws.write(SafeString.wrap(hdr.value));
            }
            if (try transfer.getCookieString(transfer.arena.allocator())) |cookies| {
                try jws.objectField("Cookie");
                try jws.write(cookies[0 .. cookies.len - 1]);
            }
            try jws.endObject();
        }
        try jws.endObject();
    }
};

const ResponseWriter = struct {
    arena: Allocator,
    transfer: *Transfer,

    fn init(arena: Allocator, transfer: *Transfer) ResponseWriter {
        return .{
            .arena = arena,
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const ResponseWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const ResponseWriter, jws: anytype) !void {
        const transfer = self.transfer;
        const response_url = if (transfer.res.header) |header|
            std.mem.span(header.url)
        else
            transfer.req.url;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.write(response_url);
        }

        if (transfer.responseStatus()) |status| {
            try jws.objectField("status");
            try jws.write(status);

            try jws.objectField("statusText");
            try jws.write(@as(std.http.Status, @enumFromInt(status)).phrase() orelse "Unknown");
        }

        {
            const mime: Mime = blk: {
                if (transfer.contentType()) |ct| {
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
            try jws.objectField("fromDiskCache");
            try jws.write(transfer._from_cache);
        }

        {
            try jws.objectField("connectionReused");
            try jws.write(transfer._conn_reused);
            try jws.objectField("connectionId");
            try jws.write(transfer._conn_id);
            // Bytes received so far, which is zero for a streaming response:
            // its headers are reported before any of the body is read.
            try jws.objectField("encodedDataLength");
            try jws.write(transfer._content_length);
            try jws.objectField("securityState");
            try jws.write(securityState(response_url));
        }

        {
            try jws.objectField("timing");
            try jws.write(.{
                // TODO: fix
                .requestTime = -1,
                .connectEnd = -1,
                .connectStart = -1,
                .dnsEnd = -1,
                .dnsStart = -1,
                .proxyEnd = -1,
                .proxyStart = -1,
                .receiveHeadersEnd = -1,
                .receiveHeadersStart = -1,
                .sendEnd = -1,
                .sendStart = -1,
                .sslEnd = -1,
                .sslStart = -1,
                // -1 is Chrome's "no service worker"; the push pair is 0 when
                // nothing was pushed, not -1.
                .workerStart = -1,
                .workerReady = -1,
                .workerFetchStart = -1,
                .workerRespondWithSettled = -1,
                .pushStart = 0,
                .pushEnd = 0,
            });
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
            try jws.beginObject();
            var map_it = map.iterator();
            while (map_it.next()) |entry| {
                try SafeString.writeObjectField(jws, entry.key_ptr.*);
                try jws.write(SafeString.wrap(entry.value_ptr.*));
            }
            try jws.endObject();
        }
        try jws.endObject();
    }
};

fn initialPriority(resource_type: HttpClient.Request.ResourceType) []const u8 {
    return switch (resource_type) {
        .document, .stylesheet => "VeryHigh",
        .script, .worker, .xhr, .fetch, .eventsource => "High",
        .image => "Low",
    };
}

fn securityState(url: [:0]const u8) []const u8 {
    if (URL.isSecure(url)) {
        return "secure";
    }
    if (std.mem.startsWith(u8, url, "http:") or std.mem.startsWith(u8, url, "ws:")) {
        return "insecure";
    }
    return "unknown";
}

fn keyFromRequestId(request_id: []const u8) !CDP.BrowserContext.CapturedKey {
    if (request_id.len < 4) {
        return error.InvalidParams;
    }

    const key = std.fmt.parseInt(u32, request_id[4..], 10) catch return error.InvalidParams;

    return if (std.mem.startsWith(u8, request_id, "LID-"))
        .{ .id = key, .kind = .loader }
    else
        .{ .id = key, .kind = .request };
}

const testing = @import("../testing.zig");
test "cdp.network emulateNetworkConditions and setBypassServiceWorker" {
    testing.silenceLog(&.{.not_implemented});
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-NET" });

    try ctx.processMessage(.{ .id = 1, .method = "Network.emulateNetworkConditions", .params = .{ .offline = false, .latency = 0, .downloadThroughput = -1, .uploadThroughput = -1 } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Network.emulateNetworkConditions", .params = .{ .offline = true, .latency = 0, .downloadThroughput = -1, .uploadThroughput = -1 } });
    try ctx.expectSentError(-32000, "Offline emulation is not supported", .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Network.setBypassServiceWorker", .params = .{ .bypass = true } });
    try ctx.expectSentResult(null, .{ .id = 3 });
}

test "cdp.network setExtraHTTPHeaders" {
    var ctx = try testing.context();
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

test "cdp.network setExtraHTTPHeaders rejects non-printable User-Agent" {
    testing.silenceLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "NID-UA1", .session_id = "NESI-UA1" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{
            .@"User-Agent" = "Bot/1.0\x01hidden",
            .@"x-custom" = "hi",
        } },
    });

    try testing.expectEqual(bc.extra_headers.items.len, 1);
    try testing.expectEqual("x-custom", bc.extra_headers.items[0].name);
    try testing.expectEqual("hi", bc.extra_headers.items[0].value);
}

test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent" {
    testing.silenceLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "NID-UA2", .session_id = "NESI-UA2" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .@"User-Agent" = "Mozilla/5.0" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.extra_headers.items.len, 0);
}

test "cdp.network setExtraHTTPHeaders accepts valid User-Agent" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "NID-UA3", .session_id = "NESI-UA3" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .@"User-Agent" = "CustomBot/2.0" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.extra_headers.items.len, 1);
}

test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent smuggled via a colon in the key" {
    testing.silenceLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "NID-UA4", .session_id = "NESI-UA4" });

    // A colon in the key would desync the stored name from what lands on the
    // wire once the pair is joined: "User-Agent:Mozilla/5.0 (X: Y)" parses to
    // name="User-Agent", value="Mozilla/5.0 (X: Y)" on the wire.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .@"User-Agent:Mozilla/5.0 (X" = "Y)" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.extra_headers.items.len, 0);
}

test "cdp.network setExtraHTTPHeaders rejects a header that smuggles CRLF" {
    testing.silenceLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "NID-UA5", .session_id = "NESI-UA5" });

    // The CRLF in the value would inject a second User-Agent line that never
    // saw validation; the whole header must be dropped.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{
            .@"x-custom" = "bar\r\nUser-Agent: Mozilla/5.0",
            .@"x-keep" = "ok",
        } },
    });

    try testing.expectEqual(bc.extra_headers.items.len, 1);
    try testing.expectEqual("x-keep", bc.extra_headers.items[0].name);
    try testing.expectEqual("ok", bc.extra_headers.items[0].value);
}

test "cdp.network setExtraHTTPHeaders rejects a name that isn't an HTTP token" {
    testing.silenceLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "NID-UA6", .session_id = "NESI-UA6" });

    // A space — or any other non-token byte — in the name would land
    // malformed on the wire.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{
            .@"X Custom" = "bar",
            .@"x-keep" = "ok",
        } },
    });

    try testing.expectEqual(bc.extra_headers.items.len, 1);
    try testing.expectEqual("x-keep", bc.extra_headers.items[0].name);
    try testing.expectEqual("ok", bc.extra_headers.items[0].value);
}

test "cdp.Network: cookies" {
    const ResCookie = CdpStorage.ResCookie;
    const CdpCookie = CdpStorage.CdpCookie;

    var ctx = try testing.context();
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

test "cdp.Network: clearBrowserCookies accepts empty params object" {
    const CdpCookie = CdpStorage.CdpCookie;
    const ResCookie = CdpStorage.ResCookie;

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-N1" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.setCookie",
        .params = CdpCookie{ .name = "foo", .value = "bar", .url = "https://example.com/" },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // Most CDP clients (chrome-remote-interface, chromedp, etc.) always include
    // a `params` field on every command, even for methods that take none.
    // Chrome ignores the empty object; we should too. Sent as raw JSON because
    // an empty Zig anonymous struct serializes as `[]`, not `{}`.
    try ctx.processMessage(
        \\{"id":2,"method":"Network.clearBrowserCookies","params":{}}
    );
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-N1" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 3 });
}

test "cdp.Network: getAllCookies returns whole jar regardless of current origin" {
    const CdpCookie = CdpStorage.CdpCookie;
    const ResCookie = CdpStorage.ResCookie;

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-N2" });

    // Two cookies on different origins. With no current frame URL,
    // Network.getCookies (no `urls`) would return -32602 InvalidParams;
    // Network.getAllCookies must still return both.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "a", .value = "1", .url = "https://example.com/" },
                .{ .name = "b", .value = "2", .url = "https://other.test/" },
            },
        },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // Empty params object — sent as raw JSON because an empty Zig anonymous
    // struct serializes as `[]`, not `{}`.
    try ctx.processMessage(
        \\{"id":2,"method":"Network.getAllCookies","params":{}}
    );
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "a", .value = "1", .domain = "example.com", .path = "/", .size = 2, .secure = true },
            .{ .name = "b", .value = "2", .domain = "other.test", .path = "/", .size = 2, .secure = true },
        },
    }, .{ .id = 2 });

    // Also works without any params field at all (CDP-spec literal "no params").
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getAllCookies",
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "a", .value = "1", .domain = "example.com", .path = "/", .size = 2, .secure = true },
            .{ .name = "b", .value = "2", .domain = "other.test", .path = "/", .size = 2, .secure = true },
        },
    }, .{ .id = 3 });
}

test "cdp.Network: clearBrowserCache succeeds" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-CC1" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.clearBrowserCache",
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
}

test "cdp.Network: clearBrowserCache accepts empty params object" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-CC2" });

    try ctx.processMessage(
        \\{"id":1,"method":"Network.clearBrowserCache","params":{}}
    );
    try ctx.expectSentResult(null, .{ .id = 1 });
}

test "cdp.Network: canClearBrowserCache" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-CC3" });
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.canClearBrowserCache",
    });

    // Cache is disabled in standard tests for now.
    try ctx.expectSentResult(.{ .result = false }, .{ .id = 1 });
}

test "cdp.Network: setCacheDisabled" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-CD1" });

    var cache: Cache = undefined;
    const client = &ctx.cdp().browser.http_client;
    client.cache = &cache;

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.setCacheDisabled",
        .params = .{ .cacheDisabled = true },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try testing.expectEqual(null, client.cache.active());
}

test "cdp.Network: configured CDP ignores setCacheDisabled" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-CD2" });

    var cache: Cache = undefined;
    const client = &ctx.cdp().browser.http_client;
    client.cache = &cache;
    defer client.cache = &testing.base.test_app.network.cache;

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.configureCDP",
        .params = .{ .disableSetCacheDisabled = true },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.setCacheDisabled",
        .params = .{ .cacheDisabled = true },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try testing.expect(client.cache == &cache);
}

test "cdp.Network: setBlockedURLs blocks requests with inspector reason" {
    testing.silenceLog(&.{.http});

    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-BLOCK",
        .session_id = "SID-BLOCK",
    });
    const page = try bc.session.createPage();
    const client = &bc.cdp.browser.http_client;
    defer client.setBlockedUrls(&.{}) catch unreachable;

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.setBlockedURLs",
        .params = .{ .urlPatterns = &[_]HttpClient.BlockPattern{
            .{ .urlPattern = "*://blocked.test/*", .block = true },
        } },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const ErrorContext = struct {
        err: ?anyerror = null,

        fn callback(raw: *anyopaque, err: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.err = err;
        }
    };
    var error_context: ErrorContext = .{};

    try client.request(.{
        .frame_id = page.frame_id,
        .loader_id = 1,
        .method = .GET,
        .url = "https://blocked.test/script.js",
        .origin = bc.security_origin,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .resource_type = .script,
        .notification = bc.session.notification,
        .ctx = &error_context,
        .error_callback = ErrorContext.callback,
        .shutdown_callback = HttpClient.noopShutdown,
    }, null);

    try ctx.expectSentEvent("Network.loadingFailed", .{
        .errorText = error.UrlBlocked,
        .blockedReason = "inspector",
    }, .{ .session_id = "SID-BLOCK" });
    try testing.expectEqual(error.UrlBlocked, error_context.err.?);

    try client.setBlockedUrls(&.{"*redirect-target*"});
    error_context.err = null;

    var redirect_request_id: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&redirect_request_id, "REQ-{d:0>10}", .{client.next_request_id +% 1}) catch unreachable;

    try client.request(.{
        .frame_id = page.frame_id,
        .loader_id = 1,
        .method = .GET,
        .url = "http://127.0.0.1:9582/redirect-no-fragment",
        .origin = bc.security_origin,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .resource_type = .script,
        .notification = bc.session.notification,
        .ctx = &error_context,
        .error_callback = ErrorContext.callback,
        .shutdown_callback = HttpClient.noopShutdown,
    }, null);

    try ctx.expectSentEvent("Network.loadingFailed", .{
        .requestId = &redirect_request_id,
        .errorText = error.UrlBlocked,
        .blockedReason = "inspector",
    }, .{ .session_id = "SID-BLOCK" });
    try testing.expectEqual(error.UrlBlocked, error_context.err.?);
}

test "cdp.Network: POST body exposed as postData" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-PD", .session_id = "SID-PD" });
    const page = try bc.session.createPage();
    const client = &bc.cdp.browser.http_client;

    try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var request_id: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&request_id, "REQ-{d:0>10}", .{client.next_request_id +% 1}) catch unreachable;

    // \xE9 exercises the Latin-1 -> UTF-8 transcode in postData;
    // postDataEntries carry the raw bytes in base64.
    const body = "name=Zig&note=caf\xE9";

    try client.request(.{
        .frame_id = page.frame_id,
        .loader_id = 1,
        .method = .POST,
        .url = "http://127.0.0.1:9582/echo_body",
        .origin = bc.security_origin,
        .body = body,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .resource_type = .fetch,
        .notification = bc.session.notification,
        .shutdown_callback = HttpClient.noopShutdown,
    }, null);

    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .requestId = &request_id,
        .request = .{
            .method = "POST",
            .hasPostData = true,
            .postData = "name=Zig&note=café",
            .postDataEntries = &[_]struct { bytes: []const u8 }{
                .{ .bytes = "bmFtZT1aaWcmbm90ZT1jYWbp" },
            },
        },
    }, .{ .session_id = "SID-PD" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = &request_id },
    });
    try ctx.expectSentResult(.{ .postData = "name=Zig&note=café" }, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = "REQ-4294967295" },
    });
    try ctx.expectSentError(-31998, "RequestNotFound", .{ .id = 3 });
}

// Drives POST /echo_body (the response echoes the body, so its size is the
// request body's) to completion and returns the wire requestId.
const EchoDriver = struct {
    done: bool = false,
    err: ?anyerror = null,

    fn doneCallback(raw: *anyopaque) !void {
        const self: *EchoDriver = @ptrCast(@alignCast(raw));
        self.done = true;
    }

    fn errorCallback(raw: *anyopaque, err: anyerror) void {
        const self: *EchoDriver = @ptrCast(@alignCast(raw));
        self.err = err;
    }

    fn run(bc: *CDP.BrowserContext, frame_id: u32, body: []const u8) ![14]u8 {
        const client = &bc.cdp.browser.http_client;
        var request_id: [14]u8 = undefined;
        _ = std.fmt.bufPrint(&request_id, "REQ-{d:0>10}", .{client.next_request_id +% 1}) catch unreachable;

        var driver: EchoDriver = .{};
        try client.request(.{
            .frame_id = frame_id,
            .loader_id = 1,
            .method = .POST,
            .url = "http://127.0.0.1:9582/echo_body",
            .body = body,
            .origin = bc.security_origin,
            .request_mode = .no_cors,
            .credentials_mode = .same_origin,
            .resource_type = .fetch,
            .notification = bc.session.notification,
            .ctx = &driver,
            .done_callback = doneCallback,
            .error_callback = errorCallback,
            .shutdown_callback = HttpClient.noopShutdown,
        }, null);

        for (0..50) |_| {
            if (driver.done or driver.err != null) break;
            _ = try client.tick(20);
        }
        try testing.expectEqual(null, driver.err);
        try testing.expect(driver.done);
        return request_id;
    }
};

test "cdp.Network: enable maxResourceBufferSize evicts oversized bodies" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-RBS", .session_id = "SID-RBS" });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxResourceBufferSize = 4 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const big = try EchoDriver.run(bc, page.frame_id, "12345678");
    const small = try EchoDriver.run(bc, page.frame_id, "123");

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &big },
    });
    try ctx.expectSentError(-32000, "Request content was evicted from inspector cache", .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &small },
    });
    try ctx.expectSentResult(.{ .body = "123", .base64Encoded = false }, .{ .id = 3 });
    try testing.expectEqual(3, bc.captured_responses_size);

    // Re-enabling with a tighter limit evicts what's already captured.
    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.enable",
        .params = .{ .maxResourceBufferSize = 2 },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &small },
    });
    try ctx.expectSentError(-32000, "Request content was evicted from inspector cache", .{ .id = 5 });
    try testing.expectEqual(0, bc.captured_responses_size);
}

test "cdp.Network: enable maxTotalBufferSize evicts oldest bodies first" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-TBS", .session_id = "SID-TBS" });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxTotalBufferSize = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const first = try EchoDriver.run(bc, page.frame_id, "aaaaaa");
    const second = try EchoDriver.run(bc, page.frame_id, "bbbbbb");

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &first },
    });
    try ctx.expectSentError(-32000, "Request content was evicted from inspector cache", .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &second },
    });
    try ctx.expectSentResult(.{ .body = "bbbbbb", .base64Encoded = false }, .{ .id = 3 });
    try testing.expectEqual(6, bc.captured_responses_size);

    // Network.disable releases everything retained.
    try ctx.processMessage(.{ .id = 4, .method = "Network.disable" });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try testing.expectEqual(0, bc.captured_responses.count());
    try testing.expectEqual(0, bc.captured_responses_size);
    try ctx.processMessage(.{
        .id = 5,
        .method = "Network.getResponseBody",
        .params = .{ .requestId = &second },
    });
    try ctx.expectSentError(-31998, "RequestNotFound", .{ .id = 5 });
}

test "cdp.Network: enable maxPostDataSize omits inline postData" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-PDS", .session_id = "SID-PDS" });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxPostDataSize = 8 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const body = "{\"source\":\"xhr\",\"pageSize\":100}";
    const request_id = try EchoDriver.run(bc, page.frame_id, body);

    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .requestId = &request_id,
        .request = .{ .method = "POST", .hasPostData = true },
    }, .{ .session_id = "SID-PDS" });

    // The subset matcher can't assert absence; look at the event directly.
    var seen = false;
    for (ctx.received.items) |received| {
        const method = received.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "Network.requestWillBeSent")) continue;
        const request = received.object.get("params").?.object.get("request").?.object;
        try testing.expectEqual(null, request.get("postData"));
        try testing.expectEqual(null, request.get("postDataEntries"));
        seen = true;
    }
    try testing.expect(seen);

    // Retention is independent of the inline limit.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = &request_id },
    });
    try ctx.expectSentResult(.{ .postData = body }, .{ .id = 2 });
}

test "cdp.Network: redirect hop precedes Fetch pause and carries redirectResponse" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-REDIRECT", .session_id = "SID-REDIRECT" });
    const page = try bc.session.createPage();
    const client = &bc.cdp.browser.http_client;

    try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.processMessage(.{ .id = 2, .method = "Fetch.enable" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const CallbackContext = struct {
        body: [64]u8 = undefined,
        body_len: usize = 0,
        done: bool = false,
        err: ?anyerror = null,

        fn dataCallback(transfer: *Transfer, data: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(transfer.req.ctx));
            @memcpy(self.body[self.body_len..][0..data.len], data);
            self.body_len += data.len;
        }

        fn doneCallback(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.done = true;
        }

        fn errorCallback(raw: *anyopaque, err: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.err = err;
        }
    };
    var callback_context: CallbackContext = .{};

    const start_url = "http://127.0.0.1:9582/redirect-cross-origin-x-hop";
    const target_url = "http://localhost:9582/echo-x-hop";
    var request_id: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&request_id, "REQ-{d:0>10}", .{client.next_request_id +% 1}) catch unreachable;

    try client.request(.{
        .frame_id = page.frame_id,
        .loader_id = 7,
        .method = .GET,
        .url = start_url,
        .origin = bc.security_origin,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .resource_type = .script,
        .notification = bc.session.notification,
        .ctx = &callback_context,
        .data_callback = CallbackContext.dataCallback,
        .done_callback = CallbackContext.doneCallback,
        .error_callback = CallbackContext.errorCallback,
        .shutdown_callback = HttpClient.noopShutdown,
    }, null);

    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .requestId = &request_id,
        .loaderId = &id.toLoaderId(7),
        .type = "Script",
        .request = .{ .url = start_url },
    }, .{ .index = 2, .session_id = "SID-REDIRECT" });
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .networkId = &request_id,
        .request = .{ .url = start_url },
    }, .{ .index = 3, .session_id = "SID-REDIRECT" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Fetch.continueRequest",
        .params = .{
            .requestId = "INT-0000000001",
            .headers = &[_]HttpClient.Header{.{ .name = "x-hop", .value = "127.0.0.1:9582" }},
        },
    });
    try ctx.expectSentResult(null, .{ .id = 3, .index = 4 });

    // Playwright requires requestWillBeSent first so it can create the new
    // redirected Request before pairing the fresh Fetch pause with it.
    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .requestId = &request_id,
        .loaderId = &id.toLoaderId(7),
        .type = "Script",
        .request = .{ .url = target_url },
        .redirectResponse = .{
            .url = start_url,
            .status = 302,
        },
    }, .{ .index = 5, .session_id = "SID-REDIRECT" });
    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .networkId = &request_id,
        .request = .{ .url = target_url },
    }, .{ .index = 6, .session_id = "SID-REDIRECT" });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Fetch.continueRequest",
        .params = .{
            .requestId = "INT-0000000002",
            .headers = &[_]HttpClient.Header{.{ .name = "x-hop", .value = "localhost:9582" }},
        },
    });
    try ctx.expectSentResult(null, .{ .id = 4, .index = 7 });

    for (0..50) |_| {
        if (callback_context.done or callback_context.err != null) break;
        _ = try client.tick(20);
    }
    try testing.expectEqual(null, callback_context.err);
    try testing.expect(callback_context.done);
    try testing.expectEqualSlices(u8, "localhost:9582", callback_context.body[0..callback_context.body_len]);
}

test "cdp.Network: worker requests emit network events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp = ctx.cdp();
    _ = try cdp.createBrowserContext();
    var bc = &cdp.browser_context.?;
    bc.id = "BID-NW";
    bc.session_id = "SID-NW";
    bc.target_id = "TID-NW-0000000".*;

    try ctx.processMessage(.{ .id = 1, .method = "Network.enable" });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const fixture_root = "http://127.0.0.1:9582/src/browser/tests/cdp/";
    const page_url = fixture_root ++ "worker_network.html";
    const worker_url = fixture_root ++ "worker_network.js";
    const api_url = "http://127.0.0.1:9582/echo_method";
    const page = try bc.session.createPage();
    try page.navigate(page_url, .{});
    try testing.waitForPage(bc);

    // Both the worker's script fetch and the fetch the worker itself issues are
    // attributed to the document that created the worker, not to the worker's
    // own frame id, which no client can resolve.
    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .documentURL = page_url,
        .type = "Script",
        .request = .{
            .url = worker_url,
            .initialPriority = "High",
            .referrerPolicy = "unsafe-url",
        },
    }, .{ .session_id = "SID-NW" });
    try ctx.expectSentEvent("Network.responseReceived", .{
        .type = "Script",
        .response = .{
            .url = worker_url,
            .securityState = "insecure",
            // The document was fetched from this origin a moment ago, so the
            // worker's script comes off the same socket. The id itself is a
            // process-wide libcurl counter, so it isn't assertable here.
            .connectionReused = true,
            .timing = .{
                .workerStart = -1,
                .workerReady = -1,
                .workerFetchStart = -1,
                .workerRespondWithSettled = -1,
                .pushStart = 0,
                .pushEnd = 0,
            },
        },
    }, .{ .session_id = "SID-NW" });
    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .documentURL = page_url,
        .type = "Fetch",
        .request = .{ .url = api_url },
    }, .{ .session_id = "SID-NW" });
}

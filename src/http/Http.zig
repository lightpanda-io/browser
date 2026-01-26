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

const std = @import("std");
const lp = @import("lightpanda");
const Config = @import("../Config.zig");

pub const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const ENABLE_DEBUG = false;
pub const Client = @import("Client.zig");
pub const Transfer = Client.Transfer;

const log = @import("../log.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// Client.zig does the bulk of the work and is loosely tied to a browser Page.
// But we still need something above Client.zig for the "utility" http stuff
// we need to do, like telemetry. The most important thing we want from this
// is to be able to share the ca_blob, which can be quite large - loading it
// once for all http connections is a win.
const Http = @This();

pub const Network = @import("Network.zig");

network: *Network,
client: *Client,

pub fn init(allocator: Allocator, network: *Network) !Http {
    var client = try Client.init(allocator, network.ca_blob, network.config);
    errdefer client.deinit();

    return .{
        .network = network,
        .client = client,
    };
}

pub fn deinit(self: *Http) void {
    self.client.deinit();
}

pub fn poll(self: *Http, timeout_ms: u32) Client.PerformStatus {
    return self.client.tick(timeout_ms) catch |err| {
        log.err(.app, "http poll", .{ .err = err });
        return .normal;
    };
}

pub fn addCDPClient(self: *Http, cdp_client: Client.CDPClient) void {
    lp.assert(self.client.cdp_client == null, "Http addCDPClient existing", .{});
    self.client.cdp_client = cdp_client;
}

pub fn removeCDPClient(self: *Http) void {
    self.client.cdp_client = null;
}

pub fn newConnection(self: *Http) !Connection {
    return Connection.init(self.network.ca_blob, self.network.config, self.network.user_agent, self.network.proxy_bearer_header);
}

pub fn newHeaders(self: *const Http) Headers {
    return Headers.init(self.network.user_agent);
}

pub const Connection = struct {
    easy: *c.CURL,
    user_agent: [:0]const u8,
    proxy_bearer_header: ?[:0]const u8,

    pub fn init(
        ca_blob_: ?c.curl_blob,
        config: *const Config,
        user_agent: [:0]const u8,
        proxy_bearer_header: ?[:0]const u8,
    ) !Connection {
        const easy = c.curl_easy_init() orelse return error.FailedToInitializeEasy;
        errdefer _ = c.curl_easy_cleanup(easy);

        // timeouts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(config.httpTimeout()))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(config.httpConnectTimeout()))));

        // redirect behavior
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(config.httpMaxRedirects()))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 2)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, "HTTP,HTTPS")); // remove FTP and FTPS from the default

        // proxy
        const http_proxy = config.httpProxy();
        if (http_proxy) |proxy| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY, proxy.ptr));
        }

        // tls
        if (ca_blob_) |ca_blob| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CAINFO_BLOB, ca_blob));
            if (http_proxy != null) {
                // Note, this can be difference for the proxy and for the main
                // request. Might be something worth exposting as command
                // line arguments at some point.
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_CAINFO_BLOB, ca_blob));
            }
        } else {
            lp.assert(config.tlsVerifyHost() == false, "Http.init tls_verify_host", .{});

            // Verify peer checks that the cert is signed by a CA, verify host makes sure the
            // cert contains the server name.
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)));
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)));

            if (http_proxy != null) {
                // Note, this can be difference for the proxy and for the main
                // request. Might be something worth exposting as command
                // line arguments at some point.
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_SSL_VERIFYHOST, @as(c_long, 0)));
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_SSL_VERIFYPEER, @as(c_long, 0)));
            }
        }

        // compression, don't remove this. CloudFront will send gzip content
        // even if we don't support it, and then it won't be decompressed.
        // empty string means: use whatever's available
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_ACCEPT_ENCODING, ""));

        // debug
        if (comptime Http.ENABLE_DEBUG) {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1)));

            // Sometimes the default debug output hides some useful data. You can
            // uncomment the following line (BUT KEEP THE LIVE ABOVE AS-IS), to
            // get more control over the data (specifically, the `CURLINFO_TEXT`
            // can include useful data).

            // try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_DEBUGFUNCTION, debugCallback));
        }

        return .{
            .easy = easy,
            .user_agent = user_agent,
            .proxy_bearer_header = proxy_bearer_header,
        };
    }

    pub fn deinit(self: *const Connection) void {
        c.curl_easy_cleanup(self.easy);
    }

    pub fn setURL(self: *const Connection, url: [:0]const u8) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_URL, url.ptr));
    }

    // a libcurl request has 2 methods. The first is the method that
    // controls how libcurl behaves. This specifically influences how redirects
    // are handled. For example, if you do a POST and get a 301, libcurl will
    // change that to a GET. But if you do a POST and get a 308, libcurl will
    // keep the POST (and re-send the body).
    // The second method is the actual string that's included in the request
    // headers.
    // These two methods can be different - you can tell curl to behave as though
    // you made a GET, but include "POST" in the request header.
    //
    // Here, we're only concerned about the 2nd method. If we want, we'll set
    // the first one based on whether or not we have a body.
    //
    // It's important that, for each use of this connection, we set the 2nd
    // method. Else, if we make a HEAD request and re-use the connection, but
    // DON'T reset this, it'll keep making HEAD requests.
    // (I don't know if it's as important to reset the 1st method, or if libcurl
    // can infer that based on the presence of the body, but we also reset it
    // to be safe);
    pub fn setMethod(self: *const Connection, method: Method) !void {
        const easy = self.easy;
        const m: [:0]const u8 = switch (method) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
        };
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, m.ptr));
    }

    pub fn setBody(self: *const Connection, body: []const u8) !void {
        const easy = self.easy;
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPPOST, @as(c_long, 1)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr));
    }

    // These are headers that may not be send to the users for inteception.
    pub fn secretHeaders(self: *const Connection, headers: *Headers) !void {
        if (self.proxy_bearer_header) |hdr| {
            try headers.add(hdr);
        }
    }

    pub fn request(self: *const Connection) !u16 {
        const easy = self.easy;

        var header_list = try Headers.init(self.user_agent);
        defer header_list.deinit();
        try self.secretHeaders(&header_list);
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, header_list.headers));

        // Add cookies.
        if (header_list.cookies) |cookies| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_COOKIE, cookies));
        }

        try errorCheck(c.curl_easy_perform(easy));
        var http_code: c_long = undefined;
        try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &http_code));
        if (http_code < 0 or http_code > std.math.maxInt(u16)) {
            return 0;
        }
        return @intCast(http_code);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    headers: ?*c.curl_slist,
    cookies: ?[*c]const u8,

    pub fn init(user_agent: [:0]const u8) !Headers {
        const header_list = c.curl_slist_append(null, user_agent);
        if (header_list == null) {
            return error.OutOfMemory;
        }
        return .{ .headers = header_list, .cookies = null };
    }

    pub fn deinit(self: *const Headers) void {
        if (self.headers) |hdr| {
            c.curl_slist_free_all(hdr);
        }
    }

    pub fn add(self: *Headers, header: [*c]const u8) !void {
        // Copies the value
        const updated_headers = c.curl_slist_append(self.headers, header);
        if (updated_headers == null) return error.OutOfMemory;
        self.headers = updated_headers;
    }

    pub fn parseHeader(header_str: []const u8) ?Header {
        const colon_pos = std.mem.indexOfScalar(u8, header_str, ':') orelse return null;

        const name = std.mem.trim(u8, header_str[0..colon_pos], " \t");
        const value = std.mem.trim(u8, header_str[colon_pos + 1 ..], " \t");

        return .{ .name = name, .value = value };
    }

    pub fn iterator(self: *Headers) Iterator {
        return .{
            .header = self.headers,
            .cookies = self.cookies,
        };
    }

    const Iterator = struct {
        header: [*c]c.curl_slist,
        cookies: ?[*c]const u8,

        pub fn next(self: *Iterator) ?Header {
            const h = self.header orelse {
                const cookies = self.cookies orelse return null;
                self.cookies = null;
                return .{ .name = "Cookie", .value = std.mem.span(@as([*:0]const u8, cookies)) };
            };

            self.header = h.*.next;
            return parseHeader(std.mem.span(@as([*:0]const u8, @ptrCast(h.*.data))));
        }
    };
};

pub fn errorCheck(code: c.CURLcode) errors.Error!void {
    if (code == c.CURLE_OK) {
        return;
    }
    return errors.fromCode(code);
}

pub fn errorMCheck(code: c.CURLMcode) errors.Multi!void {
    if (code == c.CURLM_OK) {
        return;
    }
    if (code == c.CURLM_CALL_MULTI_PERFORM) {
        // should we can client.perform() here?
        // or just wait until the next time we naturally call it?
        return;
    }
    return errors.fromMCode(code);
}

pub const Method = enum(u8) {
    GET = 0,
    PUT = 1,
    POST = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
    PATCH = 6,
};

pub fn debugCallback(_: *c.CURL, msg_type: c.curl_infotype, raw: [*c]u8, len: usize, _: *anyopaque) callconv(.c) void {
    const data = raw[0..len];
    switch (msg_type) {
        c.CURLINFO_TEXT => std.debug.print("libcurl [text]: {s}\n", .{data}),
        c.CURLINFO_HEADER_OUT => std.debug.print("libcurl [req-h]: {s}\n", .{data}),
        c.CURLINFO_HEADER_IN => std.debug.print("libcurl [res-h]: {s}\n", .{data}),
        // c.CURLINFO_DATA_IN => std.debug.print("libcurl [res-b]: {s}\n", .{data}),
        else => std.debug.print("libcurl ?? {d}\n", .{msg_type}),
    }
}

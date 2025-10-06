// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const posix = std.posix;

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

opts: Opts,
client: *Client,
ca_blob: ?c.curl_blob,
arena: ArenaAllocator,

pub fn init(allocator: Allocator, opts: Opts) !Http {
    try errorCheck(c.curl_global_init(c.CURL_GLOBAL_SSL));
    errdefer c.curl_global_cleanup();

    if (comptime ENABLE_DEBUG) {
        std.debug.print("curl version: {s}\n\n", .{c.curl_version()});
    }

    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var adjusted_opts = opts;
    if (opts.proxy_bearer_token) |bt| {
        adjusted_opts.proxy_bearer_token = try std.fmt.allocPrintSentinel(arena.allocator(), "Proxy-Authorization: Bearer {s}", .{bt}, 0);
    }

    var ca_blob: ?c.curl_blob = null;
    if (opts.tls_verify_host) {
        ca_blob = try loadCerts(allocator, arena.allocator());
    }

    var client = try Client.init(allocator, ca_blob, adjusted_opts);
    errdefer client.deinit();

    return .{
        .arena = arena,
        .client = client,
        .ca_blob = ca_blob,
        .opts = adjusted_opts,
    };
}

pub fn deinit(self: *Http) void {
    self.client.deinit();
    c.curl_global_cleanup();
    self.arena.deinit();
}

pub fn poll(self: *Http, timeout_ms: i32) Client.PerformStatus {
    return self.client.tick(timeout_ms) catch |err| {
        log.err(.app, "http poll", .{ .err = err });
        return .normal;
    };
}

pub fn monitorSocket(self: *Http, socket: posix.socket_t) void {
    self.client.extra_socket = socket;
}

pub fn unmonitorSocket(self: *Http) void {
    self.client.extra_socket = null;
}

pub fn newConnection(self: *Http) !Connection {
    return Connection.init(self.ca_blob, &self.opts);
}

pub fn newHeaders(self: *const Http) Headers {
    return Headers.init(self.opts.user_agent);
}

pub const Connection = struct {
    easy: *c.CURL,
    opts: Connection.Opts,

    const Opts = struct {
        proxy_bearer_token: ?[:0]const u8,
        user_agent: [:0]const u8,
    };

    // pointer to opts is not stable, don't hold a reference to it!
    pub fn init(ca_blob_: ?c.curl_blob, opts: *const Http.Opts) !Connection {
        const easy = c.curl_easy_init() orelse return error.FailedToInitializeEasy;
        errdefer _ = c.curl_easy_cleanup(easy);

        // timeouts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(opts.timeout_ms))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(opts.connect_timeout_ms))));

        // redirect behavior
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(opts.max_redirects))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 2)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, "HTTP,HTTPS")); // remove FTP and FTPS from the default

        // proxy
        if (opts.http_proxy) |proxy| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY, proxy.ptr));
        }

        // tls
        if (ca_blob_) |ca_blob| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CAINFO_BLOB, ca_blob));
            if (opts.http_proxy != null) {
                // Note, this can be difference for the proxy and for the main
                // request. Might be something worth exposting as command
                // line arguments at some point.
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_CAINFO_BLOB, ca_blob));
            }
        } else {
            std.debug.assert(opts.tls_verify_host == false);

            // Verify peer checks that the cert is signed by a CA, verify host makes sure the
            // cert contains the server name.
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)));
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)));

            if (opts.http_proxy != null) {
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
            .opts = .{
                .user_agent = opts.user_agent,
                .proxy_bearer_token = opts.proxy_bearer_token,
            },
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
        if (self.opts.proxy_bearer_token) |hdr| {
            try headers.add(hdr);
        }
    }

    pub fn request(self: *const Connection) !u16 {
        const easy = self.easy;

        var header_list = try Headers.init(self.opts.user_agent);
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
    headers: *c.curl_slist,
    cookies: ?[*c]const u8,

    pub fn init(user_agent: [:0]const u8) !Headers {
        const header_list = c.curl_slist_append(null, user_agent);
        if (header_list == null) return error.OutOfMemory;
        return .{ .headers = header_list, .cookies = null };
    }

    pub fn deinit(self: *const Headers) void {
        c.curl_slist_free_all(self.headers);
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

pub const Opts = struct {
    timeout_ms: u31,
    max_host_open: u8,
    max_concurrent: u8,
    connect_timeout_ms: u31,
    max_redirects: u8 = 10,
    tls_verify_host: bool = true,
    http_proxy: ?[:0]const u8 = null,
    proxy_bearer_token: ?[:0]const u8 = null,
    user_agent: [:0]const u8,
};

pub const Method = enum(u8) {
    GET = 0,
    PUT = 1,
    POST = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
};

// TODO: on BSD / Linux, we could just read the PEM file directly.
// This whole rescan + decode is really just needed for MacOS. On Linux
// bundle.rescan does find the .pem file(s) which could be in a few different
// places, so it's still useful, just not efficient.
fn loadCerts(allocator: Allocator, arena: Allocator) !c.curl_blob {
    var bundle: std.crypto.Certificate.Bundle = .{};
    try bundle.rescan(allocator);
    defer bundle.deinit(allocator);

    const bytes = bundle.bytes.items;
    if (bytes.len == 0) {
        log.warn(.app, "No system certificates", .{});
        return .{
            .len = 0,
            .flags = 0,
            .data = bytes.ptr,
        };
    }

    const encoder = std.base64.standard.Encoder;
    var arr: std.ArrayListUnmanaged(u8) = .empty;

    const encoded_size = encoder.calcSize(bytes.len);
    const buffer_size = encoded_size +
        (bundle.map.count() * 75) + // start / end per certificate + extra, just in case
        (encoded_size / 64) // newline per 64 characters
    ;
    try arr.ensureTotalCapacity(arena, buffer_size);
    var writer = arr.writer(arena);

    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        const cert = try std.crypto.Certificate.der.Element.parse(bytes, index.*);

        try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
        var line_writer = LineWriter{ .inner = writer };
        try encoder.encodeWriter(&line_writer, bytes[index.*..cert.slice.end]);
        try writer.writeAll("\n-----END CERTIFICATE-----\n");
    }

    // Final encoding should not be larger than our initial size estimate
    std.debug.assert(buffer_size > arr.items.len);

    return .{
        .len = arr.items.len,
        .data = arr.items.ptr,
        .flags = 0,
    };
}

// Wraps lines @ 64 columns. A PEM is basically a base64 encoded DER (which is
// what Zig has), with lines wrapped at 64 characters and with a basic header
// and footer
const LineWriter = struct {
    col: usize = 0,
    inner: std.ArrayListUnmanaged(u8).Writer,

    pub fn writeAll(self: *LineWriter, data: []const u8) !void {
        var writer = self.inner;

        var col = self.col;
        const len = 64 - col;

        var remain = data;
        if (remain.len > len) {
            col = 0;
            try writer.writeAll(data[0..len]);
            try writer.writeByte('\n');
            remain = data[len..];
        }

        while (remain.len > 64) {
            try writer.writeAll(remain[0..64]);
            try writer.writeByte('\n');
            remain = data[len..];
        }
        try writer.writeAll(remain);
        self.col = col + remain.len;
    }
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

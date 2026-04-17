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
const posix = std.posix;

const Config = @import("../Config.zig");
const libcurl = @import("../sys/libcurl.zig");
const IpFilter = @import("IpFilter.zig");

const log = @import("lightpanda").log;
const assert = @import("lightpanda").assert;

pub const ENABLE_DEBUG = false;

pub const Blob = libcurl.CurlBlob;
pub const WaitFd = libcurl.CurlWaitFd;
pub const readfunc_pause = libcurl.curl_readfunc_pause;
pub const writefunc_error = libcurl.curl_writefunc_error;
pub const WsFrameType = libcurl.WsFrameType;

const Error = libcurl.Error;

pub fn curl_version() [*c]const u8 {
    return libcurl.curl_version();
}

pub const Method = enum(u8) {
    GET = 0,
    PUT = 1,
    POST = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
    PATCH = 6,
    PROPFIND = 7,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    headers: ?*libcurl.CurlSList,

    pub fn init(user_agent: [:0]const u8) !Headers {
        const header_list = libcurl.curl_slist_append(null, user_agent);
        if (header_list == null) {
            return error.OutOfMemory;
        }

        // Always add sec-CH-UA header
        const updated_headers = libcurl.curl_slist_append(header_list, Config.HttpHeaders.sec_ch_ua);
        if (updated_headers == null) {
            return error.OutOfMemory;
        }

        return .{ .headers = updated_headers };
    }

    pub fn deinit(self: *const Headers) void {
        if (self.headers) |hdr| {
            libcurl.curl_slist_free_all(hdr);
        }
    }

    pub fn add(self: *Headers, header: [*c]const u8) !void {
        // Copies the value
        const updated_headers = libcurl.curl_slist_append(self.headers, header);
        if (updated_headers == null) {
            return error.OutOfMemory;
        }

        self.headers = updated_headers;
    }

    pub fn parseHeader(header_str: []const u8) ?Header {
        const colon_pos = std.mem.indexOfScalar(u8, header_str, ':') orelse return null;

        const name = std.mem.trim(u8, header_str[0..colon_pos], " \t");
        const value = std.mem.trim(u8, header_str[colon_pos + 1 ..], " \t");

        return .{ .name = name, .value = value };
    }

    pub fn iterator(self: Headers) HeaderIterator {
        return .{ .curl_slist = .{ .header = self.headers } };
    }
};

// In normal cases, the header iterator comes from the curl linked list.
// But it's also possible to inject a response, via `transfer.fulfill`. In that
// case, the response headers are a list, []const Http.Header.
// This union, is an iterator that exposes the same API for either case.
pub const HeaderIterator = union(enum) {
    curl: CurlHeaderIterator,
    curl_slist: CurlSListIterator,
    list: ListHeaderIterator,

    pub fn next(self: *HeaderIterator) ?Header {
        switch (self.*) {
            inline else => |*it| return it.next(),
        }
    }

    pub fn collect(self: *HeaderIterator, allocator: std.mem.Allocator) !std.ArrayList(Header) {
        var list: std.ArrayList(Header) = .empty;

        while (self.next()) |hdr| {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, hdr.name),
                .value = try allocator.dupe(u8, hdr.value),
            });
        }

        return list;
    }

    const CurlHeaderIterator = struct {
        conn: *const Connection,
        prev: ?*libcurl.CurlHeader = null,

        pub fn next(self: *CurlHeaderIterator) ?Header {
            const h = libcurl.curl_easy_nextheader(self.conn._easy, .header, -1, self.prev) orelse return null;
            self.prev = h;

            const header = h.*;
            return .{
                .name = std.mem.span(header.name),
                .value = std.mem.span(header.value),
            };
        }
    };

    const CurlSListIterator = struct {
        header: [*c]libcurl.CurlSList,

        pub fn next(self: *CurlSListIterator) ?Header {
            const h = self.header orelse return null;
            self.header = h.*.next;
            return Headers.parseHeader(std.mem.span(@as([*:0]const u8, @ptrCast(h.*.data))));
        }
    };

    const ListHeaderIterator = struct {
        index: usize = 0,
        list: []const Header,

        pub fn next(self: *ListHeaderIterator) ?Header {
            const idx = self.index;
            if (idx == self.list.len) {
                return null;
            }
            self.index = idx + 1;
            return self.list[idx];
        }
    };
};

const HeaderValue = struct {
    value: []const u8,
    amount: usize,
};

pub const AuthChallenge = struct {
    const Source = enum { server, proxy };
    const Scheme = enum { basic, digest };

    status: u16,
    source: ?Source,
    scheme: ?Scheme,
    realm: ?[]const u8,

    pub fn parse(status: u16, source: Source, value: []const u8) !AuthChallenge {
        var ac: AuthChallenge = .{
            .status = status,
            .source = source,
            .realm = null,
            .scheme = null,
        };

        const pos = std.mem.indexOfPos(u8, std.mem.trim(u8, value, std.ascii.whitespace[0..]), 0, " ") orelse value.len;
        const _scheme = value[0..pos];
        if (std.ascii.eqlIgnoreCase(_scheme, "basic")) {
            ac.scheme = .basic;
        } else if (std.ascii.eqlIgnoreCase(_scheme, "digest")) {
            ac.scheme = .digest;
        } else {
            return error.UnknownAuthChallengeScheme;
        }

        return ac;
    }
};

pub const ResponseHead = struct {
    pub const MAX_CONTENT_TYPE_LEN = 64;

    status: u16,
    url: [*c]const u8,
    redirect_count: u32,
    _content_type_len: usize = 0,
    _content_type: [MAX_CONTENT_TYPE_LEN]u8 = undefined,
    // this is normally an empty list, but if the response is being injected
    // than it'll be populated. It isn't meant to be used directly, but should
    // be used through the transfer.responseHeaderIterator() which abstracts
    // whether the headers are from a live curl easy handle, or injected.
    _injected_headers: []const Header = &.{},

    pub fn contentType(self: *ResponseHead) ?[]u8 {
        if (self._content_type_len == 0) {
            return null;
        }
        return self._content_type[0..self._content_type_len];
    }
};

/// Opensocket callback: blocks connections to private/internal IP ranges
/// before TCP SYN, regardless of request origin (JS, HTML resources, redirects, etc.).
/// Called by curl after DNS resolution, before the socket is created.
/// Returns CURL_SOCKET_BAD to block; otherwise creates and returns a real socket fd.
/// clientp is a *const IpFilter passed via CURLOPT_OPENSOCKETDATA.
fn opensocketCallback(
    purpose: libcurl.CurlSockType,
    address: *libcurl.CurlSockAddr,
    clientp: ?*anyopaque,
) libcurl.CurlSocket {
    const filter: *const IpFilter = @ptrCast(@alignCast(clientp orelse return libcurl.CURL_SOCKET_BAD));
    if (filter.isBlockedSockaddr(address)) {
        if (address.family == posix.AF.INET or address.family == posix.AF.INET6) {
            const ip = std.net.Address.initPosix(@ptrCast(&address.addr));
            log.warn(.http, "blocked by IP filter", .{ .ip = ip });
        } else {
            log.warn(.http, "blocked by IP filter", .{ .family = address.family });
        }
        return libcurl.CURL_SOCKET_BAD;
    }
    _ = purpose; // purpose is informational; we always open the same socket type
    const fd = posix.socket(
        @intCast(address.family),
        @intCast(address.socktype),
        @intCast(address.protocol),
    ) catch return libcurl.CURL_SOCKET_BAD;
    return fd;
}

pub const Connection = struct {
    _easy: *libcurl.Curl,
    in_use: bool,
    transport: Transport,
    node: std.DoublyLinkedList.Node = .{},

    pub const Transport = union(enum) {
        none, // used for cases that manage their own connection, e.g. telemetry
        http: *@import("../browser/HttpClient.zig").Transfer,
        websocket: *@import("../browser/webapi/net/WebSocket.zig"),
    };

    pub fn init(
        ca_blob: ?libcurl.CurlBlob,
        config: *const Config,
        ip_filter: ?*const IpFilter,
    ) !Connection {
        const easy = libcurl.curl_easy_init() orelse return error.FailedToInitializeEasy;

        var self = Connection{ ._easy = easy, .in_use = false, .transport = .none };
        errdefer self.deinit();

        try self.reset(config, ca_blob, ip_filter);
        return self;
    }

    pub fn deinit(self: *const Connection) void {
        libcurl.curl_easy_cleanup(self._easy);
    }

    pub fn setURL(self: *const Connection, url: [:0]const u8) !void {
        try libcurl.curl_easy_setopt(self._easy, .url, url.ptr);
    }

    pub fn setTimeout(self: *const Connection, timeout_ms: u32) !void {
        try libcurl.curl_easy_setopt(self._easy, .timeout_ms, timeout_ms);
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
        const easy = self._easy;
        const m: [:0]const u8 = switch (method) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
            .PROPFIND => "PROPFIND",
        };
        try libcurl.curl_easy_setopt(easy, .custom_request, m.ptr);
    }

    pub fn setBody(self: *const Connection, body: []const u8) !void {
        const easy = self._easy;
        try libcurl.curl_easy_setopt(easy, .post, true);
        try libcurl.curl_easy_setopt(easy, .post_field_size, body.len);
        try libcurl.curl_easy_setopt(easy, .copy_post_fields, body.ptr);
    }

    pub fn setGetMode(self: *const Connection) !void {
        try libcurl.curl_easy_setopt(self._easy, .http_get, true);
    }

    pub fn setHeaders(self: *const Connection, headers: *Headers) !void {
        try libcurl.curl_easy_setopt(self._easy, .http_header, headers.headers);
    }

    pub fn setCookies(self: *const Connection, cookies: [*c]const u8) !void {
        try libcurl.curl_easy_setopt(self._easy, .cookie, cookies);
    }

    pub fn setPrivate(self: *const Connection, ptr: *anyopaque) !void {
        try libcurl.curl_easy_setopt(self._easy, .private, ptr);
    }

    pub fn setProxyCredentials(self: *const Connection, creds: [:0]const u8) !void {
        try libcurl.curl_easy_setopt(self._easy, .proxy_user_pwd, creds.ptr);
    }

    pub fn setCredentials(self: *const Connection, creds: [:0]const u8) !void {
        try libcurl.curl_easy_setopt(self._easy, .user_pwd, creds.ptr);
    }

    pub fn setConnectOnly(self: *const Connection, connect_only: bool) !void {
        const value: c_long = if (connect_only) 2 else 0;
        try libcurl.curl_easy_setopt(self._easy, .connect_only, value);
    }

    pub fn setWriteCallback(
        self: *Connection,
        comptime data_cb: libcurl.CurlWriteFunction,
    ) !void {
        try libcurl.curl_easy_setopt(self._easy, .write_data, self);
        try libcurl.curl_easy_setopt(self._easy, .write_function, data_cb);
    }

    pub fn setReadCallback(
        self: *Connection,
        comptime data_cb: libcurl.CurlReadFunction,
        upload: bool,
    ) !void {
        try libcurl.curl_easy_setopt(self._easy, .read_data, self);
        try libcurl.curl_easy_setopt(self._easy, .read_function, data_cb);
        if (upload) {
            try libcurl.curl_easy_setopt(self._easy, .upload, true);
        }
    }

    pub fn setHeaderCallback(
        self: *Connection,
        comptime data_cb: libcurl.CurlHeaderFunction,
    ) !void {
        try libcurl.curl_easy_setopt(self._easy, .header_data, self);
        try libcurl.curl_easy_setopt(self._easy, .header_function, data_cb);
    }

    pub fn pause(
        self: *Connection,
        flags: libcurl.CurlPauseFlags,
    ) !void {
        try libcurl.curl_easy_pause(self._easy, flags);
    }

    pub fn reset(
        self: *Connection,
        config: *const Config,
        ca_blob: ?libcurl.CurlBlob,
        ip_filter: ?*const IpFilter,
    ) !void {
        libcurl.curl_easy_reset(self._easy);
        self.transport = .none;

        // timeouts
        try libcurl.curl_easy_setopt(self._easy, .timeout_ms, config.httpTimeout());
        try libcurl.curl_easy_setopt(self._easy, .connect_timeout_ms, config.httpConnectTimeout());

        // compression, don't remove this. CloudFront will send gzip content
        // even if we don't support it, and then it won't be decompressed.
        // empty string means: use whatever's available
        try libcurl.curl_easy_setopt(self._easy, .accept_encoding, "");

        // proxy
        const http_proxy = config.httpProxy();
        if (http_proxy) |proxy| {
            try libcurl.curl_easy_setopt(self._easy, .proxy, proxy.ptr);
        } else {
            try libcurl.curl_easy_setopt(self._easy, .proxy, null);
        }

        // tls
        if (ca_blob) |ca| {
            try libcurl.curl_easy_setopt(self._easy, .ca_info_blob, ca);
            if (http_proxy != null) {
                try libcurl.curl_easy_setopt(self._easy, .proxy_ca_info_blob, ca);
            }
        } else {
            assert(config.tlsVerifyHost() == false, "Http.init tls_verify_host", .{});

            try libcurl.curl_easy_setopt(self._easy, .ssl_verify_host, false);
            try libcurl.curl_easy_setopt(self._easy, .ssl_verify_peer, false);

            if (http_proxy != null) {
                try libcurl.curl_easy_setopt(self._easy, .proxy_ssl_verify_host, false);
                try libcurl.curl_easy_setopt(self._easy, .proxy_ssl_verify_peer, false);
            }
        }

        // debug
        if (comptime ENABLE_DEBUG) {
            try libcurl.curl_easy_setopt(self._easy, .verbose, true);

            // Sometimes the default debug output hides some useful data. You can
            // uncomment the following line (BUT KEEP THE LIVE ABOVE AS-IS), to
            // get more control over the data (specifically, the `CURLINFO_TEXT`
            // can include useful data).

            // try libcurl.curl_easy_setopt(easy, .debug_function, debugCallback);
        }

        // default write callback to prevent libcurl from writing to stdout
        try self.setWriteCallback(discardBody);

        // IP filter: block private/internal network addresses
        if (ip_filter) |filter| {
            try libcurl.curl_easy_setopt(self._easy, .opensocket_function, opensocketCallback);
            try libcurl.curl_easy_setopt(self._easy, .opensocket_data, @constCast(filter));
        }
    }

    fn discardBody(_: [*]const u8, count: usize, len: usize, _: ?*anyopaque) usize {
        return count * len;
    }

    pub fn setProxy(self: *const Connection, proxy: ?[:0]const u8) !void {
        try libcurl.curl_easy_setopt(self._easy, .proxy, if (proxy) |p| p.ptr else null);
    }

    pub fn setFollowLocation(self: *const Connection, follow: bool) !void {
        try libcurl.curl_easy_setopt(self._easy, .follow_location, @as(c_long, if (follow) 2 else 0));
    }

    pub fn setTlsVerify(self: *const Connection, verify: bool, use_proxy: bool) !void {
        try libcurl.curl_easy_setopt(self._easy, .ssl_verify_host, verify);
        try libcurl.curl_easy_setopt(self._easy, .ssl_verify_peer, verify);
        if (use_proxy) {
            try libcurl.curl_easy_setopt(self._easy, .proxy_ssl_verify_host, verify);
            try libcurl.curl_easy_setopt(self._easy, .proxy_ssl_verify_peer, verify);
        }
    }

    pub fn getEffectiveUrl(self: *const Connection) ![*c]const u8 {
        var url: [*c]u8 = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .effective_url, &url);
        return url;
    }

    pub fn getConnectCode(self: *const Connection) !u16 {
        var status: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .connect_code, &status);
        if (status < 0 or status > std.math.maxInt(u16)) {
            return 0;
        }
        return @intCast(status);
    }

    pub fn getResponseCode(self: *const Connection) !u16 {
        var status: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .response_code, &status);
        if (status < 0 or status > std.math.maxInt(u16)) {
            return 0;
        }
        return @intCast(status);
    }

    pub fn getRedirectCount(self: *const Connection) !u32 {
        var count: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .redirect_count, &count);
        return @intCast(count);
    }

    pub fn getConnectHeader(self: *const Connection, name: [:0]const u8, index: usize) ?HeaderValue {
        var hdr: ?*libcurl.CurlHeader = null;
        libcurl.curl_easy_header(self._easy, name, index, .connect, -1, &hdr) catch |err| {
            // ErrorHeader includes OutOfMemory — rare but real errors from curl internals.
            // Logged and returned as null since callers don't expect errors.
            log.err(.http, "get response header", .{
                .name = name,
                .err = err,
            });
            return null;
        };
        const h = hdr orelse return null;
        return .{
            .amount = h.amount,
            .value = std.mem.span(h.value),
        };
    }

    pub fn getResponseHeader(self: *const Connection, name: [:0]const u8, index: usize) ?HeaderValue {
        var hdr: ?*libcurl.CurlHeader = null;
        libcurl.curl_easy_header(self._easy, name, index, .header, -1, &hdr) catch |err| {
            // ErrorHeader includes OutOfMemory — rare but real errors from curl internals.
            // Logged and returned as null since callers don't expect errors.
            log.err(.http, "get response header", .{
                .name = name,
                .err = err,
            });
            return null;
        };
        const h = hdr orelse return null;
        return .{
            .amount = h.amount,
            .value = std.mem.span(h.value),
        };
    }

    // These are headers that may not be send to the users for inteception.
    pub fn secretHeaders(_: *const Connection, headers: *Headers, http_headers: *const Config.HttpHeaders) !void {
        if (http_headers.proxy_bearer_header) |hdr| {
            try headers.add(hdr);
        }
    }

    pub fn request(self: *const Connection, http_headers: *const Config.HttpHeaders) !u16 {
        var header_list = try Headers.init(http_headers.user_agent_header);
        defer header_list.deinit();
        try self.secretHeaders(&header_list, http_headers);
        try self.setHeaders(&header_list);

        try libcurl.curl_easy_perform(self._easy);
        return self.getResponseCode();
    }

    pub fn wsStartFrame(self: *const Connection, frame_type: libcurl.WsFrameType, size: usize) !void {
        try libcurl.curl_ws_start_frame(self._easy, frame_type, @intCast(size));
    }

    pub fn wsMeta(self: *const Connection) ?libcurl.WsFrameMeta {
        return libcurl.curl_ws_meta(self._easy);
    }
};

pub const Handles = struct {
    multi: *libcurl.CurlM,

    pub fn init(config: *const Config) !Handles {
        const multi = libcurl.curl_multi_init() orelse return error.FailedToInitializeMulti;
        errdefer libcurl.curl_multi_cleanup(multi) catch {};

        try libcurl.curl_multi_setopt(multi, .max_host_connections, config.httpMaxHostOpen());

        return .{ .multi = multi };
    }

    pub fn deinit(self: *Handles) void {
        libcurl.curl_multi_cleanup(self.multi) catch {};
    }

    pub fn add(self: *Handles, conn: *const Connection) !void {
        try libcurl.curl_multi_add_handle(self.multi, conn._easy);
    }

    pub fn remove(self: *Handles, conn: *const Connection) !void {
        try libcurl.curl_multi_remove_handle(self.multi, conn._easy);
    }

    pub fn perform(self: *Handles) !c_int {
        var running: c_int = undefined;
        try libcurl.curl_multi_perform(self.multi, &running);
        return running;
    }

    pub fn poll(self: *Handles, extra_fds: []libcurl.CurlWaitFd, timeout_ms: c_int) !void {
        try libcurl.curl_multi_poll(self.multi, extra_fds, timeout_ms, null);
    }

    pub const MultiMessage = struct {
        conn: *Connection,
        err: ?Error,
    };

    pub fn readMessage(self: *Handles) !?MultiMessage {
        var messages_count: c_int = 0;
        const msg = libcurl.curl_multi_info_read(self.multi, &messages_count) orelse return null;
        return switch (msg.data) {
            .done => |err| {
                var private: *anyopaque = undefined;
                try libcurl.curl_easy_getinfo(msg.easy_handle, .private, &private);
                return .{
                    .conn = @ptrCast(@alignCast(private)),
                    .err = err,
                };
            },
            else => unreachable,
        };
    }
};

fn debugCallback(_: *libcurl.Curl, msg_type: libcurl.CurlInfoType, raw: [*c]u8, len: usize, _: *anyopaque) c_int {
    const data = raw[0..len];
    switch (msg_type) {
        .text => std.debug.print("libcurl [text]: {s}\n", .{data}),
        .header_out => std.debug.print("libcurl [req-h]: {s}\n", .{data}),
        .header_in => std.debug.print("libcurl [res-h]: {s}\n", .{data}),
        // .data_in => std.debug.print("libcurl [res-b]: {s}\n", .{data}),
        else => std.debug.print("libcurl ?? {d}\n", .{msg_type}),
    }
    return 0;
}

// ── Unit tests for opensocketCallback ────────────────────────────────────────

fn makeSockAddrV4(ip: [4]u8) libcurl.CurlSockAddr {
    var sa: posix.sockaddr.in = .{
        .port = 0,
        .addr = @bitCast(ip),
    };
    var curl_sa: libcurl.CurlSockAddr = .{
        .family = posix.AF.INET,
        .socktype = posix.SOCK.STREAM,
        .protocol = 0,
        .addrlen = @sizeOf(posix.sockaddr.in),
        .addr = undefined,
    };
    @memcpy(std.mem.asBytes(&curl_sa.addr)[0..@sizeOf(posix.sockaddr.in)], std.mem.asBytes(&sa));
    return curl_sa;
}

const testing = @import("../testing.zig");
test "opensocketCallback: private IPv4 returns CURL_SOCKET_BAD" {
    const lf: testing.LogFilter = .init(&.{.http});
    defer lf.deinit();

    const filter = IpFilter.init(true, null);
    var sa = makeSockAddrV4(.{ 127, 0, 0, 1 });
    const result = opensocketCallback(.ipcxn, &sa, @ptrCast(@constCast(&filter)));
    try testing.expectEqual(libcurl.CURL_SOCKET_BAD, result);
}

test "opensocketCallback: public IPv4 opens a real socket" {
    // 8.8.8.8 — not in any blocked range; callback should create a real socket
    const filter = IpFilter.init(true, null);
    var sa = makeSockAddrV4(.{ 8, 8, 8, 8 });

    const fd = opensocketCallback(.ipcxn, &sa, @ptrCast(@constCast(&filter)));
    defer posix.close(fd);

    // A real fd is always >= 0
    try testing.expect(fd >= 0);
}

test "opensocketCallback: null clientp returns CURL_SOCKET_BAD (fail-closed)" {
    var sa = makeSockAddrV4(.{ 8, 8, 8, 8 });
    const result = opensocketCallback(.ipcxn, &sa, null);
    try testing.expectEqual(libcurl.CURL_SOCKET_BAD, result);
}

test "opensocketCallback: block_private=false allows private IP" {
    // When block_private is false the filter blocks nothing
    const filter = IpFilter.init(false, null);
    var sa = makeSockAddrV4(.{ 127, 0, 0, 1 });
    const fd = opensocketCallback(.ipcxn, &sa, @ptrCast(@constCast(&filter)));
    defer posix.close(fd);

    try testing.expect(fd >= 0);
}

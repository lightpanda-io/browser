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
const sys_net = @import("../sys/net.zig");
const libcurl = @import("../sys/libcurl.zig");
const crypto = @import("../sys/libcrypto.zig");

const IpFilter = @import("IpFilter.zig");
const Certificates = @import("Certificates.zig");

const log = lp.log;
const posix = std.posix;

pub const ENABLE_DEBUG = false;

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

    pub const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn parse(header_str: []const u8) ?Header {
        const colon_pos = std.mem.indexOfScalar(u8, header_str, ':') orelse return null;

        const name = std.mem.trim(u8, header_str[0..colon_pos], " \t");
        const value = std.mem.trim(u8, header_str[colon_pos + 1 ..], " \t");

        return .{ .name = name, .value = value };
    }

    // The header value up to the first ';', trimmed (e.g. "attachment" for a
    // Content-Disposition, "text/html" for a Content-Type).
    pub fn firstValue(self: Header) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.value, ';') orelse self.value.len;
        return std.mem.trim(u8, self.value[0..end], " \t");
    }

    // Iterates the `; key=value` parameters that follow the header's first value.
    pub fn params(self: Header) ParamIterator {
        const start = std.mem.indexOfScalar(u8, self.value, ';') orelse self.value.len;
        return .{ .rest = self.value[start..] };
    }

    // Returns the (unquoted) value of the first non-empty `key=` parameter, if any.
    pub fn param(self: Header, key: []const u8) ?[]const u8 {
        var it = self.params();
        while (it.next()) |p| {
            if (p.value.len > 0 and std.ascii.eqlIgnoreCase(p.key, key)) {
                return p.value;
            }
        }
        return null;
    }

    pub const ParamIterator = struct {
        rest: []const u8,

        pub fn next(self: *ParamIterator) ?Param {
            while (self.rest.len > 0 and self.rest[0] == ';') {
                self.rest = self.rest[1..];
                const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
                const segment = self.rest[0..end];
                self.rest = self.rest[end..];

                const eq = std.mem.indexOfScalar(u8, segment, '=') orelse continue;
                const key = std.mem.trim(u8, segment[0..eq], " \t");
                if (key.len == 0) continue;

                var value = std.mem.trim(u8, segment[eq + 1 ..], " \t");
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }
                return .{ .key = key, .value = value };
            }
            return null;
        }
    };
};

// In normal cases, the header iterator comes from the curl connection.
// But it's also possible to inject a response, via `transfer.fulfill`. In that
// case, the response headers are a list, []const Http.Header.
// This union, is an iterator that exposes the same API for either case.
pub const HeaderIterator = union(enum) {
    curl: CurlHeaderIterator,
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

        const challenge_value = std.mem.trim(u8, value, std.ascii.whitespace[0..]);
        const pos = std.mem.indexOfPos(u8, challenge_value, 0, " ") orelse challenge_value.len;
        const _scheme = challenge_value[0..pos];
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
    // Matches Mime.parse's 255-byte cap
    pub const MAX_CONTENT_TYPE_LEN = 255;

    status: u16,
    url: [*c]const u8,
    redirect_count: u32,
    _content_type_len: usize = 0,
    _content_type: [MAX_CONTENT_TYPE_LEN]u8 = undefined,

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
    clientp: ?*anyopaque,
    _: c_uint,
    addr: [*c]libcurl.CurlSockAddr,
) callconv(.c) libcurl.CurlSocket {
    const address: *libcurl.CurlSockAddr = @ptrCast(addr);
    const filter: *const IpFilter = @ptrCast(@alignCast(clientp orelse return libcurl.CURL_SOCKET_BAD));

    if (filter.isBlockedSockaddr(address)) {
        if (address.family == posix.AF.INET or address.family == posix.AF.INET6) {
            const ip = sys_net.addressFromSockaddr(@ptrCast(@alignCast(&address.addr)));
            log.warn(.http, "blocked by IP filter", .{ .ip = ip });
        } else {
            log.warn(.http, "blocked by IP filter", .{ .family = address.family });
        }
        return libcurl.CURL_SOCKET_BAD;
    }

    const fd = sys_net.socket(
        @intCast(address.family),
        @intCast(address.socktype),
        @intCast(address.protocol),
    ) catch return libcurl.CURL_SOCKET_BAD;
    return fd;
}

pub const Connection = struct {
    _easy: *libcurl.Curl,
    transport: Transport,
    node: std.DoublyLinkedList.Node = .{},

    // The curl_slist accumulated by addHeader/addRawHeader and handed to
    // curl by commitHeaders. Owned here because curl reads it during
    // perform; freed on reset/deinit or by the next clearHeaders.
    _header_list: ?*libcurl.CurlSList = null,

    pub const Transport = union(enum) {
        none, // used for cases that manage their own connection, e.g. telemetry
        http: *@import("HttpClient.zig").Transfer,
        websocket: *@import("../browser/webapi/net/WebSocket.zig"),
    };

    pub fn init(
        certificates: Certificates,
        config: *const Config,
        ip_filter: ?*const IpFilter,
    ) !Connection {
        const easy = libcurl.curl_easy_init() orelse return error.FailedToInitializeEasy;

        var self = Connection{ ._easy = easy, .transport = .none };
        errdefer self.deinit();

        try self.reset(config, certificates, ip_filter);
        return self;
    }

    pub fn deinit(self: *Connection) void {
        self.clearHeaders();
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

    // Appends "name: value" to the connection's pending header list, or
    // "name;" when the value is empty — curl reads "name:" as
    // remove-this-header and the ";" form as send-an-empty-value. curl
    // copies the string, so `allocator` only backs the transient join.
    pub fn addHeader(self: *Connection, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const joined = if (value.len == 0)
            try std.fmt.allocPrintSentinel(allocator, "{s};", .{name}, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ name, value }, 0);
        return self.addRawHeader(joined);
    }

    // `header` is raw curl header syntax, e.g. "Expect:" to suppress a
    // curl-generated header. curl copies the value.
    pub fn addRawHeader(self: *Connection, header: [*c]const u8) !void {
        const updated = libcurl.curl_slist_append(self._header_list, header);
        if (updated == null) {
            return error.OutOfMemory;
        }
        self._header_list = updated;
    }

    pub fn commitHeaders(self: *const Connection) !void {
        try libcurl.curl_easy_setopt(self._easy, .http_header, self._header_list);
    }

    pub fn clearHeaders(self: *Connection) void {
        if (self._header_list) |list| {
            libcurl.curl_slist_free_all(list);
            self._header_list = null;
        }
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
        certificates: Certificates,
        ip_filter: ?*const IpFilter,
    ) !void {
        libcurl.curl_easy_reset(self._easy);
        self.transport = .none;
        self.clearHeaders();

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

        // TLS.
        if (config.tlsVerifyHost()) {
            // Provide certificate store to connection's SSL_CTX.
            try libcurl.curl_easy_setopt(self._easy, .ssl_ctx_function, &(struct {
                fn wrap(
                    _: *libcurl.Curl,
                    raw_ssl_ctx: *anyopaque,
                    raw_x509_store: *anyopaque,
                ) callconv(.c) libcurl.CurlCode {
                    const ssl_ctx: *crypto.SSL_CTX = @ptrCast(raw_ssl_ctx);
                    const store: *crypto.X509_STORE = @ptrCast(raw_x509_store);

                    const result = crypto.SSL_CTX_set1_verify_cert_store(ssl_ctx, store);
                    if (result != 1) {
                        return libcurl.CURLE.ABORTED_BY_CALLBACK;
                    }
                    return libcurl.CURLE.OK;
                }
            }).wrap);
            // Pass our store to CURLOPT_SSL_CTX_FUNCTION.
            try libcurl.curl_easy_setopt(self._easy, .ssl_ctx_data, certificates.store);
        } else {
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

    fn discardBody(_: [*]const u8, count: usize, len: usize, _: ?*anyopaque) callconv(.c) usize {
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

    // -1 when the transfer used no connection.
    pub fn getConnId(self: *const Connection) !c_long {
        var conn_id: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .conn_id, &conn_id);
        return conn_id;
    }

    pub fn isConnReused(self: *const Connection) !bool {
        var opened: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .num_connects, &opened);
        return opened == 0;
    }

    // Total transfer time (name lookup to completion) in microseconds.
    pub fn getTotalTimeMicros(self: *const Connection) !c_long {
        var micros: c_long = undefined;
        try libcurl.curl_easy_getinfo(self._easy, .total_time_t, &micros);
        return micros;
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
    pub fn secretHeaders(self: *Connection, http_headers: *const Config.HttpHeaders) !void {
        if (http_headers.proxy_bearer_header) |hdr| {
            try self.addRawHeader(hdr);
        }
    }

    // Synchronous transfer that adds no request headers; callers that manage
    // their own connection (telemetry) use this leaner path.
    pub fn perform(self: *const Connection) !u16 {
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

    // Thread-safe wake of a poll() in progress on this multi. Used by
    // the Network thread to nudge the worker out of curl_multi_poll
    // when it pushes work onto the worker's inbox.
    pub fn wakeup(self: *Handles) !void {
        try libcurl.curl_multi_wakeup(self.multi);
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

pub const StatusCategory = enum {
    @"2xx",
    @"4xx",
    @"5xx",
    other,
};

pub fn statusCategory(status: u16) StatusCategory {
    return switch (status) {
        200...299 => .@"2xx",
        400...499 => .@"4xx",
        500...599 => .@"5xx",
        else => .other,
    };
}

// https://fetch.spec.whatwg.org/#bad-port
pub fn isBadPort(port: u16) bool {
    return switch (port) {
        1, // tcpmux
        7, // echo
        9, // discard
        11, // systat
        13, // daytime
        15, // netstat
        17, // qotd
        19, // chargen
        20, // ftp-data
        21, // ftp
        22, // ssh
        23, // telnet
        25, // smtp
        37, // time
        42, // name
        43, // nicname
        53, // domain
        69, // tftp
        77, // priv-rjs
        79, // finger
        87, // ttylink
        95, // supdup
        101, // hostriame
        102, // iso-tsap
        103, // gppitnp
        104, // acr-nema
        109, // pop2
        110, // pop3
        111, // sunrpc
        113, // auth
        115, // sftp
        117, // uucp-path
        119, // nntp
        123, // ntp
        135, // loc-srv / epmap
        137, // netbios-ns
        139, // netbios-ssn
        143, // imap2
        161, // snmp
        179, // bgp
        389, // ldap
        427, // afp (alternate)
        465, // smtp (alternate)
        512, // print / exec
        513, // login
        514, // shell
        515, // printer
        526, // tempo
        530, // courier
        531, // chat
        532, // netnews
        540, // uucp
        548, // afp
        554, // rtsp
        556, // remotefs
        563, // nntp+ssl
        587, // smtp (outgoing)
        601, // syslog-conn
        636, // ldap+ssl
        989, // ftps-data
        990, // ftps
        993, // imap+ssl
        995, // pop3+ssl
        1719, // h323gatestat
        1720, // h323hostcall
        1723, // pptp
        2049, // nfs
        3659, // apple-sasl
        4045, // lockd
        4190, // sieve
        5060, // sip
        5061, // sips
        6000, // x11
        6566, // sane-port
        6665, // irc (alternate)
        6666, // irc (alternate)
        6667, // irc (default)
        6668, // irc (alternate)
        6669, // irc (alternate)
        6679, // osaut
        6697, // irc+tls
        10080, // amanda
        => true,
        else => false,
    };
}

// Coarse failure classes for the http_error metric. Anything we don't
// explicitly bucket lands in `other`.
pub const ErrorReason = enum {
    timeout,
    connect,
    tls,
    too_large,
    aborted,
    robots_blocked,
    other,
};

pub fn errorReason(err: anyerror) ErrorReason {
    return switch (err) {
        error.OperationTimedout => .timeout,
        error.CouldntConnect,
        error.CouldntResolveHost,
        error.CouldntResolveProxy,
        error.NoConnectionAvailable,
        => .connect,
        error.SslConnectError,
        error.PeerFailedVerification,
        error.SslCertproblem,
        error.SslCacertBadfile,
        error.SslIssuerError,
        error.SslPinnedpubkeynotmatch,
        error.SslInvalidcertstatus,
        error.UseSslFailed,
        => .tls,
        error.ResponseTooLarge => .too_large,
        error.Abort,
        error.AbortedByCallback,
        error.AbortAuthChallenge,
        error.SyncWaitInterrupted,
        => .aborted,
        error.RobotsBlocked => .robots_blocked,
        else => .other,
    };
}

fn debugCallback(_: *libcurl.Curl, msg_type: libcurl.CurlInfoType, raw: [*c]u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
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

test "isBadPort" {
    for ([_]u16{ 1, 22, 25, 143, 6697, 10080 }) |port| {
        try testing.expect(isBadPort(port));
    }
    for ([_]u16{ 0, 80, 443, 8000, 8080, 9584, 65535 }) |port| {
        try testing.expect(!isBadPort(port));
    }
}

test "Header.parse" {
    {
        const h = Header.parse("Content-Type: text/html; charset=utf-8").?;
        try testing.expectEqualSlices(u8, "Content-Type", h.name);
        try testing.expectEqualSlices(u8, "text/html; charset=utf-8", h.value);
    }
    {
        // no space after the colon
        const h = Header.parse("X-Custom:value").?;
        try testing.expectEqualSlices(u8, "X-Custom", h.name);
        try testing.expectEqualSlices(u8, "value", h.value);
    }
    {
        // name and value are trimmed of spaces and tabs
        const h = Header.parse(" \tAccept \t: \tapplication/json \t").?;
        try testing.expectEqualSlices(u8, "Accept", h.name);
        try testing.expectEqualSlices(u8, "application/json", h.value);
    }
    {
        // only the first colon splits; later colons stay in the value
        const h = Header.parse("Referer: http://example.com:8080/").?;
        try testing.expectEqualSlices(u8, "Referer", h.name);
        try testing.expectEqualSlices(u8, "http://example.com:8080/", h.value);
    }
    {
        // empty value
        const h = Header.parse("X-Empty:").?;
        try testing.expectEqualSlices(u8, "X-Empty", h.name);
        try testing.expectEqualSlices(u8, "", h.value);
    }

    {
        // Splitting is all `parse` does; a name that isn't an HTTP token still
        // parses. Callers validate what comes back.
        const h = Header.parse("Foo Bar: value").?;
        try testing.expectEqualSlices(u8, "Foo Bar", h.name);
        try testing.expectEqualSlices(u8, "value", h.value);
    }

    // no colon, no header
    try testing.expect(Header.parse("not-a-header") == null);
    try testing.expect(Header.parse("") == null);
}

test "Header.firstValue" {
    try testing.expectEqualSlices(u8, "attachment", (Header{ .name = "Content-Disposition", .value = "attachment" }).firstValue());
    // firstValue trims but preserves case (callers compare case-insensitively).
    try testing.expectEqualSlices(u8, "ATTACHMENT", (Header{ .name = "Content-Disposition", .value = "  ATTACHMENT ; filename=a.csv" }).firstValue());
    try testing.expectEqualSlices(u8, "text/html", (Header{ .name = "Content-Type", .value = "text/html; charset=utf-8" }).firstValue());
    try testing.expectEqualSlices(u8, "", (Header{ .name = "X", .value = "" }).firstValue());
}

test "Header.param" {
    const h: Header = .{ .name = "Content-Disposition", .value = "attachment; filename=\"r e.csv\"; filename*=UTF-8''e.txt" };
    try testing.expectEqualSlices(u8, "r e.csv", h.param("filename").?);
    try testing.expectEqualSlices(u8, "r e.csv", h.param("FILENAME").?);
    try testing.expectEqualSlices(u8, "UTF-8''e.txt", h.param("filename*").?);
    try testing.expect(h.param("missing") == null);
    // A bare value with no parameters has nothing to return.
    try testing.expect((Header{ .name = "Content-Disposition", .value = "attachment" }).param("filename") == null);
    // Empty values are skipped.
    try testing.expect((Header{ .name = "Content-Disposition", .value = "attachment; filename=\"\"" }).param("filename") == null);
}

test "opensocketCallback: private IPv4 returns CURL_SOCKET_BAD" {
    testing.silenceLog(&.{.http});

    const filter = IpFilter.init(true, null);
    var sa = makeSockAddrV4(.{ 127, 0, 0, 1 });
    const result = opensocketCallback(@ptrCast(@constCast(&filter)), @intFromEnum(libcurl.CurlSockType.ipcxn), &sa);
    try testing.expectEqual(libcurl.CURL_SOCKET_BAD, result);
}

test "opensocketCallback: public IPv4 opens a real socket" {
    // 8.8.8.8 — not in any blocked range; callback should create a real socket
    const filter = IpFilter.init(true, null);
    var sa = makeSockAddrV4(.{ 8, 8, 8, 8 });

    const fd = opensocketCallback(@ptrCast(@constCast(&filter)), @intFromEnum(libcurl.CurlSockType.ipcxn), &sa);
    defer _ = std.c.close(fd);

    // A real fd is always >= 0
    try testing.expect(fd >= 0);
}

test "opensocketCallback: null clientp returns CURL_SOCKET_BAD (fail-closed)" {
    var sa = makeSockAddrV4(.{ 8, 8, 8, 8 });
    const result = opensocketCallback(null, @intFromEnum(libcurl.CurlSockType.ipcxn), &sa);
    try testing.expectEqual(libcurl.CURL_SOCKET_BAD, result);
}

test "opensocketCallback: block_private=false allows private IP" {
    // When block_private is false the filter blocks nothing
    const filter = IpFilter.init(false, null);
    var sa = makeSockAddrV4(.{ 127, 0, 0, 1 });
    const fd = opensocketCallback(@ptrCast(@constCast(&filter)), @intFromEnum(libcurl.CurlSockType.ipcxn), &sa);
    defer _ = std.c.close(fd);

    try testing.expect(fd >= 0);
}

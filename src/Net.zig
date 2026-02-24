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
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const c = @cImport({
    @cInclude("curl/curl.h");
});

const log = @import("log.zig");
const Config = @import("Config.zig");
const assert = @import("lightpanda").assert;

pub const ENABLE_DEBUG = false;
const IS_DEBUG = builtin.mode == .Debug;

pub const Error = error{
    UnsupportedProtocol,
    FailedInit,
    UrlMalformat,
    NotBuiltIn,
    CouldntResolveProxy,
    CouldntResolveHost,
    CouldntConnect,
    WeirdServerReply,
    RemoteAccessDenied,
    FtpAcceptFailed,
    FtpWeirdPassReply,
    FtpAcceptTimeout,
    FtpWeirdPasvReply,
    FtpWeird227Format,
    FtpCantGetHost,
    Http2,
    FtpCouldntSetType,
    PartialFile,
    FtpCouldntRetrFile,
    QuoteError,
    HttpReturnedError,
    WriteError,
    UploadFailed,
    ReadError,
    OutOfMemory,
    OperationTimedout,
    FtpPortFailed,
    FtpCouldntUseRest,
    RangeError,
    SslConnectError,
    BadDownloadResume,
    FileCouldntReadFile,
    LdapCannotBind,
    LdapSearchFailed,
    AbortedByCallback,
    BadFunctionArgument,
    InterfaceFailed,
    TooManyRedirects,
    UnknownOption,
    SetoptOptionSyntax,
    GotNothing,
    SslEngineNotfound,
    SslEngineSetfailed,
    SendError,
    RecvError,
    SslCertproblem,
    SslCipher,
    PeerFailedVerification,
    BadContentEncoding,
    FilesizeExceeded,
    UseSslFailed,
    SendFailRewind,
    SslEngineInitfailed,
    LoginDenied,
    TftpNotfound,
    TftpPerm,
    RemoteDiskFull,
    TftpIllegal,
    TftpUnknownid,
    RemoteFileExists,
    TftpNosuchuser,
    SslCacertBadfile,
    RemoteFileNotFound,
    Ssh,
    SslShutdownFailed,
    Again,
    SslCrlBadfile,
    SslIssuerError,
    FtpPretFailed,
    RtspCseqError,
    RtspSessionError,
    FtpBadFileList,
    ChunkFailed,
    NoConnectionAvailable,
    SslPinnedpubkeynotmatch,
    SslInvalidcertstatus,
    Http2Stream,
    RecursiveApiCall,
    AuthError,
    Http3,
    QuicConnectError,
    Proxy,
    SslClientcert,
    UnrecoverablePoll,
    TooLarge,
    Unknown,
};

pub fn fromCode(code: c.CURLcode) Error {
    if (comptime IS_DEBUG) {
        std.debug.assert(code != c.CURLE_OK);
    }

    return switch (code) {
        c.CURLE_UNSUPPORTED_PROTOCOL => Error.UnsupportedProtocol,
        c.CURLE_FAILED_INIT => Error.FailedInit,
        c.CURLE_URL_MALFORMAT => Error.UrlMalformat,
        c.CURLE_NOT_BUILT_IN => Error.NotBuiltIn,
        c.CURLE_COULDNT_RESOLVE_PROXY => Error.CouldntResolveProxy,
        c.CURLE_COULDNT_RESOLVE_HOST => Error.CouldntResolveHost,
        c.CURLE_COULDNT_CONNECT => Error.CouldntConnect,
        c.CURLE_WEIRD_SERVER_REPLY => Error.WeirdServerReply,
        c.CURLE_REMOTE_ACCESS_DENIED => Error.RemoteAccessDenied,
        c.CURLE_FTP_ACCEPT_FAILED => Error.FtpAcceptFailed,
        c.CURLE_FTP_WEIRD_PASS_REPLY => Error.FtpWeirdPassReply,
        c.CURLE_FTP_ACCEPT_TIMEOUT => Error.FtpAcceptTimeout,
        c.CURLE_FTP_WEIRD_PASV_REPLY => Error.FtpWeirdPasvReply,
        c.CURLE_FTP_WEIRD_227_FORMAT => Error.FtpWeird227Format,
        c.CURLE_FTP_CANT_GET_HOST => Error.FtpCantGetHost,
        c.CURLE_HTTP2 => Error.Http2,
        c.CURLE_FTP_COULDNT_SET_TYPE => Error.FtpCouldntSetType,
        c.CURLE_PARTIAL_FILE => Error.PartialFile,
        c.CURLE_FTP_COULDNT_RETR_FILE => Error.FtpCouldntRetrFile,
        c.CURLE_QUOTE_ERROR => Error.QuoteError,
        c.CURLE_HTTP_RETURNED_ERROR => Error.HttpReturnedError,
        c.CURLE_WRITE_ERROR => Error.WriteError,
        c.CURLE_UPLOAD_FAILED => Error.UploadFailed,
        c.CURLE_READ_ERROR => Error.ReadError,
        c.CURLE_OUT_OF_MEMORY => Error.OutOfMemory,
        c.CURLE_OPERATION_TIMEDOUT => Error.OperationTimedout,
        c.CURLE_FTP_PORT_FAILED => Error.FtpPortFailed,
        c.CURLE_FTP_COULDNT_USE_REST => Error.FtpCouldntUseRest,
        c.CURLE_RANGE_ERROR => Error.RangeError,
        c.CURLE_SSL_CONNECT_ERROR => Error.SslConnectError,
        c.CURLE_BAD_DOWNLOAD_RESUME => Error.BadDownloadResume,
        c.CURLE_FILE_COULDNT_READ_FILE => Error.FileCouldntReadFile,
        c.CURLE_LDAP_CANNOT_BIND => Error.LdapCannotBind,
        c.CURLE_LDAP_SEARCH_FAILED => Error.LdapSearchFailed,
        c.CURLE_ABORTED_BY_CALLBACK => Error.AbortedByCallback,
        c.CURLE_BAD_FUNCTION_ARGUMENT => Error.BadFunctionArgument,
        c.CURLE_INTERFACE_FAILED => Error.InterfaceFailed,
        c.CURLE_TOO_MANY_REDIRECTS => Error.TooManyRedirects,
        c.CURLE_UNKNOWN_OPTION => Error.UnknownOption,
        c.CURLE_SETOPT_OPTION_SYNTAX => Error.SetoptOptionSyntax,
        c.CURLE_GOT_NOTHING => Error.GotNothing,
        c.CURLE_SSL_ENGINE_NOTFOUND => Error.SslEngineNotfound,
        c.CURLE_SSL_ENGINE_SETFAILED => Error.SslEngineSetfailed,
        c.CURLE_SEND_ERROR => Error.SendError,
        c.CURLE_RECV_ERROR => Error.RecvError,
        c.CURLE_SSL_CERTPROBLEM => Error.SslCertproblem,
        c.CURLE_SSL_CIPHER => Error.SslCipher,
        c.CURLE_PEER_FAILED_VERIFICATION => Error.PeerFailedVerification,
        c.CURLE_BAD_CONTENT_ENCODING => Error.BadContentEncoding,
        c.CURLE_FILESIZE_EXCEEDED => Error.FilesizeExceeded,
        c.CURLE_USE_SSL_FAILED => Error.UseSslFailed,
        c.CURLE_SEND_FAIL_REWIND => Error.SendFailRewind,
        c.CURLE_SSL_ENGINE_INITFAILED => Error.SslEngineInitfailed,
        c.CURLE_LOGIN_DENIED => Error.LoginDenied,
        c.CURLE_TFTP_NOTFOUND => Error.TftpNotfound,
        c.CURLE_TFTP_PERM => Error.TftpPerm,
        c.CURLE_REMOTE_DISK_FULL => Error.RemoteDiskFull,
        c.CURLE_TFTP_ILLEGAL => Error.TftpIllegal,
        c.CURLE_TFTP_UNKNOWNID => Error.TftpUnknownid,
        c.CURLE_REMOTE_FILE_EXISTS => Error.RemoteFileExists,
        c.CURLE_TFTP_NOSUCHUSER => Error.TftpNosuchuser,
        c.CURLE_SSL_CACERT_BADFILE => Error.SslCacertBadfile,
        c.CURLE_REMOTE_FILE_NOT_FOUND => Error.RemoteFileNotFound,
        c.CURLE_SSH => Error.Ssh,
        c.CURLE_SSL_SHUTDOWN_FAILED => Error.SslShutdownFailed,
        c.CURLE_AGAIN => Error.Again,
        c.CURLE_SSL_CRL_BADFILE => Error.SslCrlBadfile,
        c.CURLE_SSL_ISSUER_ERROR => Error.SslIssuerError,
        c.CURLE_FTP_PRET_FAILED => Error.FtpPretFailed,
        c.CURLE_RTSP_CSEQ_ERROR => Error.RtspCseqError,
        c.CURLE_RTSP_SESSION_ERROR => Error.RtspSessionError,
        c.CURLE_FTP_BAD_FILE_LIST => Error.FtpBadFileList,
        c.CURLE_CHUNK_FAILED => Error.ChunkFailed,
        c.CURLE_NO_CONNECTION_AVAILABLE => Error.NoConnectionAvailable,
        c.CURLE_SSL_PINNEDPUBKEYNOTMATCH => Error.SslPinnedpubkeynotmatch,
        c.CURLE_SSL_INVALIDCERTSTATUS => Error.SslInvalidcertstatus,
        c.CURLE_HTTP2_STREAM => Error.Http2Stream,
        c.CURLE_RECURSIVE_API_CALL => Error.RecursiveApiCall,
        c.CURLE_AUTH_ERROR => Error.AuthError,
        c.CURLE_HTTP3 => Error.Http3,
        c.CURLE_QUIC_CONNECT_ERROR => Error.QuicConnectError,
        c.CURLE_PROXY => Error.Proxy,
        c.CURLE_SSL_CLIENTCERT => Error.SslClientcert,
        c.CURLE_UNRECOVERABLE_POLL => Error.UnrecoverablePoll,
        c.CURLE_TOO_LARGE => Error.TooLarge,
        else => Error.Unknown,
    };
}

pub const ErrorMulti = error{
    BadHandle,
    BadEasyHandle,
    OutOfMemory,
    InternalError,
    BadSocket,
    UnknownOption,
    AddedAlready,
    RecursiveApiCall,
    WakeupFailure,
    BadFunctionArgument,
    AbortedByCallback,
    UnrecoverablePoll,
    Unknown,
};

fn fromMCode(code: c.CURLMcode) ErrorMulti {
    if (comptime IS_DEBUG) {
        std.debug.assert(code != c.CURLM_OK);
    }

    return switch (code) {
        c.CURLM_BAD_HANDLE => ErrorMulti.BadHandle,
        c.CURLM_BAD_EASY_HANDLE => ErrorMulti.BadEasyHandle,
        c.CURLM_OUT_OF_MEMORY => ErrorMulti.OutOfMemory,
        c.CURLM_INTERNAL_ERROR => ErrorMulti.InternalError,
        c.CURLM_BAD_SOCKET => ErrorMulti.BadSocket,
        c.CURLM_UNKNOWN_OPTION => ErrorMulti.UnknownOption,
        c.CURLM_ADDED_ALREADY => ErrorMulti.AddedAlready,
        c.CURLM_RECURSIVE_API_CALL => ErrorMulti.RecursiveApiCall,
        c.CURLM_WAKEUP_FAILURE => ErrorMulti.WakeupFailure,
        c.CURLM_BAD_FUNCTION_ARGUMENT => ErrorMulti.BadFunctionArgument,
        c.CURLM_ABORTED_BY_CALLBACK => ErrorMulti.AbortedByCallback,
        c.CURLM_UNRECOVERABLE_POLL => ErrorMulti.UnrecoverablePoll,
        else => ErrorMulti.Unknown,
    };
}

pub fn errorCheck(code: c.CURLcode) Error!void {
    if (code == c.CURLE_OK) {
        return;
    }
    return fromCode(code);
}

pub fn errorMCheck(code: c.CURLMcode) ErrorMulti!void {
    if (code == c.CURLM_OK) {
        return;
    }
    if (code == c.CURLM_CALL_MULTI_PERFORM) {
        return;
    }
    return fromMCode(code);
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

// In normal cases, the header iterator comes from the curl linked list.
// But it's also possible to inject a response, via `transfer.fulfill`. In that
// case, the resposne headers are a list, []const Http.Header.
// This union, is an iterator that exposes the same API for either case.
pub const HeaderIterator = union(enum) {
    curl: CurlHeaderIterator,
    list: ListHeaderIterator,

    pub fn next(self: *HeaderIterator) ?Header {
        switch (self.*) {
            inline else => |*it| return it.next(),
        }
    }

    const CurlHeaderIterator = struct {
        conn: *const Connection,
        prev: ?*c.curl_header = null,

        pub fn next(self: *CurlHeaderIterator) ?Header {
            const h = c.curl_easy_nextheader(self.conn.easy, c.CURLH_HEADER, -1, self.prev) orelse return null;
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

pub const HeaderValue = struct {
    value: []const u8,
    amount: usize,
};

pub const AuthChallenge = struct {
    status: u16,
    source: enum { server, proxy },
    scheme: enum { basic, digest },
    realm: []const u8,

    pub fn parse(status: u16, header: []const u8) !AuthChallenge {
        var ac: AuthChallenge = .{
            .status = status,
            .source = undefined,
            .realm = "TODO", // TODO parser and set realm
            .scheme = undefined,
        };

        const sep = std.mem.indexOfPos(u8, header, 0, ": ") orelse return error.InvalidHeader;
        const hname = header[0..sep];
        const hvalue = header[sep + 2 ..];

        if (std.ascii.eqlIgnoreCase("WWW-Authenticate", hname)) {
            ac.source = .server;
        } else if (std.ascii.eqlIgnoreCase("Proxy-Authenticate", hname)) {
            ac.source = .proxy;
        } else {
            return error.InvalidAuthChallenge;
        }

        const pos = std.mem.indexOfPos(u8, std.mem.trim(u8, hvalue, std.ascii.whitespace[0..]), 0, " ") orelse hvalue.len;
        const _scheme = hvalue[0..pos];
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

pub fn globalInit() Error!void {
    try errorCheck(c.curl_global_init(c.CURL_GLOBAL_SSL));
}

pub fn globalDeinit() void {
    c.curl_global_cleanup();
}

pub const Connection = struct {
    easy: *c.CURL,

    pub fn init(
        ca_blob_: ?c.curl_blob,
        config: *const Config,
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
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_CAINFO_BLOB, ca_blob));
            }
        } else {
            assert(config.tlsVerifyHost() == false, "Http.init tls_verify_host", .{});

            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)));
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)));

            if (http_proxy != null) {
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_SSL_VERIFYHOST, @as(c_long, 0)));
                try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXY_SSL_VERIFYPEER, @as(c_long, 0)));
            }
        }

        // compression, don't remove this. CloudFront will send gzip content
        // even if we don't support it, and then it won't be decompressed.
        // empty string means: use whatever's available
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_ACCEPT_ENCODING, ""));

        // debug
        if (comptime ENABLE_DEBUG) {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1)));

            // Sometimes the default debug output hides some useful data. You can
            // uncomment the following line (BUT KEEP THE LIVE ABOVE AS-IS), to
            // get more control over the data (specifically, the `CURLINFO_TEXT`
            // can include useful data).

            // try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_DEBUGFUNCTION, debugCallback));
        }

        return .{
            .easy = easy,
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
            .PROPFIND => "PROPFIND",
        };
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, m.ptr));
    }

    pub fn setBody(self: *const Connection, body: []const u8) !void {
        const easy = self.easy;
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPPOST, @as(c_long, 1)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_COPYPOSTFIELDS, body.ptr));
    }

    pub fn setGetMode(self: *const Connection) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_HTTPGET, @as(c_long, 1)));
    }

    pub fn setHeaders(self: *const Connection, headers: *Headers) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_HTTPHEADER, headers.headers));
    }

    pub fn setCookies(self: *const Connection, cookies: [*c]const u8) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_COOKIE, cookies));
    }

    pub fn setPrivate(self: *const Connection, ptr: *anyopaque) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_PRIVATE, ptr));
    }

    pub fn setProxyCredentials(self: *const Connection, creds: [:0]const u8) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_PROXYUSERPWD, creds.ptr));
    }

    pub fn setCallbacks(
        self: *const Connection,
        header_cb: *const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize,
        data_cb: *const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) isize,
    ) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_HEADERDATA, self.easy));
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_HEADERFUNCTION, header_cb));
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_WRITEDATA, self.easy));
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_WRITEFUNCTION, data_cb));
    }

    pub fn setProxy(self: *const Connection, proxy: ?[*:0]const u8) !void {
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_PROXY, proxy));
    }

    pub fn setTlsVerify(self: *const Connection, verify: bool, use_proxy: bool) !void {
        const host_val: c_long = if (verify) 2 else 0;
        const peer_val: c_long = if (verify) 1 else 0;
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_SSL_VERIFYHOST, host_val));
        try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_SSL_VERIFYPEER, peer_val));
        if (use_proxy) {
            try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_PROXY_SSL_VERIFYHOST, host_val));
            try errorCheck(c.curl_easy_setopt(self.easy, c.CURLOPT_PROXY_SSL_VERIFYPEER, peer_val));
        }
    }

    pub fn getEffectiveUrl(self: *const Connection) ![*c]const u8 {
        var url: [*c]u8 = undefined;
        try errorCheck(c.curl_easy_getinfo(self.easy, c.CURLINFO_EFFECTIVE_URL, &url));
        return url;
    }

    pub fn getResponseCode(self: *const Connection) !u16 {
        var status: c_long = undefined;
        try errorCheck(c.curl_easy_getinfo(self.easy, c.CURLINFO_RESPONSE_CODE, &status));
        if (status < 0 or status > std.math.maxInt(u16)) {
            return 0;
        }
        return @intCast(status);
    }

    pub fn getRedirectCount(self: *const Connection) !u32 {
        var count: c_long = undefined;
        try errorCheck(c.curl_easy_getinfo(self.easy, c.CURLINFO_REDIRECT_COUNT, &count));
        return @intCast(count);
    }

    pub fn getResponseHeader(self: *const Connection, name: [:0]const u8, index: usize) ?HeaderValue {
        var hdr: [*c]c.curl_header = null;
        const result = c.curl_easy_header(self.easy, name, index, c.CURLH_HEADER, -1, &hdr);
        if (result == c.CURLE_OK) {
            return .{
                .amount = hdr.*.amount,
                .value = std.mem.span(hdr.*.value),
            };
        }

        if (result == c.CURLE_FAILED_INIT) {
            // seems to be what it returns if the header isn't found
            return null;
        }
        log.err(.http, "get response header", .{
            .name = name,
            .err = fromCode(result),
        });
        return null;
    }

    pub fn getPrivate(self: *const Connection) !*anyopaque {
        var private: *anyopaque = undefined;
        try errorCheck(c.curl_easy_getinfo(self.easy, c.CURLINFO_PRIVATE, &private));
        return private;
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

        // Add cookies.
        if (header_list.cookies) |cookies| {
            try self.setCookies(cookies);
        }

        try errorCheck(c.curl_easy_perform(self.easy));
        return self.getResponseCode();
    }
};

// TODO: on BSD / Linux, we could just read the PEM file directly.
// This whole rescan + decode is really just needed for MacOS. On Linux
// bundle.rescan does find the .pem file(s) which could be in a few different
// places, so it's still useful, just not efficient.
pub fn loadCerts(allocator: Allocator) !c.curl_blob {
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
    var arr: std.ArrayList(u8) = .empty;

    const encoded_size = encoder.calcSize(bytes.len);
    const buffer_size = encoded_size +
        (bundle.map.count() * 75) + // start / end per certificate + extra, just in case
        (encoded_size / 64) // newline per 64 characters
    ;
    try arr.ensureTotalCapacity(allocator, buffer_size);
    errdefer arr.deinit(allocator);
    var writer = arr.writer(allocator);

    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        const cert = try std.crypto.Certificate.der.Element.parse(bytes, index.*);

        try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
        var line_writer = LineWriter{ .inner = writer };
        try encoder.encodeWriter(&line_writer, bytes[index.*..cert.slice.end]);
        try writer.writeAll("\n-----END CERTIFICATE-----\n");
    }

    // Final encoding should not be larger than our initial size estimate
    assert(buffer_size > arr.items.len, "Http loadCerts", .{ .estimate = buffer_size, .len = arr.items.len });

    // Allocate exactly the size needed and copy the data
    const result = try allocator.dupe(u8, arr.items);
    // Free the original oversized allocation
    arr.deinit(allocator);

    return .{
        .len = result.len,
        .data = result.ptr,
        .flags = 0,
    };
}

// Wraps lines @ 64 columns. A PEM is basically a base64 encoded DER (which is
// what Zig has), with lines wrapped at 64 characters and with a basic header
// and footer
const LineWriter = struct {
    col: usize = 0,
    inner: std.ArrayList(u8).Writer,

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

fn debugCallback(_: *c.CURL, msg_type: c.curl_infotype, raw: [*c]u8, len: usize, _: *anyopaque) callconv(.c) void {
    const data = raw[0..len];
    switch (msg_type) {
        c.CURLINFO_TEXT => std.debug.print("libcurl [text]: {s}\n", .{data}),
        c.CURLINFO_HEADER_OUT => std.debug.print("libcurl [req-h]: {s}\n", .{data}),
        c.CURLINFO_HEADER_IN => std.debug.print("libcurl [res-h]: {s}\n", .{data}),
        // c.CURLINFO_DATA_IN => std.debug.print("libcurl [res-b]: {s}\n", .{data}),
        else => std.debug.print("libcurl ?? {d}\n", .{msg_type}),
    }
}

// Zig is in a weird backend transition right now. Need to determine if
// SIMD is even available.
const backend_supports_vectors = switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

// Websocket messages from client->server are masked using a 4 byte XOR mask
pub fn mask(m: []const u8, payload: []u8) void {
    var data = payload;

    if (!comptime backend_supports_vectors) return simpleMask(m, data);

    const vector_size = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
    if (data.len >= vector_size) {
        const mask_vector = std.simd.repeat(vector_size, @as(@Vector(4, u8), m[0..4].*));
        while (data.len >= vector_size) {
            const slice = data[0..vector_size];
            const masked_data_slice: @Vector(vector_size, u8) = slice.*;
            slice.* = masked_data_slice ^ mask_vector;
            data = data[vector_size..];
        }
    }
    simpleMask(m, data);
}

// Used when SIMD isn't available, or for any remaining part of the message
// which is too small to effectively use SIMD.
fn simpleMask(m: []const u8, payload: []u8) void {
    for (payload, 0..) |b, i| {
        payload[i] = b ^ m[i & 3];
    }
}

const Fragments = struct {
    type: Message.Type,
    message: std.ArrayList(u8),
};

pub const Message = struct {
    type: Type,
    data: []const u8,
    cleanup_fragment: bool,

    pub const Type = enum {
        text,
        binary,
        close,
        ping,
        pong,
    };
};

// These are the only websocket types that we're currently sending
pub const OpCode = enum(u8) {
    text = 128 | 1,
    close = 128 | 8,
    pong = 128 | 10,
};

pub fn fillWebsocketHeader(buf: std.ArrayList(u8)) []const u8 {
    // can't use buf[0..10] here, because the header length
    // is variable. If it's just 2 bytes, for example, we need the
    // framed message to be:
    //     h1, h2, data
    // If we use buf[0..10], we'd get:
    //    h1, h2, 0, 0, 0, 0, 0, 0, 0, 0, data

    var header_buf: [10]u8 = undefined;

    // -10 because we reserved 10 bytes for the header above
    const header = websocketHeader(&header_buf, .text, buf.items.len - 10);
    const start = 10 - header.len;

    const message = buf.items;
    @memcpy(message[start..10], header);
    return message[start..];
}

// makes the assumption that our caller reserved the first
// 10 bytes for the header
pub fn websocketHeader(buf: []u8, op_code: OpCode, payload_len: usize) []const u8 {
    assert(buf.len == 10, "Websocket.Header", .{ .len = buf.len });

    const len = payload_len;
    buf[0] = 128 | @intFromEnum(op_code); // fin | opcode

    if (len <= 125) {
        buf[1] = @intCast(len);
        return buf[0..2];
    }

    if (len < 65536) {
        buf[1] = 126;
        buf[2] = @intCast((len >> 8) & 0xFF);
        buf[3] = @intCast(len & 0xFF);
        return buf[0..4];
    }

    buf[1] = 127;
    buf[2] = 0;
    buf[3] = 0;
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = @intCast((len >> 24) & 0xFF);
    buf[7] = @intCast((len >> 16) & 0xFF);
    buf[8] = @intCast((len >> 8) & 0xFF);
    buf[9] = @intCast(len & 0xFF);
    return buf[0..10];
}

fn growBuffer(allocator: Allocator, buf: []u8, required_capacity: usize) ![]u8 {
    // from std.ArrayList
    var new_capacity = buf.len;
    while (true) {
        new_capacity +|= new_capacity / 2 + 8;
        if (new_capacity >= required_capacity) break;
    }

    log.debug(.app, "CDP buffer growth", .{ .from = buf.len, .to = new_capacity });

    if (allocator.resize(buf, new_capacity)) {
        return buf.ptr[0..new_capacity];
    }
    const new_buffer = try allocator.alloc(u8, new_capacity);
    @memcpy(new_buffer[0..buf.len], buf);
    allocator.free(buf);
    return new_buffer;
}

// WebSocket message reader. Given websocket message, acts as an iterator that
// can return zero or more Messages. When next returns null, any incomplete
// message will remain in reader.data
pub fn Reader(comptime EXPECT_MASK: bool) type {
    return struct {
        allocator: Allocator,

        // position in buf of the start of the next message
        pos: usize = 0,

        // position in buf up until where we have valid data
        // (any new reads must be placed after this)
        len: usize = 0,

        // we add 140 to allow 1 control message (ping/pong/close) to be
        // fragmented into a normal message.
        buf: []u8,

        fragments: ?Fragments = null,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            const buf = try allocator.alloc(u8, 16 * 1024);
            return .{
                .buf = buf,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cleanup();
            self.allocator.free(self.buf);
        }

        pub fn cleanup(self: *Self) void {
            if (self.fragments) |*f| {
                f.message.deinit(self.allocator);
                self.fragments = null;
            }
        }

        pub fn readBuf(self: *Self) []u8 {
            // We might have read a partial http or websocket message.
            // Subsequent reads must read from where we left off.
            return self.buf[self.len..];
        }

        pub fn next(self: *Self) !?Message {
            LOOP: while (true) {
                var buf = self.buf[self.pos..self.len];

                const length_of_len, const message_len = extractLengths(buf) orelse {
                    // we don't have enough bytes
                    return null;
                };

                const byte1 = buf[0];

                if (byte1 & 112 != 0) {
                    return error.ReservedFlags;
                }

                if (comptime EXPECT_MASK) {
                    if (buf[1] & 128 != 128) {
                        // client -> server messages _must_ be masked
                        return error.NotMasked;
                    }
                } else if (buf[1] & 128 != 0) {
                    // server -> client are never masked
                    return error.Masked;
                }

                var is_control = false;
                var is_continuation = false;
                var message_type: Message.Type = undefined;
                switch (byte1 & 15) {
                    0 => is_continuation = true,
                    1 => message_type = .text,
                    2 => message_type = .binary,
                    8 => {
                        is_control = true;
                        message_type = .close;
                    },
                    9 => {
                        is_control = true;
                        message_type = .ping;
                    },
                    10 => {
                        is_control = true;
                        message_type = .pong;
                    },
                    else => return error.InvalidMessageType,
                }

                if (is_control) {
                    if (message_len > 125) {
                        return error.ControlTooLarge;
                    }
                } else if (message_len > Config.CDP_MAX_MESSAGE_SIZE) {
                    return error.TooLarge;
                } else if (message_len > self.buf.len) {
                    const len = self.buf.len;
                    self.buf = try growBuffer(self.allocator, self.buf, message_len);
                    buf = self.buf[0..len];
                    // we need more data
                    return null;
                } else if (buf.len < message_len) {
                    // we need more data
                    return null;
                }

                // prefix + length_of_len + mask
                const header_len = 2 + length_of_len + if (comptime EXPECT_MASK) 4 else 0;

                const payload = buf[header_len..message_len];
                if (comptime EXPECT_MASK) {
                    mask(buf[header_len - 4 .. header_len], payload);
                }

                // whatever happens after this, we know where the next message starts
                self.pos += message_len;

                const fin = byte1 & 128 == 128;

                if (is_continuation) {
                    const fragments = &(self.fragments orelse return error.InvalidContinuation);
                    if (fragments.message.items.len + message_len > Config.CDP_MAX_MESSAGE_SIZE) {
                        return error.TooLarge;
                    }

                    try fragments.message.appendSlice(self.allocator, payload);

                    if (fin == false) {
                        // maybe we have more parts of the message waiting
                        continue :LOOP;
                    }

                    // this continuation is done!
                    return .{
                        .type = fragments.type,
                        .data = fragments.message.items,
                        .cleanup_fragment = true,
                    };
                }

                const can_be_fragmented = message_type == .text or message_type == .binary;
                if (self.fragments != null and can_be_fragmented) {
                    // if this isn't a continuation, then we can't have fragments
                    return error.NestedFragementation;
                }

                if (fin == false) {
                    if (can_be_fragmented == false) {
                        return error.InvalidContinuation;
                    }

                    // not continuation, and not fin. It has to be the first message
                    // in a fragmented message.
                    var fragments = Fragments{ .message = .{}, .type = message_type };
                    try fragments.message.appendSlice(self.allocator, payload);
                    self.fragments = fragments;
                    continue :LOOP;
                }

                return .{
                    .data = payload,
                    .type = message_type,
                    .cleanup_fragment = false,
                };
            }
        }

        fn extractLengths(buf: []const u8) ?struct { usize, usize } {
            if (buf.len < 2) {
                return null;
            }

            const length_of_len: usize = switch (buf[1] & 127) {
                126 => 2,
                127 => 8,
                else => 0,
            };

            if (buf.len < length_of_len + 2) {
                // we definitely don't have enough buf yet
                return null;
            }

            const message_len = switch (length_of_len) {
                2 => @as(u16, @intCast(buf[3])) | @as(u16, @intCast(buf[2])) << 8,
                8 => @as(u64, @intCast(buf[9])) | @as(u64, @intCast(buf[8])) << 8 | @as(u64, @intCast(buf[7])) << 16 | @as(u64, @intCast(buf[6])) << 24 | @as(u64, @intCast(buf[5])) << 32 | @as(u64, @intCast(buf[4])) << 40 | @as(u64, @intCast(buf[3])) << 48 | @as(u64, @intCast(buf[2])) << 56,
                else => buf[1] & 127,
            } + length_of_len + 2 + if (comptime EXPECT_MASK) 4 else 0; // +2 for header prefix, +4 for mask;

            return .{ length_of_len, message_len };
        }

        // This is called after we've processed complete websocket messages (this
        // only applies to websocket messages).
        // There are three cases:
        // 1 - We don't have any incomplete data (for a subsequent message) in buf.
        //     This is the easier to handle, we can set pos & len to 0.
        // 2 - We have part of the next message, but we know it'll fit in the
        //     remaining buf. We don't need to do anything
        // 3 - We have part of the next message, but either it won't fight into the
        //     remaining buffer, or we don't know (because we don't have enough
        //     of the header to tell the length). We need to "compact" the buffer
        pub fn compact(self: *Self) void {
            const pos = self.pos;
            const len = self.len;

            assert(pos <= len, "Client.Reader.compact precondition", .{ .pos = pos, .len = len });

            // how many (if any) partial bytes do we have
            const partial_bytes = len - pos;

            if (partial_bytes == 0) {
                // We have no partial bytes. Setting these to 0 ensures that we
                // get the best utilization of our buffer
                self.pos = 0;
                self.len = 0;
                return;
            }

            const partial = self.buf[pos..len];

            // If we have enough bytes of the next message to tell its length
            // we'll be able to figure out whether we need to do anything or not.
            if (extractLengths(partial)) |length_meta| {
                const next_message_len = length_meta.@"1";
                // if this isn't true, then we have a full message and it
                // should have been processed.
                assert(pos <= len, "Client.Reader.compact postcondition", .{ .next_len = next_message_len, .partial = partial_bytes });

                const missing_bytes = next_message_len - partial_bytes;

                const free_space = self.buf.len - len;
                if (missing_bytes < free_space) {
                    // we have enough space in our buffer, as is,
                    return;
                }
            }

            // We're here because we either don't have enough bytes of the next
            // message, or we know that it won't fit in our buffer as-is.
            std.mem.copyForwards(u8, self.buf, partial);
            self.pos = 0;
            self.len = partial_bytes;
        }
    };
}

// In-place string lowercase
fn toLower(str: []u8) []u8 {
    for (str, 0..) |ch, i| {
        str[i] = std.ascii.toLower(ch);
    }
    return str;
}

pub const WsConnection = struct {
    // CLOSE, 2 length, code
    const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 }; // code: 1000
    const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 }; // 1009
    const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 }; //code: 1002
    // "private-use" close codes must be from 4000-49999
    const CLOSE_TIMEOUT = [_]u8{ 136, 2, 15, 160 }; // code: 4000

    socket: posix.socket_t,
    socket_flags: usize,
    reader: Reader(true),
    send_arena: ArenaAllocator,
    json_version_response: []const u8,
    timeout_ms: u32,

    pub fn init(socket: posix.socket_t, allocator: Allocator, json_version_response: []const u8, timeout_ms: u32) !WsConnection {
        const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        assert(socket_flags & nonblocking == nonblocking, "WsConnection.init blocking", .{});

        var reader = try Reader(true).init(allocator);
        errdefer reader.deinit();

        return .{
            .socket = socket,
            .socket_flags = socket_flags,
            .reader = reader,
            .send_arena = ArenaAllocator.init(allocator),
            .json_version_response = json_version_response,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *WsConnection) void {
        self.reader.deinit();
        self.send_arena.deinit();
    }

    pub fn send(self: *WsConnection, data: []const u8) !void {
        var pos: usize = 0;
        var changed_to_blocking: bool = false;
        defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

        defer if (changed_to_blocking) {
            // We had to change our socket to blocking me to get our write out
            // We need to change it back to non-blocking.
            _ = posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
                log.err(.app, "ws restore nonblocking", .{ .err = err });
            };
        };

        LOOP: while (pos < data.len) {
            const written = posix.write(self.socket, data[pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // self.socket is nonblocking, because we don't want to block
                    // reads. But our life is a lot easier if we block writes,
                    // largely, because we don't have to maintain a queue of pending
                    // writes (which would each need their own allocations). So
                    // if we get a WouldBlock error, we'll switch the socket to
                    // blocking and switch it back to non-blocking after the write
                    // is complete. Doesn't seem particularly efficiently, but
                    // this should virtually never happen.
                    assert(changed_to_blocking == false, "WsConnection.double block", .{});
                    changed_to_blocking = true;
                    _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
                    continue :LOOP;
                },
                else => return err,
            };

            if (written == 0) {
                return error.Closed;
            }
            pos += written;
        }
    }

    const EMPTY_PONG = [_]u8{ 138, 0 };

    pub fn sendPong(self: *WsConnection, data: []const u8) !void {
        if (data.len == 0) {
            return self.send(&EMPTY_PONG);
        }
        var header_buf: [10]u8 = undefined;
        const header = websocketHeader(&header_buf, .pong, data.len);

        const allocator = self.send_arena.allocator();
        const framed = try allocator.alloc(u8, header.len + data.len);
        @memcpy(framed[0..header.len], header);
        @memcpy(framed[header.len..], data);
        return self.send(framed);
    }

    // called by CDP
    // Websocket frames have a variable length header. For server-client,
    // it could be anywhere from 2 to 10 bytes. Our IO.Loop doesn't have
    // writev, so we need to get creative. We'll JSON serialize to a
    // buffer, where the first 10 bytes are reserved. We can then backfill
    // the header and send the slice.
    pub fn sendJSON(self: *WsConnection, message: anytype, opts: std.json.Stringify.Options) !void {
        const allocator = self.send_arena.allocator();

        var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);

        // reserve space for the maximum possible header
        try aw.writer.writeAll(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        try std.json.Stringify.value(message, opts, &aw.writer);
        const framed = fillWebsocketHeader(aw.toArrayList());
        return self.send(framed);
    }

    pub fn sendJSONRaw(
        self: *WsConnection,
        buf: std.ArrayList(u8),
    ) !void {
        // Dangerous API!. We assume the caller has reserved the first 10
        // bytes in `buf`.
        const framed = fillWebsocketHeader(buf);
        return self.send(framed);
    }

    pub fn read(self: *WsConnection) !usize {
        const n = try posix.read(self.socket, self.reader.readBuf());
        self.reader.len += n;
        return n;
    }

    pub fn processMessages(self: *WsConnection, handler: anytype) !bool {
        var reader = &self.reader;
        while (true) {
            const msg = reader.next() catch |err| {
                switch (err) {
                    error.TooLarge => self.send(&CLOSE_TOO_BIG) catch {},
                    error.NotMasked => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.ReservedFlags => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.InvalidMessageType => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.ControlTooLarge => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.InvalidContinuation => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.NestedFragementation => self.send(&CLOSE_PROTOCOL_ERROR) catch {},
                    error.OutOfMemory => {}, // don't borther trying to send an error in this case
                }
                return err;
            } orelse break;

            switch (msg.type) {
                .pong => {},
                .ping => try self.sendPong(msg.data),
                .close => {
                    self.send(&CLOSE_NORMAL) catch {};
                    return false;
                },
                .text, .binary => if (handler.handleMessage(msg.data) == false) {
                    return false;
                },
            }
            if (msg.cleanup_fragment) {
                reader.cleanup();
            }
        }

        // We might have read part of the next message. Our reader potentially
        // has to move data around in its buffer to make space.
        reader.compact();
        return true;
    }

    pub fn upgrade(self: *WsConnection, request: []u8) !void {
        // our caller already confirmed that we have a trailing \r\n\r\n
        const request_line_end = std.mem.indexOfScalar(u8, request, '\r') orelse unreachable;
        const request_line = request[0..request_line_end];

        if (!std.ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
            return error.InvalidProtocol;
        }

        // we need to extract the sec-websocket-key value
        var key: []const u8 = "";

        // we need to make sure that we got all the necessary headers + values
        var required_headers: u8 = 0;

        // can't std.mem.split because it forces the iterated value to be const
        // (we could @constCast...)

        var buf = request[request_line_end + 2 ..];

        while (buf.len > 4) {
            const index = std.mem.indexOfScalar(u8, buf, '\r') orelse unreachable;
            const separator = std.mem.indexOfScalar(u8, buf[0..index], ':') orelse return error.InvalidRequest;

            const name = std.mem.trim(u8, toLower(buf[0..separator]), &std.ascii.whitespace);
            const value = std.mem.trim(u8, buf[(separator + 1)..index], &std.ascii.whitespace);

            if (std.mem.eql(u8, name, "upgrade")) {
                if (!std.ascii.eqlIgnoreCase("websocket", value)) {
                    return error.InvalidUpgradeHeader;
                }
                required_headers |= 1;
            } else if (std.mem.eql(u8, name, "sec-websocket-version")) {
                if (value.len != 2 or value[0] != '1' or value[1] != '3') {
                    return error.InvalidVersionHeader;
                }
                required_headers |= 2;
            } else if (std.mem.eql(u8, name, "connection")) {
                // find if connection header has upgrade in it, example header:
                // Connection: keep-alive, Upgrade
                if (std.ascii.indexOfIgnoreCase(value, "upgrade") == null) {
                    return error.InvalidConnectionHeader;
                }
                required_headers |= 4;
            } else if (std.mem.eql(u8, name, "sec-websocket-key")) {
                key = value;
                required_headers |= 8;
            }

            const next = index + 2;
            buf = buf[next..];
        }

        if (required_headers != 15) {
            return error.MissingHeaders;
        }

        // our caller has already made sure this request ended in \r\n\r\n
        // so it isn't something we need to check again

        const alloc = self.send_arena.allocator();

        const response = blk: {
            // Response to an ugprade request is always this, with
            // the Sec-Websocket-Accept value a spacial sha1 hash of the
            // request "sec-websocket-version" and a magic value.

            const template =
                "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: upgrade\r\n" ++
                "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n";

            // The response will be sent via the IO Loop and thus has to have its
            // own lifetime.
            const res = try alloc.dupe(u8, template);

            // magic response
            const key_pos = res.len - 32;
            var h: [20]u8 = undefined;
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(key);
            // websocket spec always used this value
            hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
            hasher.final(&h);

            _ = std.base64.standard.Encoder.encode(res[key_pos .. key_pos + 28], h[0..]);

            break :blk res;
        };

        return self.send(response);
    }

    pub fn sendHttpError(self: *WsConnection, comptime status: u16, comptime body: []const u8) void {
        const response = std.fmt.comptimePrint(
            "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ status, body.len, body },
        );

        // we're going to close this connection anyways, swallowing any
        // error seems safe
        self.send(response) catch {};
    }

    pub fn getAddress(self: *WsConnection) !std.net.Address {
        var address: std.net.Address = undefined;
        var socklen: posix.socklen_t = @sizeOf(std.net.Address);
        try posix.getpeername(self.socket, &address.any, &socklen);
        return address;
    }

    pub fn shutdown(self: *WsConnection) void {
        posix.shutdown(self.socket, .recv) catch {};
    }

    pub fn setBlocking(self: *WsConnection, blocking: bool) !void {
        if (blocking) {
            _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        } else {
            _ = try posix.fcntl(self.socket, posix.F.SETFL, self.socket_flags);
        }
    }
};

const testing = std.testing;

test "mask" {
    var buf: [4000]u8 = undefined;
    const messages = [_][]const u8{ "1234", "1234" ** 99, "1234" ** 999 };
    for (messages) |message| {
        // we need the message to be mutable since mask operates in-place
        const payload = buf[0..message.len];
        @memcpy(payload, message);

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(false, std.mem.eql(u8, payload, message));

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(true, std.mem.eql(u8, payload, message));
    }
}

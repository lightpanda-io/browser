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

const c = @cImport({
    @cInclude("curl/curl.h");
});

const IS_DEBUG = builtin.mode == .Debug;

pub const Curl = c.CURL;
pub const CurlM = c.CURLM;
pub const CurlCode = c.CURLcode;
pub const CurlMCode = c.CURLMcode;
pub const CurlSList = c.curl_slist;
pub const CurlHeader = c.curl_header;
pub const CurlHttpPost = c.curl_httppost;
pub const CurlSocket = c.curl_socket_t;
pub const CurlBlob = c.curl_blob;
pub const CurlOffT = c.curl_off_t;

pub const CurlDebugFunction = fn (*Curl, CurlInfoType, [*c]u8, usize, *anyopaque) c_int;
pub const CurlHeaderFunction = fn ([*]const u8, usize, usize, *anyopaque) usize;
pub const CurlWriteFunction = fn ([*]const u8, usize, usize, *anyopaque) usize;
pub const curl_writefunc_error: usize = c.CURL_WRITEFUNC_ERROR;

pub const CurlGlobalFlags = packed struct(u8) {
    ssl: bool = false,
    _reserved: u7 = 0,

    pub fn to_c(self: @This()) c_long {
        var flags: c_long = 0;
        if (self.ssl) flags |= c.CURL_GLOBAL_SSL;
        return flags;
    }
};

pub const CurlHeaderOrigin = enum(c_uint) {
    header = c.CURLH_HEADER,
    trailer = c.CURLH_TRAILER,
    connect = c.CURLH_CONNECT,
    @"1xx" = c.CURLH_1XX,
    pseudo = c.CURLH_PSEUDO,
};

pub const CurlWaitEvents = packed struct(c_short) {
    pollin: bool = false,
    pollpri: bool = false,
    pollout: bool = false,
    _reserved: u13 = 0,
};

pub const CurlInfoType = enum(c.curl_infotype) {
    text = c.CURLINFO_TEXT,
    header_in = c.CURLINFO_HEADER_IN,
    header_out = c.CURLINFO_HEADER_OUT,
    data_in = c.CURLINFO_DATA_IN,
    data_out = c.CURLINFO_DATA_OUT,
    ssl_data_in = c.CURLINFO_SSL_DATA_IN,
    ssl_data_out = c.CURLINFO_SSL_DATA_OUT,
    end = c.CURLINFO_END,
};

pub const CurlWaitFd = extern struct {
    fd: CurlSocket,
    events: CurlWaitEvents,
    revents: CurlWaitEvents,
};

comptime {
    const debug_cb_check: c.curl_debug_callback = struct {
        fn cb(handle: ?*Curl, msg_type: c.curl_infotype, raw: [*c]u8, len: usize, user: ?*anyopaque) callconv(.c) c_int {
            _ = handle;
            _ = msg_type;
            _ = raw;
            _ = len;
            _ = user;
            return 0;
        }
    }.cb;
    const write_cb_check: c.curl_write_callback = struct {
        fn cb(buffer: [*c]u8, count: usize, len: usize, user: ?*anyopaque) callconv(.c) usize {
            _ = buffer;
            _ = count;
            _ = len;
            _ = user;
            return 0;
        }
    }.cb;
    _ = debug_cb_check;
    _ = write_cb_check;

    if (@sizeOf(CurlWaitFd) != @sizeOf(c.curl_waitfd)) {
        @compileError("CurlWaitFd size mismatch");
    }
    if (@offsetOf(CurlWaitFd, "fd") != @offsetOf(c.curl_waitfd, "fd") or
        @offsetOf(CurlWaitFd, "events") != @offsetOf(c.curl_waitfd, "events") or
        @offsetOf(CurlWaitFd, "revents") != @offsetOf(c.curl_waitfd, "revents"))
    {
        @compileError("CurlWaitFd layout mismatch");
    }
    if (c.CURL_WAIT_POLLIN != 1 or c.CURL_WAIT_POLLPRI != 2 or c.CURL_WAIT_POLLOUT != 4) {
        @compileError("CURL_WAIT_* flag values don't match CurlWaitEvents packed struct bit layout");
    }
}

pub const CurlOption = enum(c.CURLoption) {
    url = c.CURLOPT_URL,
    timeout_ms = c.CURLOPT_TIMEOUT_MS,
    connect_timeout_ms = c.CURLOPT_CONNECTTIMEOUT_MS,
    max_redirs = c.CURLOPT_MAXREDIRS,
    follow_location = c.CURLOPT_FOLLOWLOCATION,
    redir_protocols_str = c.CURLOPT_REDIR_PROTOCOLS_STR,
    proxy = c.CURLOPT_PROXY,
    ca_info_blob = c.CURLOPT_CAINFO_BLOB,
    proxy_ca_info_blob = c.CURLOPT_PROXY_CAINFO_BLOB,
    ssl_verify_host = c.CURLOPT_SSL_VERIFYHOST,
    ssl_verify_peer = c.CURLOPT_SSL_VERIFYPEER,
    proxy_ssl_verify_host = c.CURLOPT_PROXY_SSL_VERIFYHOST,
    proxy_ssl_verify_peer = c.CURLOPT_PROXY_SSL_VERIFYPEER,
    accept_encoding = c.CURLOPT_ACCEPT_ENCODING,
    verbose = c.CURLOPT_VERBOSE,
    debug_function = c.CURLOPT_DEBUGFUNCTION,
    custom_request = c.CURLOPT_CUSTOMREQUEST,
    post = c.CURLOPT_POST,
    http_post = c.CURLOPT_HTTPPOST,
    post_field_size = c.CURLOPT_POSTFIELDSIZE,
    copy_post_fields = c.CURLOPT_COPYPOSTFIELDS,
    http_get = c.CURLOPT_HTTPGET,
    http_header = c.CURLOPT_HTTPHEADER,
    cookie = c.CURLOPT_COOKIE,
    private = c.CURLOPT_PRIVATE,
    proxy_user_pwd = c.CURLOPT_PROXYUSERPWD,
    header_data = c.CURLOPT_HEADERDATA,
    header_function = c.CURLOPT_HEADERFUNCTION,
    write_data = c.CURLOPT_WRITEDATA,
    write_function = c.CURLOPT_WRITEFUNCTION,
};

pub const CurlMOption = enum(c.CURLMoption) {
    max_host_connections = c.CURLMOPT_MAX_HOST_CONNECTIONS,
};

pub const CurlInfo = enum(c.CURLINFO) {
    effective_url = c.CURLINFO_EFFECTIVE_URL,
    private = c.CURLINFO_PRIVATE,
    redirect_count = c.CURLINFO_REDIRECT_COUNT,
    response_code = c.CURLINFO_RESPONSE_CODE,
};

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

pub fn errorFromCode(code: c.CURLcode) Error {
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

pub const ErrorHeader = error{
    OutOfMemory,
    BadArgument,
    NotBuiltIn,
    Unknown,
};

pub fn errorMFromCode(code: c.CURLMcode) ErrorMulti {
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

pub fn errorHFromCode(code: c.CURLHcode) ErrorHeader {
    if (comptime IS_DEBUG) {
        std.debug.assert(code != c.CURLHE_OK);
    }

    return switch (code) {
        c.CURLHE_OUT_OF_MEMORY => ErrorHeader.OutOfMemory,
        c.CURLHE_BAD_ARGUMENT => ErrorHeader.BadArgument,
        c.CURLHE_NOT_BUILT_IN => ErrorHeader.NotBuiltIn,
        else => ErrorHeader.Unknown,
    };
}

pub fn errorCheck(code: c.CURLcode) Error!void {
    if (code == c.CURLE_OK) {
        return;
    }
    return errorFromCode(code);
}

pub fn errorMCheck(code: c.CURLMcode) ErrorMulti!void {
    if (code == c.CURLM_OK) {
        return;
    }
    if (code == c.CURLM_CALL_MULTI_PERFORM) {
        return;
    }
    return errorMFromCode(code);
}

pub fn errorHCheck(code: c.CURLHcode) ErrorHeader!void {
    if (code == c.CURLHE_OK) {
        return;
    }
    return errorHFromCode(code);
}

pub const CurlMsgType = enum(c.CURLMSG) {
    none = c.CURLMSG_NONE,
    done = c.CURLMSG_DONE,
    last = c.CURLMSG_LAST,
};

pub const CurlMsgData = union(CurlMsgType) {
    none: ?*anyopaque,
    done: ?Error,
    last: ?*anyopaque,
};

pub const CurlMsg = struct {
    easy_handle: *Curl,
    data: CurlMsgData,
};

pub fn curl_global_init(flags: CurlGlobalFlags) Error!void {
    try errorCheck(c.curl_global_init(flags.to_c()));
}

pub fn curl_global_cleanup() void {
    c.curl_global_cleanup();
}

pub fn curl_version() [*c]const u8 {
    return c.curl_version();
}

pub fn curl_easy_init() ?*Curl {
    return c.curl_easy_init();
}

pub fn curl_easy_cleanup(easy: *Curl) void {
    c.curl_easy_cleanup(easy);
}

pub fn curl_easy_perform(easy: *Curl) Error!void {
    try errorCheck(c.curl_easy_perform(easy));
}

pub fn curl_easy_setopt(easy: *Curl, comptime option: CurlOption, value: anytype) Error!void {
    const opt: c.CURLoption = @intFromEnum(option);
    const code = switch (option) {
        .verbose,
        .post,
        .http_get,
        .ssl_verify_host,
        .ssl_verify_peer,
        .proxy_ssl_verify_host,
        .proxy_ssl_verify_peer,
        => blk: {
            const n: c_long = switch (@typeInfo(@TypeOf(value))) {
                .bool => switch (option) {
                    .ssl_verify_host, .proxy_ssl_verify_host => if (value) 2 else 0,
                    else => if (value) 1 else 0,
                },
                else => @compileError("expected bool|integer for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_easy_setopt(easy, opt, n);
        },

        .timeout_ms,
        .connect_timeout_ms,
        .max_redirs,
        .follow_location,
        .post_field_size,
        => blk: {
            const n: c_long = switch (@typeInfo(@TypeOf(value))) {
                .comptime_int, .int => @intCast(value),
                else => @compileError("expected integer for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_easy_setopt(easy, opt, n);
        },

        .url,
        .redir_protocols_str,
        .proxy,
        .accept_encoding,
        .custom_request,
        .cookie,
        .proxy_user_pwd,
        .copy_post_fields,
        => blk: {
            const s: ?[*]const u8 = value;
            break :blk c.curl_easy_setopt(easy, opt, s);
        },

        .ca_info_blob,
        .proxy_ca_info_blob,
        => blk: {
            const blob: CurlBlob = value;
            break :blk c.curl_easy_setopt(easy, opt, blob);
        },

        .http_post => blk: {
            // CURLOPT_HTTPPOST expects ?*curl_httppost (multipart formdata)
            const ptr: ?*CurlHttpPost = value;
            break :blk c.curl_easy_setopt(easy, opt, ptr);
        },

        .http_header => blk: {
            const list: ?*CurlSList = value;
            break :blk c.curl_easy_setopt(easy, opt, list);
        },

        .private,
        .header_data,
        .write_data,
        => blk: {
            const ptr: *anyopaque = @ptrCast(value);
            break :blk c.curl_easy_setopt(easy, opt, ptr);
        },

        .debug_function => blk: {
            const cb: c.curl_debug_callback = switch (@typeInfo(@TypeOf(value))) {
                .null => null,
                .@"fn" => struct {
                    fn cb(handle: ?*Curl, msg_type: c.curl_infotype, raw: [*c]u8, len: usize, user: ?*anyopaque) callconv(.c) c_int {
                        const h = handle orelse unreachable;
                        const u = user orelse unreachable;
                        return value(h, @enumFromInt(@intFromEnum(msg_type)), raw, len, u);
                    }
                }.cb,
                else => @compileError("expected Zig function or null for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_easy_setopt(easy, opt, cb);
        },

        .header_function => blk: {
            const cb: c.curl_write_callback = switch (@typeInfo(@TypeOf(value))) {
                .null => null,
                .@"fn" => struct {
                    fn cb(buffer: [*c]u8, count: usize, len: usize, user: ?*anyopaque) callconv(.c) usize {
                        const u = user orelse unreachable;
                        return value(@ptrCast(buffer), count, len, u);
                    }
                }.cb,
                else => @compileError("expected Zig function or null for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_easy_setopt(easy, opt, cb);
        },

        .write_function => blk: {
            const cb: c.curl_write_callback = switch (@typeInfo(@TypeOf(value))) {
                .null => null,
                .@"fn" => struct {
                    fn cb(buffer: [*c]u8, count: usize, len: usize, user: ?*anyopaque) callconv(.c) usize {
                        const u = user orelse unreachable;
                        return value(@ptrCast(buffer), count, len, u);
                    }
                }.cb,
                else => @compileError("expected Zig function or null for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_easy_setopt(easy, opt, cb);
        },
    };
    try errorCheck(code);
}

pub fn curl_easy_getinfo(easy: *Curl, comptime info: CurlInfo, out: anytype) Error!void {
    if (@typeInfo(@TypeOf(out)) != .pointer) {
        @compileError("curl_easy_getinfo out must be a pointer, got " ++ @typeName(@TypeOf(out)));
    }

    const inf: c.CURLINFO = @intFromEnum(info);
    const code = switch (info) {
        .effective_url => blk: {
            const p: *[*c]u8 = out;
            break :blk c.curl_easy_getinfo(easy, inf, p);
        },
        .response_code,
        .redirect_count,
        => blk: {
            const p: *c_long = out;
            break :blk c.curl_easy_getinfo(easy, inf, p);
        },
        .private => blk: {
            const p: **anyopaque = out;
            break :blk c.curl_easy_getinfo(easy, inf, p);
        },
    };
    try errorCheck(code);
}

pub fn curl_easy_header(
    easy: *Curl,
    name: [*:0]const u8,
    index: usize,
    comptime origin: CurlHeaderOrigin,
    request: c_int,
    hout: *?*CurlHeader,
) ErrorHeader!void {
    var c_hout: [*c]CurlHeader = null;
    const code = c.curl_easy_header(easy, name, index, @intFromEnum(origin), request, &c_hout);
    switch (code) {
        c.CURLHE_OK => {
            hout.* = @ptrCast(c_hout);
            return;
        },
        c.CURLHE_BADINDEX,
        c.CURLHE_MISSING,
        c.CURLHE_NOHEADERS,
        c.CURLHE_NOREQUEST,
        => {
            hout.* = null;
            return;
        },
        else => {
            hout.* = null;
            return errorHFromCode(code);
        },
    }
}

pub fn curl_easy_nextheader(
    easy: *Curl,
    comptime origin: CurlHeaderOrigin,
    request: c_int,
    prev: ?*CurlHeader,
) ?*CurlHeader {
    const ptr = c.curl_easy_nextheader(easy, @intFromEnum(origin), request, prev);
    if (ptr == null) return null;
    return @ptrCast(ptr);
}

pub fn curl_multi_init() ?*CurlM {
    return c.curl_multi_init();
}

pub fn curl_multi_cleanup(multi: *CurlM) ErrorMulti!void {
    try errorMCheck(c.curl_multi_cleanup(multi));
}

pub fn curl_multi_setopt(multi: *CurlM, comptime option: CurlMOption, value: anytype) ErrorMulti!void {
    const opt: c.CURLMoption = @intFromEnum(option);
    const code = switch (option) {
        .max_host_connections => blk: {
            const n: c_long = switch (@typeInfo(@TypeOf(value))) {
                .comptime_int, .int => @intCast(value),
                else => @compileError("expected integer for " ++ @tagName(option) ++ ", got " ++ @typeName(@TypeOf(value))),
            };
            break :blk c.curl_multi_setopt(multi, opt, n);
        },
    };
    try errorMCheck(code);
}

pub fn curl_multi_add_handle(multi: *CurlM, easy: *Curl) ErrorMulti!void {
    try errorMCheck(c.curl_multi_add_handle(multi, easy));
}

pub fn curl_multi_remove_handle(multi: *CurlM, easy: *Curl) ErrorMulti!void {
    try errorMCheck(c.curl_multi_remove_handle(multi, easy));
}

pub fn curl_multi_perform(multi: *CurlM, running_handles: *c_int) ErrorMulti!void {
    try errorMCheck(c.curl_multi_perform(multi, running_handles));
}

pub fn curl_multi_poll(
    multi: *CurlM,
    extra_fds: []CurlWaitFd,
    timeout_ms: c_int,
    numfds: ?*c_int,
) ErrorMulti!void {
    const raw_fds: [*c]c.curl_waitfd = if (extra_fds.len == 0) null else @ptrCast(extra_fds.ptr);
    try errorMCheck(c.curl_multi_poll(multi, raw_fds, @intCast(extra_fds.len), timeout_ms, numfds));
}

pub fn curl_multi_info_read(multi: *CurlM, msgs_in_queue: *c_int) ?CurlMsg {
    const ptr = c.curl_multi_info_read(multi, msgs_in_queue);
    if (ptr == null) return null;

    const msg: *const c.CURLMsg = @ptrCast(ptr);
    const easy_handle = msg.easy_handle orelse unreachable;

    return switch (msg.msg) {
        c.CURLMSG_NONE => .{
            .easy_handle = easy_handle,
            .data = .{ .none = msg.data.whatever },
        },
        c.CURLMSG_DONE => .{
            .easy_handle = easy_handle,
            .data = .{ .done = if (errorCheck(msg.data.result)) |_| null else |err| err },
        },
        c.CURLMSG_LAST => .{
            .easy_handle = easy_handle,
            .data = .{ .last = msg.data.whatever },
        },
        else => unreachable,
    };
}

pub fn curl_slist_append(list: ?*CurlSList, header: [*:0]const u8) ?*CurlSList {
    return c.curl_slist_append(list, header);
}

pub fn curl_slist_free_all(list: ?*CurlSList) void {
    if (list) |ptr| {
        c.curl_slist_free_all(ptr);
    }
}

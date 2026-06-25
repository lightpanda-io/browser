const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const http = @import("http.zig");
const HttpClient = @import("../browser/HttpClient.zig");
const Response = HttpClient.Response;
const CorsContext = @import("./layer/CorsLayer.zig").CorsContext;

// relevant docs:
// https://fetch.spec.whatwg.org/#http-cors-protocol
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS
// - https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS#simple_requests
// - https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_request_header#additional_restrictions
// - https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header

/// Determine if a request is simple or not using CorsContext.
/// If not, any unsafe headers will be stored in ctx.
pub fn determineSimpleRequestCtx(ctx: *CorsContext, req: *const HttpClient.Request) !bool {
    return determineSimple(
        ctx.arena,
        req.method,
        req.headers.iterator(),
        &ctx.unsafe_headers,
    );
}

fn determineSimple(
    arena: std.mem.Allocator,
    method: http.Method,
    headers: http.HeaderIterator,
    unsafe_headers: *std.ArrayList([]const u8),
) !bool {
    var simple = switch (method) {
        .GET, .HEAD, .POST => true,
        else => false,
    };

    var header_it = headers;

    outer: while (header_it.next()) |h| {
        if (h.value.len > 128) {
            simple = false;
        }
        if (std.ascii.startsWithIgnoreCase(h.name, "sec-") or
            std.ascii.startsWithIgnoreCase(h.name, "proxy-"))
        {
            continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "accept-language") or
            std.ascii.eqlIgnoreCase(h.name, "content-language"))
        {
            if (safeLanguageValue(h.value)) continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "accept")) {
            if (safeHeaderBytes(h.value)) continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            if (safeHeaderBytes(h.value) and safeContentType(h.value)) continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "range")) {
            if (safeRange(h.value)) continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-http-method") or
            std.ascii.eqlIgnoreCase(h.name, "x-http-method-override") or
            std.ascii.eqlIgnoreCase(h.name, "x-method-override"))
        {
            for (forbidden_methods) |n| {
                if (std.ascii.eqlIgnoreCase(h.value, n)) continue :outer;
            }
        } else {
            for (safe_headers) |a_h| {
                if (std.ascii.eqlIgnoreCase(h.name, a_h)) {
                    continue :outer;
                }
            }
        }
        // dupe it since req headers can be invalidated
        try unsafe_headers.append(arena, try arena.dupe(u8, h.name));
    }

    return unsafe_headers.items.len == 0 and simple;
}

/// Dertermine if a response passes CORS checks using an existing CorsContext
pub fn responsePassesCorsCtx(ctx: *CorsContext, response: Response) !bool {
    const arena = ctx.arena;
    var res_store: ResponseHeaderStore = .empty;

    var header_it = response.headerIterator();
    const headers = try header_it.collect(arena);

    for (headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-origin")) {
            res_store.res_origin = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-credentials")) {
            res_store.res_credentials = std.ascii.eqlIgnoreCase(h.value, "true");
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-methods")) {
            res_store.res_methods = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-headers")) {
            res_store.res_headers = h.value;
        }
    }

    return passesCors(
        ctx.from_origin,
        ctx.original_method,
        ctx.unsafe_headers.items,
        ctx.credentials,
        ctx.held != null,
        res_store,
    );
}

fn passesCors(
    req_from_origin: []const u8,
    req_method: []const u8,
    req_unsafe_headers: []const []const u8,
    req_credentials: bool,
    preflight: bool,
    store: ResponseHeaderStore,
) bool {
    const origin_wildcard: bool = std.mem.eql(u8, store.res_origin, "*");
    const origin_match = std.mem.eql(u8, store.res_origin, req_from_origin);

    if (!origin_wildcard and !origin_match) {
        return false;
    }

    if (!preflight) {
        // non-preflight:
        // no wildcards if credentials
        return !req_credentials or (store.res_credentials and origin_match);
    }

    // this is a preflight request;
    // mandatory: methods & headers, ~credentials.
    // optional: max-age

    // methods
    var method_it = std.mem.tokenizeAny(u8, store.res_methods, " ,");
    var method_wildcard = false;
    const method_match = while (method_it.next()) |m| {
        if (std.mem.eql(u8, m, req_method)) {
            break true;
        } else if (std.mem.eql(u8, m, "*")) {
            method_wildcard = true;
        }
    } else false;

    // headers
    var header_it = std.mem.tokenizeAny(u8, store.res_headers, " ,");
    var headers_wildcard = false;
    const headers_match = match: {
        for (req_unsafe_headers) |req_header| {
            header_it.reset();
            while (header_it.next()) |h| {
                if (std.mem.eql(u8, h, "*")) {
                    headers_wildcard = true;
                    continue;
                } else if (std.ascii.eqlIgnoreCase(h, req_header)) {
                    break;
                }
            } else break :match false;
        } else break :match true;
    };

    // results:
    // no wildcards if credentials
    if (req_credentials) {
        if (store.res_credentials and
            origin_match and
            method_match and
            headers_match)
        {
            return true;
        }
    } else if ((origin_wildcard or origin_match) and
        (method_wildcard or method_match) and
        (headers_wildcard or headers_match))
    {
        return true;
    }

    return false;
}

fn safeLanguageValue(header_value: []const u8) bool {
    return for (header_value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            !std.mem.containsAtLeastScalar(u8, " *,-.;=", 1, byte))
        {
            break false;
        }
    } else true;
}

fn safeHeaderBytes(header_value: []const u8) bool {
    return for (header_value) |byte| {
        if (std.mem.containsAtLeastScalar(u8, unsafe_bytes, 1, byte) or
            (byte >= 0x00 and byte <= 0x1f and byte != 0x09))
        {
            break false;
        }
    } else true;
}

fn safeContentType(header_value: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, header_value, "; ");
    while (it.next()) |ct| {
        if (std.mem.containsAtLeast(u8, ct, 1, "=")) continue;
        for (safe_content_types) |sct| {
            if (std.ascii.eqlIgnoreCase(sct, ct)) break;
        } else return false;
    } else return true;
}

// https://fetch.spec.whatwg.org/#simple-range-header-value
fn safeRange(range: []const u8) bool {
    if (!std.mem.startsWith(u8, range, "bytes")) return false;
    if (std.mem.containsAtLeastScalar(u8, range, 1, ',')) return false;

    var rem = range[5..];
    var pos: usize = 0;

    while (pos < rem.len and std.ascii.isWhitespace(rem[pos])) {
        pos += 1;
    }
    if (pos >= rem.len or rem[pos] != '=') return false;
    pos += 1;

    while (pos < rem.len and std.ascii.isWhitespace(rem[pos])) {
        pos += 1;
    }
    rem = rem[pos..];
    pos = 0;

    while (pos < rem.len and std.ascii.isDigit(rem[pos])) {
        pos += 1;
    }

    const range_start = std.fmt.parseInt(u32, rem[0..pos], 10) catch null;

    while (pos < rem.len and std.ascii.isWhitespace(rem[pos])) {
        pos += 1;
    }
    if (pos >= rem.len or rem[pos] != '-') return false;
    pos += 1;

    while (pos < rem.len and std.ascii.isWhitespace(rem[pos])) {
        pos += 1;
    }
    rem = rem[pos..];
    pos = 0;

    while (pos < rem.len and std.ascii.isDigit(rem[pos])) {
        pos += 1;
    }

    const range_end = std.fmt.parseInt(u32, rem[0..pos], 10) catch null;

    if (pos < rem.len) return false;
    if (range_start == null and range_end == null) return false;

    return true;
}

pub const CorsMode = enum {
    same_origin,
    cross_site,
    none,
};

const ResponseHeaderStore = struct {
    res_origin: []const u8,
    res_methods: []const u8,
    res_headers: []const u8,
    res_credentials: bool,

    const empty: ResponseHeaderStore = .{
        .res_origin = "",
        .res_methods = "",
        .res_headers = "",
        .res_credentials = false,
    };
};

const safe_headers = [_][]const u8{
    "accept-charset",
    "access-control-request-headers",
    "access-control-request-method",
    "accept-encoding",
    "connection",
    "content-length",
    "cookie",
    "date",
    "dnt",
    "expect",
    "host",
    "keep-alive",
    "origin",
    "referer",
    "set-cookie",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "user-agent",
    "via",
};

const safe_content_types = [_][]const u8{
    "application/x-www-form-urlencoded",
    "multipart/form-data",
    "text/plain",
};

const forbidden_methods = [_][]const u8{
    "CONNECT",
    "TRACE",
    "TRACK",
};

const unsafe_bytes = "():<>?@[\\]{}\x7f";

test "CORS: safe-range" {
    try std.testing.expect(safeRange("bytes=0-499"));
    try std.testing.expect(safeRange("bytes=100-"));
    try std.testing.expect(safeRange("bytes  =  100-  "));
    try std.testing.expect(safeRange("bytes=  -500"));
    try std.testing.expect(safeRange("bytes  =0-0"));

    try std.testing.expect(!safeRange("bytes=0-100, 200-300"));
    try std.testing.expect(!safeRange("bytes=100-200, 500-600"));
    try std.testing.expect(!safeRange("bits=0-1024"));
    try std.testing.expect(!safeRange("items=0-10"));
    try std.testing.expect(!safeRange("bytes=0-100-200"));
    try std.testing.expect(!safeRange("0-100"));
    try std.testing.expect(!safeRange("bytes=0-100 "));
}

test "CORS: safe-content-type" {
    try std.testing.expect(
        safeContentType("text/plain"),
    );
    try std.testing.expect(
        safeContentType("application/x-www-form-urlencoded; multipart/form-data; text/plain"),
    );

    try std.testing.expect(
        !safeContentType("text/plain; something/else"),
    );
    try std.testing.expect(
        !safeContentType("just/something/else"),
    );
}

test "CORS: safe-language-value" {
    try std.testing.expect(safeLanguageValue("en-US,en;q=0.9,fr;q=0.8"));
    try std.testing.expect(safeLanguageValue("*; q=0.5"));
    try std.testing.expect(safeLanguageValue("es-419, en"));

    try std.testing.expect(!safeLanguageValue("\"en-US\""));
    try std.testing.expect(!safeLanguageValue("en_US"));
    try std.testing.expect(!safeLanguageValue("en+US"));
    try std.testing.expect(!safeLanguageValue("en/GB"));
    try std.testing.expect(!safeLanguageValue("en-GB\x09"));
}

test "CORS: safe-header-bytes" {
    try std.testing.expect(safeHeaderBytes("application/json"));
    try std.testing.expect(safeHeaderBytes("application/something"));
    try std.testing.expect(safeHeaderBytes("application/vnd.api+json;charset=utf-8"));
    try std.testing.expect(safeHeaderBytes("text/html\x09application/*"));

    try std.testing.expect(!safeHeaderBytes("text/<xml>"));
    try std.testing.expect(!safeHeaderBytes("application/json; profile=(secure)"));
    try std.testing.expect(!safeHeaderBytes("application/json; versions=[1,2]"));
    try std.testing.expect(!safeHeaderBytes("application/json\x0a"));
    try std.testing.expect(!safeHeaderBytes("application/json\x00"));
}

test "CORS: passes-cors" {
    const from_origin = "the-from-origin";

    // basic non-preflight
    var res = passesCors(from_origin, "GET", &.{}, false, false, .{
        .res_methods = "GET",
        .res_origin = from_origin,
        .res_credentials = false,
        .res_headers = &.{},
    });
    try std.testing.expect(res);

    // basic non-preflight incorrect origin
    res = passesCors(from_origin, "GET", &.{}, false, false, .{
        .res_methods = "GET",
        .res_origin = "some-other-origin",
        .res_credentials = false,
        .res_headers = &.{},
    });
    try std.testing.expect(!res);
}

test "CORS: passes-cors-prefligt" {
    const from_origin = "the-from-origin";

    // basic preflight
    var res = passesCors(from_origin, "PATCH", &.{}, false, true, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = false,
        .res_headers = &.{},
    });
    try std.testing.expect(res);

    // basic preflight incorrect origin
    res = passesCors(from_origin, "PATCH", &.{}, false, true, .{
        .res_methods = "PATCH",
        .res_origin = "some-other-origin",
        .res_credentials = false,
        .res_headers = &.{},
    });

    // preflight matching unsafe headers
    res = passesCors(from_origin, "PATCH", &.{"something-custom"}, false, true, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = false,
        .res_headers = "something-custom, something-extra",
    });
    try std.testing.expect(res);

    // preflight non-matching unsafe headers
    res = passesCors(from_origin, "PATCH", &.{"something-custom"}, false, true, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = false,
        .res_headers = "only-something-extra",
    });
    try std.testing.expect(!res);
}

test "CORS: passes-cors-creds" {
    const from_origin = "the-from-origin";

    // matching creds
    var res = passesCors(from_origin, "PATCH", &.{}, true, false, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = true,
        .res_headers = &.{},
    });
    try std.testing.expect(res);

    // matching creds origin wildcard
    res = passesCors(from_origin, "PATCH", &.{}, true, false, .{
        .res_methods = "PATCH",
        .res_origin = "*",
        .res_credentials = true,
        .res_headers = &.{},
    });
    try std.testing.expect(!res);

    // non matching creds
    res = passesCors(from_origin, "PATCH", &.{}, true, false, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = false,
        .res_headers = &.{},
    });
    try std.testing.expect(!res);

    // preflight matching creds matching header and wildcard
    res = passesCors(from_origin, "PATCH", &.{"some-header"}, true, true, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = true,
        .res_headers = "some-header, *",
    });
    try std.testing.expect(res);

    // preflight matching creds non-matching header and wildcard
    res = passesCors(from_origin, "PATCH", &.{"some-header"}, true, true, .{
        .res_methods = "PATCH",
        .res_origin = from_origin,
        .res_credentials = true,
        .res_headers = "*",
    });
    try std.testing.expect(!res);

    // preflight matching creds origin wildcard
    res = passesCors(from_origin, "PATCH", &.{"some-header"}, true, true, .{
        .res_methods = "PATCH",
        .res_origin = "*",
        .res_credentials = true,
        .res_headers = "some-header",
    });
    try std.testing.expect(!res);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const HttpClient = @import("../browser/HttpClient.zig");
const Response = HttpClient.Response;
const CorsContext = @import("./layer/CorsLayer.zig").CorsContext;

// relevant docs:
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS
// - https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS#simple_requests
// - https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_request_header#additional_restrictions
// - https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header

/// Determine if a request is simple or not.
/// If not, any unsafe headers will be stored in ctx.
pub fn determineSimpleRequestCtx(ctx: *CorsContext, req: *const HttpClient.Request) !bool {
    return determineSimpleRequest(ctx.arena, &ctx.unsafe_headers, req);
}

fn determineSimpleRequest(arena: std.mem.Allocator, unsafe_headers: *std.ArrayList([]const u8), req: *const HttpClient.Request) !bool {
    var simple = switch (req.method) {
        .GET, .HEAD, .POST => true,
        else => false,
    };

    var header_iter = req.headers.iterator();
    outer: while (header_iter.next()) |h| {
        if (h.value.len > 128) {
            simple = false;
        }
        // safe headers are case-insensitive
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
                if (std.mem.eql(u8, h.value, n)) continue :outer;
            }
        } else {
            for (safe_headers) |a_h| {
                if (std.ascii.eqlIgnoreCase(h.name, a_h)) {
                    continue :outer;
                }
            }
        }
        // dupe it since headers can be invalidated
        try unsafe_headers.append(arena, try arena.dupe(u8, h.name));
    }

    return unsafe_headers.items.len == 0 and simple;
}

/// Dertermine if a response passes CORS checks using an existing Context
pub fn responsePassesCorsCtx(ctx: *CorsContext, response: Response) !bool {
    const arena = ctx.arena;
    var res_store: HeaderStore = .{};

    var header_it = response.headerIterator();
    const headers = try header_it.collect(arena);

    for (headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-origin")) {
            res_store.res_origin = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-credentials")) {
            res_store.res_credentials = std.ascii.eqlIgnoreCase(h.value, "true");
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-methods")) {
            var iter = std.mem.tokenizeAny(u8, h.value, ", ");
            while (iter.next()) |val| {
                try res_store.res_methods.append(arena, val);
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "access-control-allow-headers")) {
            var iter = std.mem.tokenizeAny(u8, h.value, ", ");
            while (iter.next()) |val| {
                try res_store.res_headers.append(arena, val);
            }
        }
    }

    return passesCors(
        ctx.from_origin,
        ctx.unsafe_headers.items,
        ctx.original_method,
        ctx.held != null,
        ctx.credentials,
        res_store,
    );
}

fn passesCors(
    from_origin: []const u8,
    req_extra_headers: [][]const u8,
    original_method: []const u8,
    preflight: bool,
    credentials: bool,
    store: HeaderStore,
) bool {
    if (store.res_origin == null) {
        return false;
    }

    const origin_wildcard: bool = std.mem.eql(u8, store.res_origin.?, "*");
    const origin_match = std.mem.eql(u8, store.res_origin.?, from_origin);

    if (!origin_wildcard and !origin_match) {
        return false;
    }

    if (!preflight) {
        // non-preflight:
        // no wildcards if credentials
        return !credentials or (store.res_credentials and !origin_wildcard);
    }
    // this is a preflight request;
    // mandatory: methods & headers, ~credentials.
    // optional: max-age
    var method_wildcard = false;
    var method_match = false;
    for (store.res_methods.items) |h| {
        if (std.mem.eql(u8, h, original_method)) {
            method_match = true;
        } else if (std.mem.eql(u8, h, "*")) {
            method_wildcard = true;
        }
    }

    var headers_wildcard = false;
    const headers_match = match: {
        for (req_extra_headers) |req_header| {
            for (store.res_headers.items) |h| {
                if (std.mem.eql(u8, h, "*")) {
                    headers_wildcard = true;
                    continue;
                } else if (std.mem.eql(u8, h, req_header)) {
                    break;
                }
            } else break :match false;
        } else break :match true;
    };

    // results:
    // no wildcards if credentials
    if (credentials) {
        if (store.res_credentials and
            !(origin_wildcard or method_wildcard or headers_wildcard) and
            (origin_match and method_match and headers_match))
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
        if (std.ascii.isHex(byte) or
            std.mem.containsAtLeastScalar(u8, " *,-.;=", 1, byte))
        {
            break true;
        }
    } else false;
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
    const content_type = it.next() orelse return true;
    return for (safe_content_types) |sct| {
        if (std.ascii.eqlIgnoreCase(sct, content_type)) break true;
    } else false;
}

// https://fetch.spec.whatwg.org/#simple-range-header-value
fn safeRange(range: []const u8) bool {
    if (!std.mem.startsWith(u8, range, "bytes")) return false;
    if (std.mem.containsAtLeastScalar(u8, range[5..], 1, ',')) return false;

    var rem = range[5..];
    var pos: usize = 0;

    while (std.ascii.isWhitespace(range[pos])) {
        pos += 1;
    }
    if (rem[pos] != '=') return false;
    pos += 1;

    while (std.ascii.isWhitespace(range[pos])) {
        pos += 1;
    }
    rem = rem[pos..];
    pos = 0;

    while (std.ascii.isDigit(rem[pos])) {
        pos += 1;
    }

    const range_start = std.fmt.parseInt(u32, rem[0..pos], 10) catch null;

    while (std.ascii.isWhitespace(range[pos])) {
        pos += 1;
    }
    if (rem[pos] != '-') return false;
    pos += 1;

    while (std.ascii.isWhitespace(range[pos])) {
        pos += 1;
    }
    rem = rem[pos..];
    pos = 0;

    while (std.ascii.isDigit(rem[pos])) {
        pos += 1;
    }

    const range_end = std.fmt.parseInt(u32, rem[0..pos], 10) catch null;

    if (pos < range.len) return false;
    if (range_start == null and range_end == null) return false;

    return true;
}

pub const CorsMode = enum {
    same_origin,
    cross_site,
    none,
};

const HeaderStore = struct {
    res_origin: ?[]const u8 = null,
    res_methods: std.ArrayList([]const u8) = .empty,
    res_headers: std.ArrayList([]const u8) = .empty,
    res_credentials: bool = false,
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

test "safe-range" {
    // safe
    // "bytes=0-499"
    // "bytes=100-"
    // "bytes=-500"
    // "bytes=0-0"

    // unsafe
    // "bytes=0-100, 200-300"
    // "bytes=100-200, 500-600"
    // "bits=0-1024"
    // "items=0-10"
    // "bytes=0-100-200"
    // "0-100"
    // "bytes=0-100 " // trailing space
}

test "safe-content-type" {}
test "safe-language-value" {}
test "safe-header-bytes" {}

const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const HttpClient = @import("../browser/HttpClient.zig");
const Response = HttpClient.Response;
const CorsContext = @import("./layer/CorsLayer.zig").CorsContext;

/// determine if a request is simple or not.
/// if not, any unsafe headers will be stored in the context.
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS#simple_requests
pub fn determineSimpleRequest(ctx: *CorsContext, req: *const HttpClient.Request) !bool {
    const arena = ctx.arena;

    var header_iter = req.headers.iterator();
    outer: while (header_iter.next()) |h| {
        // safe headers are case-insensitive
        if (std.ascii.startsWithIgnoreCase(h.name, "sec-") or
            std.ascii.startsWithIgnoreCase(h.name, "proxy-"))
        {
            continue;
        }

        for (safe_headers) |a_h| {
            if (std.ascii.eqlIgnoreCase(h.name, a_h)) {
                continue :outer;
            }
        }

        // dupe it since adding headers can invalidate existing pointers
        try ctx.extra_headers.append(arena, try arena.dupe(u8, h.name));
    }

    return ctx.extra_headers.items.len == 0 and
        switch (req.method) {
            .GET, .HEAD, .POST => true,
            else => false,
        };
}

/// dertermine if a response passes CORS checks based on an existing Context
pub fn responsePassesCors(ctx: *CorsContext, response: Response) !bool {
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
        ctx.extra_headers.items,
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
        if (credentials) {
            if (store.res_credentials and !origin_wildcard) {
                return true;
            }
        } else return true;
    } else {
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
    }

    return false;
}

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
    // FIXME: separate for further checks:
    // - https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_request_header#additional_restrictions
    // - https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header
    "accept",
    "accept-language",
    "content-language",
    "content-type",
    "range",
    "x-http-method",
    "x-http-method-override",
    "x-method-override",
};

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

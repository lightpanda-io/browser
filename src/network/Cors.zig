const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const HttpClient = @import("../browser/HttpClient.zig");
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
    // TODO: separate for further checks:
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

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
        if (std.ascii.startsWithIgnoreCase(h.name, "SEC-") or
            std.ascii.startsWithIgnoreCase(h.name, "PROXY-"))
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
    "ACCEPT-CHARSET",
    "ACCESS-CONTROL-REQUEST-HEADERS",
    "ACCESS-CONTROL-REQUEST-METHOD",
    "ACCEPT-ENCODING",
    "CONNECTION",
    "CONTENT-LENGTH",
    "COOKIE",
    "DATE",
    "DNT",
    "EXPECT",
    "HOST",
    "KEEP-ALIVE",
    "ORIGIN",
    "REFERER",
    "SET-COOKIE",
    "TE",
    "TRAILER",
    "TRANSFER-ENCODING",
    "UPGRADE",
    "USER-AGENT",
    "VIA",
    // TODO: separate for further checks:
    // - https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_request_header#additional_restrictions
    // - https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header
    "ACCEPT",
    "ACCEPT-LANGUAGE",
    "CONTENT-LANGUAGE",
    "CONTENT-TYPE",
    "RANGE",
    "X-HTTP-METHOD",
    "X-HTTP-METHOD-OVERRIDE",
    "X-METHOD-OVERRIDE",
};

pub const CorsMode = enum {
    same_origin,
    cross_site,
    none,
};

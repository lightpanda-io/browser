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
const lp = @import("lightpanda");

const CDP = @import("../CDP.zig");
const URL = @import("../../../browser/URL.zig");
const Cookie = @import("../../../browser/webapi/storage/storage.zig").Cookie;

const log = lp.log;
const Allocator = std.mem.Allocator;
const CookieJar = Cookie.Jar;
pub const PreparedUri = Cookie.PreparedUri;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        clearCookies,
        setCookies,
        getCookies,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .clearCookies => return clearCookies(cmd),
        .getCookies => return getCookies(cmd),
        .setCookies => return setCookies(cmd),
    }
}

const BrowserContextParam = struct { browserContextId: ?[]const u8 = null };

fn clearCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(BrowserContextParam)) orelse BrowserContextParam{};

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    bc.session.cookie_jar.clearRetainingCapacity();

    return cmd.sendResult(null, .{});
}

fn getCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(BrowserContextParam)) orelse BrowserContextParam{};

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }
    bc.session.cookie_jar.removeExpired(null);
    const writer = CookieWriter{ .cookies = bc.session.cookie_jar.cookies.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn setCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        cookies: []const CdpCookie,
        browserContextId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    _ = try setCdpCookies(&bc.session.cookie_jar, params.cookies);

    try cmd.sendResult(null, .{});
}

const CookiePriority = enum {
    Low,
    Medium,
    High,
};
const CookieSourceScheme = enum {
    Unset,
    NonSecure,
    Secure,
};

pub const CookiePartitionKey = struct {
    topLevelSite: []const u8,
    hasCrossSiteAncestor: bool,
};

pub const CdpCookie = struct {
    name: []const u8,
    value: []const u8,
    url: ?[:0]const u8 = null,
    domain: ?[]const u8 = null,
    path: ?[:0]const u8 = null,
    secure: ?bool = null, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    httpOnly: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    sameSite: ?[]const u8 = null, // Strict, Lax or None; anything else is unspecified, see parseSameSite
    expires: ?f64 = null, // -1? says google
    priority: CookiePriority = .Medium, // default: https://datatracker.ietf.org/doc/html/draft-west-cookie-priority-00
    sameParty: ?bool = null,
    sourceScheme: ?CookieSourceScheme = null,
    // sourcePort: Temporary ability and it will be removed from CDP
    partitionKey: ?CookiePartitionKey = null,
};

/// Network.setCookie, Network.setCookies and Storage.setCookies. Every
/// cookie is built before any is added: an entry `buildCdpCookie` refuses
/// in the middle of a batch leaves the jar untouched, as Chrome's
/// SetCookies does. `Jar.add`'s own checks can still stop a batch part-way.
/// Returns how many cookies were stored.
pub fn setCdpCookies(cookie_jar: *CookieJar, params: []const CdpCookie) !usize {
    var cookies = try std.ArrayList(Cookie).initCapacity(cookie_jar.allocator, params.len);
    defer cookies.deinit(cookie_jar.allocator);

    // A cookie handed to `Jar.add` is its to free, stored or not; the ones
    // we still hold when something fails are ours.
    var added: usize = 0;
    errdefer for (cookies.items[added..]) |*cookie| cookie.deinit();

    for (params) |param| {
        cookies.appendAssumeCapacity(try buildCdpCookie(cookie_jar.allocator, param));
    }

    const now = lp.datetime.timestamp(.real);
    var stored: usize = 0;
    for (cookies.items) |cookie| {
        added += 1;
        if (cookie.same_site == .none and !cookie.secure) {
            // Chrome's store refuses SameSite=None without Secure, as
            // `Cookie.parse` does for a Set-Cookie.
            cookie.deinit();
            continue;
        }
        try cookie_jar.add(cookie, now, true);
        stored += 1;
    }
    return stored;
}

fn buildCdpCookie(allocator: Allocator, param: CdpCookie) !Cookie {
    // Silently ignore partitionKey since we don't support partitioned cookies (CHIPS).
    // This allows Puppeteer's frame.setCookie() to work, which may send cookies with
    // partitionKey as part of its cookie-setting workflow.
    if (param.partitionKey != null) {
        log.debug(.not_implemented, "partition key", .{ .src = "buildCdpCookie" });
    }
    // Still reject unsupported features
    if (param.priority != .Medium or param.sameParty != null or param.sourceScheme != null) {
        return error.NotImplemented;
    }

    // NOTE: The param.url can affect the default domain, (NOT path), secure, source port, and source scheme.
    const secure = if (param.secure) |s| s else if (param.url) |url| URL.isSecure(url) else false;

    const same_site = parseSameSite(param.sameSite);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Allocate before the struct literal copies `arena` into the result.
    const name = try a.dupe(u8, param.name);
    const value = try a.dupe(u8, param.value);
    const domain = try Cookie.parseDomain(a, param.url, param.domain);
    const path = if (param.path == null) "/" else try Cookie.parsePath(a, null, param.path);

    return .{
        .arena = arena,
        .name = name,
        .value = value,
        .path = path,
        .domain = domain,
        .expires = param.expires,
        .secure = secure,
        .http_only = param.httpOnly,
        .same_site = same_site orelse .lax,
        .same_site_default = same_site == null,
    };
}

// Chrome's MakeCookieFromProtocolValues takes CDP's exact Strict, Lax or
// None. Anything else, "lax" included, or no value leaves the cookie
// unspecified: Lax by default with the Lax-allowing-unsafe window, like a
// Set-Cookie without the attribute (`Cookie.parse`, which, unlike CDP, is
// case-insensitive).
fn parseSameSite(value: ?[]const u8) ?Cookie.SameSite {
    const same_site = std.meta.stringToEnum(enum { Strict, Lax, None }, value orelse return null) orelse return null;
    return switch (same_site) {
        .Strict => .strict,
        .Lax => .lax,
        .None => .none,
    };
}

pub const CookieWriter = struct {
    cookies: []const Cookie,
    urls: ?[]const PreparedUri = null,

    pub fn jsonStringify(self: *const CookieWriter, w: anytype) !void {
        self.writeCookies(w) catch |err| {
            // The only error our jsonStringify method can return is @TypeOf(w).Error.
            log.err(.cdp, "json stringify", .{ .err = err });
            return error.WriteFailed;
        };
    }

    fn writeCookies(self: CookieWriter, w: anytype) !void {
        try w.beginArray();
        if (self.urls) |urls| {
            for (self.cookies) |*cookie| {
                for (urls) |*url| {
                    if (cookie.appliesTo(url, .{ .same_site = true, .is_http = true, .kind = .navigation })) { // TBD same_site, should we compare to the pages url?
                        try writeCookie(cookie, w);
                        break;
                    }
                }
            }
        } else {
            for (self.cookies) |*cookie| {
                try writeCookie(cookie, w);
            }
        }
        try w.endArray();
    }
};
fn writeCookie(cookie: *const Cookie, w: anytype) !void {
    try w.beginObject();
    {
        try w.objectField("name");
        try w.write(cookie.name);

        try w.objectField("value");
        try w.write(cookie.value);

        try w.objectField("domain");
        try w.write(cookie.domain); // Should we hide a leading dot?

        try w.objectField("path");
        try w.write(cookie.path);

        try w.objectField("expires");
        try w.write(cookie.expires orelse -1);

        try w.objectField("size");
        try w.write(cookie.name.len + cookie.value.len);

        try w.objectField("httpOnly");
        try w.write(cookie.http_only);

        try w.objectField("secure");
        try w.write(cookie.secure);

        try w.objectField("session");
        try w.write(cookie.expires == null);

        // Chrome's BuildCookie reports an explicit Strict/Lax/None only; a
        // cookie that is Lax by default has no sameSite.
        if (!cookie.same_site_default) {
            try w.objectField("sameSite");
            switch (cookie.same_site) {
                .none => try w.write("None"),
                .lax => try w.write("Lax"),
                .strict => try w.write("Strict"),
            }
        }

        // TODO experimentals
    }
    try w.endObject();
}

const testing = @import("../testing.zig");

test "cdp.Storage: cookies" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-S" });

    // Initially empty
    try ctx.processMessage(.{
        .id = 3,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 3 });

    // Has cookies after setting them
    try ctx.processMessage(.{
        .id = 4,
        .method = "Storage.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "test", .value = "value", .domain = "example.com", .path = "/mango" },
                .{ .name = "test2", .value = "value2", .url = "https://car.example.com/pancakes" },
                .{ .name = "test3", .value = "value3", .domain = "gov.uk" },
            },
            .browserContextId = "BID-S",
        },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "test", .value = "value", .domain = ".example.com", .path = "/mango", .size = 9 },
            .{ .name = "test2", .value = "value2", .domain = "car.example.com", .path = "/", .size = 11, .secure = true }, // No Pancakes!
            .{ .name = "test3", .value = "value3", .domain = "gov.uk", .path = "/", .size = 11 },
        },
    }, .{ .id = 5 });

    // Empty after clearing cookies
    try ctx.processMessage(.{
        .id = 6,
        .method = "Storage.clearCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(null, .{ .id = 6 });
    try ctx.processMessage(.{
        .id = 7,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 7 });
}

pub const ResCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    expires: f64 = -1,
    size: usize = 0,
    httpOnly: bool = false,
    secure: bool = false,
    sameSite: ?[]const u8 = null,
};

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

const log = @import("../../log.zig");
const Cookie = @import("../../browser/storage/storage.zig").Cookie;
const CookieJar = @import("../../browser/storage/storage.zig").CookieJar;
pub const PreparedUri = @import("../../browser/storage/cookie.zig").PreparedUri;

pub fn processMessage(cmd: anytype) !void {
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

fn clearCookies(cmd: anytype) !void {
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

fn getCookies(cmd: anytype) !void {
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

fn setCookies(cmd: anytype) !void {
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

    for (params.cookies) |param| {
        try setCdpCookie(&bc.session.cookie_jar, param);
    }

    try cmd.sendResult(null, .{});
}

pub const SameSite = enum {
    Strict,
    Lax,
    None,
};
pub const CookiePriority = enum {
    Low,
    Medium,
    High,
};
pub const CookieSourceScheme = enum {
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
    url: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: ?bool = null, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    httpOnly: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    sameSite: SameSite = .None, // default: https://datatracker.ietf.org/doc/html/draft-west-first-party-cookies
    expires: ?f64 = null, // -1? says google
    priority: CookiePriority = .Medium, // default: https://datatracker.ietf.org/doc/html/draft-west-cookie-priority-00
    sameParty: ?bool = null,
    sourceScheme: ?CookieSourceScheme = null,
    // sourcePort: Temporary ability and it will be removed from CDP
    partitionKey: ?CookiePartitionKey = null,
};

pub fn setCdpCookie(cookie_jar: *CookieJar, param: CdpCookie) !void {
    if (param.priority != .Medium or param.sameParty != null or param.sourceScheme != null or param.partitionKey != null) {
        return error.NotImplemented;
    }

    var arena = std.heap.ArenaAllocator.init(cookie_jar.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // NOTE: The param.url can affect the default domain, (NOT path), secure, source port, and source scheme.
    const uri = if (param.url) |url| std.Uri.parse(url) catch return error.InvalidParams else null;
    const uri_ptr = if (uri) |*u| u else null;
    const domain = try Cookie.parseDomain(a, uri_ptr, param.domain);
    const path = if (param.path == null) "/" else try Cookie.parsePath(a, null, param.path);

    const secure = if (param.secure) |s| s else if (uri) |uri_| std.mem.eql(u8, uri_.scheme, "https") else false;

    const cookie = Cookie{
        .arena = arena,
        .name = try a.dupe(u8, param.name),
        .value = try a.dupe(u8, param.value),
        .path = path,
        .domain = domain,
        .expires = param.expires,
        .secure = secure,
        .http_only = param.httpOnly,
        .same_site = switch (param.sameSite) {
            .Strict => .strict,
            .Lax => .lax,
            .None => .none,
        },
    };
    try cookie_jar.add(cookie, std.time.timestamp());
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
                    if (cookie.appliesTo(url, true, true, true)) { // TBD same_site, should we compare to the pages url?
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
pub fn writeCookie(cookie: *const Cookie, w: anytype) !void {
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

        // TODO size

        try w.objectField("httpOnly");
        try w.write(cookie.http_only);

        try w.objectField("secure");
        try w.write(cookie.secure);

        try w.objectField("session");
        try w.write(cookie.expires == null);

        try w.objectField("sameSite");
        switch (cookie.same_site) {
            .none => try w.write("None"),
            .lax => try w.write("Lax"),
            .strict => try w.write("Strict"),
        }

        // TODO experimentals
    }
    try w.endObject();
}

const testing = @import("../testing.zig");

test "cdp.Storage: cookies" {
    var ctx = testing.context();
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
            .{ .name = "test", .value = "value", .domain = ".example.com", .path = "/mango" },
            .{ .name = "test2", .value = "value2", .domain = "car.example.com", .path = "/", .secure = true }, // No Pancakes!
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
    httpOnly: bool = false,
    secure: bool = false,
    sameSite: []const u8 = "None",
};

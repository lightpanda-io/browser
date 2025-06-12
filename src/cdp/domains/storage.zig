// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const Cookie = @import("../../browser/storage/storage.zig").Cookie;
const CookieJar = @import("../../browser/storage/storage.zig").CookieJar;
pub const PreparedUri = @import("../../browser/storage/cookie.zig").PreparedUri;
pub const toLower = @import("../../browser/storage/cookie.zig").toLower;

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

fn clearCookies(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        browserContextId: ?[]const u8,
    })) orelse return error.InvalidParams;

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
    const params = (try cmd.params(struct {
        browserContextId: ?[]const u8,
    })) orelse return error.InvalidParams;

    if (params.browserContextId) |browser_context_id| {
        if (std.mem.eql(u8, browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }
    bc.session.cookie_jar.removeExpired(null);
    const cookies = CookieWriter{ .cookies = bc.session.cookie_jar.cookies.items };
    try cmd.sendResult(.{ .cookies = cookies }, .{});
}

fn setCookies(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        cookies: []const CdpCookie,
        browserContextId: ?[]const u8,
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
    secure: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    httpOnly: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
    sameSite: SameSite = .None, // default: https://datatracker.ietf.org/doc/html/draft-west-first-party-cookies
    expires: ?i64 = null, // -1? says google
    priority: CookiePriority = .Medium, // default: https://datatracker.ietf.org/doc/html/draft-west-cookie-priority-00
    sameParty: ?bool = null,
    sourceScheme: ?CookieSourceScheme = null,
    // sourcePort: Temporary ability and it will be removed from CDP
    partitionKey: ?CookiePartitionKey = null,
};

pub fn setCdpCookie(cookie_jar: *CookieJar, param: CdpCookie) !void {
    if (param.priority != .Medium or param.sameParty != null or param.sourceScheme != null or param.partitionKey != null) {
        return error.NotYetImplementedParams;
    }
    if (param.name.len == 0) return error.InvalidParams;
    if (param.value.len == 0) return error.InvalidParams;

    var arena = std.heap.ArenaAllocator.init(cookie_jar.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // NOTE: The param.url can affect the default domain, path, source port, and source scheme.
    const uri = if (param.url) |url| std.Uri.parse(url) catch return error.InvalidParams else null;
    const domain = try percentEncodedDomainOrHost(a, uri, param.domain) orelse return error.InvalidParams;

    const cookie = Cookie{
        .arena = arena,
        .name = try a.dupe(u8, param.name),
        .value = try a.dupe(u8, param.value),
        .path = if (param.path) |path| try a.dupe(u8, path) else "/", // Chrome does not actually take the path from the url and just defaults to "/".
        .domain = domain,
        .expires = param.expires,
        .secure = param.secure,
        .http_only = param.httpOnly,
        .same_site = switch (param.sameSite) {
            .Strict => .strict,
            .Lax => .lax,
            .None => .none,
        },
    };
    try cookie_jar.add(cookie, std.time.timestamp());
}

// Note: Chrome does not apply rules like removing a leading `.` from the domain.
pub fn percentEncodedDomainOrHost(allocator: Allocator, default_url: ?std.Uri, domain: ?[]const u8) !?[]const u8 {
    if (domain) |domain_| {
        const output = try allocator.dupe(u8, domain_);
        return toLower(output);
    } else if (default_url) |url| {
        const host = url.host orelse return error.InvalidParams;
        const output = try percentEncode(allocator, host, isHostChar); // TODO remove subdomains
        return toLower(output);
    } else return null;
}

pub fn percentEncode(arena: Allocator, component: std.Uri.Component, comptime isValidChar: fn (u8) bool) ![]u8 {
    switch (component) {
        .raw => |str| {
            var list = std.ArrayList(u8).init(arena);
            try list.ensureTotalCapacity(str.len); // Expect no precents needed
            try std.Uri.Component.percentEncode(list.writer(), str, isValidChar);
            return list.items; // @memory retains memory used before growing
        },
        .percent_encoded => |str| {
            return try arena.dupe(u8, str);
        },
    }
}

pub fn isHostChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        ':' => true,
        '[', ']' => true,
        else => false,
    };
}

pub fn isPathChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        '/', ':', '@' => true,
        else => false,
    };
}

pub const CookieWriter = struct {
    cookies: []const Cookie,
    urls: ?[]const PreparedUri = null,

    pub fn jsonStringify(self: *const CookieWriter, w: anytype) !void {
        self.writeCookies(w) catch |err| {
            // The only error our jsonStringify method can return is @TypeOf(w).Error.
            log.err(.cdp, "json stringify", .{ .err = err });
            return error.OutOfMemory;
        };
    }

    fn writeCookies(self: CookieWriter, w: anytype) !void {
        try w.beginArray();
        if (self.urls) |urls| {
            for (self.cookies) |*cookie| {
                for (urls) |*url| {
                    if (cookie.appliesTo(url, false, false)) { // TBD same_site, should we compare to the pages url?
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
        try w.write(cookie.domain);

        try w.objectField("path");
        try w.write(cookie.path);

        try w.objectField("expires");
        try w.write(cookie.expires orelse -1);

        // TODO size

        try w.objectField("httpOnly");
        try w.write(cookie.http_only);

        try w.objectField("secure");
        try w.write(cookie.secure);

        // TODO session

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

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

const URL = @import("../../URL.zig");
const DateTime = @import("../../../datetime.zig").DateTime;
const Notification = @import("../../../Notification.zig");
const public_suffix_list = @import("../../../data/public_suffix_list.zig").lookup;
const repeat = @import("../../../string.zig").repeat;

const log = lp.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Cookie = @This();

const max_cookie_size = 4 * 1024;
const max_cookie_header_size = 8 * 1024;

// Chrome's limits (net/cookies/cookie_monster.cc): past `max_*` cookies in
// the jar or for one site, `purge_*` are evicted.
const max_cookies = 3300;
const purge_cookies = 300;
const max_domain_cookies = 180;
const purge_domain_cookies = 30;

arena: ArenaAllocator,
name: []const u8,
value: []const u8,
domain: []const u8,
path: []const u8,
expires: ?f64,
secure: bool = false,
http_only: bool = false,
same_site: SameSite = .none,
// True when no SameSite was given, by the Set-Cookie header, the CDP
// driver or the cookie file: the cookie is Lax through the "Default"
// enforcement mode (RFC 6265bis 5.6.7.1), which makes it eligible for
// "Lax-allowing-unsafe", see appliesTo.
same_site_default: bool = false,
// Seconds since the epoch. Set by Jar.add, and inherited from the cookie it
// replaces, so a site re-setting a cookie on every response can't keep it
// "recently created" forever.
creation_time: u64 = 0,
// Seconds since the epoch. Set by Jar.add and updated by forRequest.
last_access_time: u64 = 0,

pub const SameSite = enum {
    strict,
    lax,
    none,

    // The SameSite a Set-Cookie attribute or a cookie file spells out:
    // Strict, Lax or None, case-insensitive (RFC 6265bis 5.6.7; the file
    // has both saveToFile's lowercase tags and CDP's casing). Anything
    // else, including no value at all, "unspecified" and the
    // chrome.cookies "no_restriction", is not a value: the cookie is
    // unspecified and Lax by default, see `same_site_default`. CDP takes
    // Chrome's exact spelling only, see `parseSameSite` in
    // server/cdp/domains/storage.zig.
    pub fn parse(value: ?[]const u8) ?SameSite {
        const raw = value orelse return null;
        if (std.ascii.eqlIgnoreCase(raw, "strict")) return .strict;
        if (std.ascii.eqlIgnoreCase(raw, "lax")) return .lax;
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        return null;
    }
};

// How the request carrying the Cookie header reaches its target. Only a
// cross-site request cares; it's what unlocks SameSite=Lax cookies.
pub const RequestKind = enum(u2) {
    // A sub-resource (image, script, fetch...), a sub-frame's document, or
    // a non-HTTP retrieval (document.cookie).
    subresource,
    // A top-level navigation using a "safe" method (GET, HEAD, OPTIONS).
    navigation,
    // A top-level navigation using an unsafe method, e.g. a POSTed form.
    unsafe_navigation,
};

const lax_allowing_unsafe_max_age = 2 * 60;

pub fn deinit(self: *const Cookie) void {
    self.arena.deinit();
}

// There's https://datatracker.ietf.org/doc/html/rfc6265 but browsers are
// far less strict. I only found 2 cases where browsers will reject a cookie:
//   - a byte 0...31 and 127...255 anywhere in the cookie (the HTTP header
//     parser might take care of this already)
//   - any shenanigans with the domain attribute - it has to be the current
//     domain or one of higher order, excluding TLD.
// Anything else, will turn into a cookie.
// Single value? That's a cookie with an empty name and a value
// Key or Values with characters the RFC says aren't allowed? Allowed! (
//   (as long as the characters are 32...126)
// Invalid attributes? Ignored.
// Invalid attribute values? Ignore.
// Duplicate attributes - use the last valid
// Value-less attributes with a value? Ignore the value
pub fn parse(allocator: Allocator, url: [:0]const u8, str: []const u8) !Cookie {
    if (str.len > max_cookie_header_size) {
        return error.CookieHeaderSizeExceeded;
    }

    try validateCookieString(str);

    const cookie_name, const cookie_value, const rest = parseNameValue(str) catch {
        return error.InvalidNameValue;
    };

    if (cookie_name.len == 0 and hasHiddenPrefix(cookie_value)) {
        return error.InvalidNameValue;
    }

    var scrap: [8]u8 = undefined;

    var path: ?[]const u8 = null;
    var domain: ?[]const u8 = null;
    var secure: ?bool = null;
    var max_age: ?i64 = null;
    var http_only: ?bool = null;
    var expires: ?[]const u8 = null;
    var same_site: ?Cookie.SameSite = null;

    var it = std.mem.splitScalar(u8, rest, ';');
    while (it.next()) |attribute| {
        const sep = std.mem.findScalarPos(u8, attribute, 0, '=') orelse attribute.len;
        const key_string = trim(attribute[0..sep]);

        if (key_string.len > scrap.len) {
            // not valid, ignore
            continue;
        }

        const key = std.meta.stringToEnum(enum {
            path,
            domain,
            secure,
            @"max-age",
            expires,
            httponly,
            samesite,
        }, std.ascii.lowerString(&scrap, key_string)) orelse continue;

        const value = if (sep == attribute.len) "" else trim(attribute[sep + 1 ..]);
        switch (key) {
            .path => path = value,
            .domain => domain = value,
            .secure => secure = true,
            .@"max-age" => max_age = std.fmt.parseInt(i64, value, 10) catch continue,
            .expires => expires = value,
            .httponly => http_only = true,
            .samesite => same_site = SameSite.parse(value) orelse continue,
        }
    }

    if (same_site == .none and secure == null) {
        return error.InsecureSameSite;
    }

    if (prefixOf(cookie_name)) |prefix| {
        const secure_origin = secure != null and URL.isPotentiallyTrustworthy(url);
        if (!prefix.allows(secure_origin, http_only orelse false, if (domain) |d| d.len > 0 else false, path orelse "")) {
            return error.InvalidPrefixedCookie;
        }
    }

    if (cookie_value.len > max_cookie_size) {
        return error.CookieSizeExceeded;
    }

    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const owned_name = try aa.dupe(u8, cookie_name);
    const owned_value = try aa.dupe(u8, cookie_value);
    const owned_path = try parsePath(aa, url, path);
    const owned_domain = try parseDomain(aa, url, domain);

    var normalized_expires: ?f64 = null;
    if (max_age) |ma| {
        normalized_expires = @as(f64, @floatFromInt(lp.datetime.timestamp(.real))) + @as(f64, @floatFromInt(ma));
    } else {
        // max age takes priority over expires
        if (expires) |expires_| {
            var exp_dt = DateTime.parse(expires_, .rfc822) catch null;
            if (exp_dt == null) {
                const dashed = expires_.len > 11 and expires_[7] == '-' and expires_[11] == '-';
                const utc = std.ascii.endsWithIgnoreCase(expires_, " utc");
                if (dashed or utc) {
                    // Replace dashes and a "UTC" zone, and try again
                    const output = try aa.dupe(u8, expires_);
                    if (dashed) {
                        output[7] = ' ';
                        output[11] = ' ';
                    }
                    if (utc) {
                        @memcpy(output[output.len - 3 ..], "GMT");
                    }
                    exp_dt = DateTime.parse(output, .rfc822) catch null;
                }
            }
            if (exp_dt) |dt| {
                normalized_expires = @floatFromInt(dt.unix(.seconds));
            } else {
                // Algolia, for example, will call document.setCookie with
                // an expired value which is literally 'Invalid Date'
                // (it's trying to do something like: `new Date() + undefined`).
                log.debug(.frame, "cookie expires date", .{ .date = expires_ });
            }
        }
    }

    return .{
        .arena = arena,
        .name = owned_name,
        .value = owned_value,
        .path = owned_path,
        .same_site = same_site orelse .lax,
        .same_site_default = same_site == null,
        .secure = secure orelse false,
        .http_only = http_only orelse false,
        .domain = owned_domain,
        .expires = normalized_expires,
    };
}

pub const Fields = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?f64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};

/// A cookie a protocol (CDP, BiDi, WebDriver) sets field by field rather than
/// through a Set-Cookie line, with the character and size checks of Chrome's
/// CanonicalCookie::CreateSanitizedCookie, which both its CDP and its BiDi go
/// through.
pub fn fromFields(allocator: Allocator, url: ?[:0]const u8, fields: Fields) error{ OutOfMemory, InvalidCookie, InvalidDomain }!Cookie {
    if ((fields.name.len == 0 and (fields.value.len == 0 or hasHiddenPrefix(fields.value))) or
        fields.name.len + fields.value.len > max_cookie_size or
        !isValidField(fields.name, ";=") or
        !isValidField(fields.value, ";"))
    {
        return error.InvalidCookie;
    }
    if (fields.path) |path| {
        // Chrome URL-encodes any other control character in a path.
        if (std.mem.findAny(u8, path, ";\r\n\x00") != null or hasOuterWhitespace(path)) {
            return error.InvalidCookie;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Allocate before the struct literal copies `arena` into the result.
    const name = try a.dupe(u8, fields.name);
    const value = try a.dupe(u8, fields.value);
    const domain = parseDomain(a, url, fields.domain) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDomain,
    };
    // Without a url there's nothing to encode: only the dupe can fail.
    const path = parsePath(a, null, fields.path) catch return error.OutOfMemory;

    if (prefixOf(fields.name)) |prefix| {
        if (!prefix.allows(fields.secure, fields.http_only, fields.domain != null, path)) {
            return error.InvalidCookie;
        }
    }

    return .{
        .arena = arena,
        .name = name,
        .value = value,
        .domain = domain,
        .path = path,
        .expires = fields.expires,
        .secure = fields.secure,
        .http_only = fields.http_only,
        .same_site = fields.same_site orelse .lax,
        .same_site_default = fields.same_site == null,
    };
}

pub const Prefix = struct {
    text: []const u8,
    http: bool = false,
    host: bool = false,

    /// Chrome's IsCookiePrefixValid. `secure` only when a Secure cookie could
    /// be set from where this one comes from.
    pub fn allows(self: Prefix, secure: bool, http_only: bool, has_domain: bool, path: []const u8) bool {
        return secure and
            (!self.http or http_only) and
            (!self.host or (!has_domain and std.mem.eql(u8, path, "/")));
    }
};

// Chrome's kPrefixes, matched in this order and case-insensitively, so that
// "__HoSt-" can't sidestep the rules.
// https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
const prefixes = [_]Prefix{
    .{ .text = "__Secure-" },
    .{ .text = "__Host-Http-", .http = true, .host = true },
    .{ .text = "__Http-", .http = true },
    .{ .text = "__Host-", .host = true },
};

pub fn prefixOf(name: []const u8) ?Prefix {
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(name, prefix.text)) {
            return prefix;
        }
    }
    return null;
}

/// Chrome's HasHiddenPrefixName: a nameless cookie's value would read as a
/// prefixed name in the Cookie header.
pub fn hasHiddenPrefix(value: []const u8) bool {
    return prefixOf(std.mem.trimStart(u8, value, " \t")) != null;
}

// Chrome's IsValidCookieName/Value: no control character (tab included) and
// none of `separators`, but bytes above 0x7F are fine.
fn isValidField(field: []const u8, comptime separators: []const u8) bool {
    if (hasOuterWhitespace(field)) {
        return false;
    }
    for (field) |c| {
        if (std.ascii.isControl(c) or std.mem.findScalar(u8, separators, c) != null) {
            return false;
        }
    }
    return true;
}

// Chrome's ParseTokenString/ParseValueString trim it, and refuse a field
// that doesn't survive the parse unchanged.
fn hasOuterWhitespace(field: []const u8) bool {
    return std.mem.trim(u8, field, " \t").len != field.len;
}

const ValidateCookieError = error{ Empty, InvalidByteSequence };

/// Returns an error if cookie str length is 0
/// or contains characters outside of the ascii range 32...126.
/// Tab (0x09) is also allowed, matching browser behavior and WPT.
fn validateCookieString(str: []const u8) ValidateCookieError!void {
    if (str.len == 0) {
        return error.Empty;
    }

    const vec_size_suggestion = std.simd.suggestVectorLength(u8);
    var offset: usize = 0;

    // Fast path if possible.
    if (comptime vec_size_suggestion) |size| {
        while (str.len - offset >= size) : (offset += size) {
            const Vec = @Vector(size, u8);
            const tab: Vec = @splat(9);
            const space: Vec = @splat(32);
            const tilde: Vec = @splat(126);
            const chunk: Vec = str[offset..][0..size].*;

            // Invalid if (c < 32 AND c != 9) OR c > 126. Tab is the one
            // sub-space byte we allow through (per browser/WPT behavior).
            const is_invalid = ((chunk < space) & (chunk != tab)) | (chunk > tilde);

            // Got match.
            if (@reduce(.Or, is_invalid)) {
                return error.InvalidByteSequence;
            }
        }

        // Means str.len % size == 0; we also know str.len != 0.
        // Cookie is valid.
        if (offset == str.len) {
            return;
        }
    }

    // Either remaining slice or the original if fast path not taken.
    for (str[offset..]) |c| {
        if ((c < 32 and c != 9) or c > 126) {
            return error.InvalidByteSequence;
        }
    }
}

pub fn parsePath(arena: Allocator, url_: ?[:0]const u8, explicit_path: ?[]const u8) ![]const u8 {
    // path attribute value either begins with a '/' or we
    // ignore it and use the "default-path" algorithm
    if (explicit_path) |path| {
        if (path.len > 0 and path[0] == '/') {
            return try arena.dupe(u8, path);
        }
    }

    // default-path
    const url = url_ orelse return "/";
    const url_path = URL.getPathname(url);
    if (url_path.len == 0 or (url_path.len == 1 and url_path[0] == '/')) {
        return "/";
    }

    var owned_path: []const u8 = try percentEncode(arena, url_path, isPathChar);
    const last = std.mem.findScalarLast(u8, owned_path[1..], '/') orelse {
        return "/";
    };
    return try arena.dupe(u8, owned_path[0 .. last + 1]);
}

pub fn parseDomain(arena: Allocator, url_: ?[:0]const u8, explicit_domain: ?[]const u8) ![]const u8 {
    var encoded_host: ?[]const u8 = null;
    if (url_) |url| {
        const host = try percentEncode(arena, URL.getHostname(url), isHostChar);
        _ = toLower(host);
        encoded_host = host;
    }

    if (explicit_domain) |domain| {
        if (domain.len > 0) {
            const no_leading_dot = if (domain[0] == '.') domain[1..] else domain;

            var aw = try std.Io.Writer.Allocating.initCapacity(arena, no_leading_dot.len + 1);
            try aw.writer.writeByte('.');
            try std.Uri.Component.percentEncode(&aw.writer, no_leading_dot, isHostChar);
            const owned_domain = toLower(aw.written());

            if (isIpLiteral(owned_domain[1..]) or (encoded_host != null and isIpLiteral(encoded_host.?))) {
                const host = encoded_host orelse return owned_domain[1..];
                if (std.mem.eql(u8, host, owned_domain[1..])) {
                    return owned_domain[1..];
                }
                return error.InvalidDomain;
            }

            if (std.mem.findScalarPos(u8, owned_domain, 1, '.') == null and std.mem.eql(u8, "localhost", owned_domain[1..]) == false) {
                // can't set a cookie for a TLD
                return error.InvalidDomain;
            }

            if (public_suffix_list(owned_domain[1..])) {
                // we're targetting a domain on the public suffix list. Such a
                // cookie is only allowed on to do this for a host-only domain
                // in order to make sure cookies don't get passed to a different
                // subdomain
                const host = encoded_host orelse return owned_domain[1..];
                if (std.mem.eql(u8, host, owned_domain[1..])) {
                    return owned_domain[1..];
                }
                return error.InvalidDomain;
            }

            if (encoded_host) |host| {
                // The host must match the requested domain exactly or as a
                // proper subdomain. A raw suffix check would incorrectly
                // accept "attackerexample.com" as matching "example.com",
                // letting a lookalike origin overwrite cookies on the victim
                // domain. `owned_domain` always has a leading dot, so
                // endsWith against it enforces the label boundary.
                const exact_match = std.mem.eql(u8, host, owned_domain[1..]);
                const subdomain_match = std.mem.endsWith(u8, host, owned_domain);
                if (exact_match == false and subdomain_match == false) {
                    return error.InvalidDomain;
                }
            }

            return owned_domain;
        }
    }

    if (encoded_host) |host| {
        if (host.len > 0) return host;
    }
    return error.InvalidDomain;
}

fn isIpLiteral(host: []const u8) bool {
    _ = std.Io.net.IpAddress.parseLiteral(host) catch return false;
    return true;
}

pub fn percentEncode(arena: Allocator, part: []const u8, comptime isValidChar: fn (u8) bool) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(arena, part.len);
    try std.Uri.Component.percentEncode(&aw.writer, part, isValidChar);
    return aw.written(); // @memory retains memory used before growing
}

fn isHostChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        ':' => true,
        '[', ']' => true,
        else => false,
    };
}

fn isPathChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        '/', ':', '@' => true,
        else => false,
    };
}

fn parseNameValue(str: []const u8) !struct { []const u8, []const u8, []const u8 } {
    const key_value_end = std.mem.findScalarPos(u8, str, 0, ';') orelse str.len;
    const rest = if (key_value_end == str.len) "" else str[key_value_end + 1 ..];

    const sep = std.mem.findScalarPos(u8, str[0..key_value_end], 0, '=') orelse {
        const value = trim(str[0..key_value_end]);
        if (value.len == 0) {
            return error.Empty;
        }
        return .{ "", value, rest };
    };

    const name = trim(str[0..sep]);
    const value = trim(str[sep + 1 .. key_value_end]);
    return .{ name, value, rest };
}

/// True when `host` would be eligible to receive this cookie based on its
/// `Domain` attribute alone (no path, scheme, or SameSite checks). Leading
/// `.` in `Cookie.domain` extends the match to all subdomains, matching the
/// `Set-Cookie: Domain=` semantics.
pub fn matchesHost(self: *const Cookie, host: []const u8) bool {
    if (self.domain.len == 0) return false;
    if (self.domain[0] == '.') {
        const bare = self.domain[1..];
        if (std.ascii.eqlIgnoreCase(host, bare)) return true;
        if (host.len < self.domain.len) return false;
        return std.ascii.eqlIgnoreCase(host[host.len - self.domain.len ..], self.domain);
    }
    return std.ascii.eqlIgnoreCase(host, self.domain);
}

// RFC 6265bis 5.6.7.2 "Lax-allowing-unsafe": a cookie that never asked for
// Lax (it got it by default) still rides a cross-site top-level POST, as
// long as it was created recently. Compatibility mode for the login flows
// that POST back to the site from an identity provider: without it, the
// session cookie set right before the redirect is dropped on return.
inline fn isLaxAllowingUnsafe(self: *const Cookie, now: u64) bool {
    return self.same_site_default and now -| self.creation_time <= lax_allowing_unsafe_max_age;
}

pub const MatchOpts = struct {
    // Whether the request's "site for cookies" is same-site with the target.
    same_site: bool,
    // An HTTP retrieval (Cookie header), as opposed to document.cookie.
    is_http: bool,
    kind: RequestKind = .subresource,
    // Seconds since the epoch. Only read for a cross-site unsafe navigation and `Jar.forRequest`.
    now: ?u64 = null,
};

pub fn appliesTo(self: *const Cookie, url: *const PreparedUri, opts: MatchOpts) bool {
    if (self.http_only and opts.is_http == false) {
        // http only cookies cannot be accessed from Javascript
        return false;
    }

    if (self.secure and !url.trustworthy) {
        return false;
    }

    if (opts.same_site == false) {
        // If we aren't on the "same site", then the cookie
        // can only be sent if cookie.same_site == .none, or if the
        // request is one the Lax exception covers.
        switch (self.same_site) {
            .strict => return false,
            .lax => switch (opts.kind) {
                .subresource => return false,
                .navigation => {},
                .unsafe_navigation => {
                    const now = opts.now orelse unreachable;
                    if (!self.isLaxAllowingUnsafe(now)) return false;
                },
            },
            .none => {},
        }
    }

    if (!self.matchesHost(url.host)) return false;

    return pathMatches(url.path, self.path);
}

// RFC 6265bis 5.1.4 path-match.
fn pathMatches(request_path: []const u8, cookie_path: []const u8) bool {
    if (std.mem.startsWith(u8, request_path, cookie_path) == false) {
        return false;
    }
    // The paths are equal, or the cookie path is a directory of the
    // request path: /doc/ matches /doc/*, /hello matches /hello/*.
    return request_path.len == cookie_path.len or
        cookie_path[cookie_path.len - 1] == '/' or
        request_path[cookie_path.len] == '/';
}

// RFC 6265bis "site for cookies" of a request's initiator.
pub const SiteForCookies = union(enum) {
    // Matches no site, used for a frame whose ancestor chain contains a cross-site document.
    none,
    // Same-site when the target host is same-site with this URL's host.
    url: [:0]const u8,
};

pub const Jar = struct {
    allocator: Allocator,
    // site => cookie list
    sites: std.StringArrayHashMapUnmanaged(std.ArrayList(Cookie)),
    // Cookies across all sites.
    len: usize,
    // Optional notifier for cookie change events. When set, `add` dispatches
    // `cookie_changed` after a real mutation. Session populates this; the
    // standalone test construction leaves it null.
    notification: ?*Notification = null,

    pub fn init(allocator: Allocator, notification: ?*Notification) Jar {
        return .{
            .len = 0,
            .sites = .empty,
            .allocator = allocator,
            .notification = notification,
        };
    }

    pub fn deinit(self: *Jar) void {
        self.freeSites();
        self.sites.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *Jar) void {
        self.freeSites();
        self.sites.clearRetainingCapacity();
        self.len = 0;
    }

    fn freeSites(self: *Jar) void {
        var it = self.sites.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |c| {
                c.deinit();
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
    }

    /// The only cookies that can apply to `host` (lower case, as in
    /// PreparedUri): those of its site, in send order.
    pub fn siteCookies(self: *const Jar, host: []const u8) []Cookie {
        const group = self.sites.getPtr(siteKey(host)) orelse return &.{};
        return group.items;
    }

    /// Every cookie, site by site. The jar must not change while iterating.
    pub fn iterator(self: *const Jar) Iterator {
        return .{ .groups = self.sites.values() };
    }

    pub const Iterator = struct {
        group: usize = 0,
        index: usize = 0,
        groups: []std.ArrayList(Cookie),

        pub fn next(self: *Iterator) ?*Cookie {
            while (self.group < self.groups.len) {
                const items = self.groups[self.group].items;
                if (self.index < items.len) {
                    defer self.index += 1;
                    return &items[self.index];
                }
                self.group += 1;
                self.index = 0;
            }
            return null;
        }
    };

    /// Removes the cookies `matches` accepts, `context` being its first argument.
    pub fn removeWhere(self: *Jar, context: anytype, comptime matches: fn (@TypeOf(context), *const Cookie) bool) void {
        var g = self.sites.count();
        while (g > 0) {
            g -= 1;
            // Going backwards, a group is only dropped once its last cookie,
            // index 0, is removed, and only groups already visited shift.
            var i = self.sites.values()[g].items.len;
            while (i > 0) {
                i -= 1;
                if (matches(context, &self.sites.values()[g].items[i])) {
                    self.remove(g, i);
                }
            }
        }
    }

    pub fn add(
        self: *Jar,
        new_cookie: Cookie,
        request_time: u64,
        /// Checks if addition comes from HTTP request or JS context.
        comptime is_http: bool,
    ) !void {
        var cookie = new_cookie;
        cookie.creation_time = request_time;
        cookie.last_access_time = request_time;

        // `add` takes ownership of `cookie` unconditionally on entry.
        var stored = false;
        defer if (!stored) cookie.deinit();

        if (cookie.value.len > max_cookie_size) {
            return error.CookieSizeExceeded;
        }

        const is_expired = isCookieExpired(&cookie, request_time);
        const key = siteKey(cookie.domain);
        const site = self.sites.getIndex(key);

        if (site) |g| {
            const group = &self.sites.values()[g];
            for (group.items, 0..) |*c, i| {
                // We're only looking for the equal one.
                if (areCookiesEqual(&cookie, c) == false) {
                    continue;
                }

                // RFC 6265bis 5.7.2: a non-HTTP API (e.g. document.cookie) must
                // not replace an HttpOnly cookie.
                if (c.http_only and is_http == false) {
                    return;
                }

                if (is_expired) {
                    self.remove(g, i);
                } else {
                    // RFC 6265bis 5.7 step 23: the replacement keeps the
                    // creation time of the cookie it replaces.
                    cookie.creation_time = c.creation_time;
                    // Free the old cookie's arena before overwriting the slot;
                    // after the assignment, c points at the new cookie.
                    c.deinit();
                    group.items[i] = cookie;
                    stored = true;
                    self.dispatchChange(.changed, g, i);
                }
                return;
            }
        }

        if (!is_expired) {
            // Chrome's CookieMonster::GarbageCollect, before the insert so the
            // new cookie is never evicted: expired cookies go first, then the
            // least recently accessed (RFC 6265bis 5.7).
            if (site) |g| {
                if (self.sites.values()[g].items.len >= max_domain_cookies) {
                    self.removeExpiredAt(g, request_time);
                    self.evictSite(key);
                }
            }
            if (self.len >= max_cookies) {
                self.removeExpired(request_time);
                self.evictJar();
            }

            // Looked up after eviction, which can drop this site's group.
            const g = self.sites.getIndex(key) orelse blk: {
                const owned_key = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(owned_key);
                try self.sites.putNoClobber(self.allocator, owned_key, .empty);
                break :blk self.sites.count() - 1;
            };
            const group = &self.sites.values()[g];

            // keep it in send order: longest path then creation time.
            var pos = group.items.len;
            while (pos > 0 and sendsBefore(&cookie, &group.items[pos - 1])) {
                pos -= 1;
            }
            try group.insert(self.allocator, pos, cookie);
            stored = true;
            self.len += 1;
            self.dispatchChange(.changed, g, pos);
        }
    }

    /// Stores a cookie set by a response from `url`, or by a script of a
    /// document at `url`. RFC 6265bis 5.7: a non-secure origin can't set a
    /// Secure cookie, nor shadow or overwrite one.
    pub fn addFromUrl(
        self: *Jar,
        url: [:0]const u8,
        cookie: Cookie,
        request_time: u64,
        comptime is_http: bool,
    ) !void {
        if (!URL.isPotentiallyTrustworthy(url) and (cookie.secure or self.shadowsSecureCookie(&cookie, request_time))) {
            cookie.deinit();
            return;
        }
        return self.add(cookie, request_time, is_http);
    }

    // A Secure cookie with the same name, a domain that domain-matches
    // cookie's or the other way around (a leading `.` isn't compared), and
    // a path that cookie's path path-matches. An expired cookie is already
    // gone as far as the RFC is concerned, even if the jar still holds it.
    // Domains that domain-match are of the same site.
    fn shadowsSecureCookie(self: *const Jar, cookie: *const Cookie, now: u64) bool {
        const domain = std.mem.trimStart(u8, cookie.domain, ".");
        for (self.siteCookies(cookie.domain)) |*c| {
            if (isCookieExpired(c, now)) {
                continue;
            }
            const c_domain = std.mem.trimStart(u8, c.domain, ".");
            if (c.secure and
                std.mem.eql(u8, c.name, cookie.name) and
                (URL.isSubdomainOf(domain, c_domain) or URL.isSubdomainOf(c_domain, domain)) and
                pathMatches(cookie.path, c.path))
            {
                return true;
            }
        }
        return false;
    }

    // RFC 6265bis 5.7 and Chrome: non-Secure cookies go first, then the least
    // recently accessed.
    fn evictsBefore(a: *const Cookie, b: *const Cookie) bool {
        if (a.secure != b.secure) return b.secure;
        return a.last_access_time < b.last_access_time;
    }

    // Past `max_domain_cookies` for the site, evicts down to `purge_domain_cookies`
    // fewer, counting the one being added. Never empties the group.
    fn evictSite(self: *Jar, key: []const u8) void {
        const g = self.sites.getIndex(key) orelse return;
        const count = self.sites.values()[g].items.len;
        if (count < max_domain_cookies) return;
        for (max_domain_cookies - purge_domain_cookies - 1..count) |_| {
            const items = self.sites.values()[g].items;
            var oldest: usize = 0;
            for (items[1..], 1..) |*c, i| {
                if (evictsBefore(c, &items[oldest])) oldest = i;
            }
            self.remove(g, oldest);
        }
    }

    // The same, past `max_cookies` in the jar, across sites.
    fn evictJar(self: *Jar) void {
        const count = self.len;
        if (count < max_cookies) return;
        for (max_cookies - purge_cookies - 1..count) |_| {
            var oldest: ?struct { g: usize, i: usize } = null;
            for (self.sites.values(), 0..) |*group, g| {
                for (group.items, 0..) |*c, i| {
                    if (oldest) |o| {
                        if (!evictsBefore(c, &self.sites.values()[o.g].items[o.i])) continue;
                    }
                    oldest = .{ .g = g, .i = i };
                }
            }
            const o = oldest.?;
            self.remove(o.g, o.i);
        }
    }

    // Removes cookie `i` of group `g`, and the group once empty, which
    // shifts the groups after it.
    fn remove(self: *Jar, g: usize, i: usize) void {
        self.dispatchChange(.deleted, g, i);
        const group = &self.sites.values()[g];
        const c = &group.items[i];
        c.deinit();
        _ = group.orderedRemove(i);
        self.len -= 1;
        if (group.items.len == 0) {
            self.dropSite(g);
        }
    }

    fn dropSite(self: *Jar, g: usize) void {
        self.sites.values()[g].deinit(self.allocator);
        const key = self.sites.keys()[g];
        self.sites.orderedRemoveAt(g);
        self.allocator.free(key);
    }

    // Listeners run while the caller can be mid-loop over the jar, so they
    // must not change it synchronously. In safe builds, the locks turn a
    // change that would move the cookie or the groups into a panic.
    fn dispatchChange(
        self: *Jar,
        kind: Notification.CookieChanged.Kind,
        g: usize,
        i: usize,
    ) void {
        const notification = self.notification orelse return;
        const group = &self.sites.values()[g];
        self.sites.lockPointers();
        defer self.sites.unlockPointers();
        group.lockPointers();
        defer group.unlockPointers();

        const cookie = &group.items[i];
        notification.dispatch(.cookie_changed, &.{
            .kind = kind,
            .name = cookie.name,
            .value = cookie.value,
            .domain = cookie.domain,
            .path = cookie.path,
            .secure = cookie.secure,
            .http_only = cookie.http_only,
            .same_site = cookie.same_site,
        });
    }

    pub fn removeExpired(self: *Jar, request_time: ?u64) void {
        const time = request_time orelse lp.datetime.timestamp(.real);
        var g = self.sites.count();
        while (g > 0) {
            g -= 1;
            self.removeExpiredAt(g, time);
        }
    }

    // Can drop group `g`, shifting the groups after it.
    fn removeExpiredAt(self: *Jar, g: usize, now: u64) void {
        const group = &self.sites.values()[g];
        var i: usize = group.items.len;
        while (i > 0) {
            i -= 1;
            if (isCookieExpired(&group.items[i], now)) {
                group.orderedRemove(i).deinit();
                self.len -= 1;
            }
        }
        if (group.items.len == 0) {
            self.dropSite(g);
        }
    }

    const LookupOpts = struct {
        is_http: bool,
        request_time: ?u64 = null,
        // `subresource` is the most restrictive, a caller who forgets to set
        // it won't leak `SameSite=Lax` cookies.
        kind: RequestKind = .subresource,
        prefix: ?[]const u8 = null,
        origin_url: SiteForCookies,
    };
    pub fn forRequest(self: *Jar, target_url: [:0]const u8, writer: anytype, opts: LookupOpts) !void {
        const target = PreparedUri.init(target_url);
        const same_site = areSameSite(opts.origin_url, target.host);
        const now = opts.request_time orelse lp.datetime.timestamp(.real);

        const key = siteKey(target.host);
        if (self.sites.getIndex(key)) |g| {
            self.removeExpiredAt(g, now);
        }

        var first = true;
        for (self.siteCookies(target.host)) |*cookie| {
            const applies = cookie.appliesTo(&target, .{
                .same_site = same_site,
                .is_http = opts.is_http,
                .kind = opts.kind,
                .now = now,
            });
            if (!applies) {
                continue;
            }
            cookie.last_access_time = now;

            // we have a match!
            if (first) {
                if (opts.prefix) |prefix| {
                    try writer.writeAll(prefix);
                }
                first = false;
            } else {
                try writer.writeAll("; ");
            }
            try writeCookie(cookie, writer);
        }
    }

    fn sendsBefore(a: *const Cookie, b: *const Cookie) bool {
        if (a.path.len != b.path.len) {
            return a.path.len > b.path.len;
        }
        return a.creation_time < b.creation_time;
    }

    pub fn populateFromResponse(self: *Jar, url: [:0]const u8, set_cookie: []const u8) !void {
        const c = Cookie.parse(self.allocator, url, set_cookie) catch |err| {
            log.debug(.frame, "cookie parse failed", .{ .raw = set_cookie, .err = err });
            return;
        };

        const now = lp.datetime.timestamp(.real);
        try self.addFromUrl(url, c, now, true);
    }

    fn writeCookie(cookie: *const Cookie, writer: anytype) !void {
        if (cookie.name.len > 0) {
            try writer.writeAll(cookie.name);
            try writer.writeByte('=');
        }
        if (cookie.value.len > 0) {
            try writer.writeAll(cookie.value);
        }
    }
};

fn isCookieExpired(cookie: *const Cookie, now: u64) bool {
    const ce = cookie.expires orelse return false;
    return ce <= @as(f64, @floatFromInt(now));
}

fn areCookiesEqual(a: *const Cookie, b: *const Cookie) bool {
    if (std.mem.eql(u8, a.name, b.name) == false) {
        return false;
    }
    if (std.mem.eql(u8, a.domain, b.domain) == false) {
        return false;
    }
    if (std.mem.eql(u8, a.path, b.path) == false) {
        return false;
    }
    return true;
}

pub fn areSameSite(origin_url: SiteForCookies, target_host: []const u8) bool {
    return switch (origin_url) {
        .none => false,
        .url => |url| areHostsSameSite(URL.getHostname(url), target_host),
    };
}

pub fn areHostsSameSite(target_host: []const u8, origin_host: []const u8) bool {
    // Common case.
    if (std.mem.eql(u8, target_host, origin_host)) {
        return true;
    }
    return std.mem.eql(u8, findSecondLevelDomain(target_host), findSecondLevelDomain(origin_host));
}

// The site of a cookie domain or a host: its registrable domain, like
// Chrome's CookieMonster key. A cookie only applies to hosts with its key.
fn siteKey(domain: []const u8) []const u8 {
    const host = if (domain.len > 0 and domain[0] == '.') domain[1..] else domain;
    // findSecondLevelDomain keeps a single label as is, and Domain=localhost
    // is the one single-label domain parseDomain accepts.
    if (std.mem.endsWith(u8, host, ".localhost")) return "localhost";
    return findSecondLevelDomain(host);
}

fn findSecondLevelDomain(host: []const u8) []const u8 {
    // An IP address is its own site, not one per last two octets.
    if (isIpLiteral(host)) return host;
    var i = std.mem.findScalarLast(u8, host, '.') orelse return host;
    while (true) {
        i = std.mem.findScalarLast(u8, host[0..i], '.') orelse return host;
        const strip = i + 1;
        if (public_suffix_list(host[strip..]) == false) {
            return host[strip..];
        }
    }
}

pub const PreparedUri = struct {
    host: []const u8, // Percent encoded, lower case
    path: []const u8, // Percent encoded
    trustworthy: bool, // May receive Secure cookies

    // init assumes url lifetime exceeds preparedUri one.
    pub fn init(url: [:0]const u8) PreparedUri {
        const host = URL.getHostname(url);
        return .{
            .host = host,
            .path = URL.getPathname(url),
            .trustworthy = URL.isSecure(url) or URL.isLoopbackHost(host),
        };
    }
};

fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

fn trimLeft(str: []const u8) []const u8 {
    return std.mem.trimStart(u8, str, &std.ascii.whitespace);
}

fn trimRight(str: []const u8) []const u8 {
    return std.mem.trimEnd(u8, str, &std.ascii.whitespace);
}

fn toLower(str: []u8) []u8 {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
    return str;
}

const testing = @import("../../../testing.zig");
const test_url = "http://lightpanda.io/";
test "cookie: fromFields refuses what Chrome's CreateSanitizedCookie does" {
    const url = "https://example.com/";
    const too_long: [max_cookie_size]u8 = @splat('v');
    const refused = [_]Fields{
        .{ .name = "a;b", .value = "v" },
        .{ .name = "a=b", .value = "v" },
        .{ .name = " a", .value = "v" },
        .{ .name = "a", .value = "x;y" },
        .{ .name = "a", .value = "x\ty" },
        .{ .name = "a", .value = "x\x7fy" },
        .{ .name = "a", .value = "v " },
        .{ .name = "", .value = "" },
        .{ .name = "a", .value = &too_long },
        .{ .name = "a", .value = "v", .path = "/a\nb" },
    };
    for (refused) |fields| {
        try testing.expectError(error.InvalidCookie, fromFields(testing.allocator, url, fields));
    }
    try testing.expectError(error.InvalidDomain, fromFields(testing.allocator, url, .{ .name = "a", .value = "v", .domain = "other.com" }));

    // Chrome's cookie-name prefixes, beyond what the parse tests cover.
    const prefix_refused = [_]Fields{
        .{ .name = "", .value = " __host-x" },
        .{ .name = "__host-a", .value = "v", .secure = true, .domain = ".example.com" },
        .{ .name = "__Host-Http-a", .value = "v", .secure = true },
    };
    for (prefix_refused) |fields| {
        try testing.expectError(error.InvalidCookie, fromFields(testing.allocator, url, fields));
    }
    const prefix_accepted = [_]Fields{
        .{ .name = "__Host-a", .value = "v", .secure = true },
        .{ .name = "__Host-Http-a", .value = "v", .secure = true, .http_only = true },
    };
    for (prefix_accepted) |fields| {
        const cookie = try fromFields(testing.allocator, url, fields);
        cookie.deinit();
    }

    // Wider than RFC 6265bis's grammar, as in Chrome.
    const accepted = [_]Fields{
        .{ .name = "a b", .value = "caf\xc3\xa9" },
        .{ .name = "a", .value = "" },
        .{ .name = "a", .value = "v", .path = "/a\x01b" },
    };
    for (accepted) |fields| {
        const cookie = try fromFields(testing.allocator, url, fields);
        cookie.deinit();
    }
}

test "cookie: findSecondLevelDomain" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "com", "com" },
        .{ "lightpanda.io", "lightpanda.io" },
        .{ "lightpanda.io", "test.lightpanda.io" },
        .{ "lightpanda.io", "first.test.lightpanda.io" },
        .{ "www.gov.uk", "www.gov.uk" },
        .{ "stats.gov.uk", "www.stats.gov.uk" },
        .{ "api.gov.uk", "api.gov.uk" },
        .{ "dev.api.gov.uk", "dev.api.gov.uk" },
        .{ "dev.api.gov.uk", "1.dev.api.gov.uk" },
    };
    for (cases) |c| {
        try testing.expectEqual(c.@"0", findSecondLevelDomain(c.@"1"));
    }
}

test "Jar: add" {
    const expectCookies = struct {
        fn expect(expected: []const struct { []const u8, []const u8 }, jar: Jar) !void {
            try testing.expectEqual(expected.len, jar.len);
            LOOP: for (expected) |e| {
                var it = jar.iterator();
                while (it.next()) |c| {
                    if (std.mem.eql(u8, e.@"0", c.name) and std.mem.eql(u8, e.@"1", c.value)) {
                        continue :LOOP;
                    }
                }
                std.debug.print("Cookie ({s}={s}) not found", .{ e.@"0", e.@"1" });
                return error.CookieNotFound;
            }
        }
    }.expect;

    const now = lp.datetime.timestamp(.real);

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000;Max-Age=0"), now, true);
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000"), now, true);
    try expectCookies(&.{.{ "over", "9000" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9000!!"), now, true);
    try expectCookies(&.{.{ "over", "9000!!" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "spice=flow"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flow" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "spice=flows;Path=/"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9001;Path=/other"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=9002;Path=/;Domain=lightpanda.io"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" }, .{ "over", "9002" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "over=x;Path=/other;Max-Age=-200"), now, true);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9002" } }, jar);
}

test "Jar: non-HTTP add must not replace or duplicate an HttpOnly cookie" {
    const now = lp.datetime.timestamp(.real);

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=REAL;Path=/;HttpOnly"), now, true);
    try testing.expectEqual(@as(usize, 1), jar.len);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=ATTACKER;Path=/"), now, false);
    try testing.expectEqual(@as(usize, 1), jar.len);
    try testing.expectEqual("REAL", nthCookie(&jar, 0).value);
    try testing.expectEqual(true, nthCookie(&jar, 0).http_only);

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=REFRESHED;Path=/;HttpOnly"), now, true);
    try testing.expectEqual(@as(usize, 1), jar.len);
    try testing.expectEqual("REFRESHED", nthCookie(&jar, 0).value);
}

test "Jar: add limit" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);

    // add a too big cookie value.
    try testing.expectError(error.CookieSizeExceeded, jar.add(.{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "v",
        .domain = "lightpanda.io",
        .path = "/",
        .expires = null,
        .value = repeat("v", 4096) ++ "v",
    }, now, true));
}

fn jarHas(jar: *const Jar, name: []const u8) bool {
    var it = jar.iterator();
    while (it.next()) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

fn nthCookie(jar: *const Jar, n: usize) *Cookie {
    var it = jar.iterator();
    for (0..n) |_| _ = it.next();
    return it.next().?;
}

test "Jar: past the limit of a site, the least recently accessed are evicted" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    var url_buf: [64]u8 = undefined;
    var buf: [16]u8 = undefined;

    // Another site's cookie, older than all, is not evicted for this one.
    try jar.add(try Cookie.parse(testing.allocator, "http://lightpanda.dev/", "o=v"), now, true);

    // Subdomains share lightpanda.io's limit. c1...c10 are Secure.
    for (0..max_domain_cookies) |i| {
        const url = try std.fmt.bufPrintSentinel(&url_buf, "http://s{d}.lightpanda.io/", .{i}, 0);
        const set_cookie = try std.fmt.bufPrint(&buf, "c{d}=v{s}", .{ i, if (i > 0 and i <= 10) "; Secure" else "" });
        try jar.add(try Cookie.parse(testing.allocator, url, set_cookie), now + 1 + i, true);
    }

    // Reading c0, the oldest, makes it the most recently accessed.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try jar.forRequest("http://s0.lightpanda.io/", &aw.writer, .{
        .is_http = true,
        .origin_url = .{ .url = "http://s0.lightpanda.io/" },
        .request_time = now + 1000,
    });
    try testing.expectEqual("c0=v", aw.written());

    try jar.add(try Cookie.parse(testing.allocator, "http://lightpanda.io/", "new=v"), now + 1001, true);

    // Down to 150 for lightpanda.io, the new cookie included: the 31 least
    // recently accessed non-Secure cookies, c11...c41, go.
    try testing.expectEqual(max_domain_cookies - purge_domain_cookies + 1, jar.len);
    try testing.expectEqual(true, jarHas(&jar, "o"));
    try testing.expectEqual(true, jarHas(&jar, "new"));
    for (0..max_domain_cookies) |i| {
        const name = try std.fmt.bufPrint(&buf, "c{d}", .{i});
        try testing.expectEqual(i <= 10 or i > 41, jarHas(&jar, name));
    }
}

test "Jar: past a limit, expired cookies are evicted first" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    var buf: [32]u8 = undefined;

    // The 10 most recent cookies expire first.
    for (0..max_domain_cookies) |i| {
        const set_cookie = try std.fmt.bufPrint(&buf, "c{d}=v{s}", .{ i, if (i >= 170) "; Max-Age=500" else "" });
        try jar.add(try Cookie.parse(testing.allocator, test_url, set_cookie), now + i, true);
    }
    try jar.add(try Cookie.parse(testing.allocator, test_url, "new=v"), now + 1000, true);

    // Removing them is enough: nothing else goes.
    try testing.expectEqual(max_domain_cookies - 10 + 1, jar.len);
    for (0..max_domain_cookies) |i| {
        const name = try std.fmt.bufPrint(&buf, "c{d}", .{i});
        try testing.expectEqual(i < 170, jarHas(&jar, name));
    }
}

test "Jar: past the limit of the jar, the least recently accessed are evicted" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    var url_buf: [32]u8 = undefined;
    var buf: [16]u8 = undefined;

    // 100 cookies per site, under the limit of a site. c0...c9 are Secure.
    for (0..max_cookies) |i| {
        const url = try std.fmt.bufPrintSentinel(&url_buf, "http://d{d}.test/", .{i / 100}, 0);
        const set_cookie = try std.fmt.bufPrint(&buf, "c{d}=v{s}", .{ i, if (i < 10) "; Secure" else "" });
        try jar.add(try Cookie.parse(testing.allocator, url, set_cookie), now + i, true);
    }

    try jar.add(try Cookie.parse(testing.allocator, "http://new.test/", "new=v"), now + max_cookies, true);
    try testing.expectEqual(max_cookies - purge_cookies, jar.len);
    try testing.expectEqual(true, jarHas(&jar, "new"));
    for (0..max_cookies) |i| {
        const name = try std.fmt.bufPrint(&buf, "c{d}", .{i});
        try testing.expectEqual(i < 10 or i > purge_cookies + 10, jarHas(&jar, name));
    }

    // Replacing a cookie evicts nothing.
    try jar.add(try Cookie.parse(testing.allocator, "http://new.test/", "new=w"), now + max_cookies + 1, true);
    try testing.expectEqual(max_cookies - purge_cookies, jar.len);
}

test "Jar: cookies are grouped by site" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    try jar.populateFromResponse("http://lightpanda.io/", "a=1");
    try jar.populateFromResponse("http://www.lightpanda.io/", "b=2; Domain=lightpanda.io");
    try jar.populateFromResponse("http://docs.lightpanda.io/", "c=3");
    try jar.populateFromResponse("http://lightpanda.dev/", "d=4");
    // Domain=localhost applies to its subdomains, which findSecondLevelDomain
    // alone would put in sites of their own.
    try jar.populateFromResponse("http://localhost/", "e=5; Domain=localhost");
    try testing.expectEqual(5, jar.len);
    try testing.expectEqual(3, jar.sites.count());

    try testing.expectEqual(3, jar.siteCookies("www.lightpanda.io").len);
    try testing.expectEqual(1, jar.siteCookies("lightpanda.dev").len);
    try testing.expectEqual(0, jar.siteCookies("lightpanda.com").len);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try jar.forRequest("http://a.b.localhost/", &aw.writer, .{
        .origin_url = .{ .url = "http://a.b.localhost/" },
        .is_http = true,
    });
    try testing.expectEqual("e=5", aw.written());

    // Removing a site's last cookie drops its group.
    try jar.populateFromResponse("http://lightpanda.dev/", "d=; Max-Age=0");
    try testing.expectEqual(4, jar.len);
    try testing.expectEqual(2, jar.sites.count());
}

test "Jar: a non-secure origin can't set or overwrite a Secure cookie" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    try jar.populateFromResponse("http://lightpanda.io/", "s=1; Secure");
    try testing.expectEqual(0, jar.len);
    try jar.populateFromResponse("https://lightpanda.io/", "s=1; Secure");

    // No overwrite, no shadowing on a matching domain or a longer path, no
    // deletion.
    try jar.populateFromResponse("http://lightpanda.io/", "s=2");
    try jar.populateFromResponse("http://lightpanda.io/", "s=3; Path=/sub");
    try jar.populateFromResponse("http://lightpanda.io/", "s=4; Domain=lightpanda.io");
    try jar.populateFromResponse("http://www.lightpanda.io/", "s=5");
    try jar.populateFromResponse("http://lightpanda.io/", "s=; Max-Age=0");
    try testing.expectEqual(1, jar.len);
    try testing.expectEqual("1", nthCookie(&jar, 0).value);

    // Another name, domain, or a path the Secure cookie's path doesn't cover.
    try jar.populateFromResponse("http://lightpanda.io/", "t=1");
    try jar.populateFromResponse("http://lightpanda.dev/", "s=6");
    try jar.populateFromResponse("https://lightpanda.io/", "u=1; Secure; Path=/sub");
    try jar.populateFromResponse("http://lightpanda.io/", "u=2");
    try testing.expectEqual(5, jar.len);

    // Like Chrome, loopback origins are secure ones.
    try jar.populateFromResponse("http://localhost:3000/", "s=7; Secure");
    try testing.expectEqual(6, jar.len);
}

test "Jar: an expired Secure cookie doesn't block a non-secure origin" {
    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    try jar.add(try Cookie.parse(testing.allocator, "https://lightpanda.io/", "s=1; Secure; Max-Age=10"), now, true);

    // Still in the jar (nothing purged it), but expired by `later`.
    const later = now + 20;
    try jar.addFromUrl("http://lightpanda.io/", try Cookie.parse(testing.allocator, "http://lightpanda.io/", "s=2"), later, true);
    try testing.expectEqual(1, jar.len);
    try testing.expectEqual("2", nthCookie(&jar, 0).value);
    try testing.expectEqual(false, nthCookie(&jar, 0).secure);
}

test "Jar: forRequest" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try jar.forRequest(target_url, &aw.writer, opts);
            try testing.expectEqual(expected, aw.written());
        }
    }.expect;

    const now = lp.datetime.timestamp(.real);

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const url2 = "http://test.lightpanda.io/";

    {
        // test with no cookies
        try expectCookies("", &jar, test_url, .{ .origin_url = .{ .url = test_url }, .is_http = true });
    }

    try jar.add(try Cookie.parse(testing.allocator, test_url, "global1=1"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "global2=2;Max-Age=30;domain=lightpanda.io"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "path1=3;Path=/about"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "path2=4;Path=/docs/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "secure=5;Secure"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "sitenone=6;SameSite=None;Path=/x/;Secure"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "sitelax=7;SameSite=Lax;Path=/x/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "sitestrict=8;SameSite=Strict;Path=/x/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, url2, "domain1=9;domain=test.lightpanda.io"), now, true);

    // nothing fancy here
    try expectCookies("global1=1; global2=2", &jar, test_url, .{ .origin_url = .{ .url = test_url }, .is_http = true, .kind = .navigation });
    try expectCookies("global1=1; global2=2", &jar, test_url, .{ .origin_url = .{ .url = test_url }, .is_http = true, .kind = .subresource });

    // We have a cookie where Domain=lightpanda.io
    // This should _not_ match xyxlightpanda.io
    try expectCookies("", &jar, "http://anothersitelightpanda.io/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
        .kind = .navigation,
    });

    // matching path without trailing /
    try expectCookies("path1=3; global1=1; global2=2", &jar, "http://lightpanda.io/about", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // incomplete prefix path
    try expectCookies("global1=1; global2=2", &jar, "http://lightpanda.io/abou", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // path doesn't match
    try expectCookies("global1=1; global2=2", &jar, "http://lightpanda.io/aboutus", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // path doesn't match cookie directory
    try expectCookies("global1=1; global2=2", &jar, "http://lightpanda.io/docs", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // exact directory match
    try expectCookies("path2=4; global1=1; global2=2", &jar, "http://lightpanda.io/docs/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // sub directory match
    try expectCookies("path2=4; global1=1; global2=2", &jar, "http://lightpanda.io/docs/more", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // secure
    try expectCookies("global1=1; global2=2; secure=5", &jar, "https://lightpanda.io/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // navigational cross domain, secure
    try expectCookies("sitenone=6; sitelax=7; global1=1; global2=2; secure=5", &jar, "https://lightpanda.io/x/", .{
        .origin_url = .{ .url = "https://example.com/" },
        .is_http = true,
        .kind = .navigation,
    });

    // navigational cross domain, insecure
    try expectCookies("sitelax=7; global1=1; global2=2", &jar, "http://lightpanda.io/x/", .{
        .origin_url = .{ .url = "https://example.com/" },
        .is_http = true,
        .kind = .navigation,
    });

    // non-navigational cross domain, insecure
    try expectCookies("", &jar, "http://lightpanda.io/x/", .{
        .origin_url = .{ .url = "https://example.com/" },
        .is_http = true,
        .kind = .subresource,
    });

    // non-navigational cross domain, secure
    try expectCookies("sitenone=6", &jar, "https://lightpanda.io/x/", .{
        .origin_url = .{ .url = "https://example.com/" },
        .is_http = true,
        .kind = .subresource,
    });

    // non-navigational same origin
    try expectCookies("sitelax=7; sitestrict=8; global1=1; global2=2", &jar, "http://lightpanda.io/x/", .{
        .origin_url = .{ .url = "https://lightpanda.io/" },
        .is_http = true,
        .kind = .subresource,
    });

    // exact domain match + suffix
    try expectCookies("global2=2; domain1=9", &jar, "http://test.lightpanda.io/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // domain suffix match + suffix
    try expectCookies("global2=2; domain1=9", &jar, "http://1.test.lightpanda.io/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    // non-matching domain
    try expectCookies("global2=2", &jar, "http://other.lightpanda.io/", .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });

    const l = jar.len;
    try expectCookies("global1=1", &jar, test_url, .{
        .request_time = now + 100,
        .origin_url = .{ .url = test_url },
        .is_http = true,
    });
    try testing.expectEqual(l - 1, jar.len);

    // If you add more cases after this point, note that the above test removes
    // the 'global2' cookie
}

test "Jar: forRequest orders cookies by path length, then creation time" {
    const now = lp.datetime.timestamp(.real);

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=root"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "old=1;Max-Age=10"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "session=app;Path=/app"), now + 1, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "a=2"), now + 2, true);
    try jar.add(try Cookie.parse(testing.allocator, test_url, "b=3"), now + 2, true);

    // `old` expires before the request; removing it must not reorder `a` and `b`.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try jar.forRequest("http://lightpanda.io/app/x", &aw.writer, .{
        .origin_url = .{ .url = test_url },
        .is_http = true,
        .request_time = now + 20,
    });
    try testing.expectEqual("session=app; session=root; a=2; b=3", aw.written());
}

test "Jar: forRequest Secure cookies on loopback origins" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try jar.forRequest(target_url, &aw.writer, opts);
            try testing.expectEqual(expected, aw.written());
        }
    }.expect;

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    const url = "http://127.0.0.1:3000/";
    try jar.add(try Cookie.parse(testing.allocator, url, "s=1; Secure"), now, true);
    try expectCookies("s=1", &jar, url, .{ .origin_url = .{ .url = url }, .is_http = true });
}

test "Jar: forRequest SameSite=Strict on cross-site navigation" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try jar.forRequest(target_url, &aw.writer, opts);
            try testing.expectEqual(expected, aw.written());
        }
    }.expect;

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const victim_url: [:0]const u8 = "http://victim.example/";
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "sid=STRICT_COOKIE; Path=/; SameSite=Strict"), lp.datetime.timestamp(.real), true);

    // Same-site navigation: cookie included.
    try expectCookies("sid=STRICT_COOKIE", &jar, "http://victim.example/transfer", .{
        .origin_url = .{ .url = victim_url },
        .is_http = true,
        .kind = .navigation,
    });

    // Cross-site navigation from attacker.test: cookie excluded.
    try expectCookies("", &jar, "http://victim.example/transfer", .{
        .origin_url = .{ .url = "http://attacker.test/strict-form" },
        .is_http = true,
        .kind = .navigation,
    });

    // Browser-initiated navigation: the initiator is the destination itself.
    try expectCookies("sid=STRICT_COOKIE", &jar, "http://victim.example/transfer", .{
        .origin_url = .{ .url = "http://victim.example/transfer" },
        .is_http = true,
        .kind = .navigation,
    });
}

test "Jar: forRequest with .none site-for-cookies" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try jar.forRequest(target_url, &aw.writer, opts);
            try testing.expectEqual(expected, aw.written());
        }
    }.expect;

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    const victim_url: [:0]const u8 = "https://victim.example/";
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "strict=1; Path=/; SameSite=Strict"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "lax=2; Path=/; SameSite=Lax"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "none=3; Path=/; SameSite=None; Secure"), now, true);

    // .none is the site-for-cookies of a frame whose ancestor chain contains
    // a cross-site document. Even though the target here is the cookies' own
    // site, the request is cross-site: Strict is withheld.
    try expectCookies("lax=2; none=3", &jar, victim_url, .{
        .origin_url = .none,
        .is_http = true,
        .kind = .navigation,
    });

    // Sub-resources from such a frame only carry SameSite=None cookies.
    try expectCookies("none=3", &jar, victim_url, .{
        .origin_url = .none,
        .is_http = true,
        .kind = .subresource,
    });

    // Sanity: a same-site initiator still gets everything.
    try expectCookies("strict=1; lax=2; none=3", &jar, victim_url, .{
        .origin_url = .{ .url = victim_url },
        .is_http = true,
        .kind = .subresource,
    });
}

test "Jar: forRequest Lax-allowing-unsafe" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_url: [:0]const u8, opts: Jar.LookupOpts) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try jar.forRequest(target_url, &aw.writer, opts);
            try testing.expectEqual(expected, aw.written());
        }
    }.expect;

    var jar = Jar.init(testing.allocator, null);
    defer jar.deinit();

    const now = lp.datetime.timestamp(.real);
    const victim_url: [:0]const u8 = "https://victim.example/";
    const attacker: Cookie.SiteForCookies = .{ .url = "https://attacker.test/" };
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "default=1; Path=/"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "lax=2; Path=/; SameSite=Lax"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "none=3; Path=/; SameSite=None; Secure"), now, true);
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "strict=4; Path=/; SameSite=Strict"), now, true);

    // Cross-site POST right after the cookies were set: the cookie without
    // a SameSite attribute rides along, an explicit Lax does not.
    try expectCookies("default=1; none=3", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .unsafe_navigation,
        .request_time = now + 119,
    });

    // Two minutes later, the compatibility window is closed.
    try expectCookies("none=3", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .unsafe_navigation,
        .request_time = now + 121,
    });

    // The age only matters for unsafe methods.
    try expectCookies("default=1; lax=2; none=3", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .navigation,
        .request_time = now + 121,
    });
    try expectCookies("none=3", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .subresource,
        .request_time = now + 1,
    });

    // Re-setting the cookie doesn't reopen the window: the replacement
    // inherits the creation time of the cookie it replaces.
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "default=5; Path=/"), now + 300, true);
    try expectCookies("none=3", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .unsafe_navigation,
        .request_time = now + 301,
    });

    // A brand new cookie is young again.
    try jar.add(try Cookie.parse(testing.allocator, victim_url, "fresh=6; Path=/"), now + 300, true);
    try expectCookies("none=3; fresh=6", &jar, victim_url, .{
        .origin_url = attacker,
        .is_http = true,
        .kind = .unsafe_navigation,
        .request_time = now + 301,
    });
}

test "Cookie: parse key=value" {
    try expectError(error.Empty, null, "");
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 30, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 127, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 20 });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 128 });

    // Tab (0x09) is allowed in name and value, matching browser/WPT behavior.
    try expectAttribute(.{ .name = "a\tb", .value = "c" }, null, "a\tb=c");
    try expectAttribute(.{ .name = "a", .value = "b\tc" }, null, "a=b\tc");
    // Other control characters remain rejected.
    try expectError(error.InvalidByteSequence, null, "a\nb=c");
    try expectError(error.InvalidByteSequence, null, "a\rb=c");
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 0 });

    // Nameless cookies whose value begins with a prefix (case-insensitive,
    // after leading whitespace) are rejected so they can't impersonate
    // prefixed cookies.
    try expectError(error.InvalidNameValue, null, "=__Host-abc=1");
    try expectError(error.InvalidNameValue, null, "=__Http-abc");
    try expectError(error.InvalidNameValue, null, "= __Secure-abc");
    try expectError(error.InvalidNameValue, null, "=__Secure-abc=1");
    try expectError(error.InvalidNameValue, null, "=__HoSt-abc");
    try expectError(error.InvalidNameValue, null, "__Secure-abc");

    // __Host- cookie-name-prefix rules:
    //   - must be Secure
    //   - must be set from a potentially trustworthy origin (https or loopback)
    //   - must not have a Domain attribute
    //   - must have Path=/
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://lightpanda.io/", "__Host-abc=1; Secure; Path=/");
    try expectAttribute(.{ .name = "__HoSt-abc", .value = "1" }, "https://lightpanda.io/", "__HoSt-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Host-abc=1; Path=/");
    try expectError(error.InvalidPrefixedCookie, null, "__Host-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Host-abc=1; Secure");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Host-abc=1; Secure; Path=/foo");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Host-abc=1; Secure; Path=/; Domain=lightpanda.io");

    // __Secure- cookie-name-prefix rules: must be Secure and from a
    // potentially trustworthy origin.
    try expectAttribute(.{ .name = "__Secure-abc", .value = "1" }, "https://lightpanda.io/", "__Secure-abc=1; Secure");
    try expectAttribute(.{ .name = "__SeCuRe-abc", .value = "1" }, "https://lightpanda.io/", "__SeCuRe-abc=1; Secure; Domain=lightpanda.io");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Secure-abc=1");

    // __Http- and __Host-Http- also need HttpOnly.
    try expectAttribute(.{ .name = "__Http-abc", .http_only = true }, "https://lightpanda.io/", "__Http-abc=1; Secure; HttpOnly");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Http-abc=1; Secure");
    try expectAttribute(.{ .name = "__Host-Http-abc", .http_only = true }, "https://lightpanda.io/", "__Host-Http-abc=1; Secure; HttpOnly; Path=/");
    try expectError(error.InvalidPrefixedCookie, "https://lightpanda.io/", "__Host-Http-abc=1; Secure; HttpOnly");

    // plain-http loopback
    try expectAttribute(.{ .name = "__Host-abc" }, "http://127.0.0.1:3000/", "__Host-abc=1; Secure; Path=/");
    try expectAttribute(.{ .name = "__Secure-abc" }, "http://localhost/", "__Secure-abc=1; Secure");
    try expectError(error.InvalidPrefixedCookie, "http://localhost.evil.com/", "__Host-abc=1; Secure; Path=/");
    try expectError(error.InvalidPrefixedCookie, null, "__Secure-abc=1; Secure");

    // Empty Domain= is treated as no Domain and accepted on __Host-.
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://lightpanda.io/", "__Host-abc=1; Secure; Path=/; Domain=");

    // __Host- with additional unrelated attributes remains valid.
    try expectAttribute(.{ .name = "__Host-abc", .value = "1" }, "https://lightpanda.io/", "__Host-abc=1; Secure; Path=/; Max-Age=60; HttpOnly");

    // Near-misses are not subject to the prefix rules.
    try expectAttribute(.{ .name = "__Host", .value = "1" }, null, "__Host=1");
    try expectAttribute(.{ .name = "_Host-abc", .value = "1" }, null, "_Host-abc=1");
    try expectAttribute(.{ .name = "__Hos-abc", .value = "1" }, null, "__Hos-abc=1");
    try expectAttribute(.{ .name = "__Secure", .value = "1" }, null, "__Secure=1");

    try expectAttribute(.{ .name = "", .value = "a" }, null, "a");
    try expectAttribute(.{ .name = "", .value = "a" }, null, "a;");
    try expectAttribute(.{ .name = "", .value = "a b" }, null, "a b");
    try expectAttribute(.{ .name = "a b", .value = "b" }, null, "a b=b");
    try expectAttribute(.{ .name = "a,", .value = "b" }, null, "a,=b");
    try expectAttribute(.{ .name = ":a>", .value = "b>><" }, null, ":a>=b>><");

    try expectAttribute(.{ .name = "abc", .value = "" }, null, "abc=");
    try expectAttribute(.{ .name = "abc", .value = "" }, null, "abc=;");

    try expectAttribute(.{ .name = "a", .value = "b" }, null, "a=b");
    try expectAttribute(.{ .name = "a", .value = "b" }, null, "a=b;");

    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f  ");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f;");
    try expectAttribute(.{ .name = "abc", .value = "fe f" }, null, "abc=  fe f   ;");
    try expectAttribute(.{ .name = "abc", .value = "\"  fe f\"" }, null, "abc=\"  fe f\"");
    try expectAttribute(.{ .name = "abc", .value = "\"  fe f   \"" }, null, "abc=\"  fe f   \"");
    try expectAttribute(.{ .name = "ab4344c", .value = "1ads23" }, null, "  ab4344c=1ads23  ");

    try expectAttribute(.{ .name = "ab4344c", .value = "1ads23" }, null, "  ab4344c  =  1ads23  ;");
}

test "Cookie: parse path" {
    try expectAttribute(.{ .path = "/" }, "http://a/", "b");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;path");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;Path=");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b;Path=;");
    try expectAttribute(.{ .path = "/" }, "http://a/", "b; Path=other");
    try expectAttribute(.{ .path = "/" }, "http://a/23", "b; path=other ");

    try expectAttribute(.{ .path = "/" }, "http://a/abc", "b");
    try expectAttribute(.{ .path = "/abc" }, "http://a/abc/", "b");
    try expectAttribute(.{ .path = "/abc" }, "http://a/abc/123", "b");
    try expectAttribute(.{ .path = "/abc/123" }, "http://a/abc/123/", "b");

    try expectAttribute(.{ .path = "/a" }, "http://a/", "b;Path=/a");
    try expectAttribute(.{ .path = "/aa" }, "http://a/", "b;path=/aa;");
    try expectAttribute(.{ .path = "/aabc/" }, "http://a/", "b;  path=  /aabc/ ;");

    try expectAttribute(.{ .path = "/bbb/" }, "http://a/", "b;  path=/a/; path=/bbb/");
    try expectAttribute(.{ .path = "/cc" }, "http://a/", "b;  path=/a/; path=/bbb/; path = /cc");
}

test "Cookie: parse secure" {
    try expectAttribute(.{ .secure = false }, null, "b");
    try expectAttribute(.{ .secure = false }, null, "b;secured");
    try expectAttribute(.{ .secure = false }, null, "b;security");
    try expectAttribute(.{ .secure = false }, null, "b;SecureX");
    try expectAttribute(.{ .secure = true }, null, "b; Secure");
    try expectAttribute(.{ .secure = true }, null, "b; Secure  ");
    try expectAttribute(.{ .secure = true }, null, "b; Secure=on  ");
    try expectAttribute(.{ .secure = true }, null, "b; Secure=Off  ");
    try expectAttribute(.{ .secure = true }, null, "b; secure=Off  ");
    try expectAttribute(.{ .secure = true }, null, "b; seCUre=Off  ");
}

test "Cookie: parse HttpOnly" {
    try expectAttribute(.{ .http_only = false }, null, "b");
    try expectAttribute(.{ .http_only = false }, null, "b;HttpOnly0");
    try expectAttribute(.{ .http_only = false }, null, "b;H ttpOnly");
    try expectAttribute(.{ .http_only = true }, null, "b; HttpOnly");
    try expectAttribute(.{ .http_only = true }, null, "b; Httponly  ");
    try expectAttribute(.{ .http_only = true }, null, "b; Httponly=on  ");
    try expectAttribute(.{ .http_only = true }, null, "b; httpOnly=Off  ");
    try expectAttribute(.{ .http_only = true }, null, "b; httpOnly=Off  ");
    try expectAttribute(.{ .http_only = true }, null, "b;    HttpOnly=Off  ");
}

test "Cookie: an IP address is its own site" {
    try testing.expectEqual(true, areHostsSameSite("127.0.0.1", "127.0.0.1"));
    try testing.expectEqual(false, areHostsSameSite("127.0.0.1", "10.0.0.1"));
    try testing.expectEqual(false, areHostsSameSite("192.168.0.1", "10.0.0.1"));
    try testing.expectEqual(false, areHostsSameSite("10.0.0.1", "a.0.1"));
    try testing.expectEqual(true, areHostsSameSite("a.lightpanda.io", "b.lightpanda.io"));
}

test "Cookie: parse SameSite" {
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite");
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite=lax");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Lax  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Other  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Nope  ");

    // SameSite=none is only valid when Secure is set. The whole cookie is
    // rejected otherwise
    try expectError(error.InsecureSameSite, null, "b;samesite=none");
    try expectError(error.InsecureSameSite, null, "b;SameSite=None");
    try expectAttribute(.{ .same_site = .none }, null, "b;  samesite=none; secure  ");
    try expectAttribute(.{ .same_site = .none }, null, "b;  SameSite=None  ; SECURE");
    try expectAttribute(.{ .same_site = .none }, null, "b;Secure;  SameSite=None");
    try expectAttribute(.{ .same_site = .none }, null, "b; SameSite=None; Secure");

    try expectAttribute(.{ .same_site = .strict }, null, "b;  samesite=Strict  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSite=  STRICT  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSITE=strict;");
    try expectAttribute(.{ .same_site = .strict }, null, "b; SameSite=Strict");

    try expectAttribute(.{ .same_site = .strict }, null, "b; SameSite=None; SameSite=lax; SameSite=Strict");
}

test "Cookie: parse max-age" {
    try expectAttribute(.{ .expires = null }, null, "b;max-age");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=abc");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=13.22");
    try expectAttribute(.{ .expires = null }, null, "b;max-age=13abc");

    // max-age can be negative, so the expected expiry has to be signed
    const now: i64 = @intCast(lp.datetime.timestamp(.real));
    try expectAttribute(.{ .expires = now + 13 }, null, "b;max-age=13");
    try expectAttribute(.{ .expires = now + -22 }, null, "b;max-age=-22");
    try expectAttribute(.{ .expires = now + 4294967296 }, null, "b;max-age=4294967296");
    try expectAttribute(.{ .expires = now + -4294967296 }, null, "b;Max-Age= -4294967296");
    try expectAttribute(.{ .expires = now + 0 }, null, "b; Max-Age=0");
    try expectAttribute(.{ .expires = now + 500 }, null, "b; Max-Age = 500  ; Max-Age=invalid");
    try expectAttribute(.{ .expires = now + 1000 }, null, "b;max-age=600;max-age=0;max-age = 1000");
}

test "Cookie: parse expires" {
    try expectAttribute(.{ .expires = null }, null, "b;expires=");
    try expectAttribute(.{ .expires = null }, null, "b;expires=abc");
    try expectAttribute(.{ .expires = null }, null, "b;expires=13.22");
    try expectAttribute(.{ .expires = null }, null, "b;expires=33");

    try expectAttribute(.{ .expires = 1918798080 }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 GMT");
    try expectAttribute(.{ .expires = 1784275395 }, null, "b;expires=Fri, 17-Jul-2026 08:03:15 GMT");
    try expectAttribute(.{ .expires = 1918798080 }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 UTC");
    try expectAttribute(.{ .expires = 1784275395 }, null, "b;expires=Fri, 17-Jul-2026 08:03:15 UTC");
    try expectAttribute(.{ .expires = 0 }, null, "b;expires=Thu, 01 Jan 1970 00:00:00 UTC");
    try expectAttribute(.{ .expires = 1918798080 }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 utc");
    try expectAttribute(.{ .expires = 1784275395 }, null, "b;expires=Fri, 17-Jul-2026 08:03:15 Utc");
    // max-age has priority over expires
    try expectAttribute(.{ .expires = lp.datetime.timestamp(.real) + 10 }, null, "b;Max-Age=10; expires=Wed, 21 Oct 2030 07:28:00 GMT");
}

test "Cookie: parse all" {
    try expectCookie(.{
        .name = "user-id",
        .value = "9000",
        .path = "/cms",
        .domain = "lightpanda.io",
    }, "https://lightpanda.io/cms/users", "user-id=9000");

    try expectCookie(.{
        .name = "user-id",
        .value = "9000",
        .path = "/",
        .http_only = true,
        .secure = true,
        .domain = ".lightpanda.io",
        .expires = @floatFromInt(lp.datetime.timestamp(.real) + 30),
    }, "https://lightpanda.io/cms/users", "user-id=9000; HttpOnly; Max-Age=30; Secure; path=/; Domain=lightpanda.io");

    try expectCookie(.{
        .name = "app_session",
        .value = "123",
        .path = "/",
        .http_only = true,
        .secure = false,
        .domain = ".localhost",
        .same_site = .lax,
        .expires = @floatFromInt(lp.datetime.timestamp(.real) + 7200),
    }, "http://localhost:8000/login", "app_session=123; Max-Age=7200; path=/; domain=localhost; httponly; samesite=lax");
}

test "Cookie: parse domain" {
    try expectAttribute(.{ .domain = "lightpanda.io" }, "http://lightpanda.io/", "b");
    try expectAttribute(.{ .domain = "dev.lightpanda.io" }, "http://dev.lightpanda.io/", "b");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://lightpanda.io/", "b;domain=lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://lightpanda.io/", "b;domain=.lightpanda.io");
    try expectAttribute(.{ .domain = ".dev.lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=dev.lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=.lightpanda.io");
    try expectAttribute(.{ .domain = ".localhost" }, "http://localhost/", "b;domain=localhost");
    try expectAttribute(.{ .domain = ".localhost" }, "http://localhost/", "b;domain=.localhost");
    try expectAttribute(.{ .domain = "127.0.0.1" }, "http://127.0.0.1/", "b;domain=127.0.0.1");
    try expectAttribute(.{ .domain = "127.0.0.1" }, "http://127.0.0.1/", "b;domain=.127.0.0.1");

    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=.io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.lightpanda.io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.lightpanda.com");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.example.com");
    try expectError(error.InvalidDomain, "http://127.0.0.1/", "b;domain=0.0.1");
    try expectError(error.InvalidDomain, "http://127.0.0.1/", "b;domain=127.0.0.2");

    try expectError(error.InvalidDomain, "http://attackerexample.com/", "b;domain=example.com");
    try expectError(error.InvalidDomain, "http://attackerexample.com/", "b;domain=.example.com");
    try expectError(error.InvalidDomain, "http://xyzlightpanda.io/", "b;domain=lightpanda.io");
    try expectError(error.InvalidDomain, "http://notlocalhost/", "b;domain=localhost");

    // Public suffixes should be rejected (test PSL entries: "gov.uk", "api.gov.uk")
    try expectError(error.InvalidDomain, "http://example.gov.uk/", "b;domain=gov.uk");
    try expectError(error.InvalidDomain, "http://example.gov.uk/", "b;domain=.gov.uk");
    try expectError(error.InvalidDomain, "http://test.api.gov.uk/", "b;domain=api.gov.uk");

    // Subdomains of public suffixes should still be accepted
    try expectAttribute(.{ .domain = ".example.gov.uk" }, "http://example.gov.uk/", "b;domain=example.gov.uk");
    try expectAttribute(.{ .domain = ".example.gov.uk" }, "http://sub.example.gov.uk/", "b;domain=example.gov.uk");

    // A public-suffix domain identical to the request host downgrades to a
    // host-only cookie
    try expectAttribute(.{ .domain = "gov.uk" }, "http://gov.uk/", "b;domain=gov.uk");
    try expectAttribute(.{ .domain = "gov.uk" }, "http://gov.uk/", "b;domain=.gov.uk");
    try expectAttribute(.{ .domain = "api.gov.uk" }, "http://api.gov.uk/", "b;domain=api.gov.uk");
}

test "Cookie: parse limit" {
    try expectError(error.CookieHeaderSizeExceeded, "http://lightpanda.io/", repeat("v", 8192) ++ ";domain=lightpanda.io");
    try expectError(error.CookieSizeExceeded, "http://lightpanda.io/", repeat("v", 4096) ++ "v;domain=lightpanda.io");
}

const ExpectedCookie = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8,
    domain: []const u8,
    expires: ?f64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: Cookie.SameSite = .lax,
};

fn expectCookie(expected: ExpectedCookie, url: [:0]const u8, set_cookie: []const u8) !void {
    var cookie = try Cookie.parse(testing.allocator, url, set_cookie);
    defer cookie.deinit();

    try testing.expectEqual(expected.name, cookie.name);
    try testing.expectEqual(expected.value, cookie.value);
    try testing.expectEqual(expected.secure, cookie.secure);
    try testing.expectEqual(expected.http_only, cookie.http_only);
    try testing.expectEqual(expected.same_site, cookie.same_site);
    try testing.expectEqual(expected.path, cookie.path);
    try testing.expectEqual(expected.domain, cookie.domain);

    try testing.expectDelta(expected.expires, cookie.expires, 2.0);
}

fn expectAttribute(expected: anytype, url_: ?[:0]const u8, set_cookie: []const u8) !void {
    var cookie = try Cookie.parse(testing.allocator, url_ orelse test_url, set_cookie);
    defer cookie.deinit();

    inline for (@typeInfo(@TypeOf(expected)).@"struct".field_names) |field_name| {
        if (comptime std.mem.eql(u8, field_name, "expires")) {
            switch (@typeInfo(@TypeOf(expected.expires))) {
                .int, .comptime_int => try testing.expectDelta(@as(f64, @floatFromInt(expected.expires)), cookie.expires, 1.0),
                else => try testing.expectDelta(expected.expires, cookie.expires, 1.0),
            }
        } else {
            try testing.expectEqual(@field(expected, field_name), @field(cookie, field_name));
        }
    }
}

fn expectError(expected: anyerror, url: ?[:0]const u8, set_cookie: []const u8) !void {
    try testing.expectError(expected, Cookie.parse(testing.allocator, url orelse test_url, set_cookie));
}

test "Cookie: appliesTo with empty domain" {
    const cookie = Cookie{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "test",
        .value = "value",
        .domain = "",
        .path = "/",
        .expires = null,
    };
    defer cookie.deinit();

    const target = PreparedUri{
        .host = "example.com",
        .path = "/",
        .trustworthy = false,
    };

    try testing.expectEqual(false, cookie.appliesTo(&target, .{ .same_site = true, .is_http = true, .kind = .navigation }));
}

test "Cookie: matchesHost is case-insensitive" {
    const exact = Cookie{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "n",
        .value = "v",
        .domain = "example.com",
        .path = "/",
        .expires = null,
    };
    defer exact.deinit();
    try testing.expectEqual(true, exact.matchesHost("Example.com"));
    try testing.expectEqual(true, exact.matchesHost("EXAMPLE.COM"));
    try testing.expectEqual(false, exact.matchesHost("other.com"));

    const subdomain = Cookie{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .name = "n",
        .value = "v",
        .domain = ".example.com",
        .path = "/",
        .expires = null,
    };
    defer subdomain.deinit();
    try testing.expectEqual(true, subdomain.matchesHost("Example.com"));
    try testing.expectEqual(true, subdomain.matchesHost("API.Example.COM"));
    try testing.expectEqual(false, subdomain.matchesHost("notexample.com"));
}

test "Cookie: parse rejects URL with empty host" {
    try testing.expectError(error.InvalidDomain, Cookie.parse(testing.allocator, "http:///path", "name=value"));
    try testing.expectError(error.InvalidDomain, Cookie.parse(testing.allocator, "http://", "name=value"));
}

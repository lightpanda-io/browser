const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = @import("../../log.zig");
const DateTime = @import("../../datetime.zig").DateTime;
const public_suffix_list = @import("../../data/public_suffix_list.zig").lookup;

pub const LookupOpts = struct {
    request_time: ?i64 = null,
    origin_uri: ?*const Uri = null,
    is_http: bool,
    is_navigation: bool = true,
    prefix: ?[]const u8 = null,
};

pub const Jar = struct {
    allocator: Allocator,
    cookies: std.ArrayListUnmanaged(Cookie),

    pub fn init(allocator: Allocator) Jar {
        return .{
            .cookies = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Jar) void {
        for (self.cookies.items) |c| {
            c.deinit();
        }
        self.cookies.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *Jar) void {
        for (self.cookies.items) |c| {
            c.deinit();
        }
        self.cookies.clearRetainingCapacity();
    }

    pub fn add(
        self: *Jar,
        cookie: Cookie,
        request_time: i64,
    ) !void {
        const is_expired = isCookieExpired(&cookie, request_time);
        defer if (is_expired) {
            cookie.deinit();
        };

        for (self.cookies.items, 0..) |*c, i| {
            if (areCookiesEqual(&cookie, c)) {
                c.deinit();
                if (is_expired) {
                    _ = self.cookies.swapRemove(i);
                } else {
                    self.cookies.items[i] = cookie;
                }
                return;
            }
        }

        if (!is_expired) {
            try self.cookies.append(self.allocator, cookie);
        }
    }

    pub fn removeExpired(self: *Jar, request_time: ?i64) void {
        if (self.cookies.items.len == 0) return;
        const time = request_time orelse std.time.timestamp();
        var i: usize = self.cookies.items.len - 1;
        while (i > 0) {
            defer i -= 1;
            const cookie = &self.cookies.items[i];
            if (isCookieExpired(cookie, time)) {
                self.cookies.swapRemove(i).deinit();
            }
        }
    }

    pub fn forRequest(self: *Jar, target_uri: *const Uri, writer: anytype, opts: LookupOpts) !void {
        const target = PreparedUri{
            .host = (target_uri.host orelse return error.InvalidURI).percent_encoded,
            .path = target_uri.path.percent_encoded,
            .secure = std.mem.eql(u8, target_uri.scheme, "https"),
        };
        const same_site = try areSameSite(opts.origin_uri, target.host);

        removeExpired(self, opts.request_time);

        var first = true;
        for (self.cookies.items) |*cookie| {
            if (!cookie.appliesTo(&target, same_site, opts.is_navigation, opts.is_http)) {
                continue;
            }

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

    pub fn populateFromResponse(self: *Jar, uri: *const Uri, set_cookie: []const u8) !void {
        const c = Cookie.parse(self.allocator, uri, set_cookie) catch |err| {
            log.warn(.web_api, "cookie parse failed", .{ .raw = set_cookie, .err = err });
            return;
        };

        const now = std.time.timestamp();
        try self.add(c, now);
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

fn isCookieExpired(cookie: *const Cookie, now: i64) bool {
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

fn areSameSite(origin_uri_: ?*const std.Uri, target_host: []const u8) !bool {
    const origin_uri = origin_uri_ orelse return true;
    const origin_host = (origin_uri.host orelse return error.InvalidURI).percent_encoded;

    // common case
    if (std.mem.eql(u8, target_host, origin_host)) {
        return true;
    }

    return std.mem.eql(u8, findSecondLevelDomain(target_host), findSecondLevelDomain(origin_host));
}

fn findSecondLevelDomain(host: []const u8) []const u8 {
    var i = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    while (true) {
        i = std.mem.lastIndexOfScalar(u8, host[0..i], '.') orelse return host;
        const strip = i + 1;
        if (public_suffix_list(host[strip..]) == false) {
            return host[strip..];
        }
    }
}

pub const Cookie = struct {
    arena: ArenaAllocator,
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    expires: ?f64,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .none,

    const SameSite = enum {
        strict,
        lax,
        none,
    };

    pub fn deinit(self: *const Cookie) void {
        self.arena.deinit();
    }

    // There's https://datatracker.ietf.org/doc/html/rfc6265 but browsers are
    // far less strict. I only found 2 cases where browsers will reject a cookie:
    //   - a byte 0...32 and 127..255 anywhere in the cookie (the HTTP header
    //     parser might take care of this already)
    //   - any shenanigans with the domain attribute - it has to be the current
    //     domain or one of higher order, exluding TLD.
    // Anything else, will turn into a cookie.
    // Single value? That's a cookie with an emtpy name and a value
    // Key or Values with characters the RFC says aren't allowed? Allowed! (
    //   (as long as the characters are 32...126)
    // Invalid attributes? Ignored.
    // Invalid attribute values? Ignore.
    // Duplicate attributes - use the last valid
    // Value-less attributes with a value? Ignore the value
    pub fn parse(allocator: Allocator, uri: *const std.Uri, str: []const u8) !Cookie {
        try validateCookieString(str);

        const cookie_name, const cookie_value, const rest = parseNameValue(str) catch {
            return error.InvalidNameValue;
        };

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
            const sep = std.mem.indexOfScalarPos(u8, attribute, 0, '=') orelse attribute.len;
            const key_string = trim(attribute[0..sep]);

            if (key_string.len > 8) {
                // not valid, ignore
                continue;
            }

            // Make sure no one changes our max length without also expanding the size of scrap
            std.debug.assert(key_string.len <= 8);

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
                .samesite => {
                    same_site = std.meta.stringToEnum(Cookie.SameSite, std.ascii.lowerString(&scrap, value)) orelse continue;
                },
            }
        }

        if (same_site == .none and secure == null) {
            return error.InsecureSameSite;
        }

        var arena = ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const owned_name = try aa.dupe(u8, cookie_name);
        const owned_value = try aa.dupe(u8, cookie_value);
        const owned_path = try parsePath(aa, uri, path);
        const owned_domain = try parseDomain(aa, uri, domain);

        var normalized_expires: ?f64 = null;
        if (max_age) |ma| {
            normalized_expires = @floatFromInt(std.time.timestamp() + ma);
        } else {
            // max age takes priority over expires
            if (expires) |expires_| {
                var exp_dt = DateTime.parse(expires_, .rfc822) catch null;
                if (exp_dt == null) {
                    if ((expires_.len > 11 and expires_[7] == '-' and expires_[11] == '-')) {
                        // Replace dashes and try again
                        const output = try aa.dupe(u8, expires_);
                        output[7] = ' ';
                        output[11] = ' ';
                        exp_dt = DateTime.parse(output, .rfc822) catch null;
                    }
                }
                if (exp_dt) |dt| {
                    normalized_expires = @floatFromInt(dt.unix(.seconds));
                } else {
                    // Algolia, for example, will call document.setCookie with
                    // an expired value which is literally 'Invalid Date'
                    // (it's trying to do something like: `new Date() + undefined`).
                    log.debug(.web_api, "cookie expires date", .{ .date = expires_ });
                }
            }
        }

        return .{
            .arena = arena,
            .name = owned_name,
            .value = owned_value,
            .path = owned_path,
            .same_site = same_site orelse .lax,
            .secure = secure orelse false,
            .http_only = http_only orelse false,
            .domain = owned_domain,
            .expires = normalized_expires,
        };
    }

    const ValidateCookieError = error{ Empty, InvalidByteSequence };

    /// Returns an error if cookie str length is 0
    /// or contains characters outside of the ascii range 32...126.
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
                const space: Vec = @splat(32);
                const tilde: Vec = @splat(126);
                const chunk: Vec = str[offset..][0..size].*;

                // This creates a mask where invalid characters represented
                // as ones and valid characters as zeros. We then bitCast this
                // into an unsigned integer. If the integer is not equal to 0,
                // we know that we've invalid characters in this chunk.
                // @popCount can also be used but using integers are simpler.
                const mask = (@intFromBool(chunk < space) | @intFromBool(chunk > tilde));
                const reduced: std.meta.Int(.unsigned, size) = @bitCast(mask);

                // Got match.
                if (reduced != 0) {
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
        const slice = str[offset..];
        // Slow path.
        const min, const max = std.mem.minMax(u8, slice);
        if (min < 32 or max > 126) {
            return error.InvalidByteSequence;
        }
    }

    pub fn parsePath(arena: Allocator, uri: ?*const std.Uri, explicit_path: ?[]const u8) ![]const u8 {
        // path attribute value either begins with a '/' or we
        // ignore it and use the "default-path" algorithm
        if (explicit_path) |path| {
            if (path.len > 0 and path[0] == '/') {
                return try arena.dupe(u8, path);
            }
        }

        // default-path
        const url_path = (uri orelse return "/").path;

        const either = url_path.percent_encoded;
        if (either.len == 0 or (either.len == 1 and either[0] == '/')) {
            return "/";
        }

        var owned_path: []const u8 = try percentEncode(arena, url_path, isPathChar);
        const last = std.mem.lastIndexOfScalar(u8, owned_path[1..], '/') orelse {
            return "/";
        };
        return try arena.dupe(u8, owned_path[0 .. last + 1]);
    }

    pub fn parseDomain(arena: Allocator, uri: ?*const std.Uri, explicit_domain: ?[]const u8) ![]const u8 {
        var encoded_host: ?[]const u8 = null;
        if (uri) |uri_| {
            const uri_host = uri_.host orelse return error.InvalidURI;
            const host = try percentEncode(arena, uri_host, isHostChar);
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

                if (std.mem.indexOfScalarPos(u8, owned_domain, 1, '.') == null and std.mem.eql(u8, "localhost", owned_domain[1..]) == false) {
                    // can't set a cookie for a TLD
                    return error.InvalidDomain;
                }
                if (encoded_host) |host| {
                    if (std.mem.endsWith(u8, host, owned_domain[1..]) == false) {
                        return error.InvalidDomain;
                    }
                }

                return owned_domain;
            }
        }

        return encoded_host orelse return error.InvalidDomain; // default-domain
    }

    pub fn percentEncode(arena: Allocator, component: std.Uri.Component, comptime isValidChar: fn (u8) bool) ![]u8 {
        switch (component) {
            .raw => |str| {
                var aw = try std.Io.Writer.Allocating.initCapacity(arena, str.len);
                try std.Uri.Component.percentEncode(&aw.writer, str, isValidChar);
                return aw.written(); // @memory retains memory used before growing
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

    fn parseNameValue(str: []const u8) !struct { []const u8, []const u8, []const u8 } {
        const key_value_end = std.mem.indexOfScalarPos(u8, str, 0, ';') orelse str.len;
        const rest = if (key_value_end == str.len) "" else str[key_value_end + 1 ..];

        const sep = std.mem.indexOfScalarPos(u8, str[0..key_value_end], 0, '=') orelse {
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

    pub fn appliesTo(self: *const Cookie, url: *const PreparedUri, same_site: bool, is_navigation: bool, is_http: bool) bool {
        if (self.http_only and is_http == false) {
            // http only cookies can be accessed from Javascript
            return false;
        }

        if (url.secure == false and self.secure) {
            // secure cookie can only be sent over HTTPs
            return false;
        }

        if (same_site == false) {
            // If we aren't on the "same site" (matching 2nd level domain
            // taking into account public suffix list), then the cookie
            // can only be sent if cookie.same_site == .none, or if
            // we're navigating to (as opposed to, say, loading an image)
            // and cookie.same_site == .lax
            switch (self.same_site) {
                .strict => return false,
                .lax => if (is_navigation == false) return false,
                .none => {},
            }
        }

        {
            if (self.domain[0] == '.') {
                // When a Set-Cookie header has a Domain attribute
                // Then we will _always_ prefix it with a dot, extending its
                // availability to all subdomains (yes, setting the Domain
                // attributes EXPANDS the domains which the cookie will be
                // sent to, to always include all subdomains).
                if (std.mem.eql(u8, url.host, self.domain[1..]) == false and std.mem.endsWith(u8, url.host, self.domain) == false) {
                    return false;
                }
            } else if (std.mem.eql(u8, url.host, self.domain) == false) {
                // When the Domain attribute isn't specific, then the cookie
                // is only sent on an exact match.
                return false;
            }
        }

        {
            if (self.path[self.path.len - 1] == '/') {
                // If our cookie has a trailing slash, we can only match is
                // the target path is a perfix. I.e., if our path is
                // /doc/  we can only match /doc/*
                if (std.mem.startsWith(u8, url.path, self.path) == false) {
                    return false;
                }
            } else {
                // Our cookie path is something like /hello
                if (std.mem.startsWith(u8, url.path, self.path) == false) {
                    // The target path has to either be /hello (it isn't)
                    return false;
                } else if (url.path.len < self.path.len or (url.path.len > self.path.len and url.path[self.path.len] != '/')) {
                    // Or it has to be something like /hello/* (it isn't)
                    // it isn't!
                    return false;
                }
            }
        }
        return true;
    }
};

pub const PreparedUri = struct {
    host: []const u8, // Percent encoded, lower case
    path: []const u8, // Percent encoded
    secure: bool, // True if scheme is https
};

fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

fn trimLeft(str: []const u8) []const u8 {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

fn trimRight(str: []const u8) []const u8 {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

pub fn toLower(str: []u8) []u8 {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
    return str;
}

const testing = @import("../../testing.zig");
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
            try testing.expectEqual(expected.len, jar.cookies.items.len);
            LOOP: for (expected) |e| {
                for (jar.cookies.items) |c| {
                    if (std.mem.eql(u8, e.@"0", c.name) and std.mem.eql(u8, e.@"1", c.value)) {
                        continue :LOOP;
                    }
                }
                std.debug.print("Cookie ({s}={s}) not found", .{ e.@"0", e.@"1" });
                return error.CookieNotFound;
            }
        }
    }.expect;

    const now = std.time.timestamp();

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=9000;Max-Age=0"), now);
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=9000"), now);
    try expectCookies(&.{.{ "over", "9000" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=9000!!"), now);
    try expectCookies(&.{.{ "over", "9000!!" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "spice=flow"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flow" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "spice=flows;Path=/"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=9001;Path=/other"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=9002;Path=/;Domain=lightpanda.io"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" }, .{ "over", "9002" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "over=x;Path=/other;Max-Age=-200"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9002" } }, jar);
}

test "Jar: forRequest" {
    const expectCookies = struct {
        fn expect(expected: []const u8, jar: *Jar, target_uri: Uri, opts: LookupOpts) !void {
            var arr: std.ArrayListUnmanaged(u8) = .empty;
            defer arr.deinit(testing.allocator);
            try jar.forRequest(&target_uri, arr.writer(testing.allocator), opts);
            try testing.expectEqual(expected, arr.items);
        }
    }.expect;

    const now = std.time.timestamp();

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const test_uri_2 = Uri.parse("http://test.lightpanda.io/") catch unreachable;

    {
        // test with no cookies
        try expectCookies("", &jar, test_uri, .{ .is_http = true });
    }

    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "global1=1"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "global2=2;Max-Age=30;domain=lightpanda.io"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "path1=3;Path=/about"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "path2=4;Path=/docs/"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "secure=5;Secure"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "sitenone=6;SameSite=None;Path=/x/;Secure"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "sitelax=7;SameSite=Lax;Path=/x/"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri, "sitestrict=8;SameSite=Strict;Path=/x/"), now);
    try jar.add(try Cookie.parse(testing.allocator, &test_uri_2, "domain1=9;domain=test.lightpanda.io"), now);

    // nothing fancy here
    try expectCookies("global1=1; global2=2", &jar, test_uri, .{ .is_http = true });
    try expectCookies("global1=1; global2=2", &jar, test_uri, .{ .origin_uri = &test_uri, .is_navigation = false, .is_http = true });

    // We have a cookie where Domain=lightpanda.io
    // This should _not_ match xyxlightpanda.io
    try expectCookies("", &jar, try std.Uri.parse("http://anothersitelightpanda.io/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // matching path without trailing /
    try expectCookies("global1=1; global2=2; path1=3", &jar, try std.Uri.parse("http://lightpanda.io/about"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // incomplete prefix path
    try expectCookies("global1=1; global2=2", &jar, try std.Uri.parse("http://lightpanda.io/abou"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // path doesn't match
    try expectCookies("global1=1; global2=2", &jar, try std.Uri.parse("http://lightpanda.io/aboutus"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // path doesn't match cookie directory
    try expectCookies("global1=1; global2=2", &jar, try std.Uri.parse("http://lightpanda.io/docs"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // exact directory match
    try expectCookies("global1=1; global2=2; path2=4", &jar, try std.Uri.parse("http://lightpanda.io/docs/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // sub directory match
    try expectCookies("global1=1; global2=2; path2=4", &jar, try std.Uri.parse("http://lightpanda.io/docs/more"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // secure
    try expectCookies("global1=1; global2=2; secure=5", &jar, try std.Uri.parse("https://lightpanda.io/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // navigational cross domain, secure
    try expectCookies("global1=1; global2=2; secure=5; sitenone=6; sitelax=7", &jar, try std.Uri.parse("https://lightpanda.io/x/"), .{
        .origin_uri = &(try std.Uri.parse("https://example.com/")),
        .is_http = true,
    });

    // navigational cross domain, insecure
    try expectCookies("global1=1; global2=2; sitelax=7", &jar, try std.Uri.parse("http://lightpanda.io/x/"), .{
        .origin_uri = &(try std.Uri.parse("https://example.com/")),
        .is_http = true,
    });

    // non-navigational cross domain, insecure
    try expectCookies("", &jar, try std.Uri.parse("http://lightpanda.io/x/"), .{
        .origin_uri = &(try std.Uri.parse("https://example.com/")),
        .is_http = true,
        .is_navigation = false,
    });

    // non-navigational cross domain, secure
    try expectCookies("sitenone=6", &jar, try std.Uri.parse("https://lightpanda.io/x/"), .{
        .origin_uri = &(try std.Uri.parse("https://example.com/")),
        .is_http = true,
        .is_navigation = false,
    });

    // non-navigational same origin
    try expectCookies("global1=1; global2=2; sitelax=7; sitestrict=8", &jar, try std.Uri.parse("http://lightpanda.io/x/"), .{
        .origin_uri = &(try std.Uri.parse("https://lightpanda.io/")),
        .is_http = true,
        .is_navigation = false,
    });

    // exact domain match + suffix
    try expectCookies("global2=2; domain1=9", &jar, try std.Uri.parse("http://test.lightpanda.io/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // domain suffix match + suffix
    try expectCookies("global2=2; domain1=9", &jar, try std.Uri.parse("http://1.test.lightpanda.io/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    // non-matching domain
    try expectCookies("global2=2", &jar, try std.Uri.parse("http://other.lightpanda.io/"), .{
        .origin_uri = &test_uri,
        .is_http = true,
    });

    const l = jar.cookies.items.len;
    try expectCookies("global1=1", &jar, test_uri, .{
        .request_time = now + 100,
        .origin_uri = &test_uri,
        .is_http = true,
    });
    try testing.expectEqual(l - 1, jar.cookies.items.len);

    // If you add more cases after this point, note that the above test removes
    // the 'global2' cookie
}

test "Cookie: parse key=value" {
    try expectError(error.Empty, null, "");
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 30, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', 127, '=', 'b' });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 20 });
    try expectError(error.InvalidByteSequence, null, &.{ 'a', '=', 'b', 128 });

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

    try expectAttribute(.{ .expires = std.time.timestamp() + 13 }, null, "b;max-age=13");
    try expectAttribute(.{ .expires = std.time.timestamp() + -22 }, null, "b;max-age=-22");
    try expectAttribute(.{ .expires = std.time.timestamp() + 4294967296 }, null, "b;max-age=4294967296");
    try expectAttribute(.{ .expires = std.time.timestamp() + -4294967296 }, null, "b;Max-Age= -4294967296");
    try expectAttribute(.{ .expires = std.time.timestamp() + 0 }, null, "b; Max-Age=0");
    try expectAttribute(.{ .expires = std.time.timestamp() + 500 }, null, "b; Max-Age = 500  ; Max-Age=invalid");
    try expectAttribute(.{ .expires = std.time.timestamp() + 1000 }, null, "b;max-age=600;max-age=0;max-age = 1000");
}

test "Cookie: parse expires" {
    try expectAttribute(.{ .expires = null }, null, "b;expires=");
    try expectAttribute(.{ .expires = null }, null, "b;expires=abc");
    try expectAttribute(.{ .expires = null }, null, "b;expires=13.22");
    try expectAttribute(.{ .expires = null }, null, "b;expires=33");

    try expectAttribute(.{ .expires = 1918798080 }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 GMT");
    try expectAttribute(.{ .expires = 1784275395 }, null, "b;expires=Fri, 17-Jul-2026 08:03:15 GMT");
    // max-age has priority over expires
    try expectAttribute(.{ .expires = std.time.timestamp() + 10 }, null, "b;Max-Age=10; expires=Wed, 21 Oct 2030 07:28:00 GMT");
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
        .expires = @floatFromInt(std.time.timestamp() + 30),
    }, "https://lightpanda.io/cms/users", "user-id=9000; HttpOnly; Max-Age=30; Secure; path=/; Domain=lightpanda.io");

    try expectCookie(.{
        .name = "app_session",
        .value = "123",
        .path = "/",
        .http_only = true,
        .secure = false,
        .domain = ".localhost",
        .same_site = .lax,
        .expires = @floatFromInt(std.time.timestamp() + 7200),
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

    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=.io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.lightpanda.io");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.lightpanda.com");
    try expectError(error.InvalidDomain, "http://lightpanda.io/", "b;domain=other.example.com");
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

fn expectCookie(expected: ExpectedCookie, url: []const u8, set_cookie: []const u8) !void {
    const uri = try Uri.parse(url);
    var cookie = try Cookie.parse(testing.allocator, &uri, set_cookie);
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

fn expectAttribute(expected: anytype, url: ?[]const u8, set_cookie: []const u8) !void {
    const uri = if (url) |u| try Uri.parse(u) else test_uri;
    var cookie = try Cookie.parse(testing.allocator, &uri, set_cookie);
    defer cookie.deinit();

    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "expires")) {
            switch (@typeInfo(@TypeOf(expected.expires))) {
                .int, .comptime_int => try testing.expectDelta(@as(f64, @floatFromInt(expected.expires)), cookie.expires, 1.0),
                else => try testing.expectDelta(expected.expires, cookie.expires, 1.0),
            }
        } else {
            try testing.expectEqual(@field(expected, f.name), @field(cookie, f.name));
        }
    }
}

fn expectError(expected: anyerror, url: ?[]const u8, set_cookie: []const u8) !void {
    const uri = if (url) |u| try Uri.parse(u) else test_uri;
    try testing.expectError(expected, Cookie.parse(testing.allocator, &uri, set_cookie));
}

const test_uri = Uri.parse("http://lightpanda.io/") catch unreachable;

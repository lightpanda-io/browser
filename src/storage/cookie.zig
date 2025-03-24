const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const DateTime = @import("../datetime.zig").DateTime;
const public_suffix_list = @import("../data/public_suffix_list.zig").lookup;

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

    pub fn forRequest(
        self: *Jar,
        allocator: Allocator,
        request_time: i64,
        origin_uri: ?Uri,
        target_uri: Uri,
        navigation: bool,
    ) !CookieList {
        const target_path = target_uri.path.percent_encoded;
        const target_host = (target_uri.host orelse return error.InvalidURI).percent_encoded;

        const same_site = try areSameSite(origin_uri, target_host);
        const is_secure = std.mem.eql(u8, target_uri.scheme, "https");

        var matching: std.ArrayListUnmanaged(*const Cookie) = .{};

        var i: usize = 0;
        var cookies = self.cookies.items;
        while (i < cookies.len) {
            const cookie = &cookies[i];

            if (isCookieExpired(cookie, request_time)) {
                cookie.deinit();
                _ = self.cookies.swapRemove(i);
                // don't increment i !
                continue;
            }
            i += 1;

            if (is_secure == false and cookie.secure) {
                // secure cookie can only be sent over HTTPs
                continue;
            }

            if (same_site == false) {
                // If we aren't on the "same site" (matching 2nd level domain
                // taking into account public suffix list), then the cookie
                // can only be sent if cookie.same_site == .none, or if
                // we're navigating to (as opposed to, say, loading an image)
                // and cookie.same_site == .lax
                switch (cookie.same_site) {
                    .strict => continue,
                    .lax => if (navigation == false) continue,
                    .none => {},
                }
            }

            {
                const domain = cookie.domain;
                if (domain[0] == '.') {
                    // When a Set-Cookie header has a Domain attribute
                    // Then we will _always_ prefix it with a dot, extending its
                    // availability to all subdomains (yes, setting the Domain
                    // attributes EXPANDS the domains which the cookie will be
                    // sent to, to always include all subdomains).
                    if (std.mem.eql(u8, target_host, domain[1..]) == false and std.mem.endsWith(u8, target_host, domain) == false) {
                        continue;
                    }
                } else if (std.mem.eql(u8, target_host, domain) == false) {
                    // When the Domain attribute isn't specific, then the cookie
                    // is only sent on an exact match.
                    continue;
                }
            }

            {
                const path = cookie.path;
                if (path[path.len - 1] == '/') {
                    // If our cookie has a trailing slash, we can only match is
                    // the target path is a perfix. I.e., if our path is
                    // /doc/  we can only match /doc/*
                    if (std.mem.startsWith(u8, target_path, path) == false) {
                        continue;
                    }
                } else {
                    // Our cookie path is something like /hello
                    if (std.mem.startsWith(u8, target_path, path) == false) {
                        // The target path has to either be /hello (it isn't)
                        continue;
                    } else if (target_path.len < path.len or (target_path.len > path.len and target_path[path.len] != '/')) {
                        // Or it has to be something like /hello/* (it isn't)
                        // it isn't!
                        continue;
                    }
                }
            }
            // we have a match!
            try matching.append(allocator, cookie);
        }

        return .{ ._cookies = matching };
    }
};

pub const CookieList = struct {
    _cookies: std.ArrayListUnmanaged(*const Cookie) = .{},

    pub fn deinit(self: *CookieList, allocator: Allocator) void {
        self._cookies.deinit(allocator);
    }

    pub fn cookies(self: *const CookieList) []*const Cookie {
        return self._cookies.items;
    }

    pub fn len(self: *const CookieList) usize {
        return self._cookies.items.len;
    }

    pub fn write(self: *const CookieList, writer: anytype) !void {
        const all = self._cookies.items;
        if (all.len == 0) {
            return;
        }
        try writeCookie(all[0], writer);
        for (all[1..]) |cookie| {
            try writer.writeAll("; ");
            try writeCookie(cookie, writer);
        }
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
    return ce <= now;
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

fn areSameSite(origin_uri_: ?std.Uri, target_host: []const u8) !bool {
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
    path: []const u8,
    domain: []const u8,
    expires: ?i64,
    secure: bool,
    http_only: bool,
    same_site: SameSite,

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
    pub fn parse(allocator: Allocator, uri: std.Uri, str: []const u8) !Cookie {
        if (str.len == 0) {
            // this check is necessary, `std.mem.minMax` asserts len > 0
            return error.Empty;
        }

        const host = (uri.host orelse return error.InvalidURI).percent_encoded;

        {
            const min, const max = std.mem.minMax(u8, str);
            if (min < 32 or max > 126) {
                return error.InvalidByteSequence;
            }
        }

        const cookie_name, const cookie_value, const rest = parseNameValue(str) catch {
            return error.InvalidNameValue;
        };

        var scrap: [8]u8 = undefined;

        var path: ?[]const u8 = null;
        var domain: ?[]const u8 = null;
        var secure: ?bool = null;
        var max_age: ?i64 = null;
        var http_only: ?bool = null;
        var expires: ?DateTime = null;
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

            var value = if (sep == attribute.len) "" else trim(attribute[sep + 1 ..]);
            switch (key) {
                .path => {
                    // path attribute value either begins with a '/' or we
                    // ignore it and use the "default-path" algorithm
                    if (value.len > 0 and value[0] == '/') {
                        path = value;
                    }
                },
                .domain => {
                    if (value.len == 0) {
                        continue;
                    }
                    if (value[0] == '.') {
                        // leading dot is ignored
                        value = value[1..];
                    }

                    if (std.mem.indexOfScalarPos(u8, value, 0, '.') == null) {
                        // can't set a cookie for a TLD
                        return error.InvalidDomain;
                    }

                    if (std.mem.endsWith(u8, host, value) == false) {
                        return error.InvalidDomain;
                    }
                    domain = value;
                },
                .secure => secure = true,
                .@"max-age" => max_age = std.fmt.parseInt(i64, value, 10) catch continue,
                .expires => expires = DateTime.parse(value, .rfc822) catch continue,
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
        const owned_path = if (path) |p|
            try aa.dupe(u8, p)
        else
            try defaultPath(aa, uri.path.percent_encoded);

        const owned_domain = if (domain) |d| blk: {
            const s = try aa.alloc(u8, d.len + 1);
            s[0] = '.';
            @memcpy(s[1..], d);
            break :blk s;
        } else blk: {
            break :blk try aa.dupe(u8, host);
        };

        var normalized_expires: ?i64 = null;
        if (max_age) |ma| {
            normalized_expires = std.time.timestamp() + ma;
        } else {
            // max age takes priority over expires
            if (expires) |e| {
                normalized_expires = e.sub(DateTime.now(), .seconds);
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
};

fn defaultPath(allocator: Allocator, document_path: []const u8) ![]const u8 {
    if (document_path.len == 0 or (document_path.len == 1 and document_path[0] == '/')) {
        return "/";
    }
    const last = std.mem.lastIndexOfScalar(u8, document_path[1..], '/') orelse {
        return "/";
    };
    return try allocator.dupe(u8, document_path[0 .. last + 1]);
}

fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

fn trimLeft(str: []const u8) []const u8 {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

fn trimRight(str: []const u8) []const u8 {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

const testing = @import("../testing.zig");
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

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=9000;Max-Age=0"), now);
    try expectCookies(&.{}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=9000"), now);
    try expectCookies(&.{.{ "over", "9000" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=9000!!"), now);
    try expectCookies(&.{.{ "over", "9000!!" }}, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "spice=flow"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flow" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "spice=flows;Path=/"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=9001;Path=/other"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=9002;Path=/;Domain=lightpanda.io"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9001" }, .{ "over", "9002" } }, jar);

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "over=x;Path=/other;Max-Age=-200"), now);
    try expectCookies(&.{ .{ "over", "9000!!" }, .{ "spice", "flows" }, .{ "over", "9002" } }, jar);
}

test "Jar: forRequest" {
    const expectCookies = struct {
        fn expect(expected: []const []const u8, list: *CookieList) !void {
            defer list.deinit(testing.allocator);
            const acutal_cookies = list._cookies.items;

            try testing.expectEqual(expected.len, acutal_cookies.len);
            LOOP: for (expected) |e| {
                for (acutal_cookies) |c| {
                    if (std.mem.eql(u8, e, c.name)) {
                        continue :LOOP;
                    }
                }
                std.debug.print("Cookie '{s}' not found", .{e});
                return error.CookieNotFound;
            }
        }
    }.expect;

    const now = std.time.timestamp();

    var jar = Jar.init(testing.allocator);
    defer jar.deinit();

    const test_uri_2 = Uri.parse("http://test.lightpanda.io/") catch unreachable;

    {
        // test with no cookies
        var matches = try jar.forRequest(testing.allocator, now, test_uri, test_uri, true);
        try expectCookies(&.{}, &matches);
    }

    try jar.add(try Cookie.parse(testing.allocator, test_uri, "global1=1"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "global2=2;Max-Age=30;domain=lightpanda.io"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "path1=3;Path=/about"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "path2=4;Path=/docs/"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "secure=5;Secure"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "sitenone=6;SameSite=None;Path=/x/;Secure"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "sitelax=7;SameSite=Lax;Path=/x/"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri, "sitestrict=8;SameSite=Strict;Path=/x/"), now);
    try jar.add(try Cookie.parse(testing.allocator, test_uri_2, "domain1=9;domain=test.lightpanda.io"), now);

    {
        // nothing fancy here
        var matches = try jar.forRequest(testing.allocator, now, test_uri, test_uri, true);
        try expectCookies(&.{ "global1", "global2" }, &matches);
    }

    {
        // We have a cookie where Domain=lightpanda.io
        // This should _not_ match xyxlightpanda.io
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://anothersitelightpanda.io/"),
            true,
        );
        try expectCookies(&.{}, &matches);
    }

    {
        // matching path without trailing /
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/about"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "path1" }, &matches);
    }

    {
        // incomplete prefix path
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/abou"),
            true,
        );
        try expectCookies(&.{ "global1", "global2" }, &matches);
    }

    {
        // path doesn't match
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/aboutus"),
            true,
        );
        try expectCookies(&.{ "global1", "global2" }, &matches);
    }

    {
        // path doesn't match cookie directory
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/docs"),
            true,
        );
        try expectCookies(&.{ "global1", "global2" }, &matches);
    }

    {
        // exact directory match
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/docs/"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "path2" }, &matches);
    }

    {
        // sub directory match
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://lightpanda.io/docs/more"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "path2" }, &matches);
    }

    {
        // secure
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("https://lightpanda.io/"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "secure" }, &matches);
    }

    {
        // navigational cross domain, secure
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            try std.Uri.parse("https://example.com/"),
            try std.Uri.parse("https://lightpanda.io/x/"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "sitenone", "sitelax", "secure" }, &matches);
    }

    {
        // navigational cross domain, insecure
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            try std.Uri.parse("http://example.com/"),
            try std.Uri.parse("http://lightpanda.io/x/"),
            true,
        );
        try expectCookies(&.{ "global1", "global2", "sitelax" }, &matches);
    }

    {
        // non-navigational cross domain, insecure
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            try std.Uri.parse("http://example.com/"),
            try std.Uri.parse("http://lightpanda.io/x/"),
            false,
        );
        try expectCookies(&.{}, &matches);
    }

    {
        // non-navigational cross domain, secure
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            try std.Uri.parse("https://example.com/"),
            try std.Uri.parse("https://lightpanda.io/x/"),
            false,
        );
        try expectCookies(&.{"sitenone"}, &matches);
    }

    {
        // non-navigational same origin
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            try std.Uri.parse("http://lightpanda.io/"),
            try std.Uri.parse("http://lightpanda.io/x/"),
            false,
        );
        try expectCookies(&.{ "global1", "global2", "sitelax", "sitestrict" }, &matches);
    }

    {
        // exact domain match + suffix
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://test.lightpanda.io/"),
            true,
        );
        try expectCookies(&.{ "global2", "domain1" }, &matches);
    }

    {
        // domain suffix match + suffix
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://1.test.lightpanda.io/"),
            true,
        );
        try expectCookies(&.{ "global2", "domain1" }, &matches);
    }

    {
        // non-matching domain
        var matches = try jar.forRequest(
            testing.allocator,
            now,
            test_uri,
            try std.Uri.parse("http://other.lightpanda.io/"),
            true,
        );
        try expectCookies(&.{"global2"}, &matches);
    }

    {
        // cookie has expired
        const l = jar.cookies.items.len;
        var matches = try jar.forRequest(testing.allocator, now + 100, test_uri, test_uri, true);
        try expectCookies(&.{"global1"}, &matches);
        try testing.expectEqual(l - 1, jar.cookies.items.len);
    }

    // If you add more cases after this point, note that the above test removes
    // the 'global2' cookie
}

test "CookieList: write" {
    var arr: std.ArrayListUnmanaged(u8) = .{};
    defer arr.deinit(testing.allocator);

    var cookie_list = CookieList{};
    defer cookie_list.deinit(testing.allocator);

    const c1 = try Cookie.parse(testing.allocator, test_uri, "cookie_name=cookie_value");
    defer c1.deinit();
    {
        try cookie_list._cookies.append(testing.allocator, &c1);
        try cookie_list.write(arr.writer(testing.allocator));
        try testing.expectEqual("cookie_name=cookie_value", arr.items);
    }

    const c2 = try Cookie.parse(testing.allocator, test_uri, "x84");
    defer c2.deinit();
    {
        arr.clearRetainingCapacity();
        try cookie_list._cookies.append(testing.allocator, &c2);
        try cookie_list.write(arr.writer(testing.allocator));
        try testing.expectEqual("cookie_name=cookie_value; x84", arr.items);
    }

    const c3 = try Cookie.parse(testing.allocator, test_uri, "nope=");
    defer c3.deinit();
    {
        arr.clearRetainingCapacity();
        try cookie_list._cookies.append(testing.allocator, &c3);
        try cookie_list.write(arr.writer(testing.allocator));
        try testing.expectEqual("cookie_name=cookie_value; x84; nope=", arr.items);
    }
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

    try expectAttribute(.{ .expires = 1918798080 - std.time.timestamp() }, null, "b;expires=Wed, 21 Oct 2030 07:28:00 GMT");
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
        .expires = std.time.timestamp() + 30,
    }, "https://lightpanda.io/cms/users", "user-id=9000; HttpOnly; Max-Age=30; Secure; path=/; Domain=lightpanda.io");
}

test "Cookie: parse domain" {
    try expectAttribute(.{ .domain = "lightpanda.io" }, "http://lightpanda.io/", "b");
    try expectAttribute(.{ .domain = "dev.lightpanda.io" }, "http://dev.lightpanda.io/", "b");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://lightpanda.io/", "b;domain=lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://lightpanda.io/", "b;domain=.lightpanda.io");
    try expectAttribute(.{ .domain = ".dev.lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=dev.lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=lightpanda.io");
    try expectAttribute(.{ .domain = ".lightpanda.io" }, "http://dev.lightpanda.io/", "b;domain=.lightpanda.io");

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
    expires: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: Cookie.SameSite = .lax,
};

fn expectCookie(expected: ExpectedCookie, url: []const u8, set_cookie: []const u8) !void {
    const uri = try Uri.parse(url);
    var cookie = try Cookie.parse(testing.allocator, uri, set_cookie);
    defer cookie.deinit();

    try testing.expectEqual(expected.name, cookie.name);
    try testing.expectEqual(expected.value, cookie.value);
    try testing.expectEqual(expected.secure, cookie.secure);
    try testing.expectEqual(expected.http_only, cookie.http_only);
    try testing.expectEqual(expected.same_site, cookie.same_site);
    try testing.expectEqual(expected.path, cookie.path);
    try testing.expectEqual(expected.domain, cookie.domain);

    try testing.expectDelta(expected.expires, cookie.expires, 2);
}

fn expectAttribute(expected: anytype, url: ?[]const u8, set_cookie: []const u8) !void {
    const uri = if (url) |u| try Uri.parse(u) else test_uri;
    var cookie = try Cookie.parse(testing.allocator, uri, set_cookie);
    defer cookie.deinit();

    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "expires")) {
            try testing.expectDelta(expected.expires, cookie.expires, 1);
        } else {
            try testing.expectEqual(@field(expected, f.name), @field(cookie, f.name));
        }
    }
}

fn expectError(expected: anyerror, url: ?[]const u8, set_cookie: []const u8) !void {
    const uri = if (url) |u| try Uri.parse(u) else test_uri;
    try testing.expectError(expected, Cookie.parse(testing.allocator, uri, set_cookie));
}

const test_uri = Uri.parse("http://lightpanda.io/") catch unreachable;

const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const DateTime = @import("../datetime.zig").DateTime;

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

        var arena = ArenaAllocator.init(allocator);
        errdefer arena.deinit();

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

test "Cookie: parse httponly" {
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

test "Cookie: parse strict" {
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite");
    try expectAttribute(.{ .same_site = .lax }, null, "b;samesite=lax");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Lax  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Other  ");
    try expectAttribute(.{ .same_site = .lax }, null, "b;  SameSite=Nope  ");

    try expectAttribute(.{ .same_site = .none }, null, "b;  samesite=none  ");
    try expectAttribute(.{ .same_site = .none }, null, "b;  SameSite=None  ");
    try expectAttribute(.{ .same_site = .none }, null, "b;  SameSite=None;");
    try expectAttribute(.{ .same_site = .none }, null, "b; SameSite=None");

    try expectAttribute(.{ .same_site = .strict }, null, "b;  samesite=Strict  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSite=  STRICT  ");
    try expectAttribute(.{ .same_site = .strict }, null, "b;  SameSITE=strict;");
    try expectAttribute(.{ .same_site = .strict }, null, "b; SameSite=Strict");

    try expectAttribute(.{ .same_site = .none }, null, "b; SameSite=Strict; SameSite=lax; SameSite=NONE");
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
    const uri = if (url) |u| try Uri.parse(u) else dummy_test_uri;
    var cookie = try Cookie.parse(testing.allocator, uri, set_cookie);
    defer cookie.deinit();

    inline for (@typeInfo(@TypeOf(expected)).Struct.fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "expires")) {
            try testing.expectDelta(expected.expires, cookie.expires, 1);
        } else {
            try testing.expectEqual(@field(expected, f.name), @field(cookie, f.name));
        }
    }
}

fn expectError(expected: anyerror, url: ?[]const u8, set_cookie: []const u8) !void {
    const uri = if (url) |u| try Uri.parse(u) else dummy_test_uri;
    try testing.expectError(expected, Cookie.parse(testing.allocator, uri, set_cookie));
}

const dummy_test_uri = Uri.parse("http://lightpanda.io/") catch unreachable;

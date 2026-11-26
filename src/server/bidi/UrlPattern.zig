// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// A parsed network.UrlPattern, the url filter of a network intercept.
// https://w3c.github.io/webdriver-bidi/#type-network-UrlPattern
//
// Unlike CDP's Fetch patterns, there are no wildcards: each component the
// pattern has must be equal to the url's. A null component matches anything.

const std = @import("std");

const U = @import("../../sys/url.zig");
const URL = @import("../../browser/URL.zig");

const UrlPattern = @This();

// The scheme, without the ":".
protocol: ?[]const u8 = null,
hostname: ?[]const u8 = null,
// "" means the scheme's default port.
port: ?[]const u8 = null,
pathname: ?[]const u8 = null,
// The query, without the "?".
search: ?[]const u8 = null,

// network.UrlPattern as the client sends it: a network.UrlPatternPattern
// (type "pattern") or a network.UrlPatternString (type "string").
pub const Input = struct {
    type: enum { string, pattern },
    pattern: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    port: ?[]const u8 = null,
    pathname: ?[]const u8 = null,
    search: ?[]const u8 = null,
};

// The spec's "parse URL pattern". Every error is the spec's invalid argument.
pub fn parse(arena: std.mem.Allocator, input: Input) error{ InvalidArgument, OutOfMemory }!UrlPattern {
    if (input.type == .string) {
        const pattern = input.pattern orelse return error.InvalidArgument;
        return fromUrl(arena, try unescape(arena, pattern), .{});
    }

    // Build a url from the components, with placeholders for the missing
    // ones, then parse it: the parser normalizes each component.
    var url: std.ArrayList(u8) = .empty;

    if (input.protocol) |raw| {
        const protocol = try unescapeNonEmpty(arena, raw);
        for (protocol) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
                return error.InvalidArgument;
            }
        }
        try url.appendSlice(arena, protocol);
    } else {
        try url.appendSlice(arena, "http");
    }

    const scheme = try std.ascii.allocLowerString(arena, url.items);
    try url.append(arena, ':');
    if (URL.isSpecialScheme(scheme)) {
        try url.appendSlice(arena, "//");
    }

    if (input.hostname) |raw| {
        if (std.mem.eql(u8, scheme, "file")) {
            return error.InvalidArgument;
        }
        const hostname = try unescapeNonEmpty(arena, raw);
        var inside_brackets = false;
        for (hostname) |c| {
            switch (c) {
                '/', '?', '#' => return error.InvalidArgument,
                ':' => if (!inside_brackets) return error.InvalidArgument,
                '[' => inside_brackets = true,
                ']' => inside_brackets = false,
                else => {},
            }
        }
        try url.appendSlice(arena, hostname);
    } else if (std.mem.eql(u8, scheme, "file") == false) {
        try url.appendSlice(arena, "placeholder");
    }

    if (input.port) |raw| {
        const port = try unescapeNonEmpty(arena, raw);
        for (port) |c| {
            if (!std.ascii.isDigit(c)) {
                return error.InvalidArgument;
            }
        }
        try url.append(arena, ':');
        try url.appendSlice(arena, port);
    }

    if (input.pathname) |raw| {
        const pathname = try unescape(arena, raw);
        if (std.mem.findAny(u8, pathname, "?#") != null) {
            return error.InvalidArgument;
        }
        if (!std.mem.startsWith(u8, pathname, "/")) {
            try url.append(arena, '/');
        }
        try url.appendSlice(arena, pathname);
    }

    if (input.search) |raw| {
        const search = try unescape(arena, raw);
        if (std.mem.findScalar(u8, search, '#') != null) {
            return error.InvalidArgument;
        }
        if (!std.mem.startsWith(u8, search, "?")) {
            try url.append(arena, '?');
        }
        try url.appendSlice(arena, search);
    }

    return fromUrl(arena, url.items, .{
        .protocol = input.protocol != null,
        .hostname = input.hostname != null,
        .port = input.port != null,
        .pathname = input.pathname != null,
        .search = input.search != null,
    });
}

// A copy of the pattern in `allocator`. `parse` leaves temporary buffers
// in its arena: parse in a short-lived arena, then keep only this copy.
pub fn dupe(self: *const UrlPattern, allocator: std.mem.Allocator) !UrlPattern {
    return .{
        .protocol = try dupeComponent(allocator, self.protocol),
        .hostname = try dupeComponent(allocator, self.hostname),
        .port = try dupeComponent(allocator, self.port),
        .pathname = try dupeComponent(allocator, self.pathname),
        .search = try dupeComponent(allocator, self.search),
    };
}

fn dupeComponent(allocator: std.mem.Allocator, component: ?[]const u8) !?[]const u8 {
    const value = component orelse return null;
    return try allocator.dupe(u8, value);
}

// The spec's "match URL pattern". `url` is a serialized url, like a
// request's url.
pub fn matches(self: *const UrlPattern, url: [:0]const u8) bool {
    if (self.protocol) |protocol| {
        if (!std.mem.eql(u8, protocol, schemeOf(url))) return false;
    }
    if (self.hostname) |hostname| {
        if (!std.mem.eql(u8, hostname, URL.getHostname(url))) return false;
    }
    if (self.port) |port| {
        const url_port = portOf(url) orelse return false;
        if (!std.mem.eql(u8, port, url_port)) return false;
    }
    if (self.pathname) |pathname| {
        if (!std.mem.eql(u8, pathname, URL.getPathname(url))) return false;
    }
    if (self.search) |search| {
        if (!std.mem.eql(u8, search, query(url))) return false;
    }
    return true;
}

// Which components the pattern has. A string pattern has them all.
const Has = struct {
    protocol: bool = true,
    hostname: bool = true,
    port: bool = true,
    pathname: bool = true,
    search: bool = true,
};

// Parses `raw` and keeps the components the pattern has, copied in `arena`
// since the parsed url is freed on return. Reading the url record, rather
// than its serialization, keeps the spec's nulls apart from empty strings:
// a url with no host, or with an empty path.
fn fromUrl(arena: std.mem.Allocator, raw: []const u8, has: Has) !UrlPattern {
    var err: i32 = 0;
    const url = U.url_parse(raw.ptr, raw.len, &err) orelse return error.InvalidArgument;
    defer U.url_free(url);

    const scheme = U.urlGetScheme(url);
    return .{
        .protocol = if (has.protocol) try arena.dupe(u8, scheme) else null,
        .hostname = if (has.hostname) try dupeComponent(arena, U.urlGetHostname(url)) else null,
        .port = if (has.port) try parsedPort(arena, url, scheme) else null,
        .pathname = if (has.pathname) try parsedPathname(arena, url) else null,
        .search = if (has.search) try arena.dupe(u8, U.urlGetQuery(url) orelse "") else null,
    };
}

// "" for the scheme's default port, the port when there's another one,
// else null. The parser drops a default port, so it reads as null.
fn parsedPort(arena: std.mem.Allocator, url: *const U.Url, scheme: []const u8) !?[]const u8 {
    if (U.urlGetPort(url)) |port| {
        return try arena.print("{d}", .{port});
    }
    return if (URL.defaultPort(scheme) != null) "" else null;
}

// Null for an empty path, like "foo://host"'s.
fn parsedPathname(arena: std.mem.Allocator, url: *const U.Url) !?[]const u8 {
    const path = U.urlGetPath(url);
    if (path.len == 0) {
        return null;
    }
    return try arena.dupe(u8, path);
}

// The spec's "unescape URL pattern": a backslash escapes the next
// character. The characters URLPattern gives a meaning to are forbidden
// unless escaped, so that patterns can get that syntax later.
fn unescape(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = try .initCapacity(arena, pattern.len);
    var escaped = false;
    for (pattern) |c| {
        if (!escaped) {
            switch (c) {
                '(', ')', '*', '{', '}' => return error.InvalidArgument,
                '\\' => {
                    escaped = true;
                    continue;
                },
                else => {},
            }
        }
        result.appendAssumeCapacity(c);
        escaped = false;
    }
    return result.items;
}

fn unescapeNonEmpty(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    if (pattern.len == 0) {
        return error.InvalidArgument;
    }
    return unescape(arena, pattern);
}

fn schemeOf(url: []const u8) []const u8 {
    const protocol = URL.getProtocol(url);
    return protocol[0..protocol.len -| 1];
}

// The query without its "?"; "" when there's none.
fn query(url: [:0]const u8) []const u8 {
    const search = URL.getSearch(url);
    return if (search.len > 0) search[1..] else "";
}

// The url's port as the spec compares it: "" for the scheme's default port.
// The serializer already removed a default port from the url.
fn portOf(url: [:0]const u8) ?[]const u8 {
    const port = URL.getPort(url);
    if (port.len > 0) {
        return port;
    }
    return if (URL.defaultPort(schemeOf(url)) != null) "" else null;
}

const testing = @import("../../testing.zig");

fn testParse(input: Input) !UrlPattern {
    return parse(testing.arena_allocator, input);
}

fn expectPattern(expected: UrlPattern, input: Input) !void {
    const actual = try testParse(input);
    inline for (.{ "protocol", "hostname", "port", "pathname", "search" }) |field| {
        const e = @field(expected, field);
        const a = @field(actual, field);
        if (e == null or a == null) {
            if (e != null or a != null) {
                std.debug.print("{s}: expected {?s}, got {?s}\n", .{ field, e, a });
                return error.TestUnexpectedResult;
            }
        } else {
            try std.testing.expectEqualStrings(e.?, a.?);
        }
    }
}

test "bidi.UrlPattern: parse a pattern" {
    // Only the components given are kept.
    try expectPattern(.{}, .{ .type = .pattern });
    try expectPattern(.{ .hostname = "example.com" }, .{ .type = .pattern, .hostname = "example.com" });
    try expectPattern(.{
        .protocol = "https",
        .hostname = "example.com",
        .port = "8443",
        .pathname = "/a/b",
        .search = "q=1",
    }, .{ .type = .pattern, .protocol = "https", .hostname = "example.com", .port = "8443", .pathname = "/a/b", .search = "?q=1" });

    // The parser normalizes the components.
    try expectPattern(.{ .protocol = "https", .hostname = "example.com" }, .{ .type = .pattern, .protocol = "HTTPS", .hostname = "EXAMPLE.com" });
    try expectPattern(.{ .pathname = "/a" }, .{ .type = .pattern, .pathname = "a" });
    try expectPattern(.{ .search = "q" }, .{ .type = .pattern, .search = "q" });
    try expectPattern(.{ .search = "" }, .{ .type = .pattern, .search = "" });
    try expectPattern(.{ .pathname = "/" }, .{ .type = .pattern, .pathname = "" });

    // The default port is "".
    try expectPattern(.{ .port = "" }, .{ .type = .pattern, .port = "80" });
    try expectPattern(.{ .protocol = "https", .port = "" }, .{ .type = .pattern, .protocol = "https", .port = "443" });
    try expectPattern(.{ .protocol = "https", .port = "80" }, .{ .type = .pattern, .protocol = "https", .port = "80" });

    // IPv6 hosts keep their brackets, and can have a ":" inside them.
    try expectPattern(.{ .hostname = "[::1]" }, .{ .type = .pattern, .hostname = "[::1]" });

    // Escaped characters.
    try expectPattern(.{ .pathname = "/a*b" }, .{ .type = .pattern, .pathname = "/a\\*b" });

    // A non-special scheme gets no "//", so the hostname becomes a path: the
    // url has no host, and the spec's hostname is null.
    try expectPattern(.{ .protocol = "foo" }, .{ .type = .pattern, .protocol = "foo", .hostname = "x" });
    // Only special schemes have a default port.
    try expectPattern(.{ .protocol = "ftp", .port = "" }, .{ .type = .pattern, .protocol = "ftp", .port = "21" });
    try expectPattern(.{ .protocol = "file" }, .{ .type = .pattern, .protocol = "file" });
}

test "bidi.UrlPattern: parse a string" {
    try expectPattern(.{
        .protocol = "https",
        .hostname = "example.com",
        .port = "",
        .pathname = "/",
        .search = "",
    }, .{ .type = .string, .pattern = "https://example.com" });

    try expectPattern(.{
        .protocol = "http",
        .hostname = "127.0.0.1",
        .port = "9582",
        .pathname = "/a",
        .search = "b=1",
    }, .{ .type = .string, .pattern = "http://127.0.0.1:9582/a?b=1#frag" });

    try expectPattern(.{
        .protocol = "http",
        .hostname = "example.com",
        .port = "",
        .pathname = "/(x)",
        .search = "",
    }, .{ .type = .string, .pattern = "http://example.com/\\(x\\)" });

    // A non-special url can have an empty path, and no port: both are null.
    try expectPattern(.{
        .protocol = "foo",
        .hostname = "host",
        .port = null,
        .pathname = null,
        .search = "",
    }, .{ .type = .string, .pattern = "foo://host" });

    // No host: null, not "".
    try expectPattern(.{
        .protocol = "data",
        .hostname = null,
        .port = null,
        .pathname = "text/plain,hi",
        .search = "",
    }, .{ .type = .string, .pattern = "data:text/plain,hi" });
}

test "bidi.UrlPattern: invalid patterns" {
    const invalid = [_]Input{
        .{ .type = .string },
        .{ .type = .string, .pattern = "not a url" },
        .{ .type = .string, .pattern = "http://example.com/*" },
        .{ .type = .pattern, .protocol = "" },
        .{ .type = .pattern, .protocol = "ht_tp" },
        .{ .type = .pattern, .hostname = "" },
        .{ .type = .pattern, .hostname = "a/b" },
        .{ .type = .pattern, .hostname = "a:80" },
        .{ .type = .pattern, .protocol = "file", .hostname = "a" },
        .{ .type = .pattern, .port = "" },
        .{ .type = .pattern, .port = "8a" },
        .{ .type = .pattern, .pathname = "/a?b" },
        .{ .type = .pattern, .pathname = "/a#b" },
        .{ .type = .pattern, .search = "a#b" },
        .{ .type = .pattern, .pathname = "/*" },
        .{ .type = .pattern, .hostname = "{a}" },
    };
    for (invalid) |input| {
        testing.expectError(error.InvalidArgument, testParse(input)) catch |err| {
            std.debug.print("expected invalid: {any}\n", .{input});
            return err;
        };
    }
}

test "bidi.UrlPattern: dupe outlives the parse arena" {
    const pattern = blk: {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const parsed = try parse(arena.allocator(), .{ .type = .string, .pattern = "http://127.0.0.1:9582/a?b=1" });
        break :blk try parsed.dupe(testing.arena_allocator);
    };

    try testing.expect(pattern.matches("http://127.0.0.1:9582/a?b=1"));
    try testing.expect(!pattern.matches("http://127.0.0.1:9582/a"));
}

test "bidi.UrlPattern: matches" {
    const url = "http://127.0.0.1:9582/a/b?q=1";

    const any = try testParse(.{ .type = .pattern });
    try testing.expect(any.matches(url));

    const match = [_]Input{
        .{ .type = .pattern, .protocol = "http" },
        .{ .type = .pattern, .hostname = "127.0.0.1" },
        .{ .type = .pattern, .port = "9582" },
        .{ .type = .pattern, .pathname = "/a/b" },
        .{ .type = .pattern, .search = "q=1" },
        .{ .type = .string, .pattern = url },
        // The fragment isn't compared.
        .{ .type = .string, .pattern = url ++ "#frag" },
    };
    for (match) |input| {
        try testing.expect((try testParse(input)).matches(url));
    }

    const no_match = [_]Input{
        .{ .type = .pattern, .protocol = "https" },
        .{ .type = .pattern, .hostname = "localhost" },
        .{ .type = .pattern, .port = "80" },
        // Exact compare, no prefix.
        .{ .type = .pattern, .pathname = "/a" },
        .{ .type = .pattern, .search = "" },
        .{ .type = .string, .pattern = "http://127.0.0.1:9582/a/b" },
    };
    for (no_match) |input| {
        try testing.expect(!(try testParse(input)).matches(url));
    }

    // The default port, in the pattern or in the url, is "".
    const default_port = try testParse(.{ .type = .pattern, .port = "443", .protocol = "https" });
    try testing.expect(default_port.matches("https://example.com/"));
    try testing.expect(!default_port.matches("https://example.com:8443/"));

    // No query and an empty query are the same.
    const empty_search = try testParse(.{ .type = .pattern, .search = "" });
    try testing.expect(empty_search.matches("http://example.com/"));
    try testing.expect(empty_search.matches("http://example.com/?"));

    // IPv6.
    const ipv6 = try testParse(.{ .type = .pattern, .hostname = "[::1]" });
    try testing.expect(ipv6.matches("http://[::1]:8080/"));
}

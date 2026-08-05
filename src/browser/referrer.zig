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

// Referrer Policy: https://www.w3.org/TR/referrer-policy/
const std = @import("std");
const URL = @import("URL.zig");

const Allocator = std.mem.Allocator;

pub const Policy = enum {
    no_referrer,
    no_referrer_when_downgrade,
    origin,
    origin_when_cross_origin,
    same_origin,
    strict_origin,
    strict_origin_when_cross_origin,
    unsafe_url,

    pub const default: Policy = .strict_origin_when_cross_origin;
};

pub fn parse(value: []const u8) ?Policy {
    const map = std.StaticStringMapWithEql(Policy, staticStringMapEqlAsciiIgnoreCase).initComptime(.{
        .{ "no-referrer", Policy.no_referrer },
        .{ "no-referrer-when-downgrade", Policy.no_referrer_when_downgrade },
        .{ "origin", Policy.origin },
        .{ "origin-when-cross-origin", Policy.origin_when_cross_origin },
        .{ "same-origin", Policy.same_origin },
        .{ "strict-origin", Policy.strict_origin },
        .{ "strict-origin-when-cross-origin", Policy.strict_origin_when_cross_origin },
        .{ "unsafe-url", Policy.unsafe_url },
    });
    return map.get(value);
}

pub fn parseHeader(value: []const u8) ?Policy {
    var policy: ?Policy = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |token| {
        if (parse(std.mem.trim(u8, token, " \t"))) |p| {
            policy = p;
        }
    }
    return policy;
}

pub fn parseMeta(value: []const u8) ?Policy {
    if (parse(value)) |p| {
        return p;
    }
    // legacy values
    const map = std.StaticStringMapWithEql(Policy, staticStringMapEqlAsciiIgnoreCase).initComptime(.{
        .{ "never", Policy.no_referrer },
        .{ "always", Policy.unsafe_url },
        .{ "origin-when-crossorigin", Policy.origin_when_cross_origin },
        .{ "default", Policy.default },
    });
    return map.get(value);
}

// returns the value to send as the Referrer header based on the target_url
// and the given policy
pub fn compute(arena: Allocator, policy: Policy, referrer_url: [:0]const u8, target_url: [:0]const u8) !?[]const u8 {
    if (policy == .no_referrer) {
        return null;
    }

    const referrer_origin = (try URL.getOrigin(arena, referrer_url)) orelse {
        // blob:, data: ... don't set get a referrer
        return null;
    };

    const same_origin = blk: {
        const target_origin = (try URL.getOrigin(arena, target_url)) orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(referrer_origin, target_origin);
    };
    const downgrade = URL.isSecure(referrer_url) and !URL.isSecure(target_url);

    const full = switch (policy) {
        .no_referrer => unreachable,
        .unsafe_url => true,
        .origin => false,
        .no_referrer_when_downgrade => if (downgrade) return null else true,
        .same_origin => if (same_origin) true else return null,
        .origin_when_cross_origin => same_origin,
        .strict_origin => if (downgrade) return null else false,
        .strict_origin_when_cross_origin => if (same_origin) true else if (downgrade) return null else false,
    };

    if (full) {
        // Serializing through origin + path + query strips credentials and
        // the fragment, and normalizes away default ports.
        const value = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            referrer_origin,
            URL.getPathname(referrer_url),
            URL.getSearch(referrer_url),
        });

        if (value.len <= 4096) {
            // spec limit, if it's more than this, we falllback to the origin
            return value;
        }
    }
    return try std.fmt.allocPrint(arena, "{s}/", .{referrer_origin});
}

fn staticStringMapEqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    for (a, b) |a_c, b_c| {
        if (std.ascii.toLower(a_c) != std.ascii.toLower(b_c)) {
            return false;
        }
    }
    return true;
}

const testing = @import("../testing.zig");
test "referrer: parse" {
    try testing.expectEqual(Policy.no_referrer, parse("no-referrer"));
    try testing.expectEqual(Policy.unsafe_url, parse("Unsafe-URL"));
    try testing.expectEqual(null, parse(""));
    try testing.expectEqual(null, parse("never"));
    try testing.expectEqual(null, parse("no-referrer "));

    try testing.expectEqual(null, parseHeader(""));
    try testing.expectEqual(null, parseHeader("nope"));
    try testing.expectEqual(Policy.origin, parseHeader("origin"));
    try testing.expectEqual(Policy.same_origin, parseHeader("origin, same-origin"));
    try testing.expectEqual(Policy.origin, parseHeader("origin, garbage"));
    try testing.expectEqual(Policy.same_origin, parseHeader(" origin ,\tsame-origin "));

    try testing.expectEqual(Policy.no_referrer, parseMeta("never"));
    try testing.expectEqual(Policy.unsafe_url, parseMeta("always"));
    try testing.expectEqual(Policy.origin_when_cross_origin, parseMeta("origin-when-crossorigin"));
    try testing.expectEqual(Policy.strict_origin_when_cross_origin, parseMeta("default"));
    try testing.expectEqual(Policy.origin, parseMeta("origin"));
    try testing.expectEqual(null, parseMeta("garbage"));
}

test "referrer: compute" {
    const Case = struct {
        policy: Policy,
        referrer: [:0]const u8,
        target: [:0]const u8,
        expected: ?[]const u8,
    };

    const cases = [_]Case{
        .{ .policy = .no_referrer, .referrer = "http://a.com/p", .target = "http://a.com/x", .expected = null },

        .{ .policy = .unsafe_url, .referrer = "http://a.com/p?q=1#frag", .target = "https://b.com/", .expected = "http://a.com/p?q=1" },
        .{ .policy = .unsafe_url, .referrer = "https://a.com/p", .target = "http://b.com/", .expected = "https://a.com/p" },
        .{ .policy = .unsafe_url, .referrer = "https://user:pass@a.com/p", .target = "http://b.com/", .expected = "https://a.com/p" },
        .{ .policy = .unsafe_url, .referrer = "https://a.com:443/p", .target = "http://b.com/", .expected = "https://a.com/p" },
        .{ .policy = .unsafe_url, .referrer = "http://a.com", .target = "http://b.com/", .expected = "http://a.com/" },

        .{ .policy = .origin, .referrer = "http://a.com:8000/p?q=1", .target = "http://a.com:8000/x", .expected = "http://a.com:8000/" },

        .{ .policy = .same_origin, .referrer = "http://a.com/p", .target = "http://a.com/x", .expected = "http://a.com/p" },
        .{ .policy = .same_origin, .referrer = "http://a.com/p", .target = "http://b.com/x", .expected = null },
        .{ .policy = .same_origin, .referrer = "http://a.com/p", .target = "https://a.com/x", .expected = null },

        .{ .policy = .origin_when_cross_origin, .referrer = "http://a.com/p", .target = "http://a.com/x", .expected = "http://a.com/p" },
        .{ .policy = .origin_when_cross_origin, .referrer = "http://a.com/p", .target = "http://b.com/x", .expected = "http://a.com/" },

        .{ .policy = .strict_origin, .referrer = "https://a.com/p", .target = "http://a.com/x", .expected = null },
        .{ .policy = .strict_origin, .referrer = "https://a.com/p", .target = "https://b.com/x", .expected = "https://a.com/" },
        .{ .policy = .strict_origin, .referrer = "http://a.com/p", .target = "http://b.com/x", .expected = "http://a.com/" },

        .{ .policy = .no_referrer_when_downgrade, .referrer = "https://a.com/p", .target = "http://b.com/x", .expected = null },
        .{ .policy = .no_referrer_when_downgrade, .referrer = "https://a.com/p", .target = "https://b.com/x", .expected = "https://a.com/p" },
        .{ .policy = .no_referrer_when_downgrade, .referrer = "http://a.com/p", .target = "http://b.com/x", .expected = "http://a.com/p" },

        .{ .policy = .strict_origin_when_cross_origin, .referrer = "http://a.com/p?q=1", .target = "http://a.com/x", .expected = "http://a.com/p?q=1" },
        .{ .policy = .strict_origin_when_cross_origin, .referrer = "http://a.com/p", .target = "http://b.com/x", .expected = "http://a.com/" },
        .{ .policy = .strict_origin_when_cross_origin, .referrer = "https://a.com/p", .target = "http://b.com/x", .expected = null },
        .{ .policy = .strict_origin_when_cross_origin, .referrer = "https://a.com/p", .target = "http://a.com/x", .expected = null },

        // no referrer from non-http(s) documents
        .{ .policy = .unsafe_url, .referrer = "about:blank", .target = "http://b.com/x", .expected = null },
        .{ .policy = .unsafe_url, .referrer = "data:text/html,x", .target = "http://b.com/x", .expected = null },
    };

    for (cases) |case| {
        const actual = try compute(testing.arena_allocator, case.policy, case.referrer, case.target);
        if (case.expected) |expected| {
            try testing.expectEqual(expected, actual orelse return error.UnexpectedNull);
        } else {
            try testing.expectEqual(null, actual);
        }
    }
}

test "referrer: compute caps at 4096 bytes" {
    const path = "/" ++ ("a" ** 4096);
    const url = "http://a.com" ++ path;
    // over the cap: falls back to the origin form
    try testing.expectEqual("http://a.com/", (try compute(testing.arena_allocator, .unsafe_url, url, "http://b.com/x")).?);
    try testing.expectEqual("http://a.com/", (try compute(testing.arena_allocator, .no_referrer_when_downgrade, url, "http://a.com/x")).?);

    // exactly at the cap: sent in full
    const at_cap = "http://a.com/" ++ ("a" ** (4096 - "http://a.com/".len));
    try testing.expectEqual(at_cap, (try compute(testing.arena_allocator, .unsafe_url, at_cap, "http://b.com/x")).?);

    // origin-only policies are unaffected by the referrer's length
    try testing.expectEqual("http://a.com/", (try compute(testing.arena_allocator, .origin, url, "http://b.com/x")).?);
}

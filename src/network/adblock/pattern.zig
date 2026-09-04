// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

//! Matching of a filter's URL pattern, once the type, party and `$domain=`
//! constraints have already passed. Everything here works on a lowercased,
//! fragment-stripped URL; `$match-case` only survives on /regex/ filters,
//! which never reach this file.

const std = @import("std");

const NetworkFilter = @import("NetworkFilter.zig");

/// The URL a request is matched against, with its hostname located once so
/// every filter can reuse the offsets.
pub const Url = struct {
    /// Lowercased, fragment stripped.
    text: []const u8,
    host_start: u32,
    host_end: u32,

    pub fn hostname(self: Url) []const u8 {
        return self.text[self.host_start..self.host_end];
    }

    /// Locates the hostname inside `url`: after "scheme://", up to the port,
    /// path, query or end. Offsets, not a slice, because the matcher needs to
    /// resume the pattern right where the hostname stops.
    pub fn init(url: []const u8) Url {
        var start: usize = 0;
        if (std.mem.indexOf(u8, url, "://")) |scheme| start = scheme + 3;

        var end = url.len;
        for (url[start..], start..) |c, i| {
            switch (c) {
                '/', '?', '#' => {
                    end = i;
                    break;
                },
                else => {},
            }
        }

        // "user:password@host"
        if (std.mem.lastIndexOfScalar(u8, url[start..end], '@')) |at| {
            start += at + 1;
        }

        // A ':' before the path is a port, unless we are inside an IPv6
        // literal's brackets.
        const host = url[start..end];
        var host_end = end;
        if (host.len > 0 and host[0] == '[') {
            if (std.mem.indexOfScalar(u8, host, ']')) |close| {
                host_end = start + close + 1;
            }
        } else if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
            host_end = start + colon;
        }

        return .{
            .text = url,
            .host_start = @intCast(start),
            .host_end = @intCast(host_end),
        };
    }
};

/// Whether `filter`'s pattern matches `url`. Only the pattern: the caller has
/// already decided the filter applies to this request.
pub fn matches(filter: *const NetworkFilter, url: Url) bool {
    switch (filter.kind) {
        // Option-only filters ("$script,domain=x") match any URL.
        .any => return true,
        // Never indexed: there is no regex engine to run them with.
        .regex => return false,
        .hostname, .plain, .wildcard => {},
    }

    if (filter.hostname.len != 0) {
        var from: usize = 0;
        while (hostAnchor(url, filter.hostname, from)) |at| {
            if (filter.kind == .hostname) {
                const boundary = at == url.host_end or url.text[at] == '.' or
                    filter.hostname[filter.hostname.len - 1] == '.';
                if (boundary) {
                    if (!filter.require_separator) return true;
                    if (at == url.text.len) return true;
                    // `||host^|` pins the separator to the end of the URL.
                    if (isSeparator(url.text[at]) and
                        (!filter.right_anchor or at + 1 == url.text.len))
                    {
                        return true;
                    }
                }
            } else if (matchFrom(filter, url.text, at, filter.right_anchor)) {
                return true;
            }
            // The label this attempt started on cannot match again.
            from = at - filter.hostname.len - url.host_start + 1;
        }
        return false;
    }

    if (filter.hostname_anchor) {
        var i: usize = url.host_start;
        while (true) {
            if (matchFrom(filter, url.text, i, filter.right_anchor)) return true;
            const dot = std.mem.indexOfScalarPos(u8, url.text[0..url.host_end], i, '.') orelse
                return false;
            i = dot + 1;
        }
    }

    if (filter.left_anchor) {
        return matchFrom(filter, url.text, 0, filter.right_anchor);
    }
    if (filter.kind == .plain) {
        if (filter.right_anchor) return std.mem.endsWith(u8, url.text, filter.pattern);
        return std.mem.indexOf(u8, url.text, filter.pattern) != null;
    }

    var i: usize = 0;
    while (i <= url.text.len) : (i += 1) {
        if (matchFrom(filter, url.text, i, filter.right_anchor)) return true;
    }
    return false;
}

/// Finds `needle` starting on a label boundary of the request hostname at or
/// after `from` (an offset into the hostname), and returns the offset just
/// past it in the whole URL.
fn hostAnchor(url: Url, needle: []const u8, from: usize) ?usize {
    const host = url.hostname();
    var p = from;
    while (p <= host.len) {
        if (p == 0 or host[p - 1] == '.') {
            if (std.mem.startsWith(u8, host[p..], needle)) {
                return url.host_start + p + needle.len;
            }
        }
        const dot = std.mem.indexOfScalarPos(u8, host, p, '.') orelse return null;
        p = dot + 1;
    }
    return null;
}

/// Matches the pattern starting exactly at `start`. `anchor_end` additionally
/// requires it to run to the end of the URL.
fn matchFrom(filter: *const NetworkFilter, url: []const u8, start: usize, anchor_end: bool) bool {
    if (filter.kind == .plain) {
        // No '*' and no '^': a byte comparison is the whole job.
        if (start + filter.pattern.len > url.len) return false;
        if (!std.mem.startsWith(u8, url[start..], filter.pattern)) return false;
        return !anchor_end or start + filter.pattern.len == url.len;
    }

    var it = std.mem.splitScalar(u8, filter.pattern, '*');
    var pos = matchSegment(it.first(), url, start) orelse return false;
    var pending = it.next();
    while (pending) |segment| {
        const following = it.next();
        if (following == null and anchor_end) {
            return matchSegmentAtEnd(segment, url, pos);
        }
        pos = findSegment(segment, url, pos) orelse return false;
        pending = following;
    }
    return !anchor_end or pos == url.len;
}

/// Matches one wildcard-free segment at `pos`, returning where it ends.
fn matchSegment(segment: []const u8, url: []const u8, pos: usize) ?usize {
    var i = pos;
    for (segment, 0..) |c, si| {
        if (i == url.len) {
            // A '^' at the very end of the pattern also matches the end of
            // the URL, consuming nothing.
            return if (c == '^' and si == segment.len - 1) i else null;
        }
        if (c == '^') {
            if (!isSeparator(url[i])) return null;
        } else if (url[i] != c) {
            return null;
        }
        i += 1;
    }
    return i;
}

/// Leftmost occurrence of `segment` at or after `from`; no backtracking, the
/// same simplification uBO and adblock-rust make.
fn findSegment(segment: []const u8, url: []const u8, from: usize) ?usize {
    var i = from;
    while (i <= url.len) : (i += 1) {
        if (matchSegment(segment, url, i)) |end| return end;
    }
    return null;
}

fn matchSegmentAtEnd(segment: []const u8, url: []const u8, from: usize) bool {
    var i = from;
    while (i <= url.len) : (i += 1) {
        if (matchSegment(segment, url, i)) |end| {
            if (end == url.len) return true;
        }
    }
    return false;
}

/// uBO's separator class: everything that cannot appear in a hostname or an unescaped path word.
fn isSeparator(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return false;
    return switch (c) {
        '_', '%', '.', '-' => false,
        else => true,
    };
}

const testing = @import("../../testing.zig");

fn testMatch(arena: std.mem.Allocator, line: []const u8, url: []const u8) !bool {
    const filter = try NetworkFilter.parse(arena, line);
    return matches(&filter, .init(url));
}

test "adblock.pattern: hostname location" {
    var u: Url = .init("https://ads.example.com/x?y=1");
    try testing.expectString("ads.example.com", u.hostname());

    u = .init("https://ads.example.com:8443/x");
    try testing.expectString("ads.example.com", u.hostname());

    u = .init("https://example.com");
    try testing.expectString("example.com", u.hostname());

    u = .init("http://[::1]:9222/json");
    try testing.expectString("[::1]", u.hostname());

    // Credentials are not part of the host.
    u = .init("https://user:pass@ads.example.com/x");
    try testing.expectString("ads.example.com", u.hostname());

    // A pattern is matched against whatever it is given, even a bare path.
    u = .init("/relative/path");
    try testing.expectString("", u.hostname());
}

test "adblock.pattern: hostname filters cover subdomains" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try testMatch(arena, "||ads.example.com^", "https://ads.example.com/a"));
    try testing.expect(try testMatch(arena, "||ads.example.com^", "https://x.ads.example.com/a"));
    try testing.expect(!try testMatch(arena, "||ads.example.com^", "https://notads.example.com/a"));
    try testing.expect(!try testMatch(arena, "||ads.example.com^", "https://example.com/ads.example.com"));
}

test "adblock.pattern: caret-less hostname filters match the hostname or a subdomain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The real EasyPrivacy shape "||coinimp.com$third-party": uBO reads it
    // as "||coinimp.com^", so "coinimp.com.evil.org" — evil.org's hostname,
    // not a subdomain of coinimp.com — is out.
    try testing.expect(try testMatch(arena, "||coinimp.com", "https://coinimp.com/miner.js"));
    try testing.expect(try testMatch(arena, "||coinimp.com", "https://sub.coinimp.com/x"));
    try testing.expect(try testMatch(arena, "||coinimp.com", "https://coinimp.com:8080/x"));
    try testing.expect(!try testMatch(arena, "||coinimp.com", "https://coinimp.com.evil.org/x"));
    try testing.expect(!try testMatch(arena, "||coinimp.com", "https://coinimp.community/miner.js"));

    // `||host|` is that same filter once more.
    try testing.expect(try testMatch(arena, "||coinimp.com|", "https://sub.coinimp.com/x"));
    try testing.expect(!try testMatch(arena, "||coinimp.com|", "https://coinimp.com.evil.org/x"));

    // `||host*` is NOT: uBO keeps a trailing '*' after a short run, and the
    // pattern stays a label-anchored prefix.
    try testing.expect(try testMatch(arena, "||coinimp.com*", "https://coinimp.com.evil.org/x"));
    try testing.expect(try testMatch(arena, "||coinimp.com*", "https://coinimp.community/miner.js"));

    // A filter hostname ending in '.' names no hostname; it stays a prefix
    // and carries its own boundary.
    try testing.expect(try testMatch(arena, "||adform.", "https://adform.net/banner"));
    try testing.expect(try testMatch(arena, "||adform.", "https://track.adform.co.uk/x"));
    try testing.expect(!try testMatch(arena, "||adform", "https://adformat.example/x"));
}

test "adblock.pattern: right-anchored hostname filters pin the URL end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `||host^|`: the separator '^' must also be the end of the URL.
    try testing.expect(try testMatch(arena, "||ads.com^|", "https://ads.com"));
    try testing.expect(try testMatch(arena, "||ads.com^|", "https://ads.com/"));
    try testing.expect(!try testMatch(arena, "||ads.com^|", "https://ads.com/path/x"));
    try testing.expect(!try testMatch(arena, "||ads.com^|", "https://ads.com/?q=1"));
}

test "adblock.pattern: hostname-anchored patterns resume after the host" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The real shape from the report.
    try testing.expect(try testMatch(
        arena,
        "||youtube.com/pagead/",
        "https://www.youtube.com/pagead/lvz?ei=x",
    ));
    try testing.expect(!try testMatch(
        arena,
        "||youtube.com/pagead/",
        "https://www.youtube.com/watch?v=x",
    ));
    // The path is anchored to the end of the hostname, not searched for.
    try testing.expect(!try testMatch(
        arena,
        "||youtube.com/pagead/",
        "https://example.com/www.youtube.com/pagead/x",
    ));

    try testing.expect(try testMatch(
        arena,
        "||g.doubleclick.net/gampad/ads",
        "https://g.doubleclick.net/gampad/ads?env=vp",
    ));
    try testing.expect(!try testMatch(
        arena,
        "||g.doubleclick.net/gampad/ads",
        "https://g.doubleclick.net/pagead/ads",
    ));
}

test "adblock.pattern: wildcards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try testMatch(
        arena,
        "||g.doubleclick.net/gampad/ads*%20web%20player",
        "https://g.doubleclick.net/gampad/ads?a=1&b=my%20web%20player",
    ));
    try testing.expect(!try testMatch(
        arena,
        "||g.doubleclick.net/gampad/ads*%20web%20player",
        "https://g.doubleclick.net/gampad/ads?a=1",
    ));

    // A '*' in the hostname region anchors to a label boundary.
    try testing.expect(try testMatch(arena, "||example.*/ads", "https://example.co.uk/ads/x"));
    try testing.expect(try testMatch(arena, "||example.*/ads", "https://www.example.com/ads/x"));
    try testing.expect(!try testMatch(arena, "||example.*/ads", "https://notexample.com/ads/x"));

    try testing.expect(try testMatch(arena, "/banner/*/img", "https://a.com/banner/x/img"));
}

test "adblock.pattern: separators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // '^' matches one separator...
    try testing.expect(try testMatch(arena, "||example.com/ads^", "https://example.com/ads?x=1"));
    try testing.expect(try testMatch(arena, "||example.com/ads^", "https://example.com/ads/x"));
    // ...or the end of the URL.
    try testing.expect(try testMatch(arena, "||example.com/ads^", "https://example.com/ads"));
    // Letters, digits, '_', '%', '.' and '-' are not separators.
    try testing.expect(!try testMatch(arena, "||example.com/ads^", "https://example.com/adsx"));
    try testing.expect(!try testMatch(arena, "||example.com/ads^", "https://example.com/ads.js"));
}

test "adblock.pattern: anchors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try testMatch(arena, "|https://ads.", "https://ads.example.com/"));
    try testing.expect(!try testMatch(arena, "|https://ads.", "http://ads.example.com/"));

    try testing.expect(try testMatch(arena, "-ad-300x250.gif|", "https://a.com/-ad-300x250.gif"));
    try testing.expect(!try testMatch(arena, "-ad-300x250.gif|", "https://a.com/-ad-300x250.gif?x"));

    // Unanchored patterns are plain substrings.
    try testing.expect(try testMatch(arena, "/banner/ads.", "https://a.com/x/banner/ads.png"));
    try testing.expect(!try testMatch(arena, "/banner/ads.", "https://a.com/banner/x.png"));
}

test "adblock.pattern: option-only filters match every URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try testMatch(arena, "$script,domain=example.com", "https://anything.test/x"));
}

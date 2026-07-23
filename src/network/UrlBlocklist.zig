// Copyright (C) 2026  Lightpanda (Selecy SAS)
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

const UrlBlocklist = @This();

allocator: std.mem.Allocator,
patterns: []const []const u8,
blocks: ?[]const bool = null,

pub const Pattern = struct {
    urlPattern: []const u8,
    block: bool,
};

/// Compile and own a set of URL wildcard patterns. Empty patterns (e.g. from
/// trailing or duplicate commas in `--block-urls`) are skipped so every entry
/// point behaves the same. Patterns are normalized to lowercase once so request
/// matching remains allocation-free.
pub fn init(allocator: std.mem.Allocator, patterns: []const []const u8) !UrlBlocklist {
    var count: usize = 0;
    for (patterns) |pattern| {
        if (pattern.len > 0) count += 1;
    }

    const owned = try allocator.alloc([]const u8, count);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |pattern| allocator.free(pattern);
        allocator.free(owned);
    }

    for (patterns) |pattern| {
        if (pattern.len == 0) continue;
        const normalized = try allocator.alloc(u8, pattern.len);
        for (pattern, normalized) |char, *lower| {
            lower.* = std.ascii.toLower(char);
        }
        owned[initialized] = normalized;
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .patterns = owned,
    };
}

pub fn initPatterns(allocator: std.mem.Allocator, patterns: []const Pattern) !UrlBlocklist {
    var count: usize = 0;
    for (patterns) |pattern| {
        if (pattern.urlPattern.len > 0) count += 1;
    }

    // Pre-filter empty patterns here too so `blocks` stays aligned with the
    // (also-filtered) patterns compiled by init().
    const urls = try allocator.alloc([]const u8, count);
    defer allocator.free(urls);
    const blocks = try allocator.alloc(bool, count);
    errdefer allocator.free(blocks);
    {
        var i: usize = 0;
        for (patterns) |pattern| {
            if (pattern.urlPattern.len == 0) continue;
            urls[i] = pattern.urlPattern;
            blocks[i] = pattern.block;
            i += 1;
        }
    }

    var blocklist = try init(allocator, urls);
    blocklist.blocks = blocks;
    return blocklist;
}

pub fn deinit(self: *UrlBlocklist) void {
    for (self.patterns) |pattern| self.allocator.free(pattern);
    self.allocator.free(self.patterns);
    if (self.blocks) |blocks| self.allocator.free(blocks);
}

pub fn isBlocked(self: *const UrlBlocklist, url: []const u8) bool {
    for (self.patterns, 0..) |pattern, index| {
        if (wildcardMatch(pattern, url)) return if (self.blocks) |blocks| blocks[index] else true;
    }
    return false;
}

fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;

    while (value_index < value.len) {
        if (pattern_index < pattern.len and
            pattern[pattern_index] != '*' and
            pattern[pattern_index] == std.ascii.toLower(value[value_index]))
        {
            pattern_index += 1;
            value_index += 1;
            continue;
        }

        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
            continue;
        }

        if (star_index) |star| {
            pattern_index = star + 1;
            star_value_index += 1;
            value_index = star_value_index;
            continue;
        }

        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

test "UrlBlocklist: matches full URLs with case-insensitive wildcards" {
    var blocklist = try UrlBlocklist.init(std.testing.allocator, &.{
        "*://*/*.png",
        "*doubleclick*",
        "https://example.com/exact",
    });
    defer blocklist.deinit();

    try std.testing.expect(blocklist.isBlocked("https://cdn.example.com/images/HERO.PNG"));
    try std.testing.expect(blocklist.isBlocked("https://ads.DOUBLECLICK.net/activity"));
    try std.testing.expect(blocklist.isBlocked("HTTPS://EXAMPLE.COM/EXACT"));
    try std.testing.expect(!blocklist.isBlocked("https://example.com/image.jpg"));
    try std.testing.expect(!blocklist.isBlocked("https://example.com/exact/path"));
}

test "UrlBlocklist: wildcard matching backtracks and skips empty patterns" {
    var blocklist = try UrlBlocklist.init(std.testing.allocator, &.{
        "",
        "**tracker***pixel*",
    });
    defer blocklist.deinit();

    // The empty pattern is dropped, so it never matches (not even "").
    try std.testing.expectEqual(1, blocklist.patterns.len);
    try std.testing.expect(!blocklist.isBlocked(""));
    try std.testing.expect(blocklist.isBlocked("https://tracker.test/a/pixel.gif"));
    try std.testing.expect(!blocklist.isBlocked("https://anything.test/"));

    var match_all = try UrlBlocklist.init(std.testing.allocator, &.{"*"});
    defer match_all.deinit();
    try std.testing.expect(match_all.isBlocked("https://anything.test/"));

    var empty = try UrlBlocklist.init(std.testing.allocator, &.{});
    defer empty.deinit();
    try std.testing.expect(!empty.isBlocked("https://example.com/"));
}

test "UrlBlocklist: initPatterns skips empty patterns and keeps blocks aligned" {
    var blocklist = try UrlBlocklist.initPatterns(std.testing.allocator, &.{
        .{ .urlPattern = "*allow*", .block = false },
        .{ .urlPattern = "", .block = true },
        .{ .urlPattern = "*", .block = true },
    });
    defer blocklist.deinit();

    try std.testing.expectEqual(2, blocklist.patterns.len);
    try std.testing.expectEqual(2, blocklist.blocks.?.len);
    // The exemption (block = false) still wins over the trailing catch-all,
    // proving the empty pattern was removed without shifting `blocks`.
    try std.testing.expect(!blocklist.isBlocked("https://example.com/allow/me"));
    try std.testing.expect(blocklist.isBlocked("https://example.com/other"));
}

test "UrlBlocklist: owns compiled patterns" {
    var pattern = [_]u8{ '*', 'a', 'd', 's', '*' };
    var blocklist = try UrlBlocklist.initPatterns(std.testing.allocator, &.{ .{ .urlPattern = &pattern, .block = false }, .{ .urlPattern = "*", .block = true } });
    defer blocklist.deinit();

    @memset(&pattern, 'x');
    try std.testing.expect(!blocklist.isBlocked("https://example.com/ads/script.js"));
}

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

/// Compile and own a set of URL wildcard patterns. Patterns are normalized to
/// lowercase once so request matching remains allocation-free.
pub fn init(allocator: std.mem.Allocator, patterns: []const []const u8) !UrlBlocklist {
    const owned = try allocator.alloc([]const u8, patterns.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |pattern| allocator.free(pattern);
        allocator.free(owned);
    }

    for (patterns, owned) |pattern, *compiled| {
        const normalized = try allocator.alloc(u8, pattern.len);
        for (pattern, normalized) |char, *lower| {
            lower.* = std.ascii.toLower(char);
        }
        compiled.* = normalized;
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .patterns = owned,
    };
}

pub fn initPatterns(allocator: std.mem.Allocator, patterns: []const Pattern) !UrlBlocklist {
    const urls = try allocator.alloc([]const u8, patterns.len);
    defer allocator.free(urls);
    for (patterns, urls) |pattern, *url| url.* = pattern.urlPattern;

    var blocklist = try init(allocator, urls);
    errdefer blocklist.deinit();
    const blocks = try allocator.alloc(bool, patterns.len);
    for (patterns, blocks) |pattern, *block| block.* = pattern.block;
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

test "UrlBlocklist: wildcard matching backtracks and handles empty patterns" {
    var blocklist = try UrlBlocklist.init(std.testing.allocator, &.{
        "",
        "**tracker***pixel*",
    });
    defer blocklist.deinit();

    try std.testing.expect(blocklist.isBlocked(""));
    try std.testing.expect(blocklist.isBlocked("https://tracker.test/a/pixel.gif"));
    try std.testing.expect(!blocklist.isBlocked("https://anything.test/"));

    var match_all = try UrlBlocklist.init(std.testing.allocator, &.{"*"});
    defer match_all.deinit();
    try std.testing.expect(match_all.isBlocked("https://anything.test/"));

    var empty = try UrlBlocklist.init(std.testing.allocator, &.{});
    defer empty.deinit();
    try std.testing.expect(!empty.isBlocked("https://example.com/"));
}

test "UrlBlocklist: owns compiled patterns" {
    var pattern = [_]u8{ '*', 'a', 'd', 's', '*' };
    var blocklist = try UrlBlocklist.initPatterns(std.testing.allocator, &.{ .{ .urlPattern = &pattern, .block = false }, .{ .urlPattern = "*", .block = true } });
    defer blocklist.deinit();

    @memset(&pattern, 'x');
    try std.testing.expect(!blocklist.isBlocked("https://example.com/ads/script.js"));
}

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

const std = @import("std");

pub const Rule = union(enum) {
    allow: []const u8,
    disallow: []const u8,
};

pub const Key = enum {
    @"user-agent",
    allow,
    disallow,
};

/// https://www.rfc-editor.org/rfc/rfc9309.html
pub const Robots = @This();
pub const empty: Robots = .{ .rules = &.{} };

rules: []const Rule,

const State = enum {
    not_in_entry,
    in_other_entry,
    in_our_entry,
    in_wildcard_entry,
};

fn freeRulesInList(allocator: std.mem.Allocator, rules: []const Rule) void {
    for (rules) |rule| {
        switch (rule) {
            .allow => |value| allocator.free(value),
            .disallow => |value| allocator.free(value),
        }
    }
}

fn parseRulesWithUserAgent(
    allocator: std.mem.Allocator,
    user_agent: []const u8,
    bytes: []const u8,
) ![]const Rule {
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(allocator);

    var wildcard_rules: std.ArrayList(Rule) = .empty;
    defer wildcard_rules.deinit(allocator);

    var state: State = .not_in_entry;

    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip all comment lines.
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        // Remove end of line comment.
        const true_line = if (std.mem.indexOfScalar(u8, trimmed, '#')) |pos|
            std.mem.trimRight(u8, trimmed[0..pos], &std.ascii.whitespace)
        else
            trimmed;

        if (true_line.len == 0) {
            state = .not_in_entry;
            continue;
        }

        const colon_idx = std.mem.indexOfScalar(u8, true_line, ':') orelse return error.MissingColon;
        const key_str = try std.ascii.allocLowerString(allocator, true_line[0..colon_idx]);
        defer allocator.free(key_str);

        const key = std.meta.stringToEnum(Key, key_str) orelse {
            // log.warn(.browser, "robots key", .{ .key = key_str });
            continue;
        };

        const value = std.mem.trim(u8, true_line[colon_idx + 1 ..], &std.ascii.whitespace);

        switch (key) {
            .@"user-agent" => switch (state) {
                .in_other_entry => {
                    if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                        state = .in_our_entry;
                    }
                },
                .in_our_entry => {},
                .in_wildcard_entry => {
                    if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                        state = .in_our_entry;
                    }
                },
                .not_in_entry => {
                    if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                        state = .in_our_entry;
                    } else if (std.mem.eql(u8, "*", value)) {
                        state = .in_wildcard_entry;
                    } else {
                        state = .in_other_entry;
                    }
                },
            },
            .allow => switch (state) {
                .in_our_entry => {
                    const duped_value = try allocator.dupe(u8, value);
                    errdefer allocator.free(duped_value);
                    try rules.append(allocator, .{ .allow = duped_value });
                },
                .in_other_entry => {},
                .in_wildcard_entry => {
                    const duped_value = try allocator.dupe(u8, value);
                    errdefer allocator.free(duped_value);
                    try wildcard_rules.append(allocator, .{ .allow = duped_value });
                },
                .not_in_entry => return error.UnexpectedRule,
            },
            .disallow => switch (state) {
                .in_our_entry => {
                    const duped_value = try allocator.dupe(u8, value);
                    errdefer allocator.free(duped_value);
                    try rules.append(allocator, .{ .disallow = duped_value });
                },
                .in_other_entry => {},
                .in_wildcard_entry => {
                    const duped_value = try allocator.dupe(u8, value);
                    errdefer allocator.free(duped_value);
                    try wildcard_rules.append(allocator, .{ .disallow = duped_value });
                },
                .not_in_entry => return error.UnexpectedRule,
            },
        }
    }

    if (rules.items.len > 0) {
        freeRulesInList(allocator, wildcard_rules.items);
        return try rules.toOwnedSlice(allocator);
    } else {
        freeRulesInList(allocator, rules.items);
        return try wildcard_rules.toOwnedSlice(allocator);
    }
}

pub fn fromBytes(allocator: std.mem.Allocator, user_agent: []const u8, bytes: []const u8) !Robots {
    const rules = try parseRulesWithUserAgent(allocator, user_agent, bytes);
    return .{ .rules = rules };
}

pub fn deinit(self: *Robots, allocator: std.mem.Allocator) void {
    freeRulesInList(allocator, self.rules);
    allocator.free(self.rules);
}

fn matchPatternRecursive(pattern: []const u8, path: []const u8, exact_match: bool) bool {
    if (pattern.len == 0) return true;

    const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        if (exact_match) {
            // If we end in '$', we must be exactly equal.
            return std.mem.eql(u8, path, pattern);
        } else {
            // Otherwise, we are just a prefix.
            return std.mem.startsWith(u8, path, pattern);
        }
    };

    // Ensure the prefix before the '*' matches.
    if (!std.mem.startsWith(u8, path, pattern[0..star_pos])) {
        return false;
    }

    const suffix_pattern = pattern[star_pos + 1 ..];
    if (suffix_pattern.len == 0) return true;

    var i: usize = star_pos;
    while (i <= path.len) : (i += 1) {
        if (matchPatternRecursive(suffix_pattern, path[i..], exact_match)) {
            return true;
        }
    }

    return false;
}

/// There are rules for how the pattern in robots.txt should be matched.
///
/// * should match 0 or more of any character.
/// $ should signify the end of a path, making it exact.
/// otherwise, it is a prefix path.
fn matchPattern(pattern: []const u8, path: []const u8) ?usize {
    if (pattern.len == 0) return 0;
    const exact_match = pattern[pattern.len - 1] == '$';
    const inner_pattern = if (exact_match) pattern[0 .. pattern.len - 1] else pattern;

    if (matchPatternRecursive(
        inner_pattern,
        path,
        exact_match,
    )) return pattern.len else return null;
}

pub fn isAllowed(self: *const Robots, path: []const u8) bool {
    const rules = self.rules;

    var longest_match_len: usize = 0;
    var is_allowed_result = true;

    for (rules) |rule| {
        switch (rule) {
            .allow => |pattern| {
                if (matchPattern(pattern, path)) |len| {
                    // Longest or Last Wins.
                    if (len >= longest_match_len) {
                        longest_match_len = len;
                        is_allowed_result = true;
                    }
                }
            },
            .disallow => |pattern| {
                if (pattern.len == 0) continue;

                if (matchPattern(pattern, path)) |len| {
                    // Longest or Last Wins.
                    if (len >= longest_match_len) {
                        longest_match_len = len;
                        is_allowed_result = false;
                    }
                }
            },
        }
    }

    return is_allowed_result;
}

test "Robots: simple robots.txt" {
    const allocator = std.testing.allocator;

    const file =
        \\User-agent: *
        \\Disallow: /private/
        \\Allow: /public/
        \\
        \\User-agent: Googlebot
        \\Disallow: /admin/
        \\
    ;

    const rules = try parseRulesWithUserAgent(allocator, "GoogleBot", file);
    defer {
        freeRulesInList(allocator, rules);
        allocator.free(rules);
    }

    try std.testing.expectEqual(1, rules.len);
    try std.testing.expectEqualStrings("/admin/", rules[0].disallow);
}

test "Robots: matchPattern - simple prefix" {
    try std.testing.expect(matchPattern("/admin", "/admin/page") != null);
    try std.testing.expect(matchPattern("/admin", "/admin") != null);
    try std.testing.expect(matchPattern("/admin", "/other") == null);
    try std.testing.expect(matchPattern("/admin/page", "/admin") == null);
}

test "Robots: matchPattern - single wildcard" {
    try std.testing.expect(matchPattern("/admin/*", "/admin/") != null);
    try std.testing.expect(matchPattern("/admin/*", "/admin/page") != null);
    try std.testing.expect(matchPattern("/admin/*", "/admin/page/subpage") != null);
    try std.testing.expect(matchPattern("/admin/*", "/other/page") == null);
}

test "Robots: matchPattern - wildcard in middle" {
    try std.testing.expect(matchPattern("/abc/*/xyz", "/abc/def/xyz") != null);
    try std.testing.expect(matchPattern("/abc/*/xyz", "/abc/def/ghi/xyz") != null);
    try std.testing.expect(matchPattern("/abc/*/xyz", "/abc/def") == null);
    try std.testing.expect(matchPattern("/abc/*/xyz", "/other/def/xyz") == null);
}

test "Robots: matchPattern - complex wildcard case" {
    try std.testing.expect(matchPattern("/abc/*/def/xyz", "/abc/def/def/xyz") != null);
    try std.testing.expect(matchPattern("/abc/*/def/xyz", "/abc/ANYTHING/def/xyz") != null);
}

test "Robots: matchPattern - multiple wildcards" {
    try std.testing.expect(matchPattern("/a/*/b/*/c", "/a/x/b/y/c") != null);
    try std.testing.expect(matchPattern("/a/*/b/*/c", "/a/x/y/b/z/w/c") != null);
    try std.testing.expect(matchPattern("/*.php", "/index.php") != null);
    try std.testing.expect(matchPattern("/*.php", "/admin/index.php") != null);
}

test "Robots: matchPattern - end anchor" {
    try std.testing.expect(matchPattern("/*.php$", "/index.php") != null);
    try std.testing.expect(matchPattern("/*.php$", "/index.php?param=value") == null);
    try std.testing.expect(matchPattern("/admin$", "/admin") != null);
    try std.testing.expect(matchPattern("/admin$", "/admin/") == null);
    try std.testing.expect(matchPattern("/fish$", "/fish") != null);
    try std.testing.expect(matchPattern("/fish$", "/fishheads") == null);
}

test "Robots: matchPattern - wildcard with extension" {
    try std.testing.expect(matchPattern("/fish*.php", "/fish.php") != null);
    try std.testing.expect(matchPattern("/fish*.php", "/fishheads.php") != null);
    try std.testing.expect(matchPattern("/fish*.php", "/fish/salmon.php") != null);
    try std.testing.expect(matchPattern("/fish*.php", "/fish.asp") == null);
}

test "Robots: matchPattern - empty and edge cases" {
    try std.testing.expect(matchPattern("", "/anything") != null);
    try std.testing.expect(matchPattern("/", "/") != null);
    try std.testing.expect(matchPattern("*", "/anything") != null);
    try std.testing.expect(matchPattern("/*", "/anything") != null);
    try std.testing.expect(matchPattern("$", "") != null);
}

test "Robots: matchPattern - real world examples" {
    try std.testing.expect(matchPattern("/", "/anything") != null);

    try std.testing.expect(matchPattern("/admin/", "/admin/page") != null);
    try std.testing.expect(matchPattern("/admin/", "/public/page") == null);

    try std.testing.expect(matchPattern("/*.pdf$", "/document.pdf") != null);
    try std.testing.expect(matchPattern("/*.pdf$", "/document.pdf.bak") == null);

    try std.testing.expect(matchPattern("/*?", "/page?param=value") != null);
    try std.testing.expect(matchPattern("/*?", "/page") == null);
}

test "Robots: isAllowed - basic allow/disallow" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "MyBot",
        \\User-agent: MyBot
        \\Disallow: /admin/
        \\Allow: /public/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/") == true);
    try std.testing.expect(robots.isAllowed("/public/page") == true);
    try std.testing.expect(robots.isAllowed("/admin/secret") == false);
    try std.testing.expect(robots.isAllowed("/other/page") == true);
}

test "Robots: isAllowed - longest match wins" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "TestBot",
        \\User-agent: TestBot
        \\Disallow: /admin/
        \\Allow: /admin/public/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/secret") == false);
    try std.testing.expect(robots.isAllowed("/admin/public/page") == true);
    try std.testing.expect(robots.isAllowed("/admin/public/") == true);
}

test "Robots: isAllowed - specific user-agent vs wildcard" {
    const allocator = std.testing.allocator;

    var robots1 = try Robots.fromBytes(allocator, "Googlebot",
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\
        \\User-agent: *
        \\Disallow: /admin/
        \\
    );
    defer robots1.deinit(allocator);

    try std.testing.expect(robots1.isAllowed("/private/page") == false);
    try std.testing.expect(robots1.isAllowed("/admin/page") == true);

    // Test with other bot (should use wildcard)
    var robots2 = try Robots.fromBytes(allocator, "OtherBot",
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\
        \\User-agent: *
        \\Disallow: /admin/
        \\
    );
    defer robots2.deinit(allocator);

    try std.testing.expect(robots2.isAllowed("/private/page") == true);
    try std.testing.expect(robots2.isAllowed("/admin/page") == false);
}

test "Robots: isAllowed - case insensitive user-agent" {
    const allocator = std.testing.allocator;

    var robots1 = try Robots.fromBytes(allocator, "googlebot",
        \\User-agent: GoogleBot
        \\Disallow: /private/
        \\
    );
    defer robots1.deinit(allocator);
    try std.testing.expect(robots1.isAllowed("/private/") == false);

    var robots2 = try Robots.fromBytes(allocator, "GOOGLEBOT",
        \\User-agent: GoogleBot
        \\Disallow: /private/
        \\
    );
    defer robots2.deinit(allocator);
    try std.testing.expect(robots2.isAllowed("/private/") == false);

    var robots3 = try Robots.fromBytes(allocator, "GoOgLeBoT",
        \\User-agent: GoogleBot
        \\Disallow: /private/
        \\
    );
    defer robots3.deinit(allocator);
    try std.testing.expect(robots3.isAllowed("/private/") == false);
}

test "Robots: isAllowed - merged rules for same agent" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Googlebot",
        \\User-agent: Googlebot
        \\Disallow: /admin/
        \\
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/page") == false);
    try std.testing.expect(robots.isAllowed("/private/page") == false);
    try std.testing.expect(robots.isAllowed("/public/page") == true);
}

test "Robots: isAllowed - wildcards in patterns" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot",
        \\User-agent: Bot
        \\Disallow: /*.php$
        \\Allow: /index.php$
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/page.php") == false);
    try std.testing.expect(robots.isAllowed("/index.php") == true);
    try std.testing.expect(robots.isAllowed("/page.php?param=1") == true);
    try std.testing.expect(robots.isAllowed("/page.html") == true);
}

test "Robots: isAllowed - empty disallow allows everything" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot",
        \\User-agent: Bot
        \\Disallow:
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/anything") == true);
    try std.testing.expect(robots.isAllowed("/") == true);
}

test "Robots: isAllowed - no rules" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot", "");
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/anything") == true);
}

test "Robots: isAllowed - disallow all" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot",
        \\User-agent: Bot
        \\Disallow: /
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/") == false);
    try std.testing.expect(robots.isAllowed("/anything") == false);
    try std.testing.expect(robots.isAllowed("/admin/page") == false);
}

test "Robots: isAllowed - multiple user-agents in same entry" {
    const allocator = std.testing.allocator;

    var robots1 = try Robots.fromBytes(allocator, "Googlebot",
        \\User-agent: Googlebot
        \\User-agent: Bingbot
        \\Disallow: /private/
        \\
    );
    defer robots1.deinit(allocator);
    try std.testing.expect(robots1.isAllowed("/private/") == false);

    var robots2 = try Robots.fromBytes(allocator, "Bingbot",
        \\User-agent: Googlebot
        \\User-agent: Bingbot
        \\Disallow: /private/
        \\
    );
    defer robots2.deinit(allocator);
    try std.testing.expect(robots2.isAllowed("/private/") == false);

    var robots3 = try Robots.fromBytes(allocator, "OtherBot",
        \\User-agent: Googlebot
        \\User-agent: Bingbot
        \\Disallow: /private/
        \\
    );
    defer robots3.deinit(allocator);
    try std.testing.expect(robots3.isAllowed("/private/") == true);
}

test "Robots: isAllowed - wildcard fallback" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "UnknownBot",
        \\User-agent: *
        \\Disallow: /admin/
        \\Allow: /admin/public/
        \\
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/secret") == false);
    try std.testing.expect(robots.isAllowed("/admin/public/page") == true);
    try std.testing.expect(robots.isAllowed("/private/") == true);
}

test "Robots: isAllowed - complex real-world example" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "MyBot",
        \\User-agent: *
        \\Disallow: /cgi-bin/
        \\Disallow: /tmp/
        \\Disallow: /private/
        \\
        \\User-agent: MyBot
        \\Disallow: /admin/
        \\Disallow: /*.pdf$
        \\Allow: /public/*.pdf$
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/") == true);
    try std.testing.expect(robots.isAllowed("/admin/dashboard") == false);
    try std.testing.expect(robots.isAllowed("/docs/guide.pdf") == false);
    try std.testing.expect(robots.isAllowed("/public/manual.pdf") == true);
    try std.testing.expect(robots.isAllowed("/page.html") == true);
    try std.testing.expect(robots.isAllowed("/cgi-bin/script.sh") == true);
}

test "Robots: isAllowed - order doesn't matter for same length" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot",
        \\User-agent: Bot
        \\ # WOW!!
        \\Allow: /page
        \\Disallow: /page
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/page") == false);
}

test "Robots: isAllowed - empty file uses wildcard defaults" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "MyBot",
        \\User-agent: * # ABCDEF!!!
        \\Disallow: /admin/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/") == false);
    try std.testing.expect(robots.isAllowed("/public/") == true);
}
test "Robots: isAllowed - wildcard entry with multiple user-agents including specific" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Googlebot",
        \\User-agent: *
        \\User-agent: Googlebot
        \\Disallow: /shared/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/shared/") == false);
    try std.testing.expect(robots.isAllowed("/other/") == true);

    var robots2 = try Robots.fromBytes(allocator, "Bingbot",
        \\User-agent: *
        \\User-agent: Googlebot
        \\Disallow: /shared/
        \\
    );
    defer robots2.deinit(allocator);

    try std.testing.expect(robots2.isAllowed("/shared/") == false);
}

test "Robots: isAllowed - specific agent appears after wildcard in entry" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "MyBot",
        \\User-agent: *
        \\User-agent: MyBot
        \\User-agent: Bingbot
        \\Disallow: /admin/
        \\Allow: /admin/public/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/secret") == false);
    try std.testing.expect(robots.isAllowed("/admin/public/page") == true);
}

test "Robots: isAllowed - wildcard should not override specific entry" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Googlebot",
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\
        \\User-agent: *
        \\User-agent: Googlebot
        \\Disallow: /admin/
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/private/") == false);
    try std.testing.expect(robots.isAllowed("/admin/") == false);
}

test "Robots: isAllowed - Google's real robots.txt" {
    const allocator = std.testing.allocator;

    // Simplified version of google.com/robots.txt
    const google_robots =
        \\User-agent: *
        \\User-agent: Yandex
        \\Disallow: /search
        \\Allow: /search/about
        \\Allow: /search/howsearchworks
        \\Disallow: /imgres
        \\Disallow: /m?
        \\Disallow: /m/
        \\Allow:    /m/finance
        \\Disallow: /maps/
        \\Allow: /maps/$
        \\Allow: /maps/@
        \\Allow: /maps/dir/
        \\Disallow: /shopping?
        \\Allow: /shopping?udm=28$
        \\
        \\User-agent: AdsBot-Google
        \\Disallow: /maps/api/js/
        \\Allow: /maps/api/js
        \\Disallow: /maps/api/staticmap
        \\
        \\User-agent: Yandex
        \\Disallow: /about/careers/applications/jobs/results
        \\
        \\User-agent: facebookexternalhit
        \\User-agent: Twitterbot
        \\Allow: /imgres
        \\Allow: /search
        \\Disallow: /groups
        \\Disallow: /m/
        \\
    ;

    var regular_bot = try Robots.fromBytes(allocator, "Googlebot", google_robots);
    defer regular_bot.deinit(allocator);

    try std.testing.expect(regular_bot.isAllowed("/") == true);
    try std.testing.expect(regular_bot.isAllowed("/search") == false);
    try std.testing.expect(regular_bot.isAllowed("/search/about") == true);
    try std.testing.expect(regular_bot.isAllowed("/search/howsearchworks") == true);
    try std.testing.expect(regular_bot.isAllowed("/imgres") == false);
    try std.testing.expect(regular_bot.isAllowed("/m/finance") == true);
    try std.testing.expect(regular_bot.isAllowed("/m/other") == false);
    try std.testing.expect(regular_bot.isAllowed("/maps/") == true);
    try std.testing.expect(regular_bot.isAllowed("/maps/@") == true);
    try std.testing.expect(regular_bot.isAllowed("/shopping?udm=28") == true);
    try std.testing.expect(regular_bot.isAllowed("/shopping?udm=28&extra") == false);

    var adsbot = try Robots.fromBytes(allocator, "AdsBot-Google", google_robots);
    defer adsbot.deinit(allocator);

    try std.testing.expect(adsbot.isAllowed("/maps/api/js") == true);
    try std.testing.expect(adsbot.isAllowed("/maps/api/js/") == false);
    try std.testing.expect(adsbot.isAllowed("/maps/api/staticmap") == false);

    var twitterbot = try Robots.fromBytes(allocator, "Twitterbot", google_robots);
    defer twitterbot.deinit(allocator);

    try std.testing.expect(twitterbot.isAllowed("/imgres") == true);
    try std.testing.expect(twitterbot.isAllowed("/search") == true);
    try std.testing.expect(twitterbot.isAllowed("/groups") == false);
    try std.testing.expect(twitterbot.isAllowed("/m/") == false);
}

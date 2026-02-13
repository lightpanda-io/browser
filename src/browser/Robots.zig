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

const builtin = @import("builtin");
const std = @import("std");
const log = @import("../log.zig");

pub const CompiledPattern = struct {
    pattern: []const u8,
    ty: enum {
        prefix, // "/admin/" - prefix match
        exact, // "/admin$" - exact match
        wildcard, // any pattern that contains *
    },

    fn compile(pattern: []const u8) CompiledPattern {
        if (pattern.len == 0) {
            return .{
                .pattern = pattern,
                .ty = .prefix,
            };
        }

        const is_wildcard = std.mem.indexOfScalar(u8, pattern, '*') != null;

        if (is_wildcard) {
            return .{
                .pattern = pattern,
                .ty = .wildcard,
            };
        }

        const has_end_anchor = pattern[pattern.len - 1] == '$';
        return .{
            .pattern = pattern,
            .ty = if (has_end_anchor) .exact else .prefix,
        };
    }
};

pub const Rule = union(enum) {
    allow: CompiledPattern,
    disallow: CompiledPattern,

    fn allowRule(pattern: []const u8) Rule {
        return .{ .allow = CompiledPattern.compile(pattern) };
    }

    fn disallowRule(pattern: []const u8) Rule {
        return .{ .disallow = CompiledPattern.compile(pattern) };
    }
};

pub const Key = enum {
    @"user-agent",
    allow,
    disallow,
};

/// https://www.rfc-editor.org/rfc/rfc9309.html
pub const Robots = @This();
pub const empty: Robots = .{ .rules = &.{} };

pub const RobotStore = struct {
    const RobotsEntry = union(enum) {
        present: Robots,
        absent,
    };

    pub const RobotsMap = std.HashMapUnmanaged([]const u8, RobotsEntry, struct {
        const Context = @This();

        pub fn hash(_: Context, value: []const u8) u32 {
            var hasher = std.hash.Wyhash.init(value.len);
            for (value) |c| {
                std.hash.autoHash(&hasher, std.ascii.toLower(c));
            }
            return @truncate(hasher.final());
        }

        pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }, 80);

    allocator: std.mem.Allocator,
    map: RobotsMap,

    pub fn init(allocator: std.mem.Allocator) RobotStore {
        return .{ .allocator = allocator, .map = .empty };
    }

    pub fn deinit(self: *RobotStore) void {
        var iter = self.map.iterator();

        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);

            switch (entry.value_ptr.*) {
                .present => |*robots| robots.deinit(self.allocator),
                .absent => {},
            }
        }

        self.map.deinit(self.allocator);
    }

    pub fn get(self: *RobotStore, url: []const u8) ?RobotsEntry {
        return self.map.get(url);
    }

    pub fn robotsFromBytes(self: *RobotStore, user_agent: []const u8, bytes: []const u8) !Robots {
        return try Robots.fromBytes(self.allocator, user_agent, bytes);
    }

    pub fn put(self: *RobotStore, url: []const u8, robots: Robots) !void {
        const duped = try self.allocator.dupe(u8, url);
        try self.map.put(self.allocator, duped, .{ .present = robots });
    }

    pub fn putAbsent(self: *RobotStore, url: []const u8) !void {
        const duped = try self.allocator.dupe(u8, url);
        try self.map.put(self.allocator, duped, .absent);
    }
};

rules: []const Rule,

const State = struct {
    entry: enum {
        not_in_entry,
        in_other_entry,
        in_our_entry,
        in_wildcard_entry,
    },
    has_rules: bool = false,
};

fn freeRulesInList(allocator: std.mem.Allocator, rules: []const Rule) void {
    for (rules) |rule| {
        switch (rule) {
            .allow => |compiled| allocator.free(compiled.pattern),
            .disallow => |compiled| allocator.free(compiled.pattern),
        }
    }
}

fn parseRulesWithUserAgent(
    allocator: std.mem.Allocator,
    user_agent: []const u8,
    raw_bytes: []const u8,
) ![]Rule {
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(allocator);

    var wildcard_rules: std.ArrayList(Rule) = .empty;
    defer wildcard_rules.deinit(allocator);

    var state: State = .{ .entry = .not_in_entry, .has_rules = false };

    // https://en.wikipedia.org/wiki/Byte_order_mark
    const UTF8_BOM: []const u8 = &.{ 0xEF, 0xBB, 0xBF };

    // Strip UTF8 BOM
    const bytes = if (std.mem.startsWith(u8, raw_bytes, UTF8_BOM))
        raw_bytes[3..]
    else
        raw_bytes;

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

        if (true_line.len == 0) continue;

        const colon_idx = std.mem.indexOfScalar(u8, true_line, ':') orelse {
            log.warn(.browser, "robots line missing colon", .{ .line = line });
            continue;
        };
        const key_str = try std.ascii.allocLowerString(allocator, true_line[0..colon_idx]);
        defer allocator.free(key_str);

        const key = std.meta.stringToEnum(Key, key_str) orelse continue;
        const value = std.mem.trim(u8, true_line[colon_idx + 1 ..], &std.ascii.whitespace);

        switch (key) {
            .@"user-agent" => {
                if (state.has_rules) {
                    state = .{ .entry = .not_in_entry, .has_rules = false };
                }

                switch (state.entry) {
                    .in_other_entry => {
                        if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                            state.entry = .in_our_entry;
                        }
                    },
                    .in_our_entry => {},
                    .in_wildcard_entry => {
                        if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                            state.entry = .in_our_entry;
                        }
                    },
                    .not_in_entry => {
                        if (std.ascii.eqlIgnoreCase(user_agent, value)) {
                            state.entry = .in_our_entry;
                        } else if (std.mem.eql(u8, "*", value)) {
                            state.entry = .in_wildcard_entry;
                        } else {
                            state.entry = .in_other_entry;
                        }
                    },
                }
            },
            .allow => {
                defer state.has_rules = true;

                switch (state.entry) {
                    .in_our_entry => {
                        const duped_value = try allocator.dupe(u8, value);
                        errdefer allocator.free(duped_value);
                        try rules.append(allocator, Rule.allowRule(duped_value));
                    },
                    .in_other_entry => {},
                    .in_wildcard_entry => {
                        const duped_value = try allocator.dupe(u8, value);
                        errdefer allocator.free(duped_value);
                        try wildcard_rules.append(allocator, Rule.allowRule(duped_value));
                    },
                    .not_in_entry => {
                        log.warn(.browser, "robots unexpected rule", .{ .rule = "allow" });
                        continue;
                    },
                }
            },
            .disallow => {
                defer state.has_rules = true;

                switch (state.entry) {
                    .in_our_entry => {
                        if (value.len == 0) continue;

                        const duped_value = try allocator.dupe(u8, value);
                        errdefer allocator.free(duped_value);
                        try rules.append(allocator, Rule.disallowRule(duped_value));
                    },
                    .in_other_entry => {},
                    .in_wildcard_entry => {
                        if (value.len == 0) continue;

                        const duped_value = try allocator.dupe(u8, value);
                        errdefer allocator.free(duped_value);
                        try wildcard_rules.append(allocator, Rule.disallowRule(duped_value));
                    },
                    .not_in_entry => {
                        log.warn(.browser, "robots unexpected rule", .{ .rule = "disallow" });
                        continue;
                    },
                }
            },
        }
    }

    // If we have rules for our specific User-Agent, we will use those rules.
    // If we don't have any rules, we fallback to using the wildcard ("*") rules.
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

    // sort by order once.
    std.mem.sort(Rule, rules, {}, struct {
        fn lessThan(_: void, a: Rule, b: Rule) bool {
            const a_len = switch (a) {
                .allow => |p| p.pattern.len,
                .disallow => |p| p.pattern.len,
            };

            const b_len = switch (b) {
                .allow => |p| p.pattern.len,
                .disallow => |p| p.pattern.len,
            };

            // Sort by length first.
            if (a_len != b_len) {
                return a_len > b_len;
            }

            // Otherwise, allow should beat disallow.
            const a_is_allow = switch (a) {
                .allow => true,
                .disallow => false,
            };
            const b_is_allow = switch (b) {
                .allow => true,
                .disallow => false,
            };

            return a_is_allow and !b_is_allow;
        }
    }.lessThan);

    return .{ .rules = rules };
}

pub fn deinit(self: *Robots, allocator: std.mem.Allocator) void {
    freeRulesInList(allocator, self.rules);
    allocator.free(self.rules);
}

/// There are rules for how the pattern in robots.txt should be matched.
///
/// * should match 0 or more of any character.
/// $ should signify the end of a path, making it exact.
/// otherwise, it is a prefix path.
fn matchPattern(compiled: CompiledPattern, path: []const u8) bool {
    switch (compiled.ty) {
        .prefix => return std.mem.startsWith(u8, path, compiled.pattern),
        .exact => {
            const pattern = compiled.pattern;
            return std.mem.eql(u8, path, pattern[0 .. pattern.len - 1]);
        },
        .wildcard => {
            const pattern = compiled.pattern;
            const exact_match = pattern[pattern.len - 1] == '$';
            const inner_pattern = if (exact_match) pattern[0 .. pattern.len - 1] else pattern;
            return matchInnerPattern(inner_pattern, path, exact_match);
        },
    }
}

fn matchInnerPattern(pattern: []const u8, path: []const u8, exact_match: bool) bool {
    var pattern_idx: usize = 0;
    var path_idx: usize = 0;

    var star_pattern_idx: ?usize = null;
    var star_path_idx: ?usize = null;

    while (pattern_idx < pattern.len or path_idx < path.len) {
        // 1: If pattern is consumed and we are doing prefix match, we matched.
        if (pattern_idx >= pattern.len and !exact_match) {
            return true;
        }

        // 2: Current character is a wildcard
        if (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
            star_pattern_idx = pattern_idx;
            star_path_idx = path_idx;
            pattern_idx += 1;
            continue;
        }

        // 3: Characters match, advance both heads.
        if (pattern_idx < pattern.len and path_idx < path.len and pattern[pattern_idx] == path[path_idx]) {
            pattern_idx += 1;
            path_idx += 1;
            continue;
        }

        // 4: we have a previous wildcard, backtrack and try matching more.
        if (star_pattern_idx) |star_p_idx| {
            // if we have exhausted the path,
            // we know we haven't matched.
            if (star_path_idx.? > path.len) {
                return false;
            }

            pattern_idx = star_p_idx + 1;
            path_idx = star_path_idx.?;
            star_path_idx.? += 1;
            continue;
        }

        // Fallthrough: No match and no backtracking.
        return false;
    }

    // Handle trailing widlcards that can match 0 characters.
    while (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
        pattern_idx += 1;
    }

    if (exact_match) {
        // Both must be fully consumed.
        return pattern_idx == pattern.len and path_idx == path.len;
    }

    // For prefix match, pattern must be completed.
    return pattern_idx == pattern.len;
}

pub fn isAllowed(self: *const Robots, path: []const u8) bool {
    for (self.rules) |rule| {
        switch (rule) {
            .allow => |compiled| if (matchPattern(compiled, path)) return true,
            .disallow => |compiled| if (matchPattern(compiled, path)) return false,
        }
    }

    return true;
}

fn testMatch(pattern: []const u8, path: []const u8) bool {
    comptime if (!builtin.is_test) unreachable;

    return matchPattern(CompiledPattern.compile(pattern), path);
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
    try std.testing.expectEqualStrings("/admin/", rules[0].disallow.pattern);
}

test "Robots: matchPattern - simple prefix" {
    try std.testing.expect(testMatch("/admin", "/admin/page"));
    try std.testing.expect(testMatch("/admin", "/admin"));
    try std.testing.expect(!testMatch("/admin", "/other"));
    try std.testing.expect(!testMatch("/admin/page", "/admin"));
}

test "Robots: matchPattern - single wildcard" {
    try std.testing.expect(testMatch("/admin/*", "/admin/"));
    try std.testing.expect(testMatch("/admin/*", "/admin/page"));
    try std.testing.expect(testMatch("/admin/*", "/admin/page/subpage"));
    try std.testing.expect(!testMatch("/admin/*", "/other/page"));
}

test "Robots: matchPattern - wildcard in middle" {
    try std.testing.expect(testMatch("/abc/*/xyz", "/abc/def/xyz"));
    try std.testing.expect(testMatch("/abc/*/xyz", "/abc/def/ghi/xyz"));
    try std.testing.expect(!testMatch("/abc/*/xyz", "/abc/def"));
    try std.testing.expect(!testMatch("/abc/*/xyz", "/other/def/xyz"));
}

test "Robots: matchPattern - complex wildcard case" {
    try std.testing.expect(testMatch("/abc/*/def/xyz", "/abc/def/def/xyz"));
    try std.testing.expect(testMatch("/abc/*/def/xyz", "/abc/ANYTHING/def/xyz"));
}

test "Robots: matchPattern - multiple wildcards" {
    try std.testing.expect(testMatch("/a/*/b/*/c", "/a/x/b/y/c"));
    try std.testing.expect(testMatch("/a/*/b/*/c", "/a/x/y/b/z/w/c"));
    try std.testing.expect(testMatch("/*.php", "/index.php"));
    try std.testing.expect(testMatch("/*.php", "/admin/index.php"));
}

test "Robots: matchPattern - end anchor" {
    try std.testing.expect(testMatch("/*.php$", "/index.php"));
    try std.testing.expect(!testMatch("/*.php$", "/index.php?param=value"));
    try std.testing.expect(testMatch("/admin$", "/admin"));
    try std.testing.expect(!testMatch("/admin$", "/admin/"));
    try std.testing.expect(testMatch("/fish$", "/fish"));
    try std.testing.expect(!testMatch("/fish$", "/fishheads"));
}

test "Robots: matchPattern - wildcard with extension" {
    try std.testing.expect(testMatch("/fish*.php", "/fish.php"));
    try std.testing.expect(testMatch("/fish*.php", "/fishheads.php"));
    try std.testing.expect(testMatch("/fish*.php", "/fish/salmon.php"));
    try std.testing.expect(!testMatch("/fish*.php", "/fish.asp"));
}

test "Robots: matchPattern - empty and edge cases" {
    try std.testing.expect(testMatch("", "/anything"));
    try std.testing.expect(testMatch("/", "/"));
    try std.testing.expect(testMatch("*", "/anything"));
    try std.testing.expect(testMatch("/*", "/anything"));
    try std.testing.expect(testMatch("$", ""));
}

test "Robots: matchPattern - real world examples" {
    try std.testing.expect(testMatch("/", "/anything"));

    try std.testing.expect(testMatch("/admin/", "/admin/page"));
    try std.testing.expect(!testMatch("/admin/", "/public/page"));

    try std.testing.expect(testMatch("/*.pdf$", "/document.pdf"));
    try std.testing.expect(!testMatch("/*.pdf$", "/document.pdf.bak"));

    try std.testing.expect(testMatch("/*?", "/page?param=value"));
    try std.testing.expect(!testMatch("/*?", "/page"));
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

test "Robots: isAllowed - order doesn't matter + allow wins" {
    const allocator = std.testing.allocator;

    var robots = try Robots.fromBytes(allocator, "Bot",
        \\User-agent: Bot
        \\ # WOW!!
        \\Allow: /page
        \\Disallow: /page
        \\
    );
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/page") == true);
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

test "Robots: user-agent after rules starts new entry" {
    const allocator = std.testing.allocator;

    const file =
        \\User-agent: Bot1
        \\User-agent: Bot2
        \\Disallow: /admin/
        \\Allow: /public/
        \\User-agent: Bot3
        \\Disallow: /private/
        \\
    ;

    var robots1 = try Robots.fromBytes(allocator, "Bot1", file);
    defer robots1.deinit(allocator);
    try std.testing.expect(robots1.isAllowed("/admin/") == false);
    try std.testing.expect(robots1.isAllowed("/public/") == true);
    try std.testing.expect(robots1.isAllowed("/private/") == true);

    var robots2 = try Robots.fromBytes(allocator, "Bot2", file);
    defer robots2.deinit(allocator);
    try std.testing.expect(robots2.isAllowed("/admin/") == false);
    try std.testing.expect(robots2.isAllowed("/public/") == true);
    try std.testing.expect(robots2.isAllowed("/private/") == true);

    var robots3 = try Robots.fromBytes(allocator, "Bot3", file);
    defer robots3.deinit(allocator);
    try std.testing.expect(robots3.isAllowed("/admin/") == true);
    try std.testing.expect(robots3.isAllowed("/public/") == true);
    try std.testing.expect(robots3.isAllowed("/private/") == false);
}

test "Robots: blank lines don't end entries" {
    const allocator = std.testing.allocator;

    const file =
        \\User-agent: MyBot
        \\Disallow: /admin/
        \\
        \\
        \\Allow: /public/
        \\
    ;

    var robots = try Robots.fromBytes(allocator, "MyBot", file);
    defer robots.deinit(allocator);

    try std.testing.expect(robots.isAllowed("/admin/") == false);
    try std.testing.expect(robots.isAllowed("/public/") == true);
}

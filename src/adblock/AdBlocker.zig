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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const adblock = @import("adblock.zig");
const HostnameTrie = @import("HostnameTrie.zig");
const NetworkFilter = @import("NetworkFilter.zig");

const AdBlocker = @This();

arena: std.heap.ArenaAllocator,
/// Network filters the tries cannot express: patterns, type/party/domain
/// constraints, badfilter directives.
filters: std.ArrayList(NetworkFilter),
trie: HostnameTrie,
blocked: u32,
/// $important hostname blocks: they beat exceptions.
blocked_important: u32,
/// Pure-hostname `@@` exceptions.
allowed: u32,

pub fn init(allocator: Allocator) Allocator.Error!AdBlocker {
    var trie: HostnameTrie = try .init(allocator);
    errdefer trie.deinit(allocator);
    const blocked = try trie.createTrie(allocator);
    const blocked_important = try trie.createTrie(allocator);
    const allowed = try trie.createTrie(allocator);

    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .filters = .empty,
        .trie = trie,
        .blocked = blocked,
        .blocked_important = blocked_important,
        .allowed = allowed,
    };
}

pub fn deinit(self: *AdBlocker) void {
    self.trie.deinit(self.arena.child_allocator);
    self.arena.deinit();
}

pub fn parse(self: *AdBlocker, reader: *Io.Reader) !adblock.ParseStats {
    var scratch_instance = std.heap.ArenaAllocator.init(self.arena.child_allocator);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    const arena = self.arena.allocator();
    var parser: adblock.Parser = .init(reader);

    var parsed: std.ArrayList(NetworkFilter) = .empty;
    while (try parser.next(scratch)) |filter| {
        if (self.trieRoot(&filter)) |root| {
            // Duplicate and subdomain-of-existing entries drop.
            self.trie.add(self.arena.child_allocator, root, filter.hostname) catch |err| switch (err) {
                error.OutOfMemory, error.TrieFull => |e| return e,
                // The parser never yields a .hostname filter without one.
                error.InvalidHostname => unreachable,
            };
            continue;
        }
        try parsed.append(scratch, try filter.dupe(arena));
    }

    try self.filters.appendSlice(arena, parsed.items);
    return parser.stats;
}

pub const Verdict = enum { none, allowed, blocked };

/// `.none` means no hostname-wide filter applies; the filters kept in `filters` may
/// still have an opinion once the request engine exists.
pub fn matchHostname(self: *const AdBlocker, hostname: []const u8) Verdict {
    if (self.trie.matches(self.blocked_important, hostname) != null) return .blocked;
    if (self.trie.matches(self.allowed, hostname) != null) return .allowed;
    if (self.trie.matches(self.blocked, hostname) != null) return .blocked;
    return .none;
}

/// The trie holding this filter, or null when the filter's behavior is
/// more than a hostname-wide match and must stay in `filters`.
fn trieRoot(self: *const AdBlocker, filter: *const NetworkFilter) ?u32 {
    if (filter.kind != .hostname) return null;
    // `||host` without '^' also matches hostnames merely *starting* with
    // host ("example.com.evil.org"): broader than a suffix match.
    if (!filter.require_separator) return null;
    // `||host^|` pins the URL end to the separator: narrower.
    if (filter.left_anchor or filter.right_anchor) return null;
    if (filter.badfilter) return null;
    if (!filter.first_party or !filter.third_party) return null;
    if (!filter.domains.isEmpty()) return null;
    if (filter.types.bits() != NetworkFilter.ResourceTypes.all.bits()) return null;
    if (filter.exception) {
        // Cosmetic-realm exceptions never unblock network requests.
        if (filter.generichide or filter.specifichide or filter.elemhide) return null;
        return self.allowed;
    }
    return if (filter.important) self.blocked_important else self.blocked;
}

const testing = std.testing;

test "adblock.AdBlocker: parse accumulates filters across lists" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var first: Io.Reader = .fixed(
        \\! Title: First List
        \\||ads.example.com^
        \\@@||cdn.example.com^$script
        \\example.com##.ad-banner
    );
    const first_stats = try blocker.parse(&first);

    // The pure-hostname block went into the trie; the $script exception
    // is type-restricted and stays a filter.
    try testing.expectEqual(1, blocker.filters.items.len);
    try testing.expectEqual(2, first_stats.network);
    try testing.expectEqual(1, first_stats.unsupported); // cosmetic line
    try testing.expectEqual(.blocked, blocker.matchHostname("ads.example.com"));
    try testing.expectEqual(.blocked, blocker.matchHostname("sub.ads.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("cdn.example.com"));

    var second: Io.Reader = .fixed(
        \\||tracker.net^$third-party,domain=news.com|~sports.news.com
    );
    const second_stats = try blocker.parse(&second);

    try testing.expectEqual(2, blocker.filters.items.len);
    try testing.expectEqual(1, second_stats.network);
    try testing.expectEqual(.none, blocker.matchHostname("tracker.net"));

    // The scratch arena holding each list's text is gone: every retained
    // string must have been deep-copied.
    try testing.expect(blocker.filters.items[0].exception);
    try testing.expectEqualStrings("cdn.example.com", blocker.filters.items[0].hostname);
    const tracker = blocker.filters.items[1];
    try testing.expectEqualStrings("tracker.net", tracker.hostname);
    try testing.expect(!tracker.first_party);
    try testing.expectEqualStrings("news.com", tracker.domains.included[0].value);
    try testing.expectEqualStrings("sports.news.com", tracker.domains.excluded[0].value);
}

test "adblock.AdBlocker: hostname verdict precedence" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var list: Io.Reader = .fixed(
        \\||ads.example.com^
        \\@@||good.ads.example.com^
        \\||evil.com^$important
        \\@@||evil.com^
    );
    _ = try blocker.parse(&list);

    try testing.expectEqual(.blocked, blocker.matchHostname("ads.example.com"));
    // The exception wins over the plain block...
    try testing.expectEqual(.allowed, blocker.matchHostname("good.ads.example.com"));
    try testing.expectEqual(.allowed, blocker.matchHostname("x.good.ads.example.com"));
    try testing.expectEqual(.blocked, blocker.matchHostname("other.ads.example.com"));
    // ...but $important beats the exception.
    try testing.expectEqual(.blocked, blocker.matchHostname("evil.com"));
    try testing.expectEqual(.none, blocker.matchHostname("example.com"));
}

test "adblock.AdBlocker: trie absorbs every pure-hostname form" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var list: Io.Reader = .fixed(
        \\||anchored.example.com^
        \\bare-hostname.example.com
        \\0.0.0.0 hosts-style.example.io
    );
    _ = try blocker.parse(&list);

    try testing.expectEqual(0, blocker.filters.items.len);
    try testing.expectEqual(.blocked, blocker.matchHostname("anchored.example.com"));
    try testing.expectEqual(.blocked, blocker.matchHostname("bare-hostname.example.com"));
    try testing.expectEqual(.blocked, blocker.matchHostname("hosts-style.example.io"));
}

test "adblock.AdBlocker: constrained filters stay out of the trie" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var list: Io.Reader = .fixed(
        \\||no-caret.example.com
        \\||typed.example.com^$script
        \\||party.example.com^$third-party
        \\||sited.example.com^$domain=news.com
        \\||bad.example.com^$badfilter
        \\@@||cosmetic.example.com^$generichide
    );
    _ = try blocker.parse(&list);

    try testing.expectEqual(6, blocker.filters.items.len);
    try testing.expectEqual(.none, blocker.matchHostname("no-caret.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("typed.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("party.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("sited.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("bad.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("cosmetic.example.com"));
}

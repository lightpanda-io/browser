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
const lp = @import("lightpanda");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("../../Config.zig");

const Parser = @import("Parser.zig");
const HostnameTrie = @import("HostnameTrie.zig");
const NetworkFilter = @import("NetworkFilter.zig");

const log = lp.log;

const AdBlocker = @This();

allocator: Allocator,
trie: HostnameTrie,
blocked: u32,
/// $important hostname blocks: they beat exceptions.
blocked_important: u32,
/// Pure-hostname `@@` exceptions.
allowed: u32,
suppressed: u32,
/// Rules that reached a trie, across every list parsed so far.
rules_loaded: usize,
/// Rules the lists carry and we do not apply, across those same lists: the
/// ones the parser could not read, plus the ones no trie can express.
rules_skipped: usize,

/// Read buffer for filter lists, and therefore the longest line we can see.
/// Real-world rules are well under 1KB; the parser skips anything longer.
const LINE_MAX = 8 * 1024;

pub fn init(allocator: Allocator) Allocator.Error!AdBlocker {
    var trie: HostnameTrie = try .init(allocator);
    errdefer trie.deinit(allocator);
    const blocked = try trie.createTrie(allocator);
    const blocked_important = try trie.createTrie(allocator);
    const allowed = try trie.createTrie(allocator);
    const suppressed = try trie.createTrie(allocator);

    return .{
        .allocator = allocator,
        .trie = trie,
        .blocked = blocked,
        .blocked_important = blocked_important,
        .allowed = allowed,
        .suppressed = suppressed,
        .rules_loaded = 0,
        .rules_skipped = 0,
    };
}

/// Builds the blocker from `--adblock-lists`, or null when the option is
/// unset. Lists accumulate into the one instance.
pub fn fromConfig(allocator: Allocator, config: *const Config) !?AdBlocker {
    var paths = config.adblockLists() orelse return null;

    var adblocker: ?AdBlocker = null;
    errdefer if (adblocker) |*blocker| blocker.deinit();

    const buf = try allocator.alloc(u8, LINE_MAX);
    defer allocator.free(buf);

    while (paths.next()) |path| {
        if (path.len == 0) continue;
        if (adblocker == null) adblocker = try AdBlocker.init(allocator);
        loadList(&adblocker.?, path, buf) catch |err| {
            log.err(.app, "adblock list load failed", .{ .path = path, .err = err });
            return err;
        };
    }

    if (adblocker) |*blocker| {
        log.info(.app, "adblock lists loaded", .{
            .loaded = blocker.rules_loaded,
            .skipped = blocker.rules_skipped,
        });
    }
    return adblocker;
}

/// Streams `path` into `blocker`. The list is consumed line by line, so a
/// 100MB list never needs 100MB of memory.
fn loadList(blocker: *AdBlocker, path: []const u8, buf: []u8) !void {
    const file = try std.Io.Dir.cwd().openFile(lp.io, path, .{});
    defer file.close(lp.io);

    var file_reader = file.reader(lp.io, buf);
    try blocker.parse(&file_reader.interface);
}

pub fn deinit(self: *AdBlocker) void {
    self.trie.deinit(self.allocator);
}

pub fn parse(self: *AdBlocker, reader: *Io.Reader) !void {
    var scratch_instance = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    var parser: Parser = .init(reader);
    // Lines the parser dropped are rules we did not load just as much as the
    // ones we drop below, and on a real list they are the bulk of them.
    defer self.rules_skipped += parser.skipped;

    while (try parser.next(scratch)) |filter| {
        // Nothing survives the iteration but the trie entry, so the
        // scratch arena is recycled rather than grown per filter.
        defer _ = scratch_instance.reset(.retain_capacity);

        // Filters the tries cannot express (patterns, type/party/domain
        // constraints) are dropped: deciding those needs a request engine
        // we do not have yet, and retaining them costs tens of MB on a
        // list like EasyList.
        const root = self.trieRoot(&filter) orelse {
            self.rules_skipped += 1;
            continue;
        };
        // Duplicate and subdomain-of-existing entries drop.
        self.trie.add(self.allocator, root, filter.hostname) catch |err| switch (err) {
            error.OutOfMemory, error.TrieFull => |e| return e,
            // trieRoot never routes a filter without one.
            error.InvalidHostname => unreachable,
        };
        self.rules_loaded += 1;
    }
}

pub const Verdict = enum { none, allowed, blocked };

/// `.none` means no hostname-wide verdict applies. Filters that need more
/// than a hostname match are not represented here at all.
pub fn matchHostname(self: *const AdBlocker, hostname: []const u8) Verdict {
    // A hostname something might unblock stays undecided, whatever else
    // matches it.
    if (self.trie.matches(self.suppressed, hostname) != null) return .none;
    if (self.trie.matches(self.blocked_important, hostname) != null) return .blocked;
    if (self.trie.matches(self.allowed, hostname) != null) return .allowed;
    if (self.trie.matches(self.blocked, hostname) != null) return .blocked;
    return .none;
}

/// The trie holding this filter, or null when it carries no hostname-wide
/// meaning we can represent.
fn trieRoot(self: *const AdBlocker, filter: *const NetworkFilter) ?u32 {
    // An exception or a $badfilter can only ever *unblock*. Where one is
    // narrower than a whole hostname we cannot evaluate it here — but
    // ignoring it is not neutral either, because the rule it cancels may
    // well be a plain block we did keep:
    //
    //   ||adsafeprotected.com^
    //   @@||adsafeprotected.com/iasPET.$script,domain=reuters.com|...
    //
    // uBO blocks that host everywhere but those sites; keeping only the
    // first line blocks it on those sites too, and breaks them. So the
    // hostname goes to `suppressed` and stops being blockable at all. We
    // lose most of the block's value to save the pages it would break,
    // which is the direction we want to fail in.
    if (filter.exception or filter.badfilter) {
        // Cosmetic-realm exceptions never unblock network requests.
        if (filter.exception and (filter.generichide or filter.specifichide or filter.elemhide)) {
            return null;
        }
        if (filter.exception and !filter.badfilter and isWholeHostname(filter)) {
            return self.allowed;
        }
        // `@@/ads/^$script` and friends name no hostname to key on: there
        // is nothing we can do with them until there is an engine.
        if (filter.hostname.len == 0) return null;
        return self.suppressed;
    }

    if (!isWholeHostname(filter)) return null;
    return if (filter.important) self.blocked_important else self.blocked;
}

/// Whether the filter's whole effect is "every request to this hostname and
/// its subdomains", which is all a trie can express.
fn isWholeHostname(filter: *const NetworkFilter) bool {
    if (filter.kind != .hostname) return false;
    // `||host` without '^' also matches hostnames merely *starting* with
    // host ("example.com.evil.org"): broader than a suffix match.
    if (!filter.require_separator) return false;
    // `||host^|` pins the URL end to the separator: narrower.
    if (filter.left_anchor or filter.right_anchor) return false;
    if (filter.has_domains) return false;
    if (!filter.first_party or !filter.third_party) return false;
    return filter.types.bits() == NetworkFilter.ResourceTypes.all.bits();
}

const testing = @import("../../testing.zig");

test "adblock.AdBlocker: parse accumulates across lists" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var first: Io.Reader = .fixed(
        \\! Title: First List
        \\||ads.example.com^
        \\@@||cdn.example.com^$script
        \\example.com##.ad-banner
    );
    try blocker.parse(&first);

    try testing.expectEqual(.blocked, blocker.matchHostname("ads.example.com"));
    try testing.expectEqual(.blocked, blocker.matchHostname("sub.ads.example.com"));
    // The type-restricted exception cannot be evaluated, so it suppresses
    // its hostname instead of allowing it.
    try testing.expectEqual(.none, blocker.matchHostname("cdn.example.com"));

    // The block and the exception loaded; the cosmetic line is a rule the
    // list carries and we do not apply, so it counts as skipped even though
    // it never reached a trie.
    try testing.expectEqual(2, blocker.rules_loaded);
    try testing.expectEqual(1, blocker.rules_skipped);

    var second: Io.Reader = .fixed(
        \\||tracker.net^$third-party,domain=news.com|~sports.news.com
    );
    try blocker.parse(&second);

    try testing.expectEqual(.none, blocker.matchHostname("tracker.net"));
    // The counts carry across lists, like the entries do.
    try testing.expectEqual(2, blocker.rules_loaded);
    try testing.expectEqual(2, blocker.rules_skipped);
    // The first list's entries survived the second parse.
    try testing.expectEqual(.blocked, blocker.matchHostname("ads.example.com"));
}

test "adblock.AdBlocker: rules that might unblock suppress their hostname" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    var list: Io.Reader = .fixed(
        // The easylist pair: without the exception we would break reuters.com.
        \\||adsafeprotected.com^
        \\@@||adsafeprotected.com/iasPET.$script,domain=independent.co.uk|reuters.com
        // uBO's unbreak.txt shape: a $badfilter cancelling a block we kept.
        \\||unbreak.example.com^
        \\||unbreak.example.com^$badfilter
        // Suppression outranks $important: we cannot tell which of our
        // entries the exception cancels.
        \\||strict.example.com^$important
        \\@@||strict.example.com^$xhr
    );
    try blocker.parse(&list);

    try testing.expectEqual(.none, blocker.matchHostname("adsafeprotected.com"));
    try testing.expectEqual(.none, blocker.matchHostname("sub.adsafeprotected.com"));
    try testing.expectEqual(.none, blocker.matchHostname("unbreak.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("strict.example.com"));
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
    try blocker.parse(&list);

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
    try blocker.parse(&list);

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
        \\@@||cosmetic.example.com^$generichide
    );
    try blocker.parse(&list);

    try testing.expectEqual(.none, blocker.matchHostname("no-caret.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("typed.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("party.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("sited.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("bad.example.com"));
    try testing.expectEqual(.none, blocker.matchHostname("cosmetic.example.com"));
}

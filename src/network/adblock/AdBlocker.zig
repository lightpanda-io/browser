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
const HttpClient = @import("../HttpClient.zig");

const Parser = @import("Parser.zig");
const Engine = @import("Engine.zig");
const HostnameTrie = @import("HostnameTrie.zig");
const NetworkFilter = @import("NetworkFilter.zig");

const log = lp.log;

const AdBlocker = @This();

const Request = Engine.Request;
const ResourceTypes = NetworkFilter.ResourceTypes;

allocator: Allocator,
/// Owns everything the filters point at.
arena: std.heap.ArenaAllocator,

/// Filters kept for per-request matching. Filled by `parse`, pruned and
/// partitioned by `build`; the `Engine`s index into it, so it must not move
/// after that.
filters: std.ArrayList(NetworkFilter),
/// Filled while parsing, consumed by `build`.
badfilters: std.AutoHashMapUnmanaged(u64, void),
built: bool,
trie: HostnameTrie,
blocked: u32,
/// `$important` hostname blocks: they beat exceptions.
blocked_important: u32,
/// Pure-hostname `@@` exceptions.
allowed: u32,
/// Hostnames named by an `@@` rule we could not read at all.
suppressed: u32,

blocking: Engine,
blocking_important: Engine,
exceptions: Engine,

/// Rules that reached a trie or an index, across every list parsed so far.
rules_loaded: usize,
/// Rules the lists carry and we do not apply, across those same lists: the
/// ones the parser could not read, plus the ones no matcher can express.
rules_skipped: usize,
/// Domain-scoped element-hiding rules and cosmetic-realm exceptions, across
/// those same lists. Not ours to apply, but not rules we failed at either, so
/// they stay out of `rules_skipped`. Generic "##" rules read as comments and
/// are counted nowhere.
rules_cosmetic: usize,

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
        .arena = std.heap.ArenaAllocator.init(allocator),
        .filters = .empty,
        .badfilters = .empty,
        .built = false,
        .trie = trie,
        .blocked = blocked,
        .blocked_important = blocked_important,
        .allowed = allowed,
        .suppressed = suppressed,
        .blocking = .empty,
        .blocking_important = .empty,
        .exceptions = .empty,
        .rules_loaded = 0,
        .rules_skipped = 0,
        .rules_cosmetic = 0,
    };
}

pub fn deinit(self: *AdBlocker) void {
    self.blocking.deinit(self.allocator);
    self.blocking_important.deinit(self.allocator);
    self.exceptions.deinit(self.allocator);
    self.badfilters.deinit(self.allocator);
    self.filters.deinit(self.allocator);
    self.trie.deinit(self.allocator);
    self.arena.deinit();
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
        try blocker.build();
        lp.metrics.adblock_rules.add(.loaded, @intCast(blocker.rules_loaded));
        lp.metrics.adblock_rules.add(.skipped, @intCast(blocker.rules_skipped));
        lp.metrics.adblock_rules.add(.cosmetic, @intCast(blocker.rules_cosmetic));
        log.info(.app, "adblock lists loaded", .{
            .loaded = blocker.rules_loaded,
            .skipped = blocker.rules_skipped,
            .cosmetic = blocker.rules_cosmetic,
            .indexed = blocker.filters.items.len,
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

pub fn parse(self: *AdBlocker, reader: *Io.Reader) !void {
    std.debug.assert(!self.built);

    var scratch_instance = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch_instance.deinit();
    const scratch = scratch_instance.allocator();

    var parser: Parser = .init(reader);
    // Lines the parser dropped are rules we did not load just as much as the
    // ones we drop below, and on a real list they are the bulk of them.
    defer {
        self.rules_skipped += parser.skipped;
        self.rules_cosmetic += parser.cosmetic;
    }

    const arena = self.arena.allocator();
    while (try parser.next(scratch)) |item| {
        // Everything here borrows the reader's buffer and the scratch arena,
        // both of which the next call reuses, so what we keep is copied out.
        defer _ = scratch_instance.reset(.retain_capacity);

        const filter = switch (item) {
            // The parser already counted it; all we want is whether it was an
            // exception, in which case its hostname stops being blockable.
            .dropped => |dropped| {
                if (!mayUnblock(dropped.reason)) continue;
                var buf: [253]u8 = undefined;
                if (exceptionHostname(dropped.line, &buf)) |hostname| {
                    try self.addToTrie(self.suppressed, hostname);
                }
                continue;
            },
            .filter => |filter| filter,
        };

        // Cosmetic-realm exceptions ($generichide and friends) modify element
        // hiding, which no network matcher applies: another realm's rule, not
        // one we failed at.
        if (filter.generichide or filter.specifichide or filter.elemhide) {
            self.rules_cosmetic += 1;
            continue;
        }
        if (!isSupported(&filter)) {
            self.rules_skipped += 1;
            continue;
        }

        if (filter.badfilter) {
            // It cancels a rule that may not have been read yet, so it can
            // only be resolved once every list is in. It is not a rule we
            // apply either way.
            self.rules_skipped += 1;
            try self.badfilters.put(self.allocator, identity(&filter), {});
            continue;
        }

        try self.filters.append(self.allocator, try dupe(arena, &filter));
        self.rules_loaded += 1;
    }
}

fn mayUnblock(reason: ?NetworkFilter.ParseError) bool {
    const err = reason orelse return false;
    return switch (err) {
        error.UnsupportedOption, error.UnsupportedPattern, error.NoSupportedDomains => true,
        else => false,
    };
}

/// The hostname an unreadable `@@||host…` rule is about, lowercased into
/// `buf`. Null for anything else.
fn exceptionHostname(line: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "@@||")) return null;
    const rest = line[4..];

    const end = std.mem.indexOfAny(u8, rest, "/^$*|") orelse rest.len;
    if (end == 0 or end > buf.len) return null;

    const hostname = std.ascii.lowerString(buf[0..end], rest[0..end]);
    // A hostname is what the trie can store; "example.*" and friends are not.
    for (hostname) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '.', '-', '_' => true,
            else => false,
        };
        if (!ok) return null;
    }
    if (std.mem.indexOfScalar(u8, hostname, '.') == null) return null;
    return hostname;
}

/// Resolves `$badfilter`, then splits what is left between the tries and the
/// indexes. Must run once, after every list is parsed, and before any match.
pub fn build(self: *AdBlocker) !void {
    std.debug.assert(!self.built);
    self.built = true;

    const arena = self.arena.allocator();

    // Whole-hostname filters go to a trie; the rest keep their slot in
    // `filters` so the engines can index them.
    var blocking: std.ArrayList(u32) = .empty;
    defer blocking.deinit(self.allocator);
    var important: std.ArrayList(u32) = .empty;
    defer important.deinit(self.allocator);
    var exceptions: std.ArrayList(u32) = .empty;
    defer exceptions.deinit(self.allocator);

    var kept: usize = 0;
    for (self.filters.items) |filter| {
        if (self.badfilters.count() != 0 and self.badfilters.contains(identity(&filter))) {
            self.rules_loaded -= 1;
            self.rules_skipped += 1;
            continue;
        }

        if (isWholeHostname(&filter)) {
            const root = if (filter.exception)
                self.allowed
            else if (filter.important)
                self.blocked_important
            else
                self.blocked;
            try self.addToTrie(root, filter.hostname);
            continue;
        }

        const index: u32 = @intCast(kept);
        self.filters.items[kept] = filter;
        kept += 1;

        const list = if (filter.exception)
            &exceptions
        else if (filter.important)
            &important
        else
            &blocking;
        try list.append(self.allocator, index);
    }
    self.filters.shrinkAndFree(self.allocator, kept);

    // Rarest-token selection is only meaningful across the whole corpus, so
    // the counts are taken once and shared by the three engines.
    var histogram: Engine.Histogram = .empty;
    defer histogram.deinit(self.allocator);
    for (self.filters.items) |*filter| {
        try Engine.count(&histogram, self.allocator, filter);
    }

    const filters = self.filters.items;
    self.blocking = try .build(self.allocator, arena, filters, blocking.items, &histogram);
    self.blocking_important = try .build(self.allocator, arena, filters, important.items, &histogram);
    self.exceptions = try .build(self.allocator, arena, filters, exceptions.items, &histogram);
}

fn addToTrie(self: *AdBlocker, root: u32, hostname: []const u8) !void {
    // Duplicate and subdomain-of-existing entries drop.
    self.trie.add(self.allocator, root, hostname) catch |err| switch (err) {
        error.OutOfMemory, error.TrieFull => |e| return e,
        // Callers never route a filter without a hostname here.
        error.InvalidHostname => unreachable,
    };
}

pub const Verdict = enum { none, allowed, blocked };

pub fn isBlocked(self: *const AdBlocker, transfer: *const HttpClient.Transfer) bool {
    var buffers: Request.Buffers = undefined;
    const request = Request.fromHttp(transfer, &buffers) orelse return false;
    const verdict = self.match(&request);
    lp.metrics.adblock_verdicts.incr(verdict);
    return verdict == .blocked;
}

/// The verdict for one request.
/// `$important` blocks outrank exceptions, which outrank plain blocks; same as uBO.
pub fn match(self: *const AdBlocker, request: *const Request) Verdict {
    std.debug.assert(self.built);

    const hostname = request.url.hostname();
    // A hostname something might unblock stays undecided, whatever else
    // matches it.
    if (self.trie.matches(self.suppressed, hostname) != null) return .none;

    if (self.trie.matches(self.blocked_important, hostname) != null) return .blocked;
    if (self.blocking_important.match(request) != null) return .blocked;

    if (self.exceptions.match(request) != null) return .allowed;
    if (self.trie.matches(self.allowed, hostname) != null) return .allowed;

    if (self.trie.matches(self.blocked, hostname) != null) return .blocked;
    if (self.blocking.match(request) != null) return .blocked;

    return .none;
}

/// Whether we can evaluate this filter at all.
fn isSupported(filter: *const NetworkFilter) bool {
    // No regex engine to run them with.
    return filter.kind != .regex;
}

/// Whether the filter's whole effect is "every request to this hostname and
/// its subdomains", which is all a trie can express.
fn isWholeHostname(filter: *const NetworkFilter) bool {
    if (filter.kind != .hostname) return false;
    // A prefix like `||adform.` also matches hostnames merely *starting*
    // with it, broader than a suffix match.
    if (!filter.require_separator) return false;
    // `||host^|` pins the URL end to the separator: narrower.
    if (filter.left_anchor or filter.right_anchor) return false;
    if (!filter.domains.isEmpty()) return false;
    if (!filter.first_party or !filter.third_party) return false;
    return filter.types.bits() == ResourceTypes.all.bits();
}

/// Copies a filter out of the parser's scratch memory into the arena.
fn dupe(arena: Allocator, filter: *const NetworkFilter) !NetworkFilter {
    var out = filter.*;
    out.hostname = try arena.dupe(u8, filter.hostname);
    out.pattern = try arena.dupe(u8, filter.pattern);
    out.domains = .{
        .included = try dupeEntries(arena, filter.domains.included),
        .excluded = try dupeEntries(arena, filter.domains.excluded),
    };
    return out;
}

fn dupeEntries(arena: Allocator, entries: []const domain.Entry) ![]const domain.Entry {
    if (entries.len == 0) return &.{};
    const out = try arena.alloc(domain.Entry, entries.len);
    for (entries, out) |entry, *slot| {
        slot.* = .{ .name = try arena.dupe(u8, entry.name), .entity = entry.entity };
    }
    return out;
}

/// What `$badfilter` compares two rules by: everything the rule says except
/// the `$badfilter` option itself.
fn identity(filter: *const NetworkFilter) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(filter.hostname);
    hasher.update(filter.pattern);
    // Entries are separated (names never contain NUL) and carry their entity
    // flag: "$domain=amazon.*" and "$domain=amazon" are different rules, as
    // are entry lists that merely concatenate alike.
    for (filter.domains.included) |entry| {
        hasher.update(entry.name);
        hasher.update(&.{ 0, @intFromBool(entry.entity) });
    }
    hasher.update("|");
    for (filter.domains.excluded) |entry| {
        hasher.update(entry.name);
        hasher.update(&.{ 0, @intFromBool(entry.entity) });
    }
    hasher.update(&std.mem.toBytes(filter.types.bits()));
    hasher.update(&.{
        @intFromEnum(filter.kind),
        @intFromBool(filter.exception),
        @intFromBool(filter.important),
        @intFromBool(filter.first_party),
        @intFromBool(filter.third_party),
        @intFromBool(filter.hostname_anchor),
        @intFromBool(filter.left_anchor),
        @intFromBool(filter.right_anchor),
        @intFromBool(filter.require_separator),
    });
    return hasher.final();
}

const domain = @import("domain.zig");
const testing = @import("../../testing.zig");

fn testLoad(blocker: *AdBlocker, list: []const u8) !void {
    var reader: Io.Reader = .fixed(list);
    try blocker.parse(&reader);
    try blocker.build();
}

fn expectVerdict(
    blocker: *const AdBlocker,
    expected: Verdict,
    url: []const u8,
    source: []const u8,
    kind: ResourceTypes,
) !void {
    // `match` takes a lowercased URL, as the real caller hands it; patterns
    // are lowercased too, so a rule spelled "/embed/C-iDzdvIg1Y" still lands.
    var buf: [512]u8 = undefined;
    const lowered = std.ascii.lowerString(buf[0..url.len], url);
    const request: Request = .init(lowered, source, kind);
    try testing.expectEqual(expected, blocker.match(&request));
}

const script: ResourceTypes = .{ .script = true };
const xhr: ResourceTypes = .{ .xmlhttprequest = true };
const image: ResourceTypes = .{ .image = true };
const document: ResourceTypes = .{ .document = true };
const frame: ResourceTypes = .{ .subdocument = true };

test "adblock.AdBlocker: the doubleclick rules from EasyList" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||ad.doubleclick.net^
        \\||g.doubleclick.net^
        \\||doubleclick.net^$popup
        \\||ad.doubleclick.net/ddm/clk/$domain=ad.doubleclick.net
        \\@@||doubleclick.net/ddm/$image,domain=aetv.com|fyi.tv|history.com
        \\@@||g.doubleclick.net/gampad/ads$xmlhttprequest,domain=bloomberg.com|samsclub.com
        \\@@||pubads.g.doubleclick.net/ssai/
        \\@@||static.doubleclick.net/instream/ad_status.js$script,domain=ignboards.com
    );

    // The exceptions no longer cost the blocks their hostnames: this is the
    // regression the whole engine exists for.
    try expectVerdict(&blocker, .blocked, "https://ad.doubleclick.net/x.gif", "news.com", image);
    try expectVerdict(&blocker, .blocked, "https://g.doubleclick.net/gampad/ads?a=1", "news.com", xhr);

    // ...and each exception applies exactly where it was written to.
    try expectVerdict(&blocker, .allowed, "https://g.doubleclick.net/gampad/ads?a=1", "bloomberg.com", xhr);
    // Same site, wrong type.
    try expectVerdict(&blocker, .blocked, "https://g.doubleclick.net/gampad/ads?a=1", "bloomberg.com", script);
    // Right type, wrong site.
    try expectVerdict(&blocker, .blocked, "https://g.doubleclick.net/gampad/ads?a=1", "example.com", xhr);
    // Right everything, wrong path.
    try expectVerdict(&blocker, .blocked, "https://g.doubleclick.net/pagead/ads", "bloomberg.com", xhr);

    try expectVerdict(&blocker, .allowed, "https://static.doubleclick.net/instream/ad_status.js", "ignboards.com", script);
    // The unconditional exception carves one path out of the block covering
    // the whole subtree, and leaves the rest of it blocked.
    try expectVerdict(&blocker, .allowed, "https://pubads.g.doubleclick.net/ssai/x", "history.com", xhr);
    try expectVerdict(&blocker, .blocked, "https://pubads.g.doubleclick.net/other", "history.com", xhr);

    // We issue no popup requests, so $popup filters never fire — but they no
    // longer take the rest of doubleclick.net down with them either.
    try expectVerdict(&blocker, .none, "https://doubleclick.net/x", "news.com", xhr);
}

test "adblock.AdBlocker: the youtube rules from EasyList" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||youtube.com/pagead/
        \\||youtube.com/youtubei/v1/player/ad_break
        \\||youtube.com/embed/C-iDzdvIg1Y$domain=biznews.com
        \\||googlesyndication.com^$domain=blogto.com|youtube.com
        \\||youtube.com/get_video_info?*adunit$~third-party
        \\@@||youtube.com/get_video_info?$xmlhttprequest,domain=music.youtube.com|tv.youtube.com
    );

    try expectVerdict(&blocker, .blocked, "https://www.youtube.com/pagead/lvz?ei=x", "youtube.com", xhr);
    try expectVerdict(&blocker, .blocked, "https://www.youtube.com/youtubei/v1/player/ad_break?x=1", "youtube.com", xhr);
    try expectVerdict(&blocker, .none, "https://www.youtube.com/watch?v=x", "youtube.com", document);

    // $domain= scopes an embed block to the one site that needed it. The
    // embed is an iframe, and a filter with no type option covers every type
    // but a top-level document — which is why this is `frame`, not
    // `document`.
    try expectVerdict(&blocker, .blocked, "https://www.youtube.com/embed/C-iDzdvIg1Y", "biznews.com", frame);
    try expectVerdict(&blocker, .none, "https://www.youtube.com/embed/C-iDzdvIg1Y", "example.com", frame);
    try expectVerdict(&blocker, .none, "https://www.youtube.com/embed/C-iDzdvIg1Y", "biznews.com", document);

    // A `$domain=` list matches subdomains of its entries.
    try expectVerdict(&blocker, .blocked, "https://pagead2.googlesyndication.com/x", "www.blogto.com", script);
    try expectVerdict(&blocker, .none, "https://pagead2.googlesyndication.com/x", "example.com", script);

    // $~third-party: same site only.
    try expectVerdict(&blocker, .blocked, "https://www.youtube.com/get_video_info?a=adunit", "youtube.com", xhr);
    try expectVerdict(&blocker, .none, "https://www.youtube.com/get_video_info?a=adunit", "example.com", xhr);
    // The exception outranks it where it applies.
    try expectVerdict(&blocker, .allowed, "https://www.youtube.com/get_video_info?a=adunit", "music.youtube.com", xhr);
}

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

    var second: Io.Reader = .fixed(
        \\||tracker.net^$third-party,domain=news.com|~sports.news.com
    );
    try blocker.parse(&second);
    try blocker.build();

    try expectVerdict(&blocker, .blocked, "https://ads.example.com/x", "news.com", script);
    try expectVerdict(&blocker, .blocked, "https://sub.ads.example.com/x", "news.com", script);
    // The type-restricted exception now applies to scripts only.
    try expectVerdict(&blocker, .allowed, "https://cdn.example.com/x.js", "news.com", script);
    try expectVerdict(&blocker, .none, "https://cdn.example.com/x.png", "news.com", image);

    // The party and $domain= constrained block, from the second list.
    try expectVerdict(&blocker, .blocked, "https://tracker.net/x", "news.com", script);
    try expectVerdict(&blocker, .none, "https://tracker.net/x", "sports.news.com", script);
    try expectVerdict(&blocker, .none, "https://tracker.net/x", "other.com", script);

    // Three rules loaded across the two lists; the cosmetic line is a rule of
    // another realm, counted as such rather than as one we failed to apply.
    try testing.expectEqual(3, blocker.rules_loaded);
    try testing.expectEqual(0, blocker.rules_skipped);
    try testing.expectEqual(1, blocker.rules_cosmetic);
}

test "adblock.AdBlocker: cosmetic-realm rules are not skipped rules" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||ads.example.com^
        \\@@||example.com^$generichide
        \\@@||example.com^$elemhide
        \\example.com##.ad-banner
        \\/regex-we-cannot-run/
    );

    try testing.expectEqual(1, blocker.rules_loaded);
    try testing.expectEqual(1, blocker.rules_skipped);
    try testing.expectEqual(3, blocker.rules_cosmetic);
}

test "adblock.AdBlocker: verdict precedence" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||ads.example.com^
        \\@@||good.ads.example.com^
        \\||evil.com^$important
        \\@@||evil.com^
        \\||strict.example.com^$important,script
        \\@@||strict.example.com^$script
    );

    try expectVerdict(&blocker, .blocked, "https://ads.example.com/x", "a.com", script);
    // The exception wins over the plain block...
    try expectVerdict(&blocker, .allowed, "https://good.ads.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .allowed, "https://x.good.ads.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://other.ads.example.com/x", "a.com", script);
    // ...but $important beats the exception, whichever side is indexed.
    try expectVerdict(&blocker, .blocked, "https://evil.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://strict.example.com/x.js", "a.com", script);

    try expectVerdict(&blocker, .none, "https://example.com/x", "a.com", script);
}

test "adblock.AdBlocker: $badfilter removes its target" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        // The uBO unbreak.txt shape: a $badfilter cancelling a block, whether
        // that block lives in a trie...
        \\||unbreak.example.com^
        \\||unbreak.example.com^$badfilter
        // ...or in an index.
        \\||other.example.com^$script
        \\||other.example.com^$script,badfilter
        // A $badfilter only cancels the rule it names exactly.
        \\||kept.example.com^$script
        \\||kept.example.com^$image,badfilter
        // "amazon.*" and "amazon" are different rules, not the same one.
        \\||entity.example.com^$script,domain=amazon.*
        \\||entity.example.com^$script,domain=amazon,badfilter
    );

    try expectVerdict(&blocker, .none, "https://unbreak.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .none, "https://other.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://kept.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://entity.example.com/x", "www.amazon.com", script);
}

test "adblock.AdBlocker: exceptions we cannot read suppress their hostname" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||unreadable.example.com^
        \\@@||unreadable.example.com/api/$denyallow=cdn.com
        // A rewriting option excepts the rewriting, never the block...
        \\||modified.example.com^
        \\@@||modified.example.com/x.js$redirect-rule=noopjs,script
        // ...and neither does a rule uBO rejects as well.
        \\||malformed.example.com^
        \\@@||malformed.example.com^$notarealoption
        \\||plain.example.com^
    );

    // $denyallow narrows a block in ways we cannot evaluate, so we cannot
    // tell what the exception excepts — the hostname stops being blockable
    // rather than break the page the rule was written for.
    try expectVerdict(&blocker, .none, "https://unreadable.example.com/x", "a.com", script);

    try expectVerdict(&blocker, .blocked, "https://modified.example.com/x.js", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://malformed.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://plain.example.com/x", "a.com", script);
}

test "adblock.AdBlocker: trie absorbs every pure-hostname form" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    try testLoad(&blocker,
        \\||anchored.example.com^
        \\||caretless.example.com
        \\||pinned.example.com|
        \\bare-hostname.example.com
        \\0.0.0.0 hosts-style.example.io
    );

    try expectVerdict(&blocker, .blocked, "https://anchored.example.com/x", "a.com", script);
    // `||host` and `||host|` are the same filter as `||host^`.
    try expectVerdict(&blocker, .blocked, "https://sub.caretless.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .none, "https://caretless.example.com.evil.org/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://pinned.example.com/x?q=1", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://bare-hostname.example.com/x", "a.com", script);
    try expectVerdict(&blocker, .blocked, "https://hosts-style.example.io/x", "a.com", script);
    // Pure-hostname filters block top-level documents too.
    try expectVerdict(&blocker, .blocked, "https://anchored.example.com/", "a.com", document);

    // Absorbs: every rule above went to a trie, none stayed indexed.
    try testing.expectEqual(0, blocker.filters.items.len);
}

test "adblock.AdBlocker: $important on an exception is invalid" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();

    // uBO rejects `@@…$important`, so nothing outranks a `$important`
    // block — and being a rule uBO drops too, the invalid exception does
    // not suppress its hostname either.
    try testLoad(&blocker,
        \\||tracker.com^$important,script
        \\@@||tracker.com/x.js$important,script
    );

    try expectVerdict(&blocker, .blocked, "https://tracker.com/x.js", "a.com", script);
    try testing.expectEqual(1, blocker.rules_loaded);
    try testing.expectEqual(1, blocker.rules_skipped);
}

test "adblock.AdBlocker: an empty blocker decides nothing" {
    var blocker: AdBlocker = try .init(testing.allocator);
    defer blocker.deinit();
    try blocker.build();

    try expectVerdict(&blocker, .none, "https://example.com/x", "example.com", script);
}

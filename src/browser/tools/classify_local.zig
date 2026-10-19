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

//! Scores the classify presets locally, with a linear model distilled from
//! Jev's answers, so most pages can be judged without the cloud.
//!
//! The model comes from research/page_classifier/export.py in the
//! lightpanda-python repository, and the features here follow that
//! directory's features.py byte for byte: what a page's text is, how it is
//! cut into word and character n-grams and hashed, and how the structure
//! features are computed. A change to one side needs the same change on
//! the other, and the parity test below checks the two agree.

const std = @import("std");
const Regex = @import("../../Regex.zig");

const Allocator = std.mem.Allocator;

/// The most of the semantic tree and of the HTML the model reads, in bytes.
/// jev.zig cuts a page's to these.
pub const max_tree_bytes = 8192;
pub const max_html_bytes = 262144;

/// What the model reads of a page: what classify sends Jev, plus the HTML.
pub const Page = struct {
    url: []const u8,
    title: []const u8,
    /// 0 when the page has no HTTP status.
    status: u16,
    /// The semantic tree as classify sends it, at most `max_tree_bytes`.
    tree: []const u8,
    /// The document's HTML, at most `max_html_bytes`.
    html: []const u8,
};

pub const Preset = struct {
    name: []const u8,
    /// The score from which the preset fires.
    threshold: f32,
    kind: Kind,
    /// The intercept of a linear preset, or a constant one's score.
    value: f32,

    pub const Kind = enum(u8) { linear = 0, constant = 1 };
};

const Subject = enum { html, visible, title, path, url };

const Matcher = struct {
    subject: Subject,
    regex: Regex,
};

/// Structure features measured straight off the page, rather than found by
/// a pattern.
const Measure = enum {
    status_2xx,
    status_3xx,
    status_4xx,
    status_403,
    status_404,
    status_429,
    status_5xx,
    status_none,
    tree_lines,
    tree_bytes,
    tree_tiny,
    html_bytes,
    links,
    textboxes,
    buttons,

    /// The measure's value on `page`, as features.structure computes it.
    fn of(self: Measure, page: Page) f64 {
        const status = page.status;
        const lines: usize = if (page.tree.len == 0) 0 else std.mem.countScalar(u8, page.tree, '\n') + 1;
        return switch (self) {
            .status_2xx => flag(status >= 200 and status < 300),
            .status_3xx => flag(status >= 300 and status < 400),
            .status_4xx => flag(status >= 400 and status < 500),
            .status_403 => flag(status == 403),
            .status_404 => flag(status == 404 or status == 410),
            .status_429 => flag(status == 429),
            .status_5xx => flag(status >= 500),
            .status_none => flag(status == 0),
            .tree_lines => capped(lines, 2000),
            .tree_bytes => capped(page.tree.len, max_tree_bytes),
            .tree_tiny => flag(lines < 15),
            .html_bytes => capped(page.html.len, max_html_bytes),
            .links => capped(linesWith(page.tree, "link"), 300),
            .textboxes => capped(linesWith(page.tree, "textbox"), 20),
            .buttons => capped(linesWith(page.tree, "button"), 50),
        };
    }
};

const Feature = union(enum) {
    measure: Measure,
    /// How often this tag opens in the HTML.
    tag: []const u8,
    matcher: Matcher,
    /// Set when the HTML holds any of a literal feature's strings: an index
    /// into what `Literals.find` found.
    literals: u32,

    /// The feature's value on `page`. `visible` is the title, a newline and
    /// the tree; `lowered_html` the HTML with its ASCII letters lowercased;
    /// `found` which literal features it holds.
    fn of(self: Feature, page: Page, visible: []const u8, lowered_html: []const u8, found: []const bool) f64 {
        return switch (self) {
            .measure => |m| m.of(page),
            .tag => |tag| capped(countTag(lowered_html, tag), 200),
            .matcher => |m| flag(m.regex.matches(switch (m.subject) {
                .html => page.html,
                .visible => visible,
                .title => page.title,
                .path => splitUrl(page.url).path,
                .url => page.url,
            })),
            .literals => |i| flag(found[i]),
        };
    }
};

/// The literal features: plain lowercase ASCII strings, any of which in the
/// ASCII-lowercased HTML sets one. They are the vendor fingerprints, which
/// as regexes cost more than everything else together, and even searched
/// one by one took half the scoring time; this finds them all in one pass,
/// checking only where four bytes may start some string (every string has at
/// least four: two-byte starts are too common in HTML to filter anything).
const Literals = struct {
    /// Every string with the feature it sets, ordered by its first four bytes.
    strings: []const Entry,
    /// Bit `hash(k)` set when some string starts with the four bytes `k`.
    starts: std.bit_set.Dynamic,
    features: usize,

    const Entry = struct { start: u32, string: []const u8, feature: u32 };

    fn startOf(bytes: []const u8) u32 {
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn hash(start: u32) u16 {
        return @truncate((start *% 2654435761) >> 16);
    }

    fn orderStart(start: u32, entry: Entry) std.math.Order {
        return std.math.order(start, entry.start);
    }

    /// Which features the ASCII-lowercased HTML sets, into `found`.
    fn find(self: Literals, lowered_html: []const u8, found: []bool) void {
        @memset(found, false);
        var left = self.features;
        if (left == 0 or lowered_html.len < 4) return;
        for (0..lowered_html.len - 3) |at| {
            const start = startOf(lowered_html[at..]);
            if (!self.starts.isSet(hash(start))) continue;
            const from, const to = std.sort.equalRange(Entry, self.strings, start, orderStart);
            for (self.strings[from..to]) |entry| {
                if (found[entry.feature] or !std.mem.startsWith(u8, lowered_html[at..], entry.string)) continue;
                found[entry.feature] = true;
                left -= 1;
                if (left == 0) return;
            }
        }
    }
};

/// One family of hashed n-grams: the buckets the model kept, increasing,
/// their idf, and each bucket's row of weights, one per preset.
const Family = struct {
    buckets: []const u32,
    idf: []const f32,
    weights: []const f32 = &.{},

    /// Adds the family's TF-IDF row for these counts, scaled to unit
    /// length, times each preset's weights.
    fn add(self: Family, counts: *const Counter.Map, sums: []f64, out: []f64) void {
        @memset(sums, 0);
        var norm: f64 = 0;
        var it = counts.iterator();
        while (it.next()) |entry| {
            const column = std.sort.binarySearch(u32, self.buckets, entry.key_ptr.*, orderU32) orelse continue;
            const tf: f64 = @floatFromInt(entry.value_ptr.*);
            const value = (1 + @log(tf)) * self.idf[column];
            norm += value * value;
            const row = self.weights[column * out.len ..][0..out.len];
            for (sums, row) |*sum, w| sum.* += value * w;
        }
        if (norm == 0) return;
        const length = @sqrt(norm);
        for (out, sums) |*z, sum| z.* += sum / length;
    }
};

/// Counts a text's hashed n-grams, as features.ngrams does.
const Counter = struct {
    allocator: Allocator,
    mask: u32,
    char_sizes: []const u32,
    counts: Map = .empty,
    scratch: std.ArrayList(u8) = .empty,

    const Map = std.AutoHashMapUnmanaged(u32, u32);

    fn deinit(self: *Counter) void {
        self.counts.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    fn add(self: *Counter, ngram: []const u8) Allocator.Error!void {
        const bucket = std.hash.Murmur3_32.hashWithSeed(ngram, 0) & self.mask;
        (try self.counts.getOrPutValue(self.allocator, bucket, 0)).value_ptr.* += 1;
    }

    /// features.words: every run of two or more word bytes, then every two
    /// adjacent runs joined by a space.
    fn words(self: *Counter, data: []const u8) Allocator.Error!void {
        self.counts.clearRetainingCapacity();
        var previous: ?[]const u8 = null;
        var it: WordIterator = .{ .data = data };
        while (it.next()) |word| {
            try self.add(word);
            if (previous) |p| {
                self.scratch.clearRetainingCapacity();
                try self.scratch.print(self.allocator, "{s} {s}", .{ p, word });
                try self.add(self.scratch.items);
            }
            previous = word;
        }
    }

    /// features.chars: sklearn's char_wb over the pieces between ASCII
    /// whitespace.
    fn chars(self: *Counter, data: []const u8) Allocator.Error!void {
        self.counts.clearRetainingCapacity();
        var pieces = std.mem.tokenizeAny(u8, data, &std.ascii.whitespace);
        while (pieces.next()) |piece| {
            self.scratch.clearRetainingCapacity();
            try self.scratch.print(self.allocator, " {s} ", .{piece});
            const padded = self.scratch.items;
            for (self.char_sizes) |n| {
                if (padded.len <= n) {
                    try self.add(padded);
                    break;
                }
                for (0..padded.len - n + 1) |i| try self.add(padded[i..][0..n]);
            }
        }
    }
};

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    bucket_mask: u32,
    char_sizes: []const u32,
    presets: []const Preset,
    /// Kept to free their regexes; the features hold copies.
    matchers: []const Matcher,
    literals: Literals,
    words: Family,
    chars: Family,
    structure: []const Feature,
    /// Each structure feature's row of weights, one per preset.
    structure_weights: []const f32,

    pub const ParseError = error{ InvalidModel, InvalidRegex, OutOfMemory };

    /// Reads a model export.py wrote, compiling its patterns in `regexes`,
    /// which must outlive the model. The model keeps no reference to
    /// `bytes`.
    pub fn parse(allocator: Allocator, regexes: *const Regex.Context, bytes: []const u8) ParseError!*Model {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var r: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try r.take(4), "LPCM") or try r.int() != 3) return error.InvalidModel;
        const hash_bits = try r.int();
        if (hash_bits == 0 or hash_bits > 32) return error.InvalidModel;

        const char_sizes = try r.array(a, u32, try r.int());

        const presets = try a.alloc(Preset, try r.int());
        for (presets) |*preset| {
            preset.* = .{
                .name = try a.dupe(u8, try r.string()),
                .threshold = try r.float(),
                .kind = std.enums.fromInt(Preset.Kind, (try r.take(1))[0]) orelse return error.InvalidModel,
                .value = try r.float(),
            };
        }

        const matchers = try a.alloc(Matcher, try r.int());
        var compiled: usize = 0;
        errdefer for (matchers[0..compiled]) |m| m.regex.deinit();
        for (matchers) |*matcher| {
            const subject = std.meta.stringToEnum(Subject, try r.string()) orelse return error.InvalidModel;
            matcher.* = .{
                .subject = subject,
                .regex = try regexes.compile(try r.string(), .{ .case_insensitive = true, .unicode = true }, null),
            };
            compiled += 1;
        }

        const literal_features = try r.int();
        var strings: std.ArrayList(Literals.Entry) = .empty;
        var starts: std.bit_set.Dynamic = try .initEmpty(a, 1 << 16);
        for (0..literal_features) |feature| {
            for (0..try r.int()) |_| {
                const string = try a.dupe(u8, try r.string());
                if (string.len < 4) return error.InvalidModel;
                const start = Literals.startOf(string);
                starts.set(Literals.hash(start));
                try strings.append(a, .{ .start = start, .string = string, .feature = @intCast(feature) });
            }
        }
        std.mem.sort(Literals.Entry, strings.items, {}, struct {
            fn lessThan(_: void, x: Literals.Entry, y: Literals.Entry) bool {
                return x.start < y.start;
            }
        }.lessThan);

        const tags = try a.alloc([]const u8, try r.int());
        for (tags) |*tag| tag.* = try a.dupe(u8, try r.string());

        var words = try readFamily(&r, a);
        var chars = try readFamily(&r, a);

        // Each structure column says which feature it is: a measure by name,
        // the rest by their index in the sections above.
        const structure = try a.alloc(Feature, try r.int());
        for (structure) |*feature| {
            feature.* = switch ((try r.take(1))[0]) {
                0 => .{ .measure = std.meta.stringToEnum(Measure, try r.string()) orelse return error.InvalidModel },
                1 => .{ .matcher = try r.item(Matcher, matchers) },
                2 => literals: {
                    const index = try r.int();
                    if (index >= literal_features) return error.InvalidModel;
                    break :literals .{ .literals = index };
                },
                3 => .{ .tag = try r.item([]const u8, tags) },
                else => return error.InvalidModel,
            };
        }

        // The weights come last, a row per column: words, chars, structure.
        words.weights = try r.array(a, f32, words.buckets.len * presets.len);
        chars.weights = try r.array(a, f32, chars.buckets.len * presets.len);
        const structure_weights = try r.array(a, f32, structure.len * presets.len);
        if (r.pos != bytes.len) return error.InvalidModel;

        const self = try a.create(Model);
        self.* = .{
            .arena = arena,
            .bucket_mask = if (hash_bits == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(hash_bits)) - 1,
            .char_sizes = char_sizes,
            .presets = presets,
            .matchers = matchers,
            .literals = .{ .strings = strings.items, .starts = starts, .features = literal_features },
            .words = words,
            .chars = chars,
            .structure = structure,
            .structure_weights = structure_weights,
        };
        return self;
    }

    pub fn deinit(self: *Model) void {
        for (self.matchers) |m| m.regex.deinit();
        var arena = self.arena;
        arena.deinit();
    }

    /// Each preset's score, in `presets` order, into `out`.
    pub fn score(self: *const Model, allocator: Allocator, page: Page, out: []f64) Allocator.Error!void {
        std.debug.assert(out.len == self.presets.len);
        for (out, self.presets) |*z, preset| z.* = preset.value;

        const content = try text(allocator, page);
        defer allocator.free(content);
        _ = std.ascii.lowerString(content, content);

        const sums = try allocator.alloc(f64, out.len);
        defer allocator.free(sums);
        var counter: Counter = .{ .allocator = allocator, .mask = self.bucket_mask, .char_sizes = self.char_sizes };
        defer counter.deinit();
        try counter.counts.ensureTotalCapacity(allocator, @intCast(content.len));
        try counter.words(content);
        self.words.add(&counter.counts, sums, out);
        try counter.chars(content);
        self.chars.add(&counter.counts, sums, out);

        const visible = try std.mem.concat(allocator, u8, &.{ page.title, "\n", page.tree });
        defer allocator.free(visible);
        const lowered_html = try std.ascii.allocLowerString(allocator, page.html);
        defer allocator.free(lowered_html);
        const found = try allocator.alloc(bool, self.literals.features);
        defer allocator.free(found);
        self.literals.find(lowered_html, found);
        for (self.structure, 0..) |feature, i| {
            const value = feature.of(page, visible, lowered_html, found);
            if (value == 0) continue;
            const row = self.structure_weights[i * out.len ..][0..out.len];
            for (out, row) |*z, w| z.* += value * w;
        }

        for (out, self.presets) |*z, preset| {
            z.* = switch (preset.kind) {
                .linear => 1 / (1 + @exp(-z.*)),
                .constant => preset.value,
            };
        }
    }
};

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

fn flag(value: bool) f64 {
    return if (value) 1 else 0;
}

/// min(count, limit) / limit, as features.structure scales its counts.
fn capped(count: usize, limit: usize) f64 {
    const kept: f64 = @floatFromInt(@min(count, limit));
    const most: f64 = @floatFromInt(limit);
    return kept / most;
}

fn linesWith(tree: []const u8, needle: []const u8) usize {
    if (tree.len == 0) return 0;
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| found += @intFromBool(std.mem.find(u8, line, needle) != null);
    return found;
}

/// features.count_tag: how often `<tag` opens in the ASCII-lowercased HTML,
/// followed by a byte that cannot continue a tag name.
fn countTag(lowered_html: []const u8, tag: []const u8) usize {
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.findScalarPos(u8, lowered_html, at, '<')) |open| {
        at = open + 1;
        if (!std.mem.startsWith(u8, lowered_html[at..], tag)) continue;
        at += tag.len;
        found += @intFromBool(at == lowered_html.len or !(std.ascii.isAlphanumeric(lowered_html[at]) or lowered_html[at] == '_'));
    }
    return found;
}

const UrlParts = struct { host: []const u8, path: []const u8, query: []const u8 };

/// features.split_url: the host, path and query of an http(s) url.
fn splitUrl(url: []const u8) UrlParts {
    var rest = url;
    if (std.mem.find(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.findScalar(u8, rest, '#')) |i| rest = rest[0..i];
    var query: []const u8 = "";
    if (std.mem.findScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    return .{ .host = rest[0..slash], .path = rest[slash..], .query = query };
}

/// features.text: the page as Jev sees it, flattened for the n-grams.
fn text(allocator: Allocator, page: Page) Allocator.Error![]u8 {
    const url = splitUrl(page.url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "url {s} ", .{url.host});
    // The path, a space and the query, each run of these bytes made a space.
    var in_run = false;
    for ([_][]const u8{ url.path, " ", url.query }) |part| {
        for (part) |c| {
            if (std.mem.findScalar(u8, "/_.?=&-", c) != null) {
                if (!in_run) try out.append(allocator, ' ');
                in_run = true;
            } else {
                try out.append(allocator, c);
                in_run = false;
            }
        }
    }
    try out.print(allocator, "\nstatus {d}\ntitle {s}\n{s}", .{ page.status, page.title, page.tree });
    return out.toOwnedSlice(allocator);
}

/// Runs of two or more word bytes: ASCII letters, digits, `_` and any byte
/// from 0x80 up, so every UTF-8 sequence counts as part of a word.
const WordIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    fn next(self: *WordIterator) ?[]const u8 {
        while (self.pos < self.data.len) {
            while (self.pos < self.data.len and !isWord(self.data[self.pos])) self.pos += 1;
            const start = self.pos;
            while (self.pos < self.data.len and isWord(self.data[self.pos])) self.pos += 1;
            if (self.pos - start >= 2) return self.data[start..self.pos];
        }
        return null;
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Error = error{InvalidModel} || Allocator.Error;

    fn take(self: *Reader, n: usize) error{InvalidModel}![]const u8 {
        if (self.bytes.len - self.pos < n) return error.InvalidModel;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *Reader) error{InvalidModel}!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn float(self: *Reader) error{InvalidModel}!f32 {
        return @bitCast(try self.int());
    }

    fn string(self: *Reader) error{InvalidModel}![]const u8 {
        return self.take(try self.int());
    }

    /// The element of `items` at the index read next.
    fn item(self: *Reader, comptime T: type, items: []const T) error{InvalidModel}!T {
        const index = try self.int();
        if (index >= items.len) return error.InvalidModel;
        return items[index];
    }

    /// `n` little-endian `u32`s or `f32`s, copied out of one read.
    fn array(self: *Reader, a: Allocator, comptime T: type, n: usize) Error![]T {
        comptime std.debug.assert(T == u32 or T == f32);
        const raw = try self.take(std.math.mul(usize, n, 4) catch return error.InvalidModel);
        const out = try a.alloc(T, n);
        for (out, 0..) |*v, i| v.* = @bitCast(std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
        return out;
    }
};

/// A family's buckets and idf; its weights come later in the file.
fn readFamily(r: *Reader, a: Allocator) Reader.Error!Family {
    const n = try r.int();
    const buckets = try r.array(a, u32, n);
    for (1..n) |i| if (buckets[i - 1] >= buckets[i]) return error.InvalidModel;
    return .{ .buckets = buckets, .idf = try r.array(a, f32, n) };
}

const testing = @import("../../testing.zig");
const lp = @import("../../lightpanda.zig");

// The expected values below come from features.py on the same page.
const test_page: Page = .{
    .url = "https://Example.com/a_b/c-d.html?q=x&y=1#frag",
    .title = "Héllo Wörld",
    .status = 404,
    .tree = "RootWebArea 'Not Found'\n heading '404 – page'\n link 'Home'",
    .html = "<A href=x><form><formx><a>",
};

test "browser.classify_local: text and url split follow features.py" {
    const content = try text(testing.allocator, test_page);
    defer testing.allocator.free(content);
    try testing.expectEqual(
        \\url Example.com  a b c d html q x y 1
        \\status 404
        \\title Héllo Wörld
        \\RootWebArea 'Not Found'
        \\ heading '404 – page'
        \\ link 'Home'
    , content);

    const parts = splitUrl(test_page.url);
    try testing.expectEqual("Example.com", parts.host);
    try testing.expectEqual("/a_b/c-d.html", parts.path);
    try testing.expectEqual("q=x&y=1", parts.query);
    try testing.expectEqual("", splitUrl("http://a.com?x=/y").path);
    try testing.expectEqual("x=/y", splitUrl("http://a.com?x=/y").query);
}

test "browser.classify_local: n-grams and buckets follow features.py" {
    try testing.expectEqual(613153351, std.hash.Murmur3_32.hashWithSeed("hello", 0));

    const content = try text(testing.allocator, test_page);
    defer testing.allocator.free(content);
    _ = std.ascii.lowerString(content, content);

    var counter: Counter = .{ .allocator = testing.allocator, .mask = (1 << 20) - 1, .char_sizes = &.{ 3, 4, 5 } };
    defer counter.deinit();
    try counter.words(content);
    try testing.expectEqual(.{ 35, 19006148 }, tally(&counter.counts));
    try counter.chars(content);
    try testing.expectEqual(.{ 239, 131188250 }, tally(&counter.counts));
}

/// How many n-grams were counted, and the sum of their buckets.
fn tally(counts: *const Counter.Map) struct { u64, u64 } {
    var n: u64 = 0;
    var sum: u64 = 0;
    var it = counts.iterator();
    while (it.next()) |e| {
        n += e.value_ptr.*;
        sum += @as(u64, e.key_ptr.*) * e.value_ptr.*;
    }
    return .{ n, sum };
}

test "browser.classify_local: structure features follow features.py" {
    const lowered_html = "<a href=x><form><formx><a>";
    try testing.expectEqual(2, countTag(lowered_html, "a"));
    try testing.expectEqual(1, countTag(lowered_html, "form"));
    try testing.expectEqual(0, countTag(lowered_html, "img"));
    try testing.expectEqual(0.0015, Measure.tree_lines.of(test_page));
    try testing.expectEqual(0.00732421875, Measure.tree_bytes.of(test_page));
    try testing.expectEqual(1, Measure.tree_tiny.of(test_page));
    try testing.expectEqual(1, Measure.status_404.of(test_page));
    try testing.expectEqual(0, Measure.status_none.of(test_page));
    try testing.expectDelta(1.0 / 300.0, Measure.links.of(test_page), 1e-12);
}

test "browser.classify_local: parse rejects what is not a model" {
    const regexes = testing.test_app.regex_context;
    try testing.expectError(error.InvalidModel, Model.parse(testing.allocator, regexes, "LPCM"));
    try testing.expectError(error.InvalidModel, Model.parse(testing.allocator, regexes, "nope\x01\x00\x00\x00"));
}

// Scores the pages export.py wrote to parity.jsonl and checks they match
// the Python model's. Needs LP_CLASSIFY_MODEL (model.lpcm) and
// LP_CLASSIFY_PARITY (parity.jsonl); skipped without them.
test "browser.classify_local: parity with the Python model" {
    const env = lp.environ();
    const model_path = env.getPosix("LP_CLASSIFY_MODEL") orelse return error.SkipZigTest;
    const parity_path = env.getPosix("LP_CLASSIFY_PARITY") orelse return error.SkipZigTest;

    const allocator = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(testing.io, model_path, allocator, .unlimited);
    defer allocator.free(bytes);
    const clock = std.Io.Clock.awake;
    const parse_start = clock.now(testing.io);
    const model = try Model.parse(allocator, testing.test_app.regex_context, bytes);
    defer model.deinit();
    const parse_ns = parse_start.durationTo(clock.now(testing.io)).toNanoseconds();

    const lines = try cwd.readFileAlloc(testing.io, parity_path, allocator, .unlimited);
    defer allocator.free(lines);

    const Expected = struct {
        url: []const u8,
        title: ?[]const u8 = null,
        status: ?u16 = null,
        tree: ?[]const u8 = null,
        html: ?[]const u8 = null,
        scores: []const f64,
    };
    const scores = try allocator.alloc(f64, model.presets.len);
    defer allocator.free(scores);

    var pages: usize = 0;
    var worst: f64 = 0;
    var score_ns: i96 = 0;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(Expected, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const e = parsed.value;
        const start = clock.now(testing.io);
        try model.score(allocator, .{
            .url = e.url,
            .title = e.title orelse "",
            .status = e.status orelse 0,
            .tree = e.tree orelse "",
            .html = e.html orelse "",
        }, scores);
        score_ns += start.durationTo(clock.now(testing.io)).toNanoseconds();
        for (scores, e.scores, model.presets) |got, want, preset| {
            const gap = @abs(got - want);
            if (gap > 1e-4) {
                std.debug.print("{s}: {s} scored {d:.6}, Python {d:.6}\n", .{ e.url, preset.name, got, want });
            }
            worst = @max(worst, gap);
        }
        pages += 1;
    }
    std.debug.print("parity: {d} pages, largest gap {e}; model read in {d:.1}ms, {d:.3}ms a page\n", .{
        pages,
        worst,
        @as(f64, @floatFromInt(parse_ns)) / 1e6,
        @as(f64, @floatFromInt(score_ns)) / 1e6 / @as(f64, @floatFromInt(@max(pages, 1))),
    });
    try testing.expect(pages > 0);
    try testing.expect(worst <= 1e-4);
}

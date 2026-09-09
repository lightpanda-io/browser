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

//! One indexed set of network filters — the blocking ones, the `$important`
//! ones or the exceptions — and the lookup that finds which of them a request
//! matches. A port of adblock-rust's `NetworkFilterList`.
//!
//! Checking every filter against every request is not affordable: EasyList
//! alone carries tens of thousands. Instead each filter is filed under one
//! token of its pattern — a run of alphanumerics that any URL it matches is
//! bound to contain — and a request only ever pays for the filters filed
//! under the tokens its own URL happens to have.
//!
//! Which token decides how much that costs, so each filter takes its rarest
//! one across the whole loaded corpus: "gampad" narrows to a handful of
//! filters where "com" would narrow to nothing. Filters whose pattern offers
//! no token that is guaranteed to survive into the URL (see `collectTokens`)
//! go to `fallback`, which every request pays for.

const std = @import("std");

const URL = @import("../../browser/URL.zig");
const HttpClient = @import("../HttpClient.zig");

const domain = @import("domain.zig");
const pattern = @import("pattern.zig");
const NetworkFilter = @import("NetworkFilter.zig");

const Allocator = std.mem.Allocator;

const Engine = @This();

/// The shared filter array; `buckets` and `fallback` hold indices into it.
filters: []const NetworkFilter,
buckets: std.AutoHashMapUnmanaged(u32, []const u32),
/// Filters no token can stand for; checked on every request.
fallback: []const u32,

pub const empty: Engine = .{
    .filters = &.{},
    .buckets = .empty,
    .fallback = &.{},
};

pub fn deinit(self: *Engine, allocator: Allocator) void {
    self.buckets.deinit(allocator);
    self.* = .empty;
}

/// Everything the filters need to know about a request. Built once per
/// request and shared by all three engines.
pub const Request = struct {
    url: pattern.Url,
    /// The URL as requested, fragment stripped but case kept: what a regex
    /// filter reads, since `$match-case` is only meaningful on the original.
    raw: []const u8,
    /// The hostname of the document the request belongs to. Falls back to the
    /// request's own hostname, which is what uBO does for top-level loads.
    source_hostname: []const u8,
    /// Exactly one bit set.
    kind: NetworkFilter.ResourceTypes,
    third_party: bool,
    /// The URL's first tokens, hashed once here so no engine retokenizes.
    tokens_buf: [URL_TOKENS_MAX]u32,
    tokens_len: usize,
    /// The rest of the URL, past the last token that fit.
    /// Each engine tokenizes it itself, so no token is ever lost. Token-free for
    /// all but the longest URLs.
    tail: []const u8,

    const URL_TOKENS_MAX = 128;

    /// Longest URL `fromHttp` will normalize. Anything past this is not a
    /// resource a filter list has an opinion about.
    const URL_MAX = 8 * 1024;
    /// DNS's own hostname limit.
    const SOURCE_MAX = 253;

    /// Backs the normalized text of a `fromHttp` request, which stays valid
    /// only as long as the buffers do.
    pub const Buffers = struct {
        url: [URL_MAX]u8,
        source: [SOURCE_MAX]u8,
    };

    /// `raw` and `url` are the same fragment-free URL, the second one
    /// lowercased; `source_hostname` may be empty when there is no document
    /// context.
    pub fn init(
        raw: []const u8,
        url: []const u8,
        source_hostname: []const u8,
        kind: NetworkFilter.ResourceTypes,
    ) Request {
        const parsed: pattern.Url = .init(url);
        const source = if (source_hostname.len == 0) parsed.hostname() else source_hostname;
        var request: Request = .{
            .url = parsed,
            .raw = raw,
            .source_hostname = source,
            .kind = kind,
            .third_party = domain.isThirdParty(parsed.hostname(), source),
            .tokens_buf = undefined,
            .tokens_len = 0,
            .tail = "",
        };
        var it: Tokens = .{ .text = url };
        while (request.tokens_len < request.tokens_buf.len) {
            const token = it.next() orelse break;
            request.tokens_buf[request.tokens_len] = token;
            request.tokens_len += 1;
        }
        request.tail = url[it.i..];
        return request;
    }

    pub fn fromHttp(transfer: *const HttpClient.Transfer, buffers: *Buffers) ?Request {
        const req = &transfer.req;
        // No request URL carries a fragment onto the wire.
        const fragment = std.mem.indexOfScalar(u8, req.url, '#') orelse req.url.len;
        const raw = req.url[0..fragment];
        const url = normalizeUrl(raw, &buffers.url) orelse return null;

        var owner: ?*const HttpClient.Owner = transfer.owner;
        var subframe = false;
        if (req.resource_type == .document) {
            owner = if (owner) |o| o.parent else null;
            subframe = owner != null;
        }
        const source_url = if (owner) |o| o.documentUrl() else null;
        const source_host = if (source_url) |u| URL.getOriginHostname(u) else "";
        if (source_host.len > buffers.source.len) return null;
        const source = std.ascii.lowerString(&buffers.source, source_host);

        const resource_type: NetworkFilter.ResourceTypes = switch (req.resource_type) {
            .document => if (subframe) .{ .subdocument = true } else .{ .document = true },
            .script => .{ .script = true },
            .stylesheet => .{ .stylesheet = true },
            .xhr, .fetch => .{ .xmlhttprequest = true },
            .image => .{ .image = true },
            .eventsource => .{ .other = true },
            .worker => .{ .script = true },
        };

        return .init(raw, url, source, resource_type);
    }

    inline fn tokens(self: *const Request) []const u32 {
        return self.tokens_buf[0..self.tokens_len];
    }

    /// Lowercases `url` into `buf`, as patterns are stored lowercased.
    fn normalizeUrl(url: []const u8, buf: []u8) ?[]const u8 {
        const upper = for (url, 0..) |c, i| {
            if (std.ascii.isUpper(c)) break i;
        } else return url;

        if (url.len > buf.len) return null;
        const out = buf[0..url.len];
        @memcpy(out[0..upper], url[0..upper]);
        _ = std.ascii.lowerString(out[upper..], url[upper..]);
        return out;
    }
};

/// How often each token appears across every indexed filter. Shared by the
/// engines so that "rarest" means rarest overall, not within one class.
pub const Histogram = std.AutoHashMapUnmanaged(u32, u32);

/// Tokens considered per filter. Long query-string patterns can exceed this;
/// taking the first few costs a wider bucket, never a wrong answer.
const TOKENS_MAX = 32;

/// The first filter that matches, or null.
pub fn match(self: *const Engine, request: *const Request) ?*const NetworkFilter {
    if (self.buckets.count() != 0) {
        for (request.tokens()) |token| {
            if (self.matchToken(token, request)) |filter| return filter;
        }
        // Whatever the request could not hold is hashed again.
        var it: Tokens = .{ .text = request.tail };
        while (it.next()) |token| {
            if (self.matchToken(token, request)) |filter| return filter;
        }
    }
    return self.matchIn(self.fallback, request);
}

fn matchToken(self: *const Engine, token: u32, request: *const Request) ?*const NetworkFilter {
    const bucket = self.buckets.get(token) orelse return null;
    return self.matchIn(bucket, request);
}

fn matchIn(self: *const Engine, bucket: []const u32, request: *const Request) ?*const NetworkFilter {
    for (bucket) |index| {
        const filter = &self.filters[index];
        if (matchesFilter(filter, request)) return filter;
    }
    return null;
}

/// Cheapest constraint first: the type and party bits are two comparisons,
/// the pattern walk is the expensive one.
fn matchesFilter(filter: *const NetworkFilter, request: *const Request) bool {
    if (filter.types.bits() & request.kind.bits() == 0) return false;
    if (request.third_party) {
        if (!filter.third_party) return false;
    } else if (!filter.first_party) {
        return false;
    }
    if (!filter.domains.matches(request.source_hostname)) return false;
    // uBO tests the raw URL; the case-insensitive flag is on the pattern.
    if (filter.kind == .regex) return filter.regex.?.matches(request.raw);
    return pattern.matches(filter, request.url);
}

/// Adds `filter`'s tokens to the corpus counts.
pub fn count(
    histogram: *Histogram,
    allocator: Allocator,
    filter: *const NetworkFilter,
) Allocator.Error!void {
    var buf: [TOKENS_MAX]u32 = undefined;
    for (collectTokens(filter, &buf)) |token| {
        const gop = try histogram.getOrPut(allocator, token);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
}

/// Indexes `members` (indices into `filters`) by their rarest token.
/// `allocator` backs the bucket map, `arena` the index slices it points at.
pub fn build(
    allocator: Allocator,
    arena: Allocator,
    filters: []const NetworkFilter,
    members: []const u32,
    histogram: *const Histogram,
) Allocator.Error!Engine {
    var groups: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = groups.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        groups.deinit(allocator);
    }

    var fallback: std.ArrayList(u32) = .empty;
    defer fallback.deinit(allocator);

    var buf: [TOKENS_MAX]u32 = undefined;
    for (members) |index| {
        var rarest: ?u32 = null;
        var lowest: u32 = std.math.maxInt(u32);
        for (collectTokens(&filters[index], &buf)) |token| {
            const seen = histogram.get(token) orelse 0;
            if (seen < lowest) {
                lowest = seen;
                rarest = token;
            }
        }

        const token = rarest orelse {
            try fallback.append(allocator, index);
            continue;
        };
        const gop = try groups.getOrPut(allocator, token);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, index);
    }

    var buckets: std.AutoHashMapUnmanaged(u32, []const u32) = .empty;
    errdefer buckets.deinit(allocator);
    try buckets.ensureTotalCapacity(allocator, groups.count());

    var it = groups.iterator();
    while (it.next()) |entry| {
        buckets.putAssumeCapacity(entry.key_ptr.*, try arena.dupe(u32, entry.value_ptr.items));
    }

    return .{
        .filters = filters,
        .buckets = buckets,
        .fallback = try arena.dupe(u32, fallback.items),
    };
}

/// Runs of alphanumerics. Everything else ('.', '/', '-', '%', '_', '?') is a boundary.
const Tokens = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(self: *Tokens) ?u32 {
        while (self.i < self.text.len and !isTokenChar(self.text[self.i])) self.i += 1;
        if (self.i == self.text.len) return null;

        const start = self.i;
        while (self.i < self.text.len and isTokenChar(self.text[self.i])) self.i += 1;
        return hash(self.text[start..self.i]);
    }
};

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn hash(token: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, token));
}

fn collectTokens(filter: *const NetworkFilter, buf: []u32) []u32 {
    var n: usize = 0;

    if (filter.hostname.len != 0) {
        var it: Tokens = .{ .text = filter.hostname };
        while (it.next()) |token| {
            if (n == buf.len) return buf[0..n];
            buf[n] = token;
            n += 1;
        }
    }

    // A /regex/ literal has no hostname, so `n` is still 0 here.
    if (filter.kind == .regex) return regexTokens(filter.pattern[1 .. filter.pattern.len - 1], buf);
    // `.any` has no pattern at all.
    if (filter.pattern.len == 0) return buf[0..n];

    const text = filter.pattern;
    var i: usize = 0;
    while (i < text.len) {
        if (!isTokenChar(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isTokenChar(text[i])) i += 1;

        const left_bounded = if (start == 0)
            filter.left_anchor or filter.hostname_anchor
        else
            text[start - 1] != '*';
        const right_bounded = if (i == text.len) filter.right_anchor else text[i] != '*';

        if (left_bounded and right_bounded) {
            if (n == buf.len) return buf[0..n];
            buf[n] = hash(text[start..i]);
            n += 1;
        }
    }

    return buf[0..n];
}

/// The tokens a regex is sure to have wherever it matches, uBO's
/// `tokenizableStrFromRegex`: the pattern is flattened into a string where
/// literal characters stay and everything else becomes a marker saying only
/// whether it could be a token character, then read like a plain pattern.
/// Anything the flattening does not follow yields no token at all, which is
/// never wrong: the filter then rides the fallback bucket.
fn regexTokens(source: []const u8, buf: []u32) []u32 {
    // A pattern's shape is never longer than the pattern.
    var shape_buf: [8 * 1024]u8 = undefined;
    if (source.len > shape_buf.len) return buf[0..0];
    var shape: RegexShape = .{ .source = source, .out = &shape_buf };
    const text = shape.flatten() catch return buf[0..0];

    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (!isTokenChar(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isTokenChar(text[i])) i += 1;

        // The pattern's ends are open unless anchored, and a marker that may
        // be a token character would extend the run.
        const left_bounded = start != 0 and text[start - 1] != RegexShape.maybe_token;
        const right_bounded = i != text.len and text[i] != RegexShape.maybe_token;
        if (left_bounded and right_bounded) {
            if (n == buf.len) return buf[0..n];
            buf[n] = hash(text[start..i]);
            n += 1;
        }
    }
    return buf[0..n];
}

const RegexShape = struct {
    source: []const u8,
    out: []u8,
    i: usize = 0,
    n: usize = 0,

    /// Whatever matches here is not a token character: an anchor, `\b`, a
    /// quantified non-token literal.
    const not_token = 0x00;
    /// Whatever matches here may be a token character: `.`, `[a-z]`, `\d`, a
    /// quantified literal.
    const maybe_token = 0x01;
    // The same two for a stretch that may match nothing at all; resolved
    // once both neighbours are known.
    const not_token_optional = 0x02;
    const maybe_token_optional = 0x03;

    const Error = error{Unsupported};

    fn flatten(self: *RegexShape) Error![]const u8 {
        try self.alternation(false);
        if (self.i != self.source.len) return error.Unsupported;
        self.resolveOptional();
        return self.out[0..self.n];
    }

    /// Parses alternatives up to the closing parenthesis (or the end). More
    /// than one collapses to two markers: all that is sure about `a|bc` is
    /// how it starts and ends.
    fn alternation(self: *RegexShape, nested: bool) Error!void {
        const start = self.n;
        var branches: usize = 1;
        var branch_start = start;
        var first = false;
        var last = false;
        while (true) {
            try self.sequence(nested);
            const branch = self.out[branch_start..self.n];
            first = first or startsTokenish(branch);
            last = last or endsTokenish(branch);
            if (self.i == self.source.len or self.source[self.i] != '|') break;
            self.i += 1;
            branches += 1;
            branch_start = self.n;
        }
        if (branches == 1) return;
        self.n = start;
        self.emit(if (first) maybe_token else not_token);
        self.emit(if (last) maybe_token else not_token);
    }

    fn sequence(self: *RegexShape, nested: bool) Error!void {
        while (self.i < self.source.len) {
            const atom_start = self.n;
            const c = self.source[self.i];
            switch (c) {
                '|' => return,
                ')' => {
                    if (!nested) return error.Unsupported;
                    return;
                },
                '(' => try self.group(),
                '[' => try self.class(),
                '\\' => try self.escape(),
                '.' => {
                    self.i += 1;
                    self.emit(maybe_token);
                },
                '^', '$' => {
                    self.i += 1;
                    self.emit(not_token);
                },
                '*', '+', '?' => return error.Unsupported,
                else => {
                    self.i += 1;
                    self.emit(std.ascii.toLower(c));
                },
            }
            try self.quantifier(atom_start);
        }
    }

    fn group(self: *RegexShape) Error!void {
        const start = self.n;
        self.i += 1;
        var lookaround: enum { none, positive, negative } = .none;
        if (self.i < self.source.len and self.source[self.i] == '?') {
            self.i += 1;
            const kind = self.take() orelse return error.Unsupported;
            switch (kind) {
                ':' => {},
                '=' => lookaround = .positive,
                '!' => lookaround = .negative,
                '<' => {
                    const next = self.take() orelse return error.Unsupported;
                    switch (next) {
                        '=' => lookaround = .positive,
                        '!' => lookaround = .negative,
                        else => {
                            // A named group is a plain group with a label.
                            const close = std.mem.indexOfScalarPos(u8, self.source, self.i, '>') orelse return error.Unsupported;
                            self.i = close + 1;
                        },
                    }
                },
                else => return error.Unsupported,
            }
        }
        try self.alternation(true);
        if (self.take() != ')') return error.Unsupported;
        switch (lookaround) {
            .none => {},
            // Consumes nothing, so the neighbours touch; what it asserts
            // could still be anything, and that is all a token may rely on.
            .positive => {
                self.n = start;
                self.emit(maybe_token);
            },
            // Consumes nothing and rules text out: the neighbours touch.
            .negative => self.n = start,
        }
    }

    /// `[...]` is one character; a token character can come out of it if any
    /// member is one, or if it is negated.
    fn class(self: *RegexShape) Error!void {
        self.i += 1;
        var maybe = false;
        if (self.i < self.source.len and self.source[self.i] == '^') {
            self.i += 1;
            maybe = true;
        }
        var first = true;
        while (true) {
            const c = self.take() orelse return error.Unsupported;
            if (c == ']' and !first) break;
            first = false;
            if (c == '\\') {
                const e = self.take() orelse return error.Unsupported;
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => maybe = true,
                    'b', 'n', 'r', 't', 'f', 'v' => {},
                    else => if (std.ascii.isAlphanumeric(e)) return error.Unsupported,
                }
                continue;
            }
            // A range is assumed to reach token characters.
            if (c == '-' or std.ascii.isAlphanumeric(c)) maybe = true;
        }
        self.emit(if (maybe) maybe_token else not_token);
    }

    fn escape(self: *RegexShape) Error!void {
        self.i += 1;
        const e = self.take() orelse return error.Unsupported;
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S', 'B' => self.emit(maybe_token),
            'b', 'n', 'r', 't', 'f', 'v' => self.emit(not_token),
            // Code points, backreferences, properties: not worth following.
            'x', 'u', 'c', 'k', 'p', 'P', '0'...'9' => return error.Unsupported,
            // Anything else escaped is itself, as JavaScript reads it.
            else => self.emit(std.ascii.toLower(e)),
        }
    }

    /// Applies a quantifier, if one follows, to what was just emitted. Only
    /// the first and last character classes survive a repeat: `ab+` may match
    /// "abbb", and its token is not "ab".
    fn quantifier(self: *RegexShape, atom_start: usize) Error!void {
        if (self.i == self.source.len) return;
        var min: usize = 0;
        var max: ?usize = null;
        switch (self.source[self.i]) {
            '*' => self.i += 1,
            '+' => {
                self.i += 1;
                min = 1;
            },
            '?' => {
                self.i += 1;
                max = 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, self.source, self.i, '}') orelse return;
                const body = self.source[self.i + 1 .. close];
                const comma = std.mem.indexOfScalar(u8, body, ',');
                const min_text = if (comma) |at| body[0..at] else body;
                // Not a quantifier at all: JavaScript reads the `{` literally.
                min = std.fmt.parseUnsigned(usize, min_text, 10) catch return;
                max = if (comma) |at|
                    (if (at + 1 == body.len) null else std.fmt.parseUnsigned(usize, body[at + 1 ..], 10) catch return)
                else
                    min;
                self.i = close + 1;
            },
            else => return,
        }
        // A lazy `?` changes nothing about what can match.
        if (self.i < self.source.len and self.source[self.i] == '?') self.i += 1;

        const atom = self.out[atom_start..self.n];
        const first = startsTokenish(atom);
        const last = endsTokenish(atom);
        self.n = atom_start;
        if (max == 0) return;
        if (min != 0) {
            self.emit(if (first) maybe_token else not_token);
            self.emit(if (last) maybe_token else not_token);
        } else {
            self.emit(if (first) maybe_token_optional else not_token_optional);
            self.emit(if (last) maybe_token_optional else not_token_optional);
        }
    }

    /// An optional stretch may vanish, letting its neighbours touch: it
    /// resolves to markers that carry whichever side could be a token
    /// character, so no run is read as bounded by something that may be
    /// gone.
    fn resolveOptional(self: *RegexShape) void {
        var i: usize = 0;
        while (i < self.n) {
            if (!isOptional(self.out[i])) {
                i += 1;
                continue;
            }
            var end = i;
            while (end < self.n and isOptional(self.out[end])) end += 1;
            const left = self.out[0..i];
            const middle = self.out[i..end];
            const right = self.out[end..self.n];
            const head: u8 = if (startsTokenish(right) or startsTokenish(middle)) maybe_token else not_token;
            const tail: u8 = if (endsTokenish(left) or endsTokenish(middle)) maybe_token else not_token;
            // Quantifiers emit markers in pairs, so a stretch is never shorter
            // than what replaces it.
            std.mem.copyForwards(u8, self.out[i + 2 .. self.n - (middle.len - 2)], right);
            self.out[i] = head;
            self.out[i + 1] = tail;
            self.n -= middle.len - 2;
            i += 2;
        }
    }

    fn take(self: *RegexShape) ?u8 {
        if (self.i == self.source.len) return null;
        defer self.i += 1;
        return self.source[self.i];
    }

    fn emit(self: *RegexShape, c: u8) void {
        self.out[self.n] = c;
        self.n += 1;
    }

    fn isOptional(c: u8) bool {
        return c == not_token_optional or c == maybe_token_optional;
    }

    fn isTokenish(c: u8) bool {
        return c == maybe_token or c == maybe_token_optional or isTokenChar(c);
    }

    fn startsTokenish(s: []const u8) bool {
        return s.len != 0 and isTokenish(s[0]);
    }

    fn endsTokenish(s: []const u8) bool {
        return s.len != 0 and isTokenish(s[s.len - 1]);
    }
};

const testing = @import("../../testing.zig");

fn tokensOf(arena: Allocator, line: []const u8, buf: []u32) ![]u32 {
    const filter = try NetworkFilter.parse(arena, line);
    return collectTokens(&filter, buf);
}

fn contains(tokens: []const u32, token: []const u8) bool {
    for (tokens) |t| {
        if (t == hash(token)) return true;
    }
    return false;
}

test "adblock.Engine: regex filters yield the tokens every match carries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [TOKENS_MAX]u32 = undefined;

    // Literal runs between literal non-token characters; the open end of an
    // unanchored pattern bounds nothing.
    var tokens = try tokensOf(arena, "/\\/[0-9a-f]{32}\\/invoke\\.js/", &buf);
    try testing.expectEqual(1, tokens.len);
    try testing.expect(contains(tokens, "invoke"));

    // Anchors bound; `https?` may be either, so "http" is no token.
    tokens = try tokensOf(arena, "/^https?:\\/\\/[0-9a-z]{5,}\\.com\\/.*/", &buf);
    try testing.expectEqual(1, tokens.len);
    try testing.expect(contains(tokens, "com"));
    tokens = try tokensOf(arena, "/[a-z]{2,}\\.gif$/", &buf);
    try testing.expectEqual(1, tokens.len);
    try testing.expect(contains(tokens, "gif"));

    // `\b` bounds, as uBO reads it: `/\bads\b/` is "ads", not "bads".
    tokens = try tokensOf(arena, "/\\bads\\b/", &buf);
    try testing.expect(contains(tokens, "ads"));

    // Hashed lowercased, like the URL it is looked up in.
    tokens = try tokensOf(arena, "/\\/Ads\\//$match-case", &buf);
    try testing.expect(contains(tokens, "ads"));

    // An optional stretch may vanish and glue its neighbours: "adsbanner".
    tokens = try tokensOf(arena, "/\\/ads\\/?banner\\//", &buf);
    try testing.expectEqual(0, tokens.len);
    // A repeat is not the literal it repeats.
    tokens = try tokensOf(arena, "/\\/ab+c\\//", &buf);
    try testing.expectEqual(0, tokens.len);

    // Alternation and the text under a quantified group are uncertain.
    tokens = try tokensOf(arena, "/^https?:\\/\\/(35|104)\\.(\\d){1,3}\\//", &buf);
    try testing.expectEqual(0, tokens.len);
    tokens = try tokensOf(arena, "/ads|banner/", &buf);
    try testing.expectEqual(0, tokens.len);
    // ... but a group with one branch is transparent.
    tokens = try tokensOf(arena, "/\\/(?:ads)\\//", &buf);
    try testing.expect(contains(tokens, "ads"));

    // A negative lookaround consumes nothing; a positive one is not
    // trusted to spell anything.
    tokens = try tokensOf(arena, "/\\/(?!ads)banner\\//", &buf);
    try testing.expect(contains(tokens, "banner"));
    tokens = try tokensOf(arena, "/\\/(?=ads)ads\\//", &buf);
    try testing.expectEqual(0, tokens.len);

    // What is not followed yields nothing rather than something wrong.
    tokens = try tokensOf(arena, "/\\/\\x41ds\\//", &buf);
    try testing.expectEqual(0, tokens.len);
    tokens = try tokensOf(arena, "/\\/(ads\\//", &buf);
    try testing.expectEqual(0, tokens.len);
    tokens = try tokensOf(arena, "/about:blank.*/", &buf);
    try testing.expectEqual(0, tokens.len);
}

test "adblock.Engine: a request keeps its first tokens, the rest as tail" {
    const max = Request.URL_TOKENS_MAX;
    const kind: NetworkFilter.ResourceTypes = .{ .script = true };

    // Exactly as many tokens as the buffer holds: nothing is left to walk...
    const full = "x/" ** (max - 1) ++ "x";
    var request: Request = .init(full, full, "", kind);
    try testing.expectEqual(max, request.tokens_len);
    try testing.expectEqual(0, request.tail.len);

    // ...one more, and only that one is in the tail.
    request = .init(full ++ "/y", full ++ "/y", "", kind);
    try testing.expectEqual(max, request.tokens_len);
    try testing.expectString("/y", request.tail);
    var it: Tokens = .{ .text = request.tail };
    try testing.expectEqual(hash("y"), it.next().?);
    try testing.expect(it.next() == null);

    // Fewer than the buffer holds: the tail is empty.
    request = .init("https://example.com/a", "https://example.com/a", "", kind);
    try testing.expectEqual(4, request.tokens_len);
    try testing.expectEqual(0, request.tail.len);
}

test "adblock.Engine: only tokens the URL must reproduce are collected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [TOKENS_MAX]u32 = undefined;

    // Every hostname label is bounded, the last one by the matcher's
    // label-boundary requirement — with or without '^'.
    var tokens = try tokensOf(arena, "||ads.example.com^", &buf);
    try testing.expect(contains(tokens, "ads"));
    try testing.expect(contains(tokens, "example"));
    try testing.expect(contains(tokens, "com"));

    tokens = try tokensOf(arena, "||ads.example.com", &buf);
    try testing.expect(contains(tokens, "example"));
    try testing.expect(contains(tokens, "com"));

    // A path following the hostname bounds it just as well.
    tokens = try tokensOf(arena, "||youtube.com/pagead/", &buf);
    try testing.expect(contains(tokens, "com"));
    try testing.expect(contains(tokens, "pagead"));

    // A trailing token is unbounded unless the pattern is right-anchored:
    // "/ads" also matches "/adserver".
    tokens = try tokensOf(arena, "||example.com/ads", &buf);
    try testing.expect(!contains(tokens, "ads"));
    tokens = try tokensOf(arena, "||example.com/ads|", &buf);
    try testing.expect(contains(tokens, "ads"));

    // A '*' on either side disqualifies the token beside it, so this one is
    // carried entirely by its hostname.
    tokens = try tokensOf(arena, "||example.com/a*banner*c^", &buf);
    try testing.expect(!contains(tokens, "banner"));
    try testing.expect(contains(tokens, "example"));

    // Nothing to index: option-only filters ride the fallback bucket.
    tokens = try tokensOf(arena, "$script,domain=example.com", &buf);
    try testing.expectEqual(0, tokens.len);
}

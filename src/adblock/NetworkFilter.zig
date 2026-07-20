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
const domain = @import("domain.zig");

const NetworkFilter = @This();

kind: PatternKind,
/// Normalized (lowercased) match pattern. Empty for pure-hostname filters.
/// For hostname-anchored filters with a path part, this is the remainder
/// after `hostname` (starting with '/', '^' or '*'). For regex filters, the
/// body between the slashes, stored raw.
pattern: []const u8 = "",
hostname: []const u8 = "",
types: ResourceTypes = .none,
domains: domain.List = .empty,
exception: bool = false,
important: bool = false,
badfilter: bool = false,
match_case: bool = false,
first_party: bool = true,
third_party: bool = true,
hostname_anchor: bool = false,
left_anchor: bool = false,
right_anchor: bool = false,
require_separator: bool = false,
generichide: bool = false,
specifichide: bool = false,
elemhide: bool = false,

pub const PatternKind = enum {
    /// '*' or empty pattern, matches every URL (option-only filters).
    any,
    /// Pure hostname (`||example.com^`, bare hostname lines, hosts files).
    hostname,
    /// Plain substring, possibly anchored.
    plain,
    /// Contains '*' or '^'; needs the wildcard matcher.
    wildcard,
    /// Whole-pattern /regex/ literal; body kept unvalidated for the engine.
    regex,
};

pub const ResourceTypes = packed struct(u16) {
    document: bool = false,
    subdocument: bool = false,
    script: bool = false,
    stylesheet: bool = false,
    image: bool = false,
    font: bool = false,
    media: bool = false,
    object: bool = false,
    xmlhttprequest: bool = false,
    websocket: bool = false,
    ping: bool = false,
    other: bool = false,
    _padding: u4 = 0,

    pub const none: ResourceTypes = .{};

    /// Default type set of a filter with no type option: everything except
    /// top-level documents (matches uBO/adblock-rust semantics).
    pub const all_network: ResourceTypes = .{
        .subdocument = true,
        .script = true,
        .stylesheet = true,
        .image = true,
        .font = true,
        .media = true,
        .object = true,
        .xmlhttprequest = true,
        .websocket = true,
        .ping = true,
        .other = true,
    };

    /// `all_network` + document: applied implicitly to pure-hostname
    /// filters ending in '^' ("strict" blocking) and by $all.
    pub const all: ResourceTypes = blk: {
        var t = all_network;
        t.document = true;
        break :blk t;
    };

    pub fn bits(self: ResourceTypes) u16 {
        return @bitCast(self);
    }
};

pub const ParseError = error{
    // Malformed input.
    InvalidPattern,
    InvalidOption,
    InvalidDomainList,
    UnknownOption,
    // Valid uBO syntax this we deliberately drops.
    UnsupportedOption,
    UnsupportedPattern,
    NoSupportedDomains,
    // Hosts-file noise ("127.0.0.1 localhost"), skip silently.
    Ignored,
} || std.mem.Allocator.Error;

const Option = enum {
    // Resource types.
    document,
    subdocument,
    script,
    stylesheet,
    image,
    font,
    media,
    object,
    xmlhttprequest,
    websocket,
    ping,
    other,
    all,
    // Party.
    first_party,
    third_party,
    // Constraints and switches.
    domain,
    important,
    badfilter,
    match_case,
    generichide,
    specifichide,
    elemhide,
    // Recognized but unsupported (rule dropped)...
    popup,
    popunder,
    inline_script,
    inline_font,
    genericblock,
    cname,
    denyallow,
    to,
    method,
    header,
    strict1p,
    strict3p,
    ipaddress,
    csp,
    permissions,
    removeparam,
    replace,
    urlskip,
    uritransform,
    redirect_rule,
    // ...except $redirect, which keeps its blocking half.
    redirect,
    empty,
    mp4,
    // Always invalid.
    webrtc,
};

const option_names = std.StaticStringMap(Option).initComptime(&.{
    .{ "document", .document },
    .{ "doc", .document },
    .{ "subdocument", .subdocument },
    .{ "frame", .subdocument },
    .{ "script", .script },
    .{ "stylesheet", .stylesheet },
    .{ "css", .stylesheet },
    .{ "image", .image },
    .{ "font", .font },
    .{ "media", .media },
    .{ "object", .object },
    .{ "object-subrequest", .object },
    .{ "xmlhttprequest", .xmlhttprequest },
    .{ "xhr", .xmlhttprequest },
    .{ "websocket", .websocket },
    .{ "ping", .ping },
    .{ "beacon", .ping },
    .{ "other", .other },
    .{ "all", .all },
    .{ "first-party", .first_party },
    .{ "1p", .first_party },
    .{ "third-party", .third_party },
    .{ "3p", .third_party },
    .{ "domain", .domain },
    .{ "from", .domain },
    .{ "important", .important },
    .{ "badfilter", .badfilter },
    .{ "match-case", .match_case },
    .{ "generichide", .generichide },
    .{ "ghide", .generichide },
    .{ "specifichide", .specifichide },
    .{ "shide", .specifichide },
    .{ "elemhide", .elemhide },
    .{ "ehide", .elemhide },
    .{ "popup", .popup },
    .{ "popunder", .popunder },
    .{ "inline-script", .inline_script },
    .{ "inline-font", .inline_font },
    .{ "genericblock", .genericblock },
    .{ "cname", .cname },
    .{ "denyallow", .denyallow },
    .{ "to", .to },
    .{ "method", .method },
    .{ "header", .header },
    .{ "responseheader", .header },
    .{ "strict1p", .strict1p },
    .{ "strict3p", .strict3p },
    .{ "ipaddress", .ipaddress },
    .{ "csp", .csp },
    .{ "permissions", .permissions },
    .{ "removeparam", .removeparam },
    .{ "queryprune", .removeparam },
    .{ "replace", .replace },
    .{ "urlskip", .urlskip },
    .{ "uritransform", .uritransform },
    .{ "redirect-rule", .redirect_rule },
    .{ "redirect", .redirect },
    .{ "rewrite", .redirect },
    .{ "empty", .empty },
    .{ "mp4", .mp4 },
    .{ "webrtc", .webrtc },
});

/// Parses one already-trimmed network filter line. All allocations come from
/// `arena` and live as long as it; returned slices may alias `line`.
pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!NetworkFilter {
    var filter: NetworkFilter = .{ .kind = .plain };

    var rest = line;
    if (std.mem.startsWith(u8, rest, "@@")) {
        filter.exception = true;
        rest = rest[2..];
    }
    if (rest.len == 0) return error.InvalidPattern;

    rest = stripInlineComment(rest);
    if (rest.len == 0) return error.InvalidPattern;

    const split = splitOptions(rest);
    var explicit_types = false;
    if (split.options) |options| {
        try filter.parseOptions(arena, options, &explicit_types);
    }

    if (std.mem.indexOfAny(u8, split.pattern, &std.ascii.whitespace) != null) {
        // Whitespace only occurs in hosts-file style lines; anywhere else it
        // is malformed.
        if (filter.exception or split.options != null) return error.InvalidPattern;
        try filter.parseHostsLine(arena, split.pattern);
    } else {
        try filter.parsePattern(arena, split.pattern, split.options != null);
    }

    filter.resolveTypes(explicit_types);

    if (filter.match_case and filter.kind != .regex) {
        // uBO discards $match-case on anything but /regex/ filters.
        return error.InvalidOption;
    }
    if (!filter.exception and
        (filter.generichide or filter.specifichide or filter.elemhide))
    {
        return error.InvalidOption;
    }

    return filter;
}

/// Deep-copies the filter so it outlives the list text and arena it was
/// parsed from (parsed slices may alias both).
pub fn dupe(self: *const NetworkFilter, arena: std.mem.Allocator) std.mem.Allocator.Error!NetworkFilter {
    var out = self.*;
    out.pattern = try arena.dupe(u8, self.pattern);
    out.hostname = try arena.dupe(u8, self.hostname);
    out.domains = try self.domains.dupe(arena);
    return out;
}

/// uBO allows a trailing "  # comment" on lines containing whitespace.
fn stripInlineComment(line: []const u8) []const u8 {
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '#' and std.ascii.isWhitespace(line[i - 1])) {
            return std.mem.trimRight(u8, line[0..i], &std.ascii.whitespace);
        }
    }
    return line;
}

const OptionsSplit = struct {
    pattern: []const u8,
    options: ?[]const u8,
};

fn splitOptions(line: []const u8) OptionsSplit {
    var search = line;
    while (std.mem.lastIndexOfScalar(u8, search, '$')) |pos| {
        const suffix = line[pos + 1 ..];
        if (isOptionListStart(suffix)) {
            return .{ .pattern = line[0..pos], .options = suffix };
        }
        search = line[0..pos];
    }
    return .{ .pattern = line, .options = null };
}

fn isOptionListStart(text: []const u8) bool {
    if (text.len == 0) return false;
    var rest = text;
    if (rest[0] == '~') rest = rest[1..];

    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) break;
    }
    if (end == 0) return false;
    return end == rest.len or rest[end] == ',' or rest[end] == '=';
}

/// '_' placeholder options ("___") are valid and ignored.
fn isNoop(name: []const u8) bool {
    for (name) |c| {
        if (c != '_') return false;
    }
    return name.len > 0;
}

fn parseOptions(
    self: *NetworkFilter,
    arena: std.mem.Allocator,
    options: []const u8,
    explicit_types: *bool,
) ParseError!void {
    var positive: ResourceTypes = .none;
    var negative: ResourceTypes = .none;

    var it = std.mem.splitScalar(u8, options, ',');
    while (it.next()) |raw_option| {
        if (raw_option.len == 0) return error.InvalidOption;

        var negated = false;
        var body = raw_option;
        if (body[0] == '~') {
            negated = true;
            body = body[1..];
        }

        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            value = body[eq + 1 ..];
            body = body[0..eq];
        }
        if (body.len == 0) return error.InvalidOption;
        if (isNoop(body) and !negated and value == null) continue;

        const option = option_names.get(body) orelse return error.UnknownOption;

        // Only $domain and the modifier options carry values.
        if (value != null) switch (option) {
            .domain, .denyallow, .to, .method, .header, .ipaddress => {},
            .csp, .permissions, .removeparam, .replace, .urlskip => {},
            .redirect, .redirect_rule => {},
            else => return error.InvalidOption,
        };

        switch (option) {
            .document,
            .subdocument,
            .script,
            .stylesheet,
            .image,
            .font,
            .media,
            .object,
            .xmlhttprequest,
            .websocket,
            .ping,
            .other,
            => {
                if (negated and option == .document) return error.InvalidOption;
                explicit_types.* = true;
                setType(if (negated) &negative else &positive, option);
            },
            .all => {
                if (negated) return error.InvalidOption;
                explicit_types.* = true;
                positive = .all;
            },
            .first_party => {
                if (negated) self.first_party = false else self.third_party = false;
            },
            .third_party => {
                if (negated) self.third_party = false else self.first_party = false;
            },
            .domain => {
                // Negation belongs inside the value ($domain=~x), never on
                // the option itself.
                if (negated) return error.InvalidOption;
                const v = value orelse return error.InvalidOption;
                if (v.len == 0) return error.InvalidOption;
                self.domains = try domain.parse(arena, v, '|');
            },
            .important => {
                if (negated) return error.InvalidOption;
                self.important = true;
            },
            .badfilter => {
                if (negated) return error.InvalidOption;
                self.badfilter = true;
            },
            .match_case => {
                if (negated) return error.InvalidOption;
                self.match_case = true;
            },
            .generichide => {
                if (negated) return error.InvalidOption;
                self.generichide = true;
            },
            .specifichide => {
                if (negated) return error.InvalidOption;
                self.specifichide = true;
            },
            .elemhide => {
                if (negated) return error.InvalidOption;
                self.elemhide = true;
            },
            // $redirect (and deprecated $empty/$mp4 aliases) is "block +
            // serve a stub"; without a resources library we keep the block
            // and drop the directive. $mp4 implies the media type.
            .redirect, .empty => {
                if (negated) return error.InvalidOption;
            },
            .mp4 => {
                if (negated) return error.InvalidOption;
                explicit_types.* = true;
                positive.media = true;
            },
            .popup,
            .popunder,
            .inline_script,
            .inline_font,
            .genericblock,
            .cname,
            .denyallow,
            .to,
            .method,
            .header,
            .strict1p,
            .strict3p,
            .ipaddress,
            .csp,
            .permissions,
            .removeparam,
            .replace,
            .urlskip,
            .uritransform,
            .redirect_rule,
            => return error.UnsupportedOption,
            .webrtc => return error.InvalidOption,
        }
    }

    // Resolve the final type set the way uBO/adblock-rust do: explicit
    // positives win; any negation starts from the full network set; no type
    // option at all also means the full network set (see resolveTypes for
    // the pure-hostname exception).
    var types = positive;
    if (negative.bits() != 0 and positive.bits() == 0) {
        types = .all_network;
    }
    types = @bitCast(types.bits() & ~negative.bits());
    self.types = types;
}

fn setType(set: *ResourceTypes, option: Option) void {
    switch (option) {
        .document => set.document = true,
        .subdocument => set.subdocument = true,
        .script => set.script = true,
        .stylesheet => set.stylesheet = true,
        .image => set.image = true,
        .font => set.font = true,
        .media => set.media = true,
        .object => set.object = true,
        .xmlhttprequest => set.xmlhttprequest = true,
        .websocket => set.websocket = true,
        .ping => set.ping = true,
        .other => set.other = true,
        else => unreachable,
    }
}

fn resolveTypes(self: *NetworkFilter, explicit_types: bool) void {
    if (explicit_types) return;

    if (self.kind == .hostname and self.require_separator) {
        self.types = .all;
    } else {
        self.types = .all_network;
    }
}

fn parseHostsLine(self: *NetworkFilter, arena: std.mem.Allocator, pattern: []const u8) ParseError!void {
    var it = std.mem.tokenizeAny(u8, pattern, &std.ascii.whitespace);
    const sink = it.next() orelse return error.Ignored;
    const host_raw = it.next() orelse return error.Ignored;
    if (it.next() != null) return error.Ignored;

    for (sink) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '%', '.', ':', '[', ']', '-' => true,
            else => false,
        };
        if (!ok) return error.Ignored;
    }

    const host = try domain.lowered(arena, host_raw);
    if (isRedirectHostName(host) or !isHostnameShaped(host)) return error.Ignored;

    self.kind = .hostname;
    self.hostname = host;
    self.hostname_anchor = true;
    self.require_separator = true;
}

fn parsePattern(
    self: *NetworkFilter,
    arena: std.mem.Allocator,
    raw: []const u8,
    has_options: bool,
) ParseError!void {
    if (raw.len == 0 or std.mem.eql(u8, raw, "*")) {
        if (!has_options) return error.InvalidPattern;
        self.kind = .any;
        return;
    }

    for (raw) |c| {
        if (c >= 0x80) return error.UnsupportedPattern; // needs punycode/%-encoding
        if (std.ascii.isControl(c)) return error.InvalidPattern;
    }

    // Whole-pattern regex literal: /.../ with anything between the slashes.
    if (raw.len > 2 and raw[0] == '/' and raw[raw.len - 1] == '/') {
        self.kind = .regex;
        self.pattern = raw[1 .. raw.len - 1];
        return;
    }

    // A literal '#' can never match: request URLs have their fragment
    // stripped before matching. This is also what drops cosmetic filter
    // lines (example.com##.ad-banner), which classify as network now that
    // there is no cosmetic-separator scan.
    if (std.mem.indexOfScalar(u8, raw, '#') != null) return error.UnsupportedPattern;

    var pattern = raw;
    if (std.mem.startsWith(u8, pattern, "||")) {
        self.hostname_anchor = true;
        pattern = pattern[2..];
    } else if (pattern.len > 0 and pattern[0] == '|') {
        self.left_anchor = true;
        pattern = pattern[1..];
    }
    if (pattern.len > 0 and pattern[pattern.len - 1] == '|') {
        // A '*' right before '|' makes the anchor pointless; uBO drops it.
        if (pattern.len < 2 or pattern[pattern.len - 2] != '*') {
            self.right_anchor = true;
        }
        pattern = pattern[0 .. pattern.len - 1];
    }

    // Trim pointless wildcards touching the (now removed) ends.
    while (std.mem.startsWith(u8, pattern, "*")) {
        pattern = pattern[1..];
        self.left_anchor = false;
    }
    while (std.mem.endsWith(u8, pattern, "*")) {
        pattern = pattern[0 .. pattern.len - 1];
        self.right_anchor = false;
    }

    if (pattern.len == 0) {
        if (self.hostname_anchor) return error.InvalidPattern;
        if (!has_options and !self.left_anchor and !self.right_anchor) {
            return error.InvalidPattern;
        }
        self.kind = .any;
        return;
    }

    pattern = try domain.lowered(arena, pattern);

    if (self.hostname_anchor) {
        const host_end = std.mem.indexOfAny(u8, pattern, "/^") orelse pattern.len;
        if (std.mem.indexOfScalar(u8, pattern[0..host_end], '*') != null) {
            // Wildcard inside the hostname region (`||example.*/ads`):
            // no hostname split, the whole thing is a generic pattern.
            self.kind = .wildcard;
            self.pattern = pattern;
            return;
        }
        if (host_end == 0) return error.InvalidPattern;
        self.hostname = pattern[0..host_end];
        const remainder = pattern[host_end..];
        if (remainder.len == 0) {
            self.kind = .hostname;
        } else if (std.mem.eql(u8, remainder, "^")) {
            self.kind = .hostname;
            self.require_separator = true;
        } else {
            self.pattern = remainder;
            self.kind = if (std.mem.indexOfAny(u8, remainder, "*^") != null) .wildcard else .plain;
        }
        return;
    }

    // A pattern that reads as a bare hostname is a hostname filter
    // (`ads.example.com` == `||ads.example.com^`)
    if (!self.left_anchor and !self.right_anchor and isHostnameShaped(pattern)) {
        if (isRedirectHostName(pattern)) return error.Ignored;
        self.kind = .hostname;
        self.hostname = pattern;
        self.hostname_anchor = true;
        self.require_separator = true;
        return;
    }

    if (!has_options and pattern.len <= 1 and !self.left_anchor and !self.right_anchor) {
        return error.InvalidPattern;
    }

    self.pattern = pattern;
    self.kind = if (std.mem.indexOfAny(u8, pattern, "*^") != null) .wildcard else .plain;
}

/// Matches uBO's hostname flavor: dot-separated labels of [a-z0-9_-], each
/// starting alphanumeric; the last label is [a-z0-9][a-z0-9-]*[a-z0-9]
/// (len >= 2, no '_'). Accepts IPv4 literals. Input must be lowercase.
fn isHostnameShaped(s: []const u8) bool {
    if (s.len == 0) return false;
    var labels = std.mem.splitScalar(u8, s, '.');
    var last: []const u8 = "";
    while (labels.next()) |label| {
        if (label.len == 0) return false;
        if (!std.ascii.isAlphanumeric(label[0])) return false;
        for (label) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
        }
        last = label;
    }
    if (last.len < 2) return false;
    if (!std.ascii.isAlphanumeric(last[last.len - 1])) return false;
    if (std.mem.indexOfScalar(u8, last, '_') != null) return false;
    return true;
}

/// Hostnames that only appear as hosts-file plumbing, never as filters.
fn isRedirectHostName(host: []const u8) bool {
    if (std.mem.startsWith(u8, host, "ip6-")) return true;
    const names = [_][]const u8{
        "localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0",
    };
    for (names) |name| {
        if (std.mem.eql(u8, host, name)) return true;
    }
    return false;
}

const testing = std.testing;

fn testParse(arena: std.mem.Allocator, line: []const u8) ParseError!NetworkFilter {
    return parse(arena, line);
}

test "adblock.NetworkFilter: pure hostname forms" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The single most common rule shape: `||host^`.
    var f = try testParse(arena, "||ads.example.com^");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expectEqualStrings("ads.example.com", f.hostname);
    try testing.expect(f.require_separator);
    try testing.expect(!f.exception);
    // Implicit "strict" blocking: documents included.
    try testing.expectEqual(ResourceTypes.all.bits(), f.types.bits());

    // Without '^' there is no separator requirement and no implicit
    // document blocking.
    f = try testParse(arena, "||ads.example.com");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expect(!f.require_separator);
    try testing.expectEqual(ResourceTypes.all_network.bits(), f.types.bits());

    // Bare hostname line == ||host^ (uBO divergence from ABP).
    f = try testParse(arena, "tracker.example.net");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expectEqualStrings("tracker.example.net", f.hostname);
    try testing.expect(f.require_separator);

    // Raw IPv4 lines (URLhaus style).
    f = try testParse(arena, "101.126.11.168");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expectEqualStrings("101.126.11.168", f.hostname);
}

test "adblock.NetworkFilter: hosts-file lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "0.0.0.0 ads.tracker.com");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expectEqualStrings("ads.tracker.com", f.hostname);
    try testing.expectEqual(ResourceTypes.all.bits(), f.types.bits());

    f = try testParse(arena, "127.0.0.1 AdServer.Example.com # inline comment");
    try testing.expectEqualStrings("adserver.example.com", f.hostname);

    // Hosts noise is silently ignored, not an error.
    try testing.expectError(error.Ignored, testParse(arena, "127.0.0.1 localhost"));
    try testing.expectError(error.Ignored, testParse(arena, "::1 ip6-localhost"));
    try testing.expectError(error.Ignored, testParse(arena, "0.0.0.0 a.com b.com"));
    try testing.expectError(error.Ignored, testParse(arena, "localhost"));
}

test "adblock.NetworkFilter: anchors and pattern kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "/banner/ads.");
    try testing.expectEqual(.plain, f.kind);
    try testing.expectEqualStrings("/banner/ads.", f.pattern);

    // Starting AND ending with '/' means regex, not path substring — lists
    // write "*/banner/" or "/banner/*" to force substring semantics.
    f = try testParse(arena, "/banner/ads/");
    try testing.expectEqual(.regex, f.kind);
    try testing.expectEqualStrings("banner/ads", f.pattern);

    f = try testParse(arena, "|https://ads.");
    try testing.expectEqual(.plain, f.kind);
    try testing.expect(f.left_anchor);
    try testing.expectEqualStrings("https://ads.", f.pattern);

    f = try testParse(arena, "-Ad-300x250.gif|");
    try testing.expect(f.right_anchor);
    try testing.expectEqualStrings("-ad-300x250.gif", f.pattern);

    f = try testParse(arena, "||example.com/ads/*.js");
    try testing.expectEqual(.wildcard, f.kind);
    try testing.expectEqualStrings("example.com", f.hostname);
    try testing.expectEqualStrings("/ads/*.js", f.pattern);

    f = try testParse(arena, "/ads/banner^");
    try testing.expectEqual(.wildcard, f.kind);

    // Pointless wildcards get trimmed; '*|' drops the anchor.
    f = try testParse(arena, "*-ads-*|");
    try testing.expectEqual(.plain, f.kind);
    try testing.expect(!f.right_anchor);
    try testing.expectEqualStrings("-ads-", f.pattern);

    // A pattern that trims down to a bare hostname shape gets promoted
    // (uBO flavor rules), even a single label.
    f = try testParse(arena, "*ads*|");
    try testing.expectEqual(.hostname, f.kind);
    try testing.expectEqualStrings("ads", f.hostname);

    // '||' hostname region containing '*' stays a generic pattern.
    f = try testParse(arena, "||example.*/ads");
    try testing.expectEqual(.wildcard, f.kind);
    try testing.expect(f.hostname_anchor);
    try testing.expectEqualStrings("", f.hostname);
}

test "adblock.NetworkFilter: regex literals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "/banner\\d+/");
    try testing.expectEqual(.regex, f.kind);
    try testing.expectEqualStrings("banner\\d+", f.pattern);

    // '$' inside a regex must not be mistaken for an options separator.
    f = try testParse(arena, "/ads\\$/");
    try testing.expectEqual(.regex, f.kind);
    try testing.expectEqualStrings("ads\\$", f.pattern);

    // ... but a real options list after a regex still splits.
    f = try testParse(arena, "/^https?:.*banner/$image");
    try testing.expectEqual(.regex, f.kind);
    try testing.expect(f.types.image);
    try testing.expect(!f.types.script);

    f = try testParse(arena, "/re/$match-case");
    try testing.expect(f.match_case);
    try testing.expectError(error.InvalidOption, testParse(arena, "ads$match-case"));
}

test "adblock.NetworkFilter: exceptions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "@@||example.com^");
    try testing.expect(f.exception);
    try testing.expectEqual(.hostname, f.kind);

    f = try testParse(arena, "@@||example.com^$generichide");
    try testing.expect(f.generichide);

    // $generichide & co. are exception-only.
    try testing.expectError(error.InvalidOption, testParse(arena, "||example.com^$generichide"));
}

test "adblock.NetworkFilter: type options, aliases and negation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "||ads.com^$script,image");
    try testing.expect(f.types.script);
    try testing.expect(f.types.image);
    try testing.expect(!f.types.xmlhttprequest);
    try testing.expect(!f.types.document);

    f = try testParse(arena, "||ads.com^$xhr,frame,css,doc");
    try testing.expect(f.types.xmlhttprequest);
    try testing.expect(f.types.subdocument);
    try testing.expect(f.types.stylesheet);
    try testing.expect(f.types.document);

    // Negated types start from the full network set.
    f = try testParse(arena, "||ads.com^$~script");
    try testing.expect(!f.types.script);
    try testing.expect(f.types.image);
    try testing.expect(!f.types.document);

    f = try testParse(arena, "||ads.com^$all");
    try testing.expectEqual(ResourceTypes.all.bits(), f.types.bits());

    try testing.expectError(error.UnknownOption, testParse(arena, "||ads.com^$bogus"));
    try testing.expectError(error.InvalidOption, testParse(arena, "||ads.com^$~document"));
}

test "adblock.NetworkFilter: party options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "||ads.com^$third-party");
    try testing.expect(f.third_party);
    try testing.expect(!f.first_party);

    f = try testParse(arena, "||ads.com^$3p");
    try testing.expect(!f.first_party);

    f = try testParse(arena, "||ads.com^$~third-party");
    try testing.expect(f.first_party);
    try testing.expect(!f.third_party);

    f = try testParse(arena, "||ads.com^$1p");
    try testing.expect(!f.third_party);
}

test "adblock.NetworkFilter: domain option" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try testParse(arena, "||ads.com^$script,domain=news.com|~sports.news.com|google.*");
    try testing.expectEqual(2, f.domains.included.len);
    try testing.expectEqual(1, f.domains.excluded.len);
    try testing.expectEqualStrings("news.com", f.domains.included[0].value);
    try testing.expect(f.domains.included[1].entity);

    try testing.expectError(error.InvalidOption, testParse(arena, "||ads.com^$domain="));
    try testing.expectError(error.NoSupportedDomains, testParse(arena, "||ads.com^$domain=/re/"));
    // The option itself is not negatable; negation goes inside the value.
    try testing.expectError(error.InvalidOption, testParse(arena, "||ads.com^$~domain=example.com"));
}

test "adblock.NetworkFilter: important, badfilter, noop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "||ads.com^$important");
    try testing.expect(f.important);

    f = try testParse(arena, "||ads.com^$badfilter");
    try testing.expect(f.badfilter);

    f = try testParse(arena, "||ads.com^$script,_,__,image");
    try testing.expect(f.types.script);
    try testing.expect(f.types.image);
}

test "adblock.NetworkFilter: unsupported and modifier options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Modifier/rewrite rules are dropped: keeping them as plain blocks
    // would over-block (a $removeparam rule matches nearly everything).
    try testing.expectError(error.UnsupportedOption, testParse(arena, "$removeparam=utm_source"));
    try testing.expectError(error.UnsupportedOption, testParse(arena, "||ads.com^$csp=script-src 'none'"));
    try testing.expectError(error.UnsupportedOption, testParse(arena, "||ads.com^$popup"));
    try testing.expectError(error.UnsupportedOption, testParse(arena, "||ads.com^$redirect-rule=noopjs"));

    // $redirect keeps its blocking half; the directive itself is ignored.
    var f = try testParse(arena, "||ads.com/ad.js$script,redirect=noopjs");
    try testing.expect(f.types.script);
    try testing.expectEqualStrings("ads.com", f.hostname);

    f = try testParse(arena, "||ads.com/v.mp4$mp4");
    try testing.expect(f.types.media);
}

test "adblock.NetworkFilter: option-only and invalid patterns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try testParse(arena, "*$script,domain=example.com");
    try testing.expectEqual(.any, f.kind);
    try testing.expect(f.types.script);

    f = try testParse(arena, "$script,domain=example.com");
    try testing.expectEqual(.any, f.kind);

    try testing.expectError(error.InvalidPattern, testParse(arena, "*"));
    try testing.expectError(error.InvalidPattern, testParse(arena, "a"));
    try testing.expectError(error.InvalidPattern, testParse(arena, "@@"));
    try testing.expectError(error.InvalidPattern, testParse(arena, "||^"));
    try testing.expectError(error.InvalidPattern, testParse(arena, "foo bar$script"));
    try testing.expectError(error.UnsupportedPattern, testParse(arena, "||exämple.com^"));

    // Cosmetic lines reach this parser undetected (no separator scan) and
    // drop here: a '#' never matches a fragment-stripped request URL.
    try testing.expectError(error.UnsupportedPattern, testParse(arena, "example.com##.ad-banner"));
    try testing.expectError(error.UnsupportedPattern, testParse(arena, "example.com#@#.sponsored"));
    try testing.expectError(error.UnsupportedPattern, testParse(arena, "|https://a.com/x#y|"));
    // ... but '#' inside a /regex/ body is untouched.
    const regex = try testParse(arena, "/ads#[0-9]+/");
    try testing.expectEqual(.regex, regex.kind);
}

test "adblock.NetworkFilter: uppercase patterns are normalized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try testParse(arena, "||Ads.Example.COM^");
    try testing.expectEqualStrings("ads.example.com", f.hostname);

    // Option names are lowercase in the wild; uppercase names are unknown.
    try testing.expectError(error.UnknownOption, testParse(arena, "||ads.com^$Script"));
}

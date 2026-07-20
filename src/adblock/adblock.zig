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

pub const AdBlocker = @import("AdBlocker.zig");
pub const NetworkFilter = @import("NetworkFilter.zig");
pub const domain = @import("domain.zig");

pub const LineClass = enum(u3) {
    empty,
    comment,
    network,
    /// Recognized syntax we deliberately do not support (AdGuard HTML filtering `$$`).
    unsupported,

    /// Classifies one trimmed line. There is no cosmetic-separator scan.
    pub fn fromLine(line: []const u8) LineClass {
        if (line.len == 0) return .empty;

        switch (line[0]) {
            '!', '#' => return .comment,
            '[' => {
                if (std.ascii.startsWithIgnoreCase(line, "[adblock")) return .comment;
            },
            else => {},
        }

        if (line[0] == '|' or std.mem.startsWith(u8, line, "@@|")) return .network;
        if (std.mem.indexOf(u8, line, "$$") != null) return .unsupported;
        return .network;
    }
};

pub const ParseStats = struct {
    lines: usize = 0,
    network: usize = 0,
    comments: usize = 0,
    /// Valid syntax outside the supported subset (cosmetic filters,
    /// scriptlets, AdGuard forms, modifier options, ...).
    unsupported: usize = 0,
    /// Lines with an option name we do not recognize at all.
    unknown_option: usize = 0,
    /// Malformed lines.
    invalid: usize = 0,
    /// Hosts-file noise ("127.0.0.1 localhost").
    ignored: usize = 0,
};

pub const Parser = struct {
    reader: *std.Io.Reader,
    stats: ParseStats = .{},
    title: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    version: ?[]const u8 = null,
    /// Metadata headers only count until the first filter line.
    in_header: bool = true,
    first_line: bool = true,

    pub fn init(reader: *std.Io.Reader) Parser {
        return .{ .reader = reader };
    }

    pub const Error = error{ OutOfMemory, ReadFailed, StreamTooLong };

    /// Returns the next network filter, or null at end of list.
    pub fn next(self: *Parser, arena: std.mem.Allocator) Error!?NetworkFilter {
        while (try self.reader.takeDelimiter('\n')) |raw_line| {
            var stripped: []const u8 = raw_line;
            if (self.first_line) {
                self.first_line = false;
                if (std.mem.startsWith(u8, stripped, "\xEF\xBB\xBF")) {
                    stripped = stripped[3..];
                }
            }
            const line = std.mem.trim(u8, stripped, &std.ascii.whitespace);
            self.stats.lines += 1;

            switch (LineClass.fromLine(line)) {
                .empty => {},
                .comment => {
                    self.stats.comments += 1;
                    if (self.in_header) try self.parseMetadata(arena, line);
                },
                .unsupported => {
                    self.in_header = false;
                    self.stats.unsupported += 1;
                },
                .network => {
                    self.in_header = false;
                    if (NetworkFilter.parse(arena, line)) |filter| {
                        self.stats.network += 1;
                        return filter;
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Ignored => self.stats.ignored += 1,
                        error.UnknownOption => self.stats.unknown_option += 1,
                        error.UnsupportedOption,
                        error.UnsupportedPattern,
                        error.NoSupportedDomains,
                        => self.stats.unsupported += 1,
                        error.InvalidPattern,
                        error.InvalidOption,
                        error.InvalidDomainList,
                        => self.stats.invalid += 1,
                    }
                },
            }
        }
        return null;
    }

    /// `! Key: value` headers in the leading comment block. First
    /// occurrence wins; identical text later in the file is just a comment.
    fn parseMetadata(self: *Parser, arena: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!void {
        if (line.len == 0 or line[0] != '!') return;
        const rest = std.mem.trimLeft(u8, line[1..], &std.ascii.whitespace);
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return;
        const key = std.mem.trim(u8, rest[0..colon], &std.ascii.whitespace);
        const value = std.mem.trim(u8, rest[colon + 1 ..], &std.ascii.whitespace);
        if (value.len == 0) return;

        const slot: *?[]const u8 = if (std.ascii.eqlIgnoreCase(key, "title"))
            &self.title
        else if (std.ascii.eqlIgnoreCase(key, "expires"))
            &self.expires
        else if (std.ascii.eqlIgnoreCase(key, "homepage"))
            &self.homepage
        else if (std.ascii.eqlIgnoreCase(key, "version"))
            &self.version
        else
            return;
        if (slot.* == null) slot.* = try arena.dupe(u8, value);
    }
};

pub const List = struct {
    network: []NetworkFilter,
    title: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    version: ?[]const u8 = null,
    stats: ParseStats,

    pub fn parse(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!List {
        var reader: std.Io.Reader = .fixed(text);
        var parser: Parser = .init(&reader);

        var network: std.ArrayList(NetworkFilter) = .empty;
        while (parser.next(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A fixed reader's buffer is the whole text: reads cannot fail and no line can outgrow the buffer.
            error.ReadFailed, error.StreamTooLong => unreachable,
        }) |filter| {
            try network.append(arena, filter);
        }

        return .{
            .network = try network.toOwnedSlice(arena),
            .title = parser.title,
            .expires = parser.expires,
            .homepage = parser.homepage,
            .version = parser.version,
            .stats = parser.stats,
        };
    }
};

const testing = std.testing;

test "adblock: line classification" {
    try testing.expectEqual(.empty, LineClass.fromLine(""));
    try testing.expectEqual(.comment, LineClass.fromLine("! EasyList"));
    try testing.expectEqual(.comment, LineClass.fromLine("[Adblock Plus 2.0]"));
    // Pre-parsing directives are plain comments; their blocks parse
    // unconditionally.
    try testing.expectEqual(.comment, LineClass.fromLine("!#if env_mobile"));
    try testing.expectEqual(.comment, LineClass.fromLine("!#endif"));
    // Every '#'-prefixed line is a comment, including generic cosmetic
    // filters — there is no separator scan.
    try testing.expectEqual(.comment, LineClass.fromLine("# hosts-style comment"));
    try testing.expectEqual(.comment, LineClass.fromLine("#### section"));
    try testing.expectEqual(.comment, LineClass.fromLine("#nosep"));
    try testing.expectEqual(.comment, LineClass.fromLine("## heading text"));
    try testing.expectEqual(.comment, LineClass.fromLine("##.ad-banner"));
    try testing.expectEqual(.comment, LineClass.fromLine("###banner"));

    try testing.expectEqual(.network, LineClass.fromLine("||ads.example.com^"));
    try testing.expectEqual(.network, LineClass.fromLine("@@|https://example.com/path#frag|"));
    try testing.expectEqual(.network, LineClass.fromLine("0.0.0.0 tracker.com"));
    // Domain-prefixed cosmetic lines classify as network; the filter
    // parser drops them via their '#' (see NetworkFilter tests).
    try testing.expectEqual(.network, LineClass.fromLine("example.com#@#.ad"));
    try testing.expectEqual(.network, LineClass.fromLine("example.com#?#.ad:has-text(x)"));
    try testing.expectEqual(.network, LineClass.fromLine("example.com#$#body { padding: 0 }"));

    try testing.expectEqual(.unsupported, LineClass.fromLine("example.com$$script[data-x]"));
}

test "adblock: Parser yields one filter per next() call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // BOM-prefixed, no trailing newline on the last line.
    var reader: std.Io.Reader = .fixed("\xEF\xBB\xBF! Title: Streamed\n" ++
        "||ads.example.com^\n" ++
        "example.com##.ad-banner\n" ++
        "||tracker.net^");
    var parser: Parser = .init(&reader);

    const first = (try parser.next(arena)).?;
    try testing.expectEqualStrings("ads.example.com", first.hostname);

    const second = (try parser.next(arena)).?;
    try testing.expectEqualStrings("tracker.net", second.hostname);

    try testing.expect(try parser.next(arena) == null);
    try testing.expect(try parser.next(arena) == null);

    try testing.expectEqualStrings("Streamed", parser.title.?);
    try testing.expectEqual(2, parser.stats.network);
    try testing.expectEqual(1, parser.stats.unsupported); // cosmetic line
    try testing.expectEqual(4, parser.stats.lines);
}

test "adblock: List.parse end to end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        "[Adblock Plus 2.0]\n" ++
        "! Title: Test List\n" ++
        "! Expires: 4 days (update frequency)\n" ++
        "! Homepage: https://example.org\n" ++
        "!\n" ++
        "||ads.example.com^\n" ++
        "||tracker.net^$third-party,script\n" ++
        "@@||cdn.example.com^$script\n" ++
        "-banner-468x60.\n" ++
        "0.0.0.0 telemetry.example.io\n" ++
        "127.0.0.1 localhost\n" ++
        "##.ad-banner\n" ++
        "example.com###sidebar-ad\n" ++
        "example.com#@#.sponsored\n" ++
        "example.com##+js(no-fetch-if, ads)\n" ++
        "||modifier.example.com^$removeparam=utm_source\n" ++
        "||bogus.example.com^$notarealoption\n" ++
        "!#if env_mobile\n" ++
        "||mobile-only.example.com^\n" ++
        "!#else\n" ++
        "||desktop-only.example.com^\n" ++
        "!#endif\n" ++
        "! Title: not metadata anymore\n";

    const list = try List.parse(arena, text);

    try testing.expectEqualStrings("Test List", list.title.?);
    try testing.expectEqualStrings("4 days (update frequency)", list.expires.?);
    try testing.expectEqualStrings("https://example.org", list.homepage.?);

    // 5 direct network filters + both branches of the !#if block: the
    // directives are comments, their contents parse unconditionally.
    try testing.expectEqual(7, list.network.len);
    try testing.expectEqual(7, list.stats.network);
    // Domain-prefixed cosmetic lines (###sidebar-ad, #@#.sponsored) and
    // $removeparam land in unsupported; the generic ##.ad-banner is a
    // comment; the whitespace-carrying scriptlet joins localhost in
    // ignored.
    try testing.expectEqual(3, list.stats.unsupported);
    try testing.expectEqual(2, list.stats.ignored);
    try testing.expectEqual(1, list.stats.unknown_option);
    try testing.expectEqual(0, list.stats.invalid);

    const desktop = list.network[list.network.len - 1];
    try testing.expectEqualStrings("desktop-only.example.com", desktop.hostname);

    // "-banner-468x60." is not hostname-shaped (leading '-'): plain pattern.
    try testing.expectEqual(.plain, list.network[3].kind);
    try testing.expectEqualStrings("-banner-468x60.", list.network[3].pattern);
}

test {
    std.testing.refAllDecls(@This());
}

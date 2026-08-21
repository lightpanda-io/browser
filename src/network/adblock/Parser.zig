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

//! Streams an EasyList-syntax filter list, yielding one supported network
//! filter per `next` call. Lines we do not support are skipped.

const std = @import("std");

const NetworkFilter = @import("NetworkFilter.zig");

const Allocator = std.mem.Allocator;

const Parser = @This();

reader: *std.Io.Reader,
first_line: bool = true,
/// Rule-shaped lines that never became a filter: syntax outside our subset,
/// malformed rules, and lines too long to read. Blank lines and comments are
/// not rules, so they never count. The caller adds this to whatever it drops
/// afterwards, so that "skipped" means every rule the list has and we do not.
skipped: usize = 0,

pub const Error = error{ OutOfMemory, ReadFailed };

/// One rule-shaped line. Dropped lines are surfaced rather than swallowed
/// because an `@@` rule we cannot read still tells the caller that something
/// on that hostname is not meant to be blocked.
pub const Item = union(enum) {
    filter: NetworkFilter,
    /// Already counted in `skipped`; the caller only inspects it.
    dropped: Dropped,
};

pub const Dropped = struct {
    line: []const u8,
    /// Why the filter parser refused it. Null when the line never reached it
    /// (AdGuard `$$` syntax).
    reason: ?NetworkFilter.ParseError,
};

pub fn init(reader: *std.Io.Reader) Parser {
    return .{ .reader = reader };
}

/// Returns the next rule-shaped line, or null at end of list. Allocations
/// come from `arena`; the result borrows from it and from the reader's
/// buffer, so it only stays valid until the following call.
pub fn next(self: *Parser, arena: Allocator) Error!?Item {
    while (try self.takeLine()) |raw_line| {
        var stripped: []const u8 = raw_line;
        if (self.first_line) {
            self.first_line = false;
            if (std.mem.startsWith(u8, stripped, "\xEF\xBB\xBF")) {
                stripped = stripped[3..];
            }
        }
        const line = std.mem.trim(u8, stripped, &std.ascii.whitespace);

        switch (LineClass.fromLine(line)) {
            .empty, .comment => {},
            .unsupported => {
                self.skipped += 1;
                return .{ .dropped = .{ .line = line, .reason = null } };
            },
            .network => {
                if (NetworkFilter.parse(arena, line)) |filter| {
                    return .{ .filter = filter };
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Anything else is a line outside the supported subset
                    // or malformed; either way it is not ours to enforce.
                    else => {
                        self.skipped += 1;
                        return .{ .dropped = .{ .line = line, .reason = err } };
                    },
                }
            },
        }
    }
    return null;
}

/// `Io.Reader.takeDelimiter`, except that a line too long to fit the reader's
/// buffer is dropped instead of aborting the list. Nothing that long is a
/// filter we could support, and a single monster line should not cost us the
/// rest of the file.
fn takeLine(self: *Parser) error{ReadFailed}!?[]u8 {
    while (true) {
        if (self.reader.takeDelimiter('\n')) |line| {
            return line;
        } else |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => {
                // Counted without knowing what it was: a line we cannot read
                // is a line we cannot rule out being a filter.
                self.skipped += 1;
                // takeDelimiter leaves the stream untouched on StreamTooLong,
                // so the oversized line still has to be stepped over.
                _ = self.reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return null,
                };
            },
        }
    }
}

const LineClass = enum {
    empty,
    comment,
    network,
    /// Recognized syntax we deliberately do not support (AdGuard HTML filtering `$$`).
    unsupported,

    /// Classifies one trimmed line. There is no cosmetic-separator scan.
    fn fromLine(line: []const u8) LineClass {
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

const testing = @import("../../testing.zig");

test "adblock.Parser: line classification" {
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

/// The next item that is a filter, skipping over dropped lines.
fn nextFilter(parser: *Parser, arena: Allocator) !?NetworkFilter {
    while (try parser.next(arena)) |item| {
        switch (item) {
            .filter => |filter| return filter,
            .dropped => {},
        }
    }
    return null;
}

test "adblock.Parser: yields one item per next() call" {
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
    try testing.expectString("ads.example.com", first.filter.hostname);

    // The cosmetic line comes back as dropped rather than being swallowed,
    // with the reason the filter parser gave.
    const second = (try parser.next(arena)).?;
    try testing.expectString("example.com##.ad-banner", second.dropped.line);
    try testing.expectEqual(error.UnsupportedPattern, second.dropped.reason.?);

    const third = (try parser.next(arena)).?;
    try testing.expectString("tracker.net", third.filter.hostname);

    // The header and the end of the list yield nothing, and next() keeps
    // returning null once drained.
    try testing.expect(try parser.next(arena) == null);
    try testing.expect(try parser.next(arena) == null);
}

test "adblock.Parser: only rule-shaped lines count as skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reader: std.Io.Reader = .fixed(
        \\[Adblock Plus 2.0]
        \\! Title: Counted
        \\
        \\||ads.example.com^
        \\example.com##.ad-banner
        \\||bogus.example.com^$notarealoption
        \\example.com$$script[data-x]
    );
    var parser: Parser = .init(&reader);

    var count: usize = 0;
    while (try nextFilter(&parser, arena)) |_| count += 1;

    // The header, the comment and the blank line are not rules.
    try testing.expectEqual(1, count);
    // The cosmetic filter, the unknown option and the AdGuard line are.
    try testing.expectEqual(3, parser.skipped);
}

test "adblock.Parser: a line too long for the buffer is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "||ads.example.com^\n||");
    try text.appendNTimes(testing.allocator, 'a', 128);
    try text.appendSlice(testing.allocator, ".example.com^\n||tracker.net^\n");

    // A buffer too small to ever hold the middle line.
    var buf: [64]u8 = undefined;
    var text_reader: std.Io.Reader = .fixed(text.items);
    var reader = text_reader.limited(.unlimited, &buf);
    var parser: Parser = .init(&reader.interface);

    const first = (try nextFilter(&parser, arena)).?;
    try testing.expectString("ads.example.com", first.hostname);

    // The oversized line was stepped over, not treated as end of list.
    const second = (try nextFilter(&parser, arena)).?;
    try testing.expectString("tracker.net", second.hostname);

    try testing.expect(try nextFilter(&parser, arena) == null);
    // It is still a line we could not load, and it says so.
    try testing.expectEqual(1, parser.skipped);
}

test "adblock.Parser: full list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reader: std.Io.Reader = .fixed(
        "[Adblock Plus 2.0]\n" ++
            "! Title: Test List\n" ++
            "! Expires: 4 days (update frequency)\n" ++
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
            "!#endif\n",
    );
    var parser: Parser = .init(&reader);

    // A filter only borrows the reader's buffer until the next call, so
    // assert on each one as it comes out.
    var count: usize = 0;
    while (try nextFilter(&parser, arena)) |filter| : (count += 1) {
        switch (count) {
            // "-banner-468x60." is not hostname-shaped (leading '-'), so it
            // stays a plain pattern rather than becoming a hostname filter.
            3 => {
                try testing.expectEqual(.plain, filter.kind);
                try testing.expectString("", filter.hostname);
            },
            6 => try testing.expectString("desktop-only.example.com", filter.hostname),
            else => {},
        }
    }

    // 5 direct network filters + both branches of the !#if block: the
    // directives are comments, their contents parse unconditionally.
    // Everything else in the list — cosmetic lines, the scriptlet, the
    // hosts-file noise, $removeparam and the unknown option — is skipped.
    try testing.expectEqual(7, count);
}

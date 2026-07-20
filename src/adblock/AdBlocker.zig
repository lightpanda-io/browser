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
const NetworkFilter = @import("NetworkFilter.zig");

const AdBlocker = @This();

arena: std.heap.ArenaAllocator,
/// All network filters from every list parsed so far.
filters: std.ArrayList(NetworkFilter),

pub fn init(allocator: Allocator) AdBlocker {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .filters = .empty,
    };
}

pub fn deinit(self: *AdBlocker) void {
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
        try parsed.append(scratch, try filter.dupe(arena));
    }

    try self.filters.appendSlice(arena, parsed.items);
    return parser.stats;
}

const testing = std.testing;

test "adblock.AdBlocker: parse accumulates filters across lists" {
    var blocker: AdBlocker = .init(testing.allocator);
    defer blocker.deinit();

    var first: Io.Reader = .fixed(
        \\! Title: First List
        \\||ads.example.com^
        \\@@||cdn.example.com^$script
        \\example.com##.ad-banner
    );
    const first_stats = try blocker.parse(&first);

    try testing.expectEqual(2, blocker.filters.items.len);
    try testing.expectEqual(2, first_stats.network);
    try testing.expectEqual(1, first_stats.unsupported); // cosmetic line

    var second: Io.Reader = .fixed(
        \\||tracker.net^$third-party,domain=news.com|~sports.news.com
    );
    const second_stats = try blocker.parse(&second);

    try testing.expectEqual(3, blocker.filters.items.len);
    try testing.expectEqual(1, second_stats.network);

    // The scratch arena holding each list's text is gone: every retained
    // string must have been deep-copied.
    try testing.expectEqualStrings("ads.example.com", blocker.filters.items[0].hostname);
    try testing.expect(blocker.filters.items[1].exception);
    const tracker = blocker.filters.items[2];
    try testing.expectEqualStrings("tracker.net", tracker.hostname);
    try testing.expect(!tracker.first_party);
    try testing.expectEqualStrings("news.com", tracker.domains.included[0].value);
    try testing.expectEqualStrings("sports.news.com", tracker.domains.excluded[0].value);
}

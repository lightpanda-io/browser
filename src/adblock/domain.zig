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

pub const Domain = struct {
    /// Lowercase hostname. For entities, stored without the trailing ".*".
    value: []const u8,
    entity: bool = false,
};

pub const List = struct {
    included: []const Domain = &.{},
    excluded: []const Domain = &.{},

    pub const empty: List = .{};

    pub fn isEmpty(self: *const List) bool {
        return self.included.len == 0 and self.excluded.len == 0;
    }

    /// Deep-copies the list so it outlives the arena it was parsed from.
    pub fn dupe(self: *const List, arena: std.mem.Allocator) std.mem.Allocator.Error!List {
        return .{
            .included = try dupeDomains(arena, self.included),
            .excluded = try dupeDomains(arena, self.excluded),
        };
    }

    fn dupeDomains(arena: std.mem.Allocator, domains: []const Domain) ![]const Domain {
        if (domains.len == 0) return &.{};
        const out = try arena.dupe(Domain, domains);
        for (out) |*d| d.value = try arena.dupe(u8, d.value);
        return out;
    }
};

/// All allocations are made from `arena` and are never individually freed.
pub fn parse(arena: std.mem.Allocator, raw: []const u8, separator: u8) !List {
    var included: std.ArrayList(Domain) = .empty;
    var excluded: std.ArrayList(Domain) = .empty;

    var had_entries = false;
    var it = std.mem.splitScalar(u8, raw, separator);
    while (it.next()) |raw_entry| {
        var entry = std.mem.trim(u8, raw_entry, &std.ascii.whitespace);
        if (entry.len == 0) continue;
        had_entries = true;

        var negated = false;
        if (entry[0] == '~') {
            negated = true;
            entry = entry[1..];
            if (entry.len == 0) return error.InvalidDomainList;
        }

        // /regex/ entries are valid uBO syntax but unsupported here.
        if (entry[0] == '/') continue;

        var entity = false;
        if (std.mem.endsWith(u8, entry, ".*")) {
            entity = true;
            entry = entry[0 .. entry.len - 2];
            if (entry.len == 0) return error.InvalidDomainList;
        }

        if (!isValidHost(entry)) return error.InvalidDomainList;

        const domain: Domain = .{
            .value = try lowered(arena, entry),
            .entity = entity,
        };
        if (negated) {
            try excluded.append(arena, domain);
        } else {
            try included.append(arena, domain);
        }
    }

    if (had_entries and included.items.len == 0 and excluded.items.len == 0) {
        // Every entry was an unsupported /regex/; the caller must drop the
        // rule rather than let it apply everywhere.
        return error.NoSupportedDomains;
    }

    return .{
        .included = try included.toOwnedSlice(arena),
        .excluded = try excluded.toOwnedSlice(arena),
    };
}

fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    var prev: u8 = '.';
    for (host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
        if (c == '.' and prev == '.') return false;
        prev = c;
    }
    return true;
}

/// Returns the input slice unchanged when it is already lowercase, otherwise
/// an arena-allocated lowercase copy.
pub fn lowered(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            const out = try arena.dupe(u8, s);
            for (out[i..], i..) |c2, j| out[j] = std.ascii.toLower(c2);
            return out;
        }
    }
    return s;
}

const testing = std.testing;

test "adblock.domain: plain, negated and entity entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try parse(arena, "example.com|~sub.Example.com|google.*", '|');
    try testing.expectEqual(2, list.included.len);
    try testing.expectEqual(1, list.excluded.len);
    try testing.expectEqualStrings("example.com", list.included[0].value);
    try testing.expect(!list.included[0].entity);
    try testing.expectEqualStrings("google", list.included[1].value);
    try testing.expect(list.included[1].entity);
    try testing.expectEqualStrings("sub.example.com", list.excluded[0].value);
}

test "adblock.domain: comma separator (cosmetic prefixes)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const list = try parse(arena_state.allocator(), "a.com,~b.a.com", ',');
    try testing.expectEqual(1, list.included.len);
    try testing.expectEqual(1, list.excluded.len);
}

test "adblock.domain: regex entries are skipped, all-regex errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try parse(arena, "/foo/|example.com", '|');
    try testing.expectEqual(1, list.included.len);

    try testing.expectError(error.NoSupportedDomains, parse(arena, "/foo/", '|'));
}

test "adblock.domain: invalid entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.InvalidDomainList, parse(arena, "exa mple.com", '|'));
    try testing.expectError(error.InvalidDomainList, parse(arena, ".example.com", '|'));
    try testing.expectError(error.InvalidDomainList, parse(arena, "~", '|'));
}

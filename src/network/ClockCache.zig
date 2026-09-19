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

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ClockCache(comptime K: type) type {
    return struct {
        const Self = @This();

        const Map = if (K == []const u8)
            std.array_hash_map.String(bool)
        else
            std.array_hash_map.Auto(K, bool);

        allocator: Allocator,
        capacity: usize,
        map: Map = .empty,
        hand: usize = 0,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            std.debug.assert(capacity > 0);
            return .{ .allocator = allocator, .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit(self.allocator);
        }

        pub fn insert(self: *Self, key: K) !?K {
            try self.map.put(self.allocator, key, true);

            if (self.map.count() <= self.capacity) return null;
            return self.evictOne();
        }

        pub fn touch(self: *Self, key: K) void {
            if (self.map.getPtr(key)) |referenced| referenced.* = true;
        }

        fn evictOne(self: *Self) ?K {
            const referenced = self.map.values();
            while (true) {
                if (self.hand >= referenced.len) self.hand = 0;

                if (referenced[self.hand]) {
                    referenced[self.hand] = false;
                    self.hand += 1;
                    continue;
                }

                const key = self.map.keys()[self.hand];
                self.map.swapRemoveAt(self.hand);
                return key;
            }
        }
    };
}

const testing = @import("../testing.zig");

test "ClockCache: no eviction under capacity" {
    var q = ClockCache([]const u8).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));
    try testing.expectEqual(null, try q.insert("c"));
    try testing.expectEqual(3, q.map.count());
}

test "ClockCache: evicts once over capacity" {
    var q = ClockCache([]const u8).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));

    const evicted = try q.insert("c");
    try testing.expect(evicted != null);
    try testing.expectString("a", evicted.?);
    try testing.expectEqual(2, q.map.count());
}

test "ClockCache: touch protects a key from eviction" {
    var q = ClockCache([]const u8).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));

    const evicted1 = try q.insert("c");
    try testing.expect(evicted1 != null);
    try testing.expectString("a", evicted1.?);
    try testing.expect(q.map.contains("b"));
    try testing.expect(q.map.contains("c"));

    q.touch("b");
    const evicted2 = try q.insert("d");
    try testing.expect(evicted2 != null);
    try testing.expectString("c", evicted2.?);
    try testing.expect(q.map.contains("b"));
    try testing.expectEqual(2, q.map.count());
}

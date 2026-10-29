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

pub fn Entry(comptime V: type) type {
    return struct {
        value: V,
        referenced: bool,
    };
}

pub fn ClockCache(comptime V: type) type {
    return struct {
        const Self = @This();

        const Map = std.array_hash_map.String(Entry(V));

        pub const InsertResult = union(enum) {
            exists,
            inserted: ?V,
        };

        allocator: Allocator,
        capacity: ?usize,
        map: Map = .empty,
        hand: usize = 0,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            const true_capacity = if (capacity == 0) null else capacity;
            return .{ .allocator = allocator, .capacity = true_capacity };
        }

        pub fn deinit(self: *Self) void {
            for (self.map.keys()) |key| {
                self.allocator.free(key);
            }
            self.map.deinit(self.allocator);
        }

        pub fn entries(self: *Self) []Entry(V) {
            return self.map.values();
        }

        pub fn get(self: *Self, key: []const u8) ?*V {
            const entry = self.map.getPtr(key) orelse return null;
            entry.referenced = true;
            return &entry.value;
        }

        pub fn remove(self: *Self, key: []const u8) ?V {
            const index = self.map.getIndex(key) orelse return null;
            const owned_key = self.map.keys()[index];
            const value = self.map.values()[index].value;
            self.map.swapRemoveAt(index);
            self.allocator.free(owned_key);
            return value;
        }

        pub fn insert(self: *Self, key: []const u8, value: V) !InsertResult {
            const gop = try self.map.getOrPut(self.allocator, key);
            if (gop.found_existing) return .exists;

            errdefer self.map.swapRemoveAt(gop.index);
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = .{ .value = value, .referenced = true };

            if (self.capacity) |cap| {
                if (self.map.count() > cap) {
                    return .{ .inserted = self.evictOne() };
                }
            }

            return .{ .inserted = null };
        }

        fn evictOne(self: *Self) V {
            const items = self.map.values();
            while (true) {
                if (self.hand >= items.len) self.hand = 0;

                if (items[self.hand].referenced) {
                    items[self.hand].referenced = false;
                    self.hand += 1;
                    continue;
                }

                const key = self.map.keys()[self.hand];
                const value = items[self.hand].value;
                self.map.swapRemoveAt(self.hand);
                self.allocator.free(key);
                return value;
            }
        }
    };
}

const testing = @import("../testing.zig");

fn evictedOf(comptime V: type, r: ClockCache(V).InsertResult) ?V {
    return switch (r) {
        .exists => unreachable,
        .inserted => |v| v,
    };
}

test "ClockCache: no eviction under capacity" {
    var q = ClockCache(u32).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(null, evictedOf(u32, try q.insert("a", 1)));
    try testing.expectEqual(null, evictedOf(u32, try q.insert("b", 2)));
    try testing.expectEqual(null, evictedOf(u32, try q.insert("c", 3)));
    try testing.expectEqual(3, q.map.count());
}

test "ClockCache: evicts once over capacity" {
    var q = ClockCache(u32).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, evictedOf(u32, try q.insert("a", 1)));
    try testing.expectEqual(null, evictedOf(u32, try q.insert("b", 2)));

    const evicted = evictedOf(u32, try q.insert("c", 3));
    try testing.expectEqual(1, evicted.?);
    try testing.expect(q.get("a") == null);
    try testing.expectEqual(2, q.map.count());
}

test "ClockCache: touch protects a key from eviction" {
    var q = ClockCache(u32).init(testing.allocator, 2);
    defer q.deinit();

    _ = try q.insert("a", 1);
    _ = try q.insert("b", 2);

    const evicted1 = evictedOf(u32, try q.insert("c", 3));
    try testing.expectEqual(1, evicted1.?);
    try testing.expect(q.get("b") != null);
    try testing.expect(q.get("c") != null);

    _ = q.get("b");
    const evicted2 = evictedOf(u32, try q.insert("d", 4));
    try testing.expectEqual(3, evicted2.?);
    try testing.expect(q.get("b") != null);
    try testing.expectEqual(2, q.map.count());
}

test "ClockCache: insert does not overwrite" {
    var q = ClockCache(u32).init(testing.allocator, 2);
    defer q.deinit();

    _ = try q.insert("a", 1);
    try testing.expect((try q.insert("a", 99)) == .exists);
    try testing.expectEqual(1, q.get("a").?.*);
}

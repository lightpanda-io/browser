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

pub fn EvictionQueue(comptime K: type) type {
    return struct {
        const Self = @This();

        const Item = struct {
            seq: u64,
            key: K,
        };

        fn olderFirst(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.seq, b.seq);
        }

        const Heap = std.PriorityQueue(Item, void, olderFirst);

        allocator: Allocator,
        capacity: usize,
        next_seq: u64 = 0,
        heap: Heap = .empty,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            return .{ .allocator = allocator, .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit(self.allocator);
        }

        // Record a newly-inserted key. If this pushes the queue over
        // capacity, returns the oldest key so the caller can evict it from
        // its own map. Callers must only call this once per new key -- it
        // does not check for duplicates.
        pub fn insert(self: *Self, key: K) !?K {
            const seq = self.next_seq;
            self.next_seq += 1;

            try self.heap.push(self.allocator, .{ .seq = seq, .key = key });
            if (self.heap.count() <= self.capacity) {
                return null;
            }
            return self.heap.pop().?.key;
        }
    };
}

const testing = @import("../testing.zig");

test "EvictionQueue: no eviction under capacity" {
    var q = EvictionQueue([]const u8).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));
    try testing.expectEqual(null, try q.insert("c"));
    try testing.expectEqual(3, q.heap.count());
}

test "EvictionQueue: evicts oldest key once over capacity" {
    var q = EvictionQueue([]const u8).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));

    const evicted = try q.insert("c");
    try testing.expect(evicted != null);
    try testing.expectString("a", evicted.?);
    try testing.expectEqual(2, q.heap.count());

    const evicted2 = try q.insert("d");
    try testing.expect(evicted2 != null);
    try testing.expectString("b", evicted2.?);
    try testing.expectEqual(2, q.heap.count());
}

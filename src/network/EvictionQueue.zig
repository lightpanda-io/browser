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

        const Map = if (K == []const u8) std.StringHashMapUnmanaged(*Entry) else std.AutoArrayHashMapUnmanaged(K, *Entry);

        const Entry = struct {
            key: K,
            node: std.DoublyLinkedList.Node = .{},
        };

        allocator: Allocator,
        capacity: usize,
        list: std.DoublyLinkedList = .{},
        map: Map = .empty,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            return .{ .allocator = allocator, .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |node| self.allocator.destroy(node.*);
            self.map.deinit(self.allocator);
        }

        pub fn insert(self: *Self, key: K) !?K {
            const entry = try self.allocator.create(Entry);
            entry.* = .{ .key = key };
            try self.map.put(self.allocator, key, entry);
            self.list.append(&entry.node);

            if (self.map.count() <= self.capacity) return null;
            return self.evictOldest();
        }

        pub fn touch(self: *Self, key: K) void {
            const entry = self.map.get(key).?;
            self.list.remove(&entry.node);
            self.list.append(&entry.node);
        }

        fn evictOldest(self: *Self) ?K {
            const node = self.list.popFirst() orelse return null;
            const entry: *Entry = @fieldParentPtr("node", node);
            const key = entry.key;
            _ = self.map.remove(key);
            self.allocator.destroy(entry);
            return key;
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
    try testing.expectEqual(3, q.list.len());
}

test "EvictionQueue: evicts oldest key once over capacity" {
    var q = EvictionQueue([]const u8).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));

    const evicted = try q.insert("c");
    try testing.expect(evicted != null);
    try testing.expectString("a", evicted.?);
    try testing.expectEqual(2, q.list.len());

    const evicted2 = try q.insert("d");
    try testing.expect(evicted2 != null);
    try testing.expectString("b", evicted2.?);
    try testing.expectEqual(2, q.list.len());
}

test "EvictionQueue: touch properly prevents eviction on oldest" {
    var q = EvictionQueue([]const u8).init(testing.allocator, 2);
    defer q.deinit();

    try testing.expectEqual(null, try q.insert("a"));
    try testing.expectEqual(null, try q.insert("b"));
    q.touch("a");

    const evicted = try q.insert("c");
    try testing.expect(evicted != null);
    try testing.expectString("b", evicted.?);
    try testing.expectEqual(2, q.list.len());
    q.touch("a");

    const evicted2 = try q.insert("d");
    try testing.expect(evicted2 != null);
    try testing.expectString("c", evicted2.?);
    try testing.expectEqual(2, q.list.len());
}

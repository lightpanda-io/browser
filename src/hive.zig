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

//! A hive is an efficient data structure that can be preferred over
//! integer keyed hashmaps. Inspired from Bun's HiveArray:
//! https://github.com/oven-sh/bun/blob/main/src/collections/hive_array.zig

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const lp = @import("lightpanda");

pub const StaticOptions = struct {
    /// If set, memory for buckets are reused. Can be good if mutators
    /// (put, remove e.g.) are used excessively.
    pooling: bool = true,
};

/// A static hive can be a good option if max. limits for storage is known
/// but lazy allocation for memory is desired.
pub fn Static(
    comptime T: type,
    comptime count: usize,
    comptime options: StaticOptions,
) type {
    // Sanity check.
    lp.assert(count != 0, "hive: 0-sized hive", .{});
    lp.assert(@sizeOf(T) != 0, "hive: 0-sized type", .{ .type = T });

    return struct {
        const Self = @This();
        const max_bits = @bitSizeOf(u64);
        /// A bucket can take 64 items max.
        const bucket_size = max_bits;
        const Bucket = *[bucket_size]T;
        const bucket_count = (count + max_bits - 1) / max_bits;

        /// Follows what `std.heap.MemoryPool` do.
        const Node = blk: {
            if (options.pooling == false) {
                break :blk void;
            }

            break :blk extern struct {
                next: ?*align(mem.Alignment.of(T).toByteUnits()) @This(),
            };
        };

        /// This is our source of truth. We use this to understand;
        /// if a bucket is empty,
        /// if a key is active.
        lookup: std.bit_set.ArrayBitSet(u64, count),
        /// Where items stored.
        buckets: [bucket_count]Bucket,
        /// If pooling requested, we store unused buckets here.
        pool: if (options.pooling) ?*Node else void,

        /// Initializes a new, empty hive.
        pub const empty = Self{
            .lookup = .initEmpty(),
            .buckets = undefined,
            .pool = if (options.pooling) null else {},
        };

        /// Deinitializes a hive.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            defer self.* = undefined;

            // TODO: Can optimize this to directly free rather than using pool.
            for (self.lookup.masks, 0..) |population, bucket_id| {
                // No population == no allocated memory.
                if (population == 0) continue;
                self.destroyBucket(allocator, self.getBucket(bucket_id));
            }

            if (comptime options.pooling) {
                // If pooling is active, we have to iterate over it also since
                // `destroyBucket` puts buckets back to pool and we may already
                // have returned buckets.
                while (self.pool) |node| {
                    self.pool = node.next;
                    const bucket: Bucket = @ptrCast(node);
                    allocator.free(bucket);
                }
            }
        }

        /// Whether a bucket is empty or not.
        inline fn isEmpty(self: *const Self, bucket_id: usize) bool {
            return self.lookup.masks[bucket_id] == 0;
        }

        /// Returns a bucket by its id.
        inline fn getBucket(self: *const Self, bucket_id: usize) Bucket {
            return self.buckets[bucket_id];
        }

        /// Creates a bucket.
        fn createBucket(self: *Self, allocator: Allocator) Allocator.Error!Bucket {
            if (comptime options.pooling) {
                const node = blk: {
                    // Return the free bucket if we have.
                    if (self.pool) |node| {
                        self.pool = node.next;
                        break :blk node;
                    }

                    // Allocate a new one.
                    const raw = try allocator.alignedAlloc(u8, .of(T), @sizeOf(T) * bucket_size);
                    break :blk @as(*Node, @ptrCast(raw));
                };

                const bucket: Bucket = @ptrCast(node);
                bucket.* = undefined;
                return bucket;
            }

            // If we're not pooling, just create an ordinary bucket.
            return allocator.alloc(T, bucket_size);
        }

        /// Destroys a bucket.
        fn destroyBucket(self: *Self, allocator: Allocator, bucket: Bucket) void {
            // If pooling active, return to pool instead.
            if (comptime options.pooling) {
                const node: *Node = @ptrCast(bucket);
                node.* = .{ .next = self.pool };
                self.pool = node;
                return;
            }

            allocator.free(bucket);
        }

        /// Puts an item to given key; returns a pointer to newly added item.
        pub fn put(self: *Self, allocator: Allocator, k: usize, v: T) Allocator.Error!*T {
            lp.assert(k < count, "hive: key beyond limits", .{ .key = k, .value = v });
            // Find the bucket.
            const bucket_id = k / bucket_size;
            // Allocate memory for bucket if there are no items.
            if (self.isEmpty(bucket_id)) {
                self.buckets[bucket_id] = try self.createBucket(allocator);
            }

            // Save.
            const ptr = &self.getBucket(bucket_id)[k % bucket_size];
            ptr.* = v;
            // Indicate that this slot is now in use.
            self.lookup.set(k);
            return ptr;
        }

        /// Returns the next available key.
        pub fn getKey(self: *const Self) ?usize {
            // This is fast on its own (thanks to @ctz) but can be faster still.
            var it = self.lookup.iterator(.{ .kind = .unset });
            return it.next();
        }

        /// Returns a pointer to item.
        pub fn getPtr(self: *const Self, k: usize) ?*T {
            if (k > count - 1) return null;

            if (self.lookup.isSet(k)) {
                return &self.getBucket(k / bucket_size)[k % bucket_size];
            }

            return null;
        }

        /// Returns an item.
        pub fn get(self: *const Self, k: usize) ?T {
            if (self.lookup.isSet(k)) {
                return self.getBucket(k / bucket_size)[k % bucket_size];
            }

            return null;
        }

        /// Invalidates an item by key; pointers to item are also invalid
        /// after a call to this.
        pub fn remove(self: *Self, allocator: Allocator, k: usize) void {
            const bucket_id = k / bucket_size;
            const was_empty = self.isEmpty(bucket_id);
            // Invalidate.
            self.lookup.unset(k);

            // If bucket wasn't empty and become empty after a removal, we have
            // to free this memory to avoid double-free in deinit.
            if (!was_empty and self.isEmpty(bucket_id)) {
                self.destroyBucket(allocator, self.getBucket(bucket_id));
            }
        }
    };
}

const testing = std.testing;

// Use u64 (8-byte alignment) since the pooling Node reuse requires T's alignment
// to be at least pointer-sized.
const TestHive64 = Static(u64, 64, .{});
const TestHive128 = Static(u64, 128, .{});

test "Static hive - getKey on empty hive" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 0), hive.getKey());
}

test "Static hive - put and get" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    const key = hive.getKey().?;
    const ptr = try hive.put(testing.allocator, key, 42);
    try testing.expectEqual(@as(u64, 42), ptr.*);
    try testing.expectEqual(@as(?u64, 42), hive.get(key));
}

test "Static hive - put and getPtr" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    const key = hive.getKey().?;
    _ = try hive.put(testing.allocator, key, 99);

    const ptr = hive.getPtr(key).?;
    try testing.expectEqual(@as(u64, 99), ptr.*);
}

test "Static hive - get and getPtr on unset key return null" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    try testing.expectEqual(@as(?u64, null), hive.get(0));
    try testing.expectEqual(@as(?*u64, null), hive.getPtr(0));
}

test "Static hive - getPtr returns null for out-of-bounds key" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    // k == count is out of range (valid keys are 0..count-1).
    try testing.expectEqual(@as(?*u64, null), hive.getPtr(64));
}

test "Static hive - remove invalidates key" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    const key = hive.getKey().?;
    _ = try hive.put(testing.allocator, key, 7);
    hive.remove(testing.allocator, key);

    try testing.expectEqual(@as(?u64, null), hive.get(key));
    try testing.expectEqual(@as(?*u64, null), hive.getPtr(key));
    // Slot should be available again.
    try testing.expectEqual(@as(?usize, key), hive.getKey());
}

test "Static hive - sequential keys" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    for (0..10) |i| {
        const key = hive.getKey().?;
        try testing.expectEqual(i, key);
        _ = try hive.put(testing.allocator, key, i);
    }

    for (0..10) |i| {
        try testing.expectEqual(@as(?u64, i), hive.get(i));
    }
}

test "Static hive - full hive returns null from getKey" {
    const N = 64;
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    for (0..N) |i| {
        const key = hive.getKey().?;
        try testing.expectEqual(i, key);
        _ = try hive.put(testing.allocator, key, i);
    }

    try testing.expectEqual(@as(?usize, null), hive.getKey());
}

test "Static hive - cross-bucket keys" {
    var hive = TestHive128.empty;
    defer hive.deinit(testing.allocator);

    // Fill first bucket (keys 0..63).
    for (0..64) |i| {
        const key = hive.getKey().?;
        _ = try hive.put(testing.allocator, key, i * 10);
    }

    // Next available key should be in the second bucket.
    const key64 = hive.getKey().?;
    try testing.expectEqual(@as(usize, 64), key64);
    _ = try hive.put(testing.allocator, key64, 640);

    try testing.expectEqual(@as(?u64, 0), hive.get(0));
    try testing.expectEqual(@as(?u64, 630), hive.get(63));
    try testing.expectEqual(@as(?u64, 640), hive.get(64));
}

test "Static hive - remove frees bucket when last item removed" {
    var hive = TestHive128.empty;
    defer hive.deinit(testing.allocator);

    // Put two items in the second bucket only.
    _ = try hive.put(testing.allocator, 64, 1);
    _ = try hive.put(testing.allocator, 65, 2);

    hive.remove(testing.allocator, 64);
    hive.remove(testing.allocator, 65);

    try testing.expectEqual(@as(?u64, null), hive.get(64));
    try testing.expectEqual(@as(?u64, null), hive.get(65));
}

test "Static hive - put overwrites existing key" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    const key = hive.getKey().?;
    _ = try hive.put(testing.allocator, key, 10);
    _ = try hive.put(testing.allocator, key, 20);

    try testing.expectEqual(@as(?u64, 20), hive.get(key));
}

test "Static hive - bucket reuse after remove with pooling" {
    var hive = TestHive64.empty;
    defer hive.deinit(testing.allocator);

    // Fill and drain a bucket to put it back into the pool.
    for (0..64) |i| {
        _ = try hive.put(testing.allocator, i, i);
    }
    for (0..64) |i| {
        hive.remove(testing.allocator, i);
    }
    // The bucket should now be in the pool. Filling again should reuse it.
    for (0..64) |i| {
        const key = hive.getKey().?;
        _ = try hive.put(testing.allocator, key, i * 2);
    }
    try testing.expectEqual(@as(?u64, 0), hive.get(0));
    try testing.expectEqual(@as(?u64, 126), hive.get(63));
}

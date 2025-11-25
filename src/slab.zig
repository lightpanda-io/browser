const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub fn SlabAllocator(comptime slot_count: usize) type {
    comptime assert(std.math.isPowerOfTwo(slot_count));

    const Slab = struct {
        const Slab = @This();
        const chunk_shift = std.math.log2_int(usize, slot_count);
        const chunk_mask = slot_count - 1;

        alignment: Alignment,
        item_size: usize,

        bitset: std.bit_set.DynamicBitSetUnmanaged,
        chunks: std.ArrayListUnmanaged([]u8),

        pub fn init(
            allocator: Allocator,
            alignment: Alignment,
            item_size: usize,
        ) !Slab {
            return .{
                .alignment = alignment,
                .item_size = item_size,
                .bitset = try .initFull(allocator, 0),
                .chunks = .empty,
            };
        }

        pub fn deinit(self: *Slab, allocator: Allocator) void {
            self.bitset.deinit(allocator);

            for (self.chunks.items) |chunk| {
                allocator.rawFree(chunk, self.alignment, @returnAddress());
            }

            self.chunks.deinit(allocator);
        }

        inline fn toBitsetIndex(chunk_index: usize, slot_index: usize) usize {
            return chunk_index * slot_count + slot_index;
        }

        inline fn chunkIndex(bitset_index: usize) usize {
            return bitset_index >> chunk_shift;
        }

        inline fn slotIndex(bitset_index: usize) usize {
            return bitset_index & chunk_mask;
        }

        fn alloc(self: *Slab, allocator: Allocator) ![]u8 {
            if (self.bitset.findFirstSet()) |index| {
                // if we have a free slot
                const chunk_index = chunkIndex(index);
                const slot_index = slotIndex(index);
                self.bitset.unset(index);

                const chunk = self.chunks.items[chunk_index];
                const offset = slot_index * self.item_size;
                return chunk.ptr[offset..][0..self.item_size];
            } else {
                const old_capacity = self.bitset.bit_length;

                // if we have don't have a free slot
                try self.allocateChunk(allocator);

                const first_slot_index = old_capacity;
                self.bitset.unset(first_slot_index);

                const new_chunk = self.chunks.items[self.chunks.items.len - 1];
                return new_chunk.ptr[0..self.item_size];
            }
        }

        fn free(self: *Slab, ptr: [*]u8) void {
            const addr = @intFromPtr(ptr);

            for (self.chunks.items, 0..) |chunk, i| {
                const chunk_start = @intFromPtr(chunk.ptr);
                const chunk_end = chunk_start + (slot_count * self.item_size);

                if (addr >= chunk_start and addr < chunk_end) {
                    const offset = addr - chunk_start;
                    const slot_index = offset / self.item_size;

                    const bitset_index = toBitsetIndex(i, slot_index);
                    assert(!self.bitset.isSet(bitset_index));

                    self.bitset.set(bitset_index);
                    return;
                }
            }

            unreachable;
        }

        fn allocateChunk(self: *Slab, allocator: Allocator) !void {
            const chunk_len = self.item_size * slot_count;

            const chunk_ptr = allocator.rawAlloc(
                chunk_len,
                self.alignment,
                @returnAddress(),
            ) orelse return error.FailedChildAllocation;

            const chunk = chunk_ptr[0..chunk_len];
            try self.chunks.append(allocator, chunk);

            const new_capacity = self.chunks.items.len * slot_count;
            try self.bitset.resize(allocator, new_capacity, true);
        }
    };

    const SlabKey = struct {
        size: usize,
        alignment: Alignment,
    };

    return struct {
        const Self = @This();

        child_allocator: Allocator,
        slabs: std.ArrayHashMapUnmanaged(SlabKey, Slab, struct {
            const Context = @This();

            pub fn hash(_: Context, key: SlabKey) u32 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, key.size);
                std.hash.autoHash(&hasher, key.alignment);
                return @truncate(hasher.final());
            }

            pub fn eql(_: Context, a: SlabKey, b: SlabKey, _: usize) bool {
                return a.size == b.size and a.alignment == b.alignment;
            }
        }, false) = .empty,

        pub fn init(child_allocator: Allocator) Self {
            return .{
                .child_allocator = child_allocator,
                .slabs = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slabs.values()) |*slab| {
                slab.deinit(self.child_allocator);
            }

            self.slabs.deinit(self.child_allocator);
        }

        pub const ResetKind = enum {
            /// Free all chunks and release all memory.
            clear,
            /// Keep all chunks, reset trees to reuse memory.
            retain_capacity,
        };

        /// This clears all of the stored memory, freeing the currently used chunks.
        pub fn reset(self: *Self, kind: ResetKind) void {
            switch (kind) {
                .clear => {
                    for (self.slabs.values()) |*slab| {
                        for (slab.chunks.items) |chunk| {
                            self.child_allocator.free(chunk);
                        }

                        slab.chunks.clearAndFree(self.child_allocator);
                        slab.bitset.deinit(self.child_allocator);
                    }

                    self.slabs.clearAndFree(self.child_allocator);
                },
                .retain_capacity => {
                    for (self.slabs.values()) |*slab| {
                        slab.bitset.setAll();
                    }
                },
            }
        }

        pub const vtable = Allocator.VTable{
            .alloc = alloc,
            .free = free,
            .remap = Allocator.noRemap,
            .resize = Allocator.noResize,
        };

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = ret_addr;

            const list_gop = self.slabs.getOrPut(
                self.child_allocator,
                SlabKey{ .size = len, .alignment = alignment },
            ) catch return null;

            if (!list_gop.found_existing) {
                list_gop.value_ptr.* = Slab.init(
                    self.child_allocator,
                    alignment,
                    len,
                ) catch return null;
            }

            const list = list_gop.value_ptr;
            const buf = list.alloc(self.child_allocator) catch return null;
            return buf.ptr;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = ret_addr;

            const ptr = memory.ptr;
            const len = memory.len;

            const list = self.slabs.getPtr(.{ .size = len, .alignment = alignment }).?;
            list.free(ptr);
        }
    };
}

const testing = std.testing;

const TestSlabAllocator = SlabAllocator(32);

test "slab allocator - basic allocation and free" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate some memory
    const ptr1 = try allocator.alloc(u8, 100);
    try testing.expect(ptr1.len == 100);

    // Write to it to ensure it's valid
    @memset(ptr1, 42);
    try testing.expectEqual(@as(u8, 42), ptr1[50]);

    // Free it
    allocator.free(ptr1);
}

test "slab allocator - multiple allocations" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    const ptr1 = try allocator.alloc(u8, 64);
    const ptr2 = try allocator.alloc(u8, 128);
    const ptr3 = try allocator.alloc(u8, 256);

    // Ensure they don't overlap
    const addr1 = @intFromPtr(ptr1.ptr);
    const addr2 = @intFromPtr(ptr2.ptr);
    const addr3 = @intFromPtr(ptr3.ptr);

    try testing.expect(addr1 + 64 <= addr2 or addr2 + 128 <= addr1);
    try testing.expect(addr2 + 128 <= addr3 or addr3 + 256 <= addr2);

    allocator.free(ptr1);
    allocator.free(ptr2);
    allocator.free(ptr3);
}

test "slab allocator - no coalescing (different size classes)" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate two blocks of same size
    const ptr1 = try allocator.alloc(u8, 128);
    const ptr2 = try allocator.alloc(u8, 128);

    // Free them (no coalescing in slab allocator)
    allocator.free(ptr1);
    allocator.free(ptr2);

    // Can't allocate larger block from these freed 128-byte blocks
    const ptr3 = try allocator.alloc(u8, 256);

    // ptr3 will be from a different size class, not coalesced from ptr1+ptr2
    const addr1 = @intFromPtr(ptr1.ptr);
    const addr3 = @intFromPtr(ptr3.ptr);

    // They should NOT be adjacent (different size classes)
    try testing.expect(addr3 < addr1 or addr3 >= addr1 + 256);

    allocator.free(ptr3);
}

test "slab allocator - reuse freed memory" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    const ptr1 = try allocator.alloc(u8, 64);
    const addr1 = @intFromPtr(ptr1.ptr);
    allocator.free(ptr1);

    // Allocate same size, should reuse from same slab
    const ptr2 = try allocator.alloc(u8, 64);
    const addr2 = @intFromPtr(ptr2.ptr);

    try testing.expectEqual(addr1, addr2);
    allocator.free(ptr2);
}

test "slab allocator - multiple size classes" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate various sizes - each creates a new slab
    var ptrs: [10][]u8 = undefined;
    const sizes = [_]usize{ 24, 40, 64, 88, 128, 144, 200, 256, 512, 1000 };

    for (&ptrs, sizes) |*ptr, size| {
        ptr.* = try allocator.alloc(u8, size);
        @memset(ptr.*, 0xFF);
    }

    // Should have created multiple slabs
    try testing.expect(slab_alloc.slabs.count() >= 10);

    // Free all
    for (ptrs) |ptr| {
        allocator.free(ptr);
    }
}

test "slab allocator - various sizes" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Test different sizes (not limited to powers of 2!)
    const sizes = [_]usize{ 8, 16, 24, 32, 40, 64, 88, 128, 144, 256 };

    for (sizes) |size| {
        const ptr = try allocator.alloc(u8, size);
        try testing.expect(ptr.len == size);
        @memset(ptr, @intCast(size & 0xFF));
        allocator.free(ptr);
    }
}

test "slab allocator - exact sizes (no rounding)" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Odd sizes stay exact (unlike buddy which rounds to power of 2)
    const ptr1 = try allocator.alloc(u8, 100);
    const ptr2 = try allocator.alloc(u8, 200);
    const ptr3 = try allocator.alloc(u8, 50);

    // Exact sizes!
    try testing.expect(ptr1.len == 100);
    try testing.expect(ptr2.len == 200);
    try testing.expect(ptr3.len == 50);

    allocator.free(ptr1);
    allocator.free(ptr2);
    allocator.free(ptr3);
}

test "slab allocator - chunk allocation" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate many items of same size to force multiple chunks
    var ptrs: [100][]u8 = undefined;
    for (&ptrs) |*ptr| {
        ptr.* = try allocator.alloc(u8, 64);
    }

    // Should have allocated multiple chunks (32 items per chunk)
    const slab = slab_alloc.slabs.getPtr(.{ .size = 64, .alignment = Alignment.@"1" }).?;
    try testing.expect(slab.chunks.items.len > 1);

    // Free all
    for (ptrs) |ptr| {
        allocator.free(ptr);
    }
}

test "slab allocator - reset with retain_capacity" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate some memory
    const ptr1 = try allocator.alloc(u8, 128);
    const ptr2 = try allocator.alloc(u8, 256);
    _ = ptr1;
    _ = ptr2;

    const slabs_before = slab_alloc.slabs.count();
    const slab_128 = slab_alloc.slabs.getPtr(.{ .size = 128, .alignment = Alignment.@"1" }).?;
    const chunks_before = slab_128.chunks.items.len;

    // Reset but keep chunks
    slab_alloc.reset(.retain_capacity);

    try testing.expectEqual(slabs_before, slab_alloc.slabs.count());
    try testing.expectEqual(chunks_before, slab_128.chunks.items.len);

    // Should be able to allocate again
    const ptr3 = try allocator.alloc(u8, 512);
    allocator.free(ptr3);
}

test "slab allocator - reset with clear" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate some memory
    const ptr1 = try allocator.alloc(u8, 128);
    _ = ptr1;

    try testing.expect(slab_alloc.slabs.count() > 0);

    // Reset and free everything
    slab_alloc.reset(.clear);

    try testing.expectEqual(@as(usize, 0), slab_alloc.slabs.count());

    // Should still work after reset
    const ptr2 = try allocator.alloc(u8, 256);
    allocator.free(ptr2);
}

test "slab allocator - stress test" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var ptrs: std.ArrayList([]u8) = .empty;

    defer {
        for (ptrs.items) |ptr| {
            allocator.free(ptr);
        }
        ptrs.deinit(allocator);
    }

    // Random allocations and frees
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (random.boolean() and ptrs.items.len > 0) {
            // Free a random allocation
            const index = random.uintLessThan(usize, ptrs.items.len);
            allocator.free(ptrs.swapRemove(index));
        } else {
            // Allocate random size (8 to 512)
            const size = random.uintAtMost(usize, 504) + 8;
            const ptr = try allocator.alloc(u8, size);
            try ptrs.append(allocator, ptr);

            // Write to ensure it's valid
            @memset(ptr, @intCast(i & 0xFF));
        }
    }
}

test "slab allocator - alignment" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    const ptr1 = try allocator.create(u64);
    const ptr2 = try allocator.create(u32);
    const ptr3 = try allocator.create([100]u8);

    allocator.destroy(ptr1);
    allocator.destroy(ptr2);
    allocator.destroy(ptr3);
}

test "slab allocator - no resize support" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    const slice = try allocator.alloc(u8, 100);
    @memset(slice, 42);

    // Resize should fail (not supported)
    try testing.expect(!allocator.resize(slice, 90));
    try testing.expect(!allocator.resize(slice, 200));

    allocator.free(slice);
}

test "slab allocator - fragmentation pattern" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate 10 items
    var items: [10][]u8 = undefined;
    for (&items) |*item| {
        item.* = try allocator.alloc(u8, 64);
        @memset(item.*, 0xFF);
    }

    // Free every other one
    allocator.free(items[0]);
    allocator.free(items[2]);
    allocator.free(items[4]);
    allocator.free(items[6]);
    allocator.free(items[8]);

    // Allocate new items - should reuse freed slots
    const new1 = try allocator.alloc(u8, 64);
    const new2 = try allocator.alloc(u8, 64);
    const new3 = try allocator.alloc(u8, 64);

    // Should get some of the freed slots back
    const addrs = [_]usize{
        @intFromPtr(items[0].ptr),
        @intFromPtr(items[2].ptr),
        @intFromPtr(items[4].ptr),
        @intFromPtr(items[6].ptr),
        @intFromPtr(items[8].ptr),
    };

    const new1_addr = @intFromPtr(new1.ptr);
    var found = false;
    for (addrs) |addr| {
        if (new1_addr == addr) found = true;
    }
    try testing.expect(found);

    // Cleanup
    allocator.free(items[1]);
    allocator.free(items[3]);
    allocator.free(items[5]);
    allocator.free(items[7]);
    allocator.free(items[9]);
    allocator.free(new1);
    allocator.free(new2);
    allocator.free(new3);
}

test "slab allocator - many small allocations" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate 1000 small items
    var ptrs: std.ArrayList([]u8) = .empty;
    defer {
        for (ptrs.items) |ptr| {
            allocator.free(ptr);
        }
        ptrs.deinit(allocator);
    }

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const ptr = try allocator.alloc(u8, 24);
        try ptrs.append(allocator, ptr);
    }

    // Should have created multiple chunks
    const slab = slab_alloc.slabs.getPtr(.{ .size = 24, .alignment = Alignment.@"1" }).?;
    try testing.expect(slab.chunks.items.len > 10);
}

test "slab allocator - zero waste for exact sizes" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // These sizes have zero internal fragmentation (unlike buddy)
    const sizes = [_]usize{ 24, 40, 56, 88, 144, 152, 184, 232, 648 };

    for (sizes) |size| {
        const ptr = try allocator.alloc(u8, size);

        // Exact size returned!
        try testing.expectEqual(size, ptr.len);

        @memset(ptr, 0xFF);
        allocator.free(ptr);
    }
}

test "slab allocator - different size classes don't interfere" {
    var slab_alloc = TestSlabAllocator.init(testing.allocator);
    defer slab_alloc.deinit();

    const allocator = slab_alloc.allocator();

    // Allocate size 64
    const ptr_64 = try allocator.alloc(u8, 64);
    const addr_64 = @intFromPtr(ptr_64.ptr);
    allocator.free(ptr_64);

    // Allocate size 128 - should NOT reuse size-64 slot
    const ptr_128 = try allocator.alloc(u8, 128);
    const addr_128 = @intFromPtr(ptr_128.ptr);

    try testing.expect(addr_64 != addr_128);

    // Allocate size 64 again - SHOULD reuse original slot
    const ptr_64_again = try allocator.alloc(u8, 64);
    const addr_64_again = @intFromPtr(ptr_64_again.ptr);

    try testing.expectEqual(addr_64, addr_64_again);

    allocator.free(ptr_128);
    allocator.free(ptr_64_again);
}

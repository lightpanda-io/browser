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

// Allocator for the Factory. Almost everything allocated here lives until the
// child arena goes: DOM nodes are never destroyed. The frees that do happen
// are mostly GC-finalized wrappers (collections, iterators), in batches.
//
// So an allocation is a plain allocation from the child (an arena), and a freed
// slot goes on the free list for its class, to be handed to the next
// allocation of that class. The free lists are only looked at once something
// has been freed. Nothing is ever returned to the child.

const std = @import("std");
const lp = @import("lightpanda");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const RecyclingAllocator = @This();

child_allocator: Allocator,

// Slots currently sitting on a free list. While 0, alloc skips the lookup.
free_slots: usize = 0,
free_lists: std.array_hash_map.Custom(Class, ?[*]u8, Class.Context, false) = .empty,

// Every slot can hold the free-list link. Alignments below usize's share a
// class, e.g. a 34-byte string and a 40-byte node recycle each other.
const Class = packed struct(u64) {
    alignment: Alignment,
    size: std.meta.Int(.unsigned, 64 - @bitSizeOf(Alignment)),

    fn of(len: usize, alignment: Alignment) Class {
        const class_alignment = Alignment.max(alignment, .of(usize));
        return .{
            .size = @intCast(class_alignment.forward(@max(len, @sizeOf(usize)))),
            .alignment = class_alignment,
        };
    }

    const Context = struct {
        pub fn hash(_: Context, class: Class) u32 {
            // A few dozen classes per page: a multiply spreads them well enough.
            return @truncate((@as(u64, @bitCast(class)) *% 0x9e3779b97f4a7c15) >> 32);
        }

        pub fn eql(_: Context, a: Class, b: Class, _: usize) bool {
            return a == b;
        }
    };
};

const Link = *align(1) ?[*]u8;

pub fn init(child_allocator: Allocator) RecyclingAllocator {
    return .{ .child_allocator = child_allocator };
}

pub fn allocator(self: *RecyclingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .free = free,
            .remap = Allocator.noRemap,
            .resize = Allocator.noResize,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *RecyclingAllocator = @ptrCast(@alignCast(ctx));
    const class = Class.of(len, alignment);

    if (self.free_slots > 0) {
        if (self.free_lists.getPtr(class)) |head| {
            if (head.*) |slot| {
                head.* = @as(Link, @ptrCast(slot)).*;
                self.free_slots -= 1;
                return slot;
            }
        }
    }

    return self.child_allocator.rawAlloc(class.size, class.alignment, ret_addr);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const self: *RecyclingAllocator = @ptrCast(@alignCast(ctx));
    const class = Class.of(memory.len, alignment);

    // On OOM the slot just isn't recycled; the child still owns it.
    const gop = self.free_lists.getOrPut(self.child_allocator, class) catch return;
    if (gop.found_existing == false) {
        gop.value_ptr.* = null;
    }

    const slot = memory.ptr;
    if (comptime lp.IS_DEBUG) {
        // Make a use-after-free read garbage rather than the old object.
        @memset(slot[0..class.size], undefined);
    }
    @as(Link, @ptrCast(slot)).* = gop.value_ptr.*;
    gop.value_ptr.* = slot;
    self.free_slots += 1;
}

const testing = @import("testing.zig");
const TestAllocator = struct {
    arena: std.heap.ArenaAllocator,
    recycling: RecyclingAllocator,

    fn init(self: *TestAllocator) void {
        self.arena = .init(testing.allocator);
        self.recycling = .init(self.arena.allocator());
    }

    fn deinit(self: *TestAllocator) void {
        self.arena.deinit();
    }
};

test "RecyclingAllocator: allocation without frees never touches the free lists" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    for (0..100) |i| {
        const ptr = try recycler.alloc(u8, 24 + i);
        @memset(ptr, 42);
    }

    try testing.expectEqual(0, t.recycling.free_lists.count());
}

test "RecyclingAllocator: reuses freed memory of the same class" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    const ptr1 = try recycler.alloc(u8, 64);
    recycler.free(ptr1);

    const ptr2 = try recycler.alloc(u8, 64);
    try testing.expect(ptr1.ptr == ptr2.ptr);

    // free list is LIFO
    const a = try recycler.alloc(u8, 64);
    const b = try recycler.alloc(u8, 64);
    recycler.free(a);
    recycler.free(b);
    try testing.expectEqual(2, t.recycling.free_slots);
    try testing.expect(b.ptr == (try recycler.alloc(u8, 64)).ptr);
    try testing.expect(a.ptr == (try recycler.alloc(u8, 64)).ptr);
    try testing.expectEqual(0, t.recycling.free_slots);
}

test "RecyclingAllocator: different classes don't interfere" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    const ptr_64 = try recycler.alloc(u8, 64);
    recycler.free(ptr_64);

    const ptr_128 = try recycler.alloc(u8, 128);
    try testing.expect(ptr_64.ptr != ptr_128.ptr);

    try testing.expect(ptr_64.ptr == (try recycler.alloc(u8, 64)).ptr);
}

test "RecyclingAllocator: sizes share a class after rounding" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    // 34 and 40 bytes both round to 40, even at alignment 1
    const small = try recycler.alloc(u8, 34);
    recycler.free(small);
    const ptr = try recycler.alignedAlloc(u8, .@"8", 40);
    try testing.expect(small.ptr == ptr.ptr);

    // anything smaller than a pointer still fits the free-list link
    const tiny = try recycler.alloc(u8, 1);
    recycler.free(tiny);
    try testing.expect(tiny.ptr == (try recycler.alloc(u8, 3)).ptr);

    // u64 and u32 share the 8-byte class
    const int64 = try recycler.create(u64);
    recycler.destroy(int64);
    try testing.expectEqual(@intFromPtr(int64), @intFromPtr(try recycler.create(u32)));
}

test "RecyclingAllocator: never hands out a slot with weaker alignment" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    const ptr8 = try recycler.alignedAlloc(u8, .@"8", 64);
    recycler.free(ptr8);

    const ptr32 = try recycler.alignedAlloc(u8, .@"32", 64);
    try testing.expect(std.mem.isAligned(@intFromPtr(ptr32.ptr), 32));
    try testing.expect(ptr8.ptr != ptr32.ptr);
}

test "RecyclingAllocator: no resize support" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    const slice = try recycler.alloc(u8, 100);
    try testing.expect(!recycler.resize(slice, 90));
    try testing.expect(!recycler.resize(slice, 200));
}

test "RecyclingAllocator: stress" {
    var t: TestAllocator = undefined;
    t.init();
    defer t.deinit();
    const recycler = t.recycling.allocator();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var live: std.ArrayList([]u8) = .empty;
    defer live.deinit(testing.allocator);

    var frees: usize = 0;
    for (0..2000) |_| {
        if (random.boolean() and live.items.len > 0) {
            const slice = live.swapRemove(random.uintLessThan(usize, live.items.len));
            // still holds what we wrote: the slot wasn't handed out twice
            for (slice) |b| try testing.expectEqual(@as(u8, @truncate(slice.len)), b);
            recycler.free(slice);
            frees += 1;
        } else {
            const slice = try recycler.alloc(u8, random.uintAtMost(usize, 256) + 1);
            @memset(slice, @truncate(slice.len));
            try live.append(testing.allocator, slice);
        }
    }

    // some frees were handed back out
    try testing.expect(t.recycling.free_slots < frees);
}

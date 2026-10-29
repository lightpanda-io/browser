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

// A single-threaded std.heap.ArenaAllocator. Same API and the same reset
// semantics, minus the atomics std needs to be thread-safe.
//
// Allocation bumps `cur` towards `end`, both of which point into the newest
// node. A reset that has nothing to give back (a single node already within
// the retain limit) is O(1), so resetting an arena that wasn't used is cheap.

// This came from digging into the known slow WPT tests:
//    `dom/nodes/NodeList-static-length-getter-tampered-*`
// The idea was to skip resetting the arena in Caller.deinit if nothing had
// been allocated (because std's ArenaAllocator reset isn't as cheap as it
// could be in that case). Investigating why this was led to the fact that
// in Zig 0.16 ArenaAllocator became thread-safe. Benchmarking this, using
// those WPT tests, showed that a singled-threaded allocator would give us a
// ~10% improvement in those specific tests.
// The design is similar to the 0.15 ArenaAllocator, but it's designed so that
// reset on no-allocation is cheaper.

const std = @import("std");

const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const ArenaAllocator = @This();

child_allocator: Allocator,

// Newest node first. Allocations only ever come from this one.
first: ?*Node = null,

// The free range of `first`'s buffer, as addresses. Both 0 when there's no
// node, which makes every allocation take the slow path without a null check.
cur: usize = 0,
end: usize = 0,

const Node = struct {
    next: ?*Node,
    // Bytes allocated from the child, including this header.
    size: usize,

    fn allocatedSlice(node: *Node) []u8 {
        return @as([*]u8, @ptrCast(node))[0..node.size];
    }

    fn bufStart(node: *Node) usize {
        return @intFromPtr(node) + @sizeOf(Node);
    }

    fn capacity(node: *const Node) usize {
        return node.size - @sizeOf(Node);
    }
};

pub fn init(child_allocator: Allocator) ArenaAllocator {
    return .{ .child_allocator = child_allocator };
}

pub fn deinit(self: ArenaAllocator) void {
    var it = self.first;
    while (it) |node| {
        it = node.next;
        self.child_allocator.rawFree(node.allocatedSlice(), .of(Node), @returnAddress());
    }
}

pub fn allocator(self: *ArenaAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

// Memory held from the child, excluding node headers.
pub fn queryCapacity(self: *const ArenaAllocator) usize {
    var capacity: usize = 0;
    var it = self.first;
    while (it) |node| : (it = node.next) {
        capacity += node.capacity();
    }
    return capacity;
}

pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

// Frees every allocation. Returns false only if `retain_*` couldn't preheat
// the arena; it is still usable then, just colder.
pub fn reset(self: *ArenaAllocator, mode: ResetMode) bool {
    const limit: usize = switch (mode) {
        .free_all => {
            self.deinit();
            self.first = null;
            self.cur = 0;
            self.end = 0;
            return true;
        },
        .retain_capacity => std.math.maxInt(usize),
        .retain_with_limit => |limit| limit,
    };

    const first = self.first orelse return true;
    if (first.next == null and first.capacity() <= limit) {
        // The common case once an arena has warmed up: nothing to free or
        // resize, just rewind.
        self.cur = first.bufStart();
        return true;
    }
    return self.resetSlow(first, limit);
}

fn resetSlow(self: *ArenaAllocator, first: *Node, limit: usize) bool {
    @branchHint(.cold);

    const child = self.child_allocator;
    const total = self.queryCapacity();

    // Keep the newest (largest) node, give back the rest.
    var it = first.next;
    while (it) |node| {
        it = node.next;
        child.rawFree(node.allocatedSlice(), .of(Node), @returnAddress());
    }
    first.next = null;

    const new_size = mem.alignBackward(usize, @sizeOf(Node) + @min(limit, total), @alignOf(Node));
    if (new_size <= @sizeOf(Node)) {
        child.rawFree(first.allocatedSlice(), .of(Node), @returnAddress());
        self.first = null;
        self.cur = 0;
        self.end = 0;
        return true;
    }

    var ok = true;
    var node = first;
    if (node.size != new_size) {
        // Grow in place, but never shrink in place: std.heap.c_allocator
        // reports any shrink as done without telling libc, so the whole block
        // would stay allocated and the arena would keep its largest node.
        if (new_size > node.size and child.rawResize(node.allocatedSlice(), .of(Node), new_size, @returnAddress())) {
            node.size = new_size;
        } else if (child.rawAlloc(new_size, .of(Node), @returnAddress())) |ptr| {
            child.rawFree(node.allocatedSlice(), .of(Node), @returnAddress());
            node = @ptrCast(@alignCast(ptr));
            node.* = .{ .next = null, .size = new_size };
        } else {
            // Keep what we have.
            ok = false;
        }
    }
    self.setFirst(node);
    return ok;
}

fn setFirst(self: *ArenaAllocator, node: *Node) void {
    self.first = node;
    self.cur = node.bufStart();
    self.end = @intFromPtr(node) + node.size;
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = ret_addr;

    const addr = alignment.forward(self.cur);
    const new_cur = addr +% n;
    if (new_cur <= self.end and new_cur >= addr) {
        self.cur = new_cur;
        return @ptrFromInt(addr);
    }
    return self.allocSlow(n, alignment);
}

noinline fn allocSlow(self: *ArenaAllocator, n: usize, alignment: Alignment) ?[*]u8 {
    const child = self.child_allocator;
    const prev_capacity: usize = if (self.first) |node| node.capacity() else 0;

    // Same growth curve as std: half again the previous node, plus the request.
    const min_size = @sizeOf(Node) + alignment.toByteUnits() + n;
    const big_enough = prev_capacity + min_size + 16;
    const size = mem.alignForward(usize, big_enough + big_enough / 2, @alignOf(Node));

    // Grow the current node in place by the full step rather than just
    // enough for `n`. c_allocator grows a node in place up to its usable
    // size: growing by just `n` would succeed and bring every allocation back
    // here until that slack runs out.
    if (self.first) |node| {
        if (child.rawResize(node.allocatedSlice(), .of(Node), size, @returnAddress())) {
            node.size = size;
            self.end = @intFromPtr(node) + size;
            return self.bump(n, alignment);
        }
    }

    const ptr = child.rawAlloc(size, .of(Node), @returnAddress()) orelse return null;
    const node: *Node = @ptrCast(@alignCast(ptr));
    node.* = .{ .next = self.first, .size = size };
    self.setFirst(node);
    return self.bump(n, alignment);
}

// Only after allocSlow has made room.
fn bump(self: *ArenaAllocator, n: usize, alignment: Alignment) [*]u8 {
    const addr = alignment.forward(self.cur);
    std.debug.assert(addr + n <= self.end);
    self.cur = addr + n;
    return @ptrFromInt(addr);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    const start = @intFromPtr(memory.ptr);
    if (start + memory.len != self.cur) {
        // Not the most recent allocation: can shrink (by doing nothing), can't grow.
        return new_len <= memory.len;
    }

    if (new_len <= memory.len or new_len - memory.len <= self.end - self.cur) {
        self.cur = start + new_len;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    // Only the most recent allocation can be given back.
    if (@intFromPtr(memory.ptr) + memory.len == self.cur) {
        self.cur = @intFromPtr(memory.ptr);
    }
}

const testing = std.testing;

test "ArenaAllocator: alloc, alignment and growth" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = rng.random();
    for (0..2000) |_| {
        const size = random.intRangeAtMost(usize, 1, 3000);
        const slice = try a.alignedAlloc(u8, .@"32", size);
        try testing.expect(Alignment.@"32".check(@intFromPtr(slice.ptr)));
        @memset(slice, 0xAA);
    }
    try testing.expect(arena.first.?.next != null);
}

test "ArenaAllocator: reset with preheating" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var rng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = rng.random();
    for (0..25) |_| {
        _ = arena.reset(.retain_capacity);
        var allocated: usize = 0;
        const total = random.intRangeAtMost(usize, 256, 16384);
        while (allocated < total) {
            const size = random.intRangeAtMost(usize, 16, 256);
            const slice = try arena.allocator().alignedAlloc(u8, .@"32", size);
            try testing.expect(Alignment.@"32".check(@intFromPtr(slice.ptr)));
            allocated += slice.len;
        }
    }
    // After warming up, everything fits in one node.
    _ = arena.reset(.retain_capacity);
    try testing.expect(arena.first.?.next == null);
}

test "ArenaAllocator: reset while retaining a buffer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 1);
    while (arena.first.?.next == null) {
        _ = try a.alloc(u8, 1000);
    }

    try testing.expect(arena.reset(.{ .retain_with_limit = 16 }));
    try testing.expect(arena.first.?.next == null);
    try testing.expectEqual(16, arena.queryCapacity());
}

test "ArenaAllocator: reset of an unused arena" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expect(arena.reset(.{ .retain_with_limit = 1024 }));
    try testing.expect(arena.first == null);

    const one = try arena.allocator().alloc(u8, 100);
    const node = arena.first.?;
    try testing.expect(arena.reset(.{ .retain_with_limit = 1024 }));
    try testing.expectEqual(node, arena.first.?);
    try testing.expectEqual(node.bufStart(), arena.cur);

    // Rewound: the next allocation reuses the same memory.
    const two = try arena.allocator().alloc(u8, 100);
    try testing.expectEqual(one.ptr, two.ptr);

    try testing.expect(arena.reset(.free_all));
    try testing.expect(arena.first == null);
    try testing.expect(arena.reset(.free_all));
}

test "ArenaAllocator: limit shrinks a large single node" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.allocator().alloc(u8, 10_000);
    try testing.expect(arena.queryCapacity() > 1024);
    try testing.expect(arena.reset(.{ .retain_with_limit = 1024 }));
    try testing.expectEqual(1024, arena.queryCapacity());

    try testing.expect(arena.reset(.{ .retain_with_limit = 0 }));
    try testing.expect(arena.first == null);
}

// Like std.heap.c_allocator: a shrink reports success but the whole block
// stays allocated. `held` is what the child really holds.
const KeepsBlockOnShrink = struct {
    child: Allocator,
    held: usize = 0,
    blocks: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    fn deinit(self: *KeepsBlockOnShrink) void {
        self.blocks.deinit(self.child);
    }

    fn allocator(self: *KeepsBlockOnShrink) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = keepAlloc,
            .resize = keepResize,
            .remap = Allocator.noRemap,
            .free = keepFree,
        } };
    }

    fn keepAlloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *KeepsBlockOnShrink = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(n, alignment, ra) orelse return null;
        self.blocks.put(self.child, @intFromPtr(ptr), n) catch {
            self.child.rawFree(ptr[0..n], alignment, ra);
            return null;
        };
        self.held += n;
        return ptr;
    }

    fn keepResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        return new_len <= memory.len;
    }

    fn keepFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *KeepsBlockOnShrink = @ptrCast(@alignCast(ctx));
        const n = self.blocks.fetchRemove(@intFromPtr(memory.ptr)).?.value;
        self.child.rawFree(memory.ptr[0..n], alignment, ra);
        self.held -= n;
    }
};

test "ArenaAllocator: a reset with a limit gives back the block it can't keep" {
    var child: KeepsBlockOnShrink = .{ .child = testing.allocator };
    defer child.deinit();
    var arena = ArenaAllocator.init(child.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    // One node past the limit.
    _ = try a.alloc(u8, 64 * 1024);
    try testing.expect(arena.reset(.{ .retain_with_limit = 1024 }));
    try testing.expectEqual(1024, arena.queryCapacity());
    try testing.expectEqual(@sizeOf(Node) + 1024, child.held);

    // Several nodes past the limit.
    while (arena.first.?.next == null) {
        _ = try a.alloc(u8, 1000);
    }
    try testing.expect(arena.reset(.{ .retain_with_limit = 1024 }));
    try testing.expectEqual(1024, arena.queryCapacity());
    try testing.expectEqual(@sizeOf(Node) + 1024, child.held);

    // What's kept is still usable up to the limit without the child.
    const before = child.held;
    const buf = try a.alloc(u8, 1024);
    @memset(buf, 0xAA);
    try testing.expectEqual(before, child.held);
}

test "ArenaAllocator: growth past a reset limit doesn't take the slow path per allocation" {
    // With c_allocator, refilling an arena past its retain_with_limit reset:
    // each slow path grows by a full step.
    var arena = ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 64 * 1024);
    try testing.expect(arena.reset(.{ .retain_with_limit = 16 * 1024 }));

    var slow: usize = 0;
    var end = arena.end;
    for (0..1000) |_| {
        _ = try a.alloc(u8, 48);
        if (arena.end != end) {
            slow += 1;
            end = arena.end;
        }
    }
    try testing.expect(slow < 5);
}

test "ArenaAllocator: resize and free of the last allocation" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 1); // so the next allocation isn't at the buffer start
    var buf = try a.alloc(u8, 10);
    const before = arena.cur;

    try testing.expect(a.resize(buf, 20));
    buf = buf.ptr[0..20];
    try testing.expectEqual(before + 10, arena.cur);

    try testing.expect(a.resize(buf, 5));
    buf = buf.ptr[0..5];
    try testing.expectEqual(before - 5, arena.cur);

    a.free(buf);
    try testing.expectEqual(@intFromPtr(buf.ptr), arena.cur);

    // Not the last allocation: shrink is a no-op success, grow fails.
    const x = try a.alloc(u8, 8);
    _ = try a.alloc(u8, 8);
    try testing.expect(a.resize(x, 4));
    try testing.expect(a.resize(x, 16) == false);

    // Growing past the node's end fails.
    const last = try a.alloc(u8, 8);
    try testing.expect(a.resize(last, 1 << 30) == false);
}

test "ArenaAllocator: ArrayList growth" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..10_000) |i| {
        try list.append(a, @intCast(i));
    }
    for (list.items, 0..) |v, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), v);
    }
}

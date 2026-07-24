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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const log = lp.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const NativeMemoryAccount = @import("browser/NativeMemoryAccount.zig");

const ArenaPool = @This();

const IS_DEBUG = builtin.mode == .Debug;

// In Debug, disable pooling to better catch UAF.
const SAFETY = IS_DEBUG == true and builtin.is_test == false;

pub const BucketSize = enum { tiny, small, medium, large };

const Bucket = struct {
    free_list: ?*Entry = null,
    free_list_len: u16 = 0,
    free_list_max: u16,
    retain_bytes: usize,
};

const Entry = struct {
    next: ?*Entry,
    arena: ArenaAllocator,
    bucket: *Bucket,
    parent_allocator: Allocator,
    owner: std.atomic.Value(?*NativeMemoryAccount) = .init(null),
    allocated_bytes: std.atomic.Value(usize) = .init(0),
    debug: if (IS_DEBUG) []const u8 else void = if (IS_DEBUG) "" else {},

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Entry) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setOwner(self: *Entry, owner: ?*NativeMemoryAccount) void {
        std.debug.assert(self.owner.load(.acquire) == null);
        self.owner.store(owner, .release);
        if (owner) |account| {
            const bytes = self.allocated_bytes.load(.acquire);
            account.add(bytes);
            lp.metrics.browser_native_memory_bytes.incrBy(bytes);
        }
    }

    fn clearOwner(self: *Entry) void {
        const owner = self.owner.swap(null, .acq_rel) orelse return;
        const bytes = self.allocated_bytes.load(.acquire);
        owner.remove(bytes);
        lp.metrics.browser_native_memory_bytes.decrBy(bytes);
    }

    fn addBytes(self: *Entry, bytes: usize) void {
        if (bytes == 0) return;
        _ = self.allocated_bytes.fetchAdd(bytes, .monotonic);
        if (self.owner.load(.acquire)) |owner| {
            owner.add(bytes);
            lp.metrics.browser_native_memory_bytes.incrBy(bytes);
        }
    }

    fn removeBytes(self: *Entry, bytes: usize) void {
        if (bytes == 0) return;
        const previous = self.allocated_bytes.fetchSub(bytes, .monotonic);
        std.debug.assert(previous >= bytes);
        if (self.owner.load(.acquire)) |owner| {
            owner.remove(bytes);
            lp.metrics.browser_native_memory_bytes.decrBy(bytes);
        }
    }

    fn adjustBytes(self: *Entry, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.addBytes(new_len - old_len);
        } else {
            self.removeBytes(old_len - new_len);
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Entry = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, alignment, return_address) orelse return null;
        self.addBytes(len);
        return result;
    }

    fn resize(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *Entry = @ptrCast(@alignCast(ctx));
        if (!self.parent_allocator.rawResize(old_mem, alignment, new_len, return_address)) return false;
        self.adjustBytes(old_mem.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *Entry = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawRemap(old_mem, alignment, new_len, return_address) orelse return null;
        self.adjustBytes(old_mem.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Entry = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(old_mem, alignment, return_address);
        self.removeBytes(old_mem.len);
    }
};

pub const Config = struct {
    tiny: Config.Bucket = .{ .max = 512, .retain = 1024 },
    small: Config.Bucket = .{ .max = 128, .retain = 4 * 1024 },
    medium: Config.Bucket = .{ .max = 64, .retain = 16 * 1024 },
    large: Config.Bucket = .{ .max = 32, .retain = 128 * 1024 },

    const Bucket = struct {
        max: u16,
        retain: usize,
    };
};

tiny: Bucket,
small: Bucket,
medium: Bucket,
large: Bucket,
allocator: Allocator,
mutex: std.Io.Mutex = .init,
entry_pool: std.heap.memory_pool.ExtraManaged(Entry, .{}),

_leak_track: if (IS_DEBUG) std.StringHashMapUnmanaged(isize) else void = if (IS_DEBUG) .empty else {},

pub fn init(allocator: Allocator, config: Config) ArenaPool {
    return .{
        .allocator = allocator,
        .entry_pool = .init(allocator),
        .tiny = .{ .free_list_max = config.tiny.max, .retain_bytes = config.tiny.retain },
        .small = .{ .free_list_max = config.small.max, .retain_bytes = config.small.retain },
        .medium = .{ .free_list_max = config.medium.max, .retain_bytes = config.medium.retain },
        .large = .{ .free_list_max = config.large.max, .retain_bytes = config.large.retain },
    };
}

pub fn deinit(self: *ArenaPool) void {
    if (IS_DEBUG) {
        var has_leaks = false;
        var it = self._leak_track.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != 0) {
                log.err(.bug, "ArenaPool leak", .{ .name = kv.key_ptr.*, .count = kv.value_ptr.* });
                has_leaks = true;
            }
        }
        if (has_leaks) {
            @panic("ArenaPool: leaked arenas detected");
        }
        self._leak_track.deinit(self.allocator);
    }

    // Free all arenas in all buckets
    inline for (&[_]*Bucket{ &self.tiny, &self.small, &self.medium, &self.large }) |bucket| {
        var entry = bucket.free_list;
        while (entry) |e| {
            entry = e.next;
            e.arena.deinit();
        }
    }
    self.entry_pool.deinit();
}

// Acquire an arena from the pool.
// - Pass a BucketSize (.tiny, .small, .medium, .large) for explicit bucket selection
// - Pass a usize for automatic bucket selection based on expected size
pub fn acquire(self: *ArenaPool, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.acquireFor(null, size_or_bucket, debug);
}

pub fn acquireFor(self: *ArenaPool, owner: ?*NativeMemoryAccount, size_or_bucket: anytype, debug: []const u8) !Allocator {
    const bucket_size: BucketSize = blk: {
        const T = @TypeOf(size_or_bucket);
        if (T == BucketSize or T == @TypeOf(.enum_literal)) {
            break :blk @as(BucketSize, size_or_bucket);
        }
        if (T == usize or T == comptime_int) {
            if (size_or_bucket <= self.tiny.retain_bytes) break :blk .tiny;
            if (size_or_bucket <= self.small.retain_bytes) break :blk .small;
            if (size_or_bucket <= self.medium.retain_bytes) break :blk .medium;
            break :blk .large;
        }
        @compileError("acquire expects BucketSize or usize, got " ++ @typeName(T));
    };

    const bucket = switch (bucket_size) {
        .tiny => &self.tiny,
        .small => &self.small,
        .medium => &self.medium,
        .large => &self.large,
    };

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    if (bucket.free_list) |entry| {
        bucket.free_list = entry.next;
        bucket.free_list_len -= 1;
        if (IS_DEBUG) {
            entry.debug = debug;
            const gop = try self._leak_track.getOrPut(self.allocator, debug);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        entry.setOwner(owner);
        lp.metrics.arena_hit.incr(bucket_size);
        return entry.arena.allocator();
    }

    lp.metrics.arena_miss.incr(bucket_size);

    const entry = try self.entry_pool.create();
    entry.* = .{
        .next = null,
        .bucket = bucket,
        .parent_allocator = self.allocator,
        .debug = if (IS_DEBUG) debug else {},
        .arena = undefined,
    };
    entry.arena = ArenaAllocator.init(entry.allocator());
    entry.setOwner(owner);

    if (IS_DEBUG) {
        const gop = try self._leak_track.getOrPut(self.allocator, debug);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
    return entry.arena.allocator();
}

// Universal release - determines bucket from the Entry automatically
pub fn release(self: *ArenaPool, allocator: Allocator) void {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    const entry: *Entry = @fieldParentPtr("arena", arena);
    const bucket = entry.bucket;

    if (IS_DEBUG) {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self._leak_track.getPtr(entry.debug)) |count| {
            count.* -= 1;
            if (count.* < 0) {
                log.err(.bug, "ArenaPool double-free", .{ .name = entry.debug });
                @panic("ArenaPool: double-free detected");
            }
        } else {
            log.err(.bug, "ArenaPool release unknown", .{ .name = entry.debug });
            @panic("ArenaPool: release of untracked arena");
        }
    }

    _ = arena.reset(.{ .retain_with_limit = bucket.retain_bytes });
    entry.clearOwner();

    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    if ((comptime SAFETY) or bucket.free_list_len >= bucket.free_list_max) {
        // In Debug, we never pool. It can mask UAF bugs.
        arena.deinit();
        self.entry_pool.destroy(entry);
        return;
    }

    entry.next = bucket.free_list;
    bucket.free_list = entry;
    bucket.free_list_len += 1;
}

pub fn reset(_: *const ArenaPool, allocator: Allocator, retain: usize) void {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    // In Debug, free_all, it's less likely to hide things
    _ = arena.reset(if (comptime SAFETY) .free_all else .{ .retain_with_limit = retain });
}

pub fn resetRetain(_: *const ArenaPool, allocator: Allocator) void {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    // In Debug, free_all, it's less likely to hide things
    _ = arena.reset(if (comptime SAFETY) .free_all else .retain_capacity);
}

const testing = std.testing;
test "ArenaPool: basic acquire and release" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const tiny = try pool.acquire(.tiny, "test-tiny");
    const medium = try pool.acquire(.medium, "test-medium");
    const large = try pool.acquire(.large, "test-large");

    // All three must be distinct arenas
    try testing.expect(tiny.ptr != medium.ptr);
    try testing.expect(medium.ptr != large.ptr);

    _ = try tiny.alloc(u8, 64);
    _ = try medium.alloc(u8, 1024);
    _ = try large.alloc(u8, 4096);

    // Universal release works for all buckets
    pool.release(tiny);
    pool.release(medium);
    pool.release(large);

    try testing.expectEqual(1, pool.tiny.free_list_len);
    try testing.expectEqual(1, pool.medium.free_list_len);
    try testing.expectEqual(1, pool.large.free_list_len);
}

test "ArenaPool: reuse from correct bucket" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const tiny1 = try pool.acquire(.tiny, "test");
    pool.release(tiny1);
    try testing.expectEqual(1, pool.tiny.free_list_len);

    // Next acquire with .tiny should reuse from tiny bucket
    const tiny2 = try pool.acquire(.tiny, "test");
    try testing.expectEqual(0, pool.tiny.free_list_len);
    try testing.expectEqual(tiny1.ptr, tiny2.ptr);

    // acquire with .medium should NOT get the tiny arena
    const medium = try pool.acquire(.medium, "test-medium");
    try testing.expect(medium.ptr != tiny2.ptr);

    pool.release(tiny2);
    pool.release(medium);
}

test "ArenaPool: respects per-bucket max limits" {
    var pool = ArenaPool.init(testing.allocator, .{
        .tiny = .{ .max = 1, .retain = 1024 },
        .medium = .{ .max = 2, .retain = 1024 },
        .large = .{ .max = 1, .retain = 1024 },
    });
    defer pool.deinit();

    // Acquire 3 tiny arenas
    const t1 = try pool.acquire(.tiny, "t1");
    const t2 = try pool.acquire(.tiny, "t2");
    const t3 = try pool.acquire(.tiny, "t3");

    // Release all 3, but only 1 should be kept (tiny_max = 1)
    pool.release(t1);
    try testing.expectEqual(1, pool.tiny.free_list_len);
    pool.release(t2);
    try testing.expectEqual(1, pool.tiny.free_list_len); // still 1, t2 discarded
    pool.release(t3);
    try testing.expectEqual(1, pool.tiny.free_list_len); // still 1, t3 discarded

    // Acquire 3 medium arenas
    const m1 = try pool.acquire(.medium, "m1");
    const m2 = try pool.acquire(.medium, "m2");
    const m3 = try pool.acquire(.medium, "m3");

    // Release all 3, but only 2 should be kept (medium_max = 2)
    pool.release(m1);
    pool.release(m2);
    pool.release(m3);
    try testing.expectEqual(2, pool.medium.free_list_len);
}

test "ArenaPool: reset clears memory without releasing" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const alloc = try pool.acquire(.medium, "test");

    const buf = try alloc.alloc(u8, 128);
    @memset(buf, 0xFF);

    // reset() frees arena memory but keeps the allocator in-flight.
    pool.reset(alloc, 0);

    // The free list must stay empty; the allocator was not released.
    try testing.expectEqual(0, pool.medium.free_list_len);

    // Allocating again through the same arena must still work.
    const buf2 = try alloc.alloc(u8, 64);
    @memset(buf2, 0x00);
    try testing.expectEqual(@as(u8, 0x00), buf2[0]);

    pool.release(alloc);
}

test "ArenaPool: deinit with entries in free list" {
    // Verifies that deinit properly cleans up free-listed arenas (no leaks
    // detected by the test allocator).
    var pool = ArenaPool.init(testing.allocator, .{});

    const a1 = try pool.acquire(.tiny, "test1");
    const a2 = try pool.acquire(.medium, "test2");
    _ = try a1.alloc(u8, 256);
    _ = try a2.alloc(u8, 512);
    pool.release(a1);
    pool.release(a2);
    try testing.expectEqual(1, pool.tiny.free_list_len);
    try testing.expectEqual(1, pool.medium.free_list_len);

    pool.deinit();
}

test "ArenaPool: small bucket" {
    var pool = ArenaPool.init(testing.allocator, .{
        .small = .{ .max = 2, .retain = 4 * 1024 },
    });
    defer pool.deinit();

    const s1 = try pool.acquire(.small, "s1");
    const s2 = try pool.acquire(.small, "s2");
    const s3 = try pool.acquire(.small, "s3");

    pool.release(s1);
    pool.release(s2);
    pool.release(s3);

    try testing.expectEqual(2, pool.small.free_list_len);
}

test "ArenaPool: size-based acquire" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // <= 1KB -> tiny
    const a = try pool.acquire(500, "fits-tiny");
    // <= 4KB -> small
    const b = try pool.acquire(2000, "fits-small");
    // <= 16KB -> medium
    const c = try pool.acquire(8000, "fits-medium");
    // > 16KB -> large
    const d = try pool.acquire(20000, "fits-large");

    pool.release(a);
    pool.release(b);
    pool.release(c);
    pool.release(d);

    try testing.expectEqual(1, pool.tiny.free_list_len);
    try testing.expectEqual(1, pool.small.free_list_len);
    try testing.expectEqual(1, pool.medium.free_list_len);
    try testing.expectEqual(1, pool.large.free_list_len);
}

test "ArenaPool: browser account follows retained capacity ownership" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    var first: NativeMemoryAccount = .{};
    var second: NativeMemoryAccount = .{};

    const first_arena = try pool.acquireFor(&first, .tiny, "first");
    _ = try first_arena.alloc(u8, 256);
    const retained_bytes = first.active();
    try testing.expect(retained_bytes > 0);
    try testing.expectEqual(@as(i64, @intCast(retained_bytes)), first.takePendingDelta());

    pool.release(first_arena);
    try testing.expectEqual(0, first.active());
    try testing.expectEqual(-@as(i64, @intCast(retained_bytes)), first.takePendingDelta());

    const second_arena = try pool.acquireFor(&second, .tiny, "second");
    try testing.expectEqual(retained_bytes, second.active());
    try testing.expectEqual(@as(i64, @intCast(retained_bytes)), second.takePendingDelta());

    pool.release(second_arena);
    try testing.expectEqual(0, second.active());
    try testing.expectEqual(-@as(i64, @intCast(retained_bytes)), second.takePendingDelta());
}

test "ArenaPool: reset updates the active browser account" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    var account: NativeMemoryAccount = .{};

    const arena = try pool.acquireFor(&account, .large, "reset");
    _ = try arena.alloc(u8, 256 * 1024);
    try testing.expect(account.active() > 0);
    _ = account.takePendingDelta();

    pool.reset(arena, 0);
    try testing.expectEqual(0, account.active());
    try testing.expect(account.takePendingDelta() < 0);

    pool.release(arena);
    try testing.expectEqual(0, account.active());
    try testing.expectEqual(0, account.takePendingDelta());
}

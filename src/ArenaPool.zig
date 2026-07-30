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

const Arena = @import("Arena.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const ArenaPool = @This();

const IS_DEBUG = builtin.mode == .Debug;
const SAFETY = Arena.SAFETY;

pub const BucketSize = enum { tiny, small, medium, large };

pub const Bucket = struct {
    free_list: ?*Arena = null,
    free_list_len: u16 = 0,
    free_list_max: u16,
    retain_bytes: usize,
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
entry_pool: std.heap.MemoryPool(Arena),

_leak_track: if (IS_DEBUG) std.StringHashMapUnmanaged(isize) else void = if (IS_DEBUG) .empty else {},

pub fn init(allocator: Allocator, config: Config) ArenaPool {
    return .{
        .allocator = allocator,
        .entry_pool = .empty,
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
            e._arena.deinit();
        }
    }
    self.entry_pool.deinit(self.allocator);
}

// Acquire an arena from the pool.
// - Pass a BucketSize (.tiny, .small, .medium, .large) for explicit bucket selection
// - Pass a usize for automatic bucket selection based on expected size
pub fn acquire(self: *ArenaPool, size_or_bucket: anytype, debug: []const u8) !*Arena {
    return self._acquire(null, size_or_bucket, debug);
}

// An arena that, once its owner's last native reference is gone, is kept alive
// by nothing but a V8 finalizer. These are the only arenas wort telling v8 about.//
pub fn acquirePinned(self: *ArenaPool, account: *Arena.Account, size_or_bucket: anytype, debug: []const u8) !*Arena {
    return self._acquire(account, size_or_bucket, debug);
}

fn _acquire(self: *ArenaPool, account: ?*Arena.Account, size_or_bucket: anytype, debug: []const u8) !*Arena {
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
        entry.account = account;
        lp.metrics.arena_hit.incr(bucket_size);
        return entry;
    }

    lp.metrics.arena_miss.incr(bucket_size);

    const entry = try self.entry_pool.create(self.allocator);
    entry.* = .{
        .next = null,
        .pool = self,
        .bucket = bucket,
        .bytes = 0,
        .account = account,
        .reported = 0,
        .debug = if (IS_DEBUG) debug else {},
        ._arena = undefined,
    };
    // Routed through the entry so it sees every node the arena takes and gives
    // back. entry is pool-allocated, so this pointer is stable.
    entry._arena = ArenaAllocator.init(entry.backing());

    if (IS_DEBUG) {
        const gop = try self._leak_track.getOrPut(self.allocator, debug);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
    return entry;
}

// Prefer Arena.release(). Determines the bucket from the Arena automatically.
pub fn release(self: *ArenaPool, entry: *Arena) void {
    const arena = &entry._arena;
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

    entry.unpin();
    _ = arena.reset(.{ .retain_with_limit = bucket.retain_bytes });

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

const testing = std.testing;
test "ArenaPool: basic acquire and release" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const tiny = try pool.acquire(.tiny, "test-tiny");
    const medium = try pool.acquire(.medium, "test-medium");
    const large = try pool.acquire(.large, "test-large");

    // All three must be distinct arenas
    try testing.expect(tiny != medium);
    try testing.expect(medium != large);

    _ = try tiny.alloc(u8, 64);
    _ = try medium.alloc(u8, 1024);
    _ = try large.alloc(u8, 4096);

    // Universal release works for all buckets
    tiny.release();
    medium.release();
    large.release();

    try testing.expectEqual(1, pool.tiny.free_list_len);
    try testing.expectEqual(1, pool.medium.free_list_len);
    try testing.expectEqual(1, pool.large.free_list_len);
}

test "ArenaPool: reuse from correct bucket" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const tiny1 = try pool.acquire(.tiny, "test");
    tiny1.release();
    try testing.expectEqual(1, pool.tiny.free_list_len);

    // Next acquire with .tiny should reuse from tiny bucket
    const tiny2 = try pool.acquire(.tiny, "test");
    try testing.expectEqual(0, pool.tiny.free_list_len);
    try testing.expectEqual(tiny1, tiny2);

    // acquire with .medium should NOT get the tiny arena
    const medium = try pool.acquire(.medium, "test-medium");
    try testing.expect(medium != tiny2);

    tiny2.release();
    medium.release();
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
    t1.release();
    try testing.expectEqual(1, pool.tiny.free_list_len);
    t2.release();
    try testing.expectEqual(1, pool.tiny.free_list_len); // still 1, t2 discarded
    t3.release();
    try testing.expectEqual(1, pool.tiny.free_list_len); // still 1, t3 discarded

    // Acquire 3 medium arenas
    const m1 = try pool.acquire(.medium, "m1");
    const m2 = try pool.acquire(.medium, "m2");
    const m3 = try pool.acquire(.medium, "m3");

    // Release all 3, but only 2 should be kept (medium_max = 2)
    m1.release();
    m2.release();
    m3.release();
    try testing.expectEqual(2, pool.medium.free_list_len);
}

test "ArenaPool: reset clears memory without releasing" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const alloc = try pool.acquire(.medium, "test");

    const buf = try alloc.alloc(u8, 128);
    @memset(buf, 0xFF);

    // reset() frees arena memory but keeps the allocator in-flight.
    alloc.reset(0);

    // The free list must stay empty; the allocator was not released.
    try testing.expectEqual(0, pool.medium.free_list_len);

    // Allocating again through the same arena must still work.
    const buf2 = try alloc.alloc(u8, 64);
    @memset(buf2, 0x00);
    try testing.expectEqual(@as(u8, 0x00), buf2[0]);

    alloc.release();
}

test "ArenaPool: deinit with entries in free list" {
    // Verifies that deinit properly cleans up free-listed arenas (no leaks
    // detected by the test allocator).
    var pool = ArenaPool.init(testing.allocator, .{});

    const a1 = try pool.acquire(.tiny, "test1");
    const a2 = try pool.acquire(.medium, "test2");
    _ = try a1.alloc(u8, 256);
    _ = try a2.alloc(u8, 512);
    a1.release();
    a2.release();
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

    s1.release();
    s2.release();
    s3.release();

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

    a.release();
    b.release();
    c.release();
    d.release();

    try testing.expectEqual(1, pool.tiny.free_list_len);
    try testing.expectEqual(1, pool.small.free_list_len);
    try testing.expectEqual(1, pool.medium.free_list_len);
    try testing.expectEqual(1, pool.large.free_list_len);
}

test "ArenaPool: bytes track the arena's backing allocations" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arena = try pool.acquire(.large, "bytes");
    defer arena.release();
    try testing.expectEqual(0, arena.bytes);

    _ = try arena.alloc(u8, 256 * 1024);
    try testing.expect(arena.bytes >= 256 * 1024);

    arena.reset(0);
    try testing.expectEqual(0, arena.bytes);
}

test "ArenaPool: only a pinned arena reports, and only when asked" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    var account: Arena.Account = .{};

    // An unpinned arena never touches the account.
    {
        const arena = try pool.acquire(.large, "unpinned");
        defer arena.release();
        _ = try arena.alloc(u8, 256 * 1024);
        arena.report();
        try testing.expectEqual(0, account.pending);
    }

    const arena = try pool.acquirePinned(&account, .large, "pinned");
    _ = try arena.alloc(u8, 256 * 1024);

    // Growing is not enough: until the owner reports, V8 hears nothing.
    try testing.expectEqual(0, account.pending);

    arena.report();
    const reported = account.pending;
    try testing.expect(reported >= 256 * 1024);

    // report() is a delta, so repeating it is a no-op.
    arena.report();
    try testing.expectEqual(reported, account.pending);

    // Release takes back exactly what was reported.
    arena.release();
    try testing.expectEqual(0, account.pending);
}

test "ArenaPool: release un-reports even when the owner never reported" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    var account: Arena.Account = .{};

    const arena = try pool.acquirePinned(&account, .large, "unreported");
    _ = try arena.alloc(u8, 256 * 1024);
    arena.release();
    try testing.expectEqual(0, account.pending);
}

test "ArenaPool: a reused arena carries its retained bytes to the new owner" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();
    var first: Arena.Account = .{};
    var second: Arena.Account = .{};

    const a = try pool.acquirePinned(&first, .tiny, "first");
    _ = try a.alloc(u8, 256);
    a.report();
    try testing.expect(first.pending > 0);
    a.release();
    try testing.expectEqual(0, first.pending);

    const retained = a.bytes;
    try testing.expect(retained > 0);

    const b = try pool.acquirePinned(&second, .tiny, "second");
    try testing.expectEqual(a, b);
    try testing.expectEqual(retained, b.bytes);

    // The new owner inherits the bytes but still has to report them itself.
    try testing.expectEqual(0, second.pending);
    b.report();
    try testing.expectEqual(@as(i64, @intCast(retained)), second.pending);

    b.release();
    try testing.expectEqual(0, second.pending);
}

test "ArenaPool: bytes agrees with the arena's own view of its capacity" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arena = try pool.acquire(.large, "capacity");
    defer arena.release();

    // queryCapacity excludes each node's header, which `bytes` counts, so the
    // two bracket each other rather than matching exactly.
    for ([_]usize{ 64, 4096, 300 * 1024, 2 * 1024 * 1024 }) |n| {
        _ = try arena.alloc(u8, n);
        const capacity = arena._arena.queryCapacity();
        try testing.expect(arena.bytes >= capacity);
        try testing.expect(arena.bytes - capacity < 1024); // header slop only
    }
}

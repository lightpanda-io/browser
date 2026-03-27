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
const builtin = @import("builtin");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const ArenaPool = @This();

const IS_DEBUG = builtin.mode == .Debug;

allocator: Allocator,
retain_bytes: usize,
free_list_len: u16 = 0,
free_list: ?*Entry = null,
free_list_max: u16,
entry_pool: std.heap.MemoryPool(Entry),
mutex: std.Thread.Mutex = .{},
// Debug mode: track acquire/release counts per debug name to detect leaks and double-frees
_leak_track: if (IS_DEBUG) std.StringHashMapUnmanaged(isize) else void = if (IS_DEBUG) .empty else {},

const Entry = struct {
    next: ?*Entry,
    arena: ArenaAllocator,
    debug: if (IS_DEBUG) []const u8 else void = if (IS_DEBUG) "" else {},
};

pub const DebugInfo = struct {
    debug: []const u8 = "",
};

pub fn init(allocator: Allocator, free_list_max: u16, retain_bytes: usize) ArenaPool {
    return .{
        .allocator = allocator,
        .free_list_max = free_list_max,
        .retain_bytes = retain_bytes,
        .entry_pool = .init(allocator),
        ._leak_track = if (IS_DEBUG) .empty else {},
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

    var entry = self.free_list;
    while (entry) |e| {
        entry = e.next;
        e.arena.deinit();
    }
    self.entry_pool.deinit();
}

pub fn acquire(self: *ArenaPool, dbg: DebugInfo) !Allocator {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.free_list) |entry| {
        self.free_list = entry.next;
        self.free_list_len -= 1;
        if (IS_DEBUG) {
            entry.debug = dbg.debug;
            const gop = try self._leak_track.getOrPut(self.allocator, dbg.debug);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        return entry.arena.allocator();
    }

    const entry = try self.entry_pool.create();
    entry.* = .{
        .next = null,
        .arena = ArenaAllocator.init(self.allocator),
        .debug = if (IS_DEBUG) dbg.debug else {},
    };

    if (IS_DEBUG) {
        const gop = try self._leak_track.getOrPut(self.allocator, dbg.debug);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
    return entry.arena.allocator();
}

pub fn release(self: *ArenaPool, allocator: Allocator) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    const entry: *Entry = @fieldParentPtr("arena", arena);

    // Reset the arena before acquiring the lock to minimize lock hold time
    _ = arena.reset(.{ .retain_with_limit = self.retain_bytes });

    self.mutex.lock();
    defer self.mutex.unlock();

    if (IS_DEBUG) {
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

    const free_list_len = self.free_list_len;
    if (free_list_len == self.free_list_max) {
        arena.deinit();
        self.entry_pool.destroy(entry);
        return;
    }

    entry.next = self.free_list;
    self.free_list_len = free_list_len + 1;
    self.free_list = entry;
}

pub fn reset(_: *const ArenaPool, allocator: Allocator, retain: usize) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    _ = arena.reset(.{ .retain_with_limit = retain });
}

pub fn resetRetain(_: *const ArenaPool, allocator: Allocator) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    _ = arena.reset(.retain_capacity);
}

const testing = std.testing;

test "arena pool - basic acquire and use" {
    var pool = ArenaPool.init(testing.allocator, 512, 1024 * 16);
    defer pool.deinit();

    const alloc = try pool.acquire(.{ .debug = "test" });
    const buf = try alloc.alloc(u8, 64);
    @memset(buf, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);

    pool.release(alloc);
}

test "arena pool - reuse entry after release" {
    var pool = ArenaPool.init(testing.allocator, 512, 1024 * 16);
    defer pool.deinit();

    const alloc1 = try pool.acquire(.{ .debug = "test" });
    try testing.expectEqual(@as(u16, 0), pool.free_list_len);

    pool.release(alloc1);
    try testing.expectEqual(@as(u16, 1), pool.free_list_len);

    // The same entry should be returned from the free list.
    const alloc2 = try pool.acquire(.{ .debug = "test" });
    try testing.expectEqual(@as(u16, 0), pool.free_list_len);
    try testing.expectEqual(alloc1.ptr, alloc2.ptr);

    pool.release(alloc2);
}

test "arena pool - multiple concurrent arenas" {
    var pool = ArenaPool.init(testing.allocator, 512, 1024 * 16);
    defer pool.deinit();

    const a1 = try pool.acquire(.{ .debug = "test1" });
    const a2 = try pool.acquire(.{ .debug = "test2" });
    const a3 = try pool.acquire(.{ .debug = "test3" });

    // All three must be distinct arenas.
    try testing.expect(a1.ptr != a2.ptr);
    try testing.expect(a2.ptr != a3.ptr);
    try testing.expect(a1.ptr != a3.ptr);

    _ = try a1.alloc(u8, 16);
    _ = try a2.alloc(u8, 32);
    _ = try a3.alloc(u8, 48);

    pool.release(a1);
    pool.release(a2);
    pool.release(a3);

    try testing.expectEqual(@as(u16, 3), pool.free_list_len);
}

test "arena pool - free list respects max limit" {
    // Cap the free list at 1 so the second release discards its arena.
    var pool = ArenaPool.init(testing.allocator, 1, 1024 * 16);
    defer pool.deinit();

    const a1 = try pool.acquire(.{ .debug = "test1" });
    const a2 = try pool.acquire(.{ .debug = "test2" });

    pool.release(a1);
    try testing.expectEqual(@as(u16, 1), pool.free_list_len);

    // The free list is full; a2's arena should be destroyed, not queued.
    pool.release(a2);
    try testing.expectEqual(@as(u16, 1), pool.free_list_len);
}

test "arena pool - reset clears memory without releasing" {
    var pool = ArenaPool.init(testing.allocator, 512, 1024 * 16);
    defer pool.deinit();

    const alloc = try pool.acquire(.{ .debug = "test" });

    const buf = try alloc.alloc(u8, 128);
    @memset(buf, 0xFF);

    // reset() frees arena memory but keeps the allocator in-flight.
    pool.reset(alloc, 0);

    // The free list must stay empty; the allocator was not released.
    try testing.expectEqual(@as(u16, 0), pool.free_list_len);

    // Allocating again through the same arena must still work.
    const buf2 = try alloc.alloc(u8, 64);
    @memset(buf2, 0x00);
    try testing.expectEqual(@as(u8, 0x00), buf2[0]);

    pool.release(alloc);
}

test "arena pool - deinit with entries in free list" {
    // Verifies that deinit properly cleans up free-listed arenas (no leaks
    // detected by the test allocator).
    var pool = ArenaPool.init(testing.allocator, 512, 1024 * 16);

    const a1 = try pool.acquire(.{ .debug = "test1" });
    const a2 = try pool.acquire(.{ .debug = "test2" });
    _ = try a1.alloc(u8, 256);
    _ = try a2.alloc(u8, 512);
    pool.release(a1);
    pool.release(a2);
    try testing.expectEqual(@as(u16, 2), pool.free_list_len);

    pool.deinit();
}

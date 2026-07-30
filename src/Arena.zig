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

// An arena checked out of an ArenaPool. Owners hold the *Arena and release it
// when they're done with it; everything downstream takes the plain Allocator
// from allocator().
//
// Never copy an Arena by value: the Allocator it hands out points back into it.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const ArenaPool = @import("ArenaPool.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Arena = @This();

const IS_DEBUG = builtin.mode == .Debug;

// In Debug, don't pool and don't retain capacity. Both can mask UAF.
pub const SAFETY = IS_DEBUG == true and builtin.is_test == false;

// Amount of memory the arena hasn't reported to v8 yet. This is only tracked
// when account != null.
pub const Account = struct {
    pending: i64 = 0,
};

_arena: ArenaAllocator,
pool: *ArenaPool,
bucket: *ArenaPool.Bucket,

// Only meaningful while this arena sits in its bucket's free list.
next: ?*Arena,

// Bytes _arena holds from the backing allocator, maintained by the vtable
// below. Changes only when the arena grows or frees a node, so this costs
// O(log n) updates over an arena's life, not one per allocation.
bytes: usize,

// Set only for an arena pinned by a V8 finalizer: see ArenaPool.acquirePinned.
account: ?*Account,

// `bytes` as of the last report() — what the account has already been told.
reported: usize,

debug: if (IS_DEBUG) []const u8 else void = if (IS_DEBUG) "" else {},

pub fn allocator(self: *Arena) Allocator {
    return self._arena.allocator();
}

// The allocator _arena grows from. Sits between the arena and the pool's
// allocator purely to keep `bytes` current.
pub fn backing(self: *Arena) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

// Attribute everything this arena is currently holding to V8's external memory
// counter. Only meaningful for a pinned arena, and only correct once nothing
// but the JS wrapper's finalizer is keeping the arena alive — before that a GC
// can't reclaim it and reporting is pure GC pressure. See ArenaPool.acquirePinned.
pub fn report(self: *Arena) void {
    const account = self.account orelse return;
    account.pending += @as(i64, @intCast(self.bytes)) - @as(i64, @intCast(self.reported));
    self.reported = self.bytes;
}

pub fn release(self: *Arena) void {
    self.pool.release(self);
}

pub fn reset(self: *Arena, retain: usize) void {
    _ = self._arena.reset(if (comptime SAFETY) .free_all else .{ .retain_with_limit = retain });
}

pub fn resetRetain(self: *Arena) void {
    _ = self._arena.reset(if (comptime SAFETY) .free_all else .retain_capacity);
}

pub fn alloc(self: *Arena, comptime T: type, n: usize) ![]T {
    return self.allocator().alloc(T, n);
}

pub fn create(self: *Arena, comptime T: type) !*T {
    return self.allocator().create(T);
}

pub fn dupe(self: *Arena, comptime T: type, m: []const T) ![]T {
    return self.allocator().dupe(T, m);
}

pub fn dupeZ(self: *Arena, comptime T: type, m: []const T) ![:0]T {
    return self.allocator().dupeZ(T, m);
}

// Arena is being released. Account goes back to 0 (everything is being released)
pub fn unpin(self: *Arena) void {
    const account = self.account orelse return;
    account.pending -= @intCast(self.reported);
    self.reported = 0;
    self.account = null;
}

fn grew(self: *Arena, n: usize) void {
    self.bytes += n;
    lp.metrics.arena_memory_bytes.incrBy(n);
}

fn shrank(self: *Arena, n: usize) void {
    self.bytes -= n;
    lp.metrics.arena_memory_bytes.decrBy(n);
}

fn resized(self: *Arena, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) self.grew(new_len - old_len) else self.shrank(old_len - new_len);
}

const vtable = Allocator.VTable{
    .alloc = rawAlloc,
    .resize = rawResize,
    .remap = rawRemap,
    .free = rawFree,
};

fn rawAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    const buf = self.pool.allocator.rawAlloc(len, alignment, ra) orelse return null;
    self.grew(len);
    return buf;
}

fn rawResize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    if (!self.pool.allocator.rawResize(mem, alignment, new_len, ra)) return false;
    self.resized(mem.len, new_len);
    return true;
}

fn rawRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    const buf = self.pool.allocator.rawRemap(mem, alignment, new_len, ra) orelse return null;
    self.resized(mem.len, new_len);
    return buf;
}

fn rawFree(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    self.pool.allocator.rawFree(mem, alignment, ra);
    self.shrank(mem.len);
}

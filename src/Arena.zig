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
const builtin = @import("builtin");

const ArenaPool = @import("ArenaPool.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Arena = @This();

const IS_DEBUG = builtin.mode == .Debug;

// In Debug, don't pool and don't retain capacity. Both can mask UAF.
pub const SAFETY = IS_DEBUG == true and builtin.is_test == false;

_arena: ArenaAllocator,
pool: *ArenaPool,
bucket: *ArenaPool.Bucket,

// Only meaningful while this arena sits in its bucket's free list.
next: ?*Arena,

debug: if (IS_DEBUG) []const u8 else void = if (IS_DEBUG) "" else {},

pub fn allocator(self: *Arena) Allocator {
    return self._arena.allocator();
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

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
const ArenaAllocator = std.heap.ArenaAllocator;

const ArenaPool = @This();

allocator: Allocator,
retain_bytes: usize,
free_list_len: u16 = 0,
free_list: ?*Entry = null,
free_list_max: u16,
entry_pool: std.heap.MemoryPool(Entry),
mutex: std.Thread.Mutex = .{},

const Entry = struct {
    next: ?*Entry,
    arena: ArenaAllocator,
};

pub fn init(allocator: Allocator) ArenaPool {
    return .{
        .allocator = allocator,
        .free_list_max = 512, //  TODO make configurable
        .retain_bytes = 1024 * 16, // TODO make configurable
        .entry_pool = std.heap.MemoryPool(Entry).init(allocator),
    };
}

pub fn deinit(self: *ArenaPool) void {
    var entry = self.free_list;
    while (entry) |e| {
        entry = e.next;
        e.arena.deinit();
    }
    self.entry_pool.deinit();
}

pub fn acquire(self: *ArenaPool) !Allocator {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.free_list) |entry| {
        self.free_list = entry.next;
        self.free_list_len -= 1;
        return entry.arena.allocator();
    }

    const entry = try self.entry_pool.create();
    entry.* = .{
        .next = null,
        .arena = ArenaAllocator.init(self.allocator),
    };

    return entry.arena.allocator();
}

pub fn release(self: *ArenaPool, allocator: Allocator) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(allocator.ptr));
    const entry: *Entry = @fieldParentPtr("arena", arena);

    // Reset the arena before acquiring the lock to minimize lock hold time
    _ = arena.reset(.{ .retain_with_limit = self.retain_bytes });

    self.mutex.lock();
    defer self.mutex.unlock();

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

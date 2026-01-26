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

const LimitedAllocator = @This();

parent: Allocator,
limit: usize,
allocated: usize = 0,

pub fn init(parent: Allocator, limit: usize) LimitedAllocator {
    return .{ .parent = parent, .limit = limit };
}

pub fn allocator(self: *LimitedAllocator) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    if (self.allocated + len > self.limit) return null;
    const result = self.parent.rawAlloc(len, alignment, ret_addr);
    if (result != null) self.allocated += len;
    return result;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and self.allocated + new_len - memory.len > self.limit) return false;
    if (self.parent.rawResize(memory, alignment, new_len, ret_addr)) {
        if (new_len > memory.len) self.allocated += new_len - memory.len else self.allocated -= memory.len - new_len;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and self.allocated + new_len - memory.len > self.limit) return null;
    const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    if (result != null) {
        if (new_len > memory.len) self.allocated += new_len - memory.len else self.allocated -= memory.len - new_len;
    }
    return result;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    self.parent.rawFree(memory, alignment, ret_addr);
    self.allocated -= memory.len;
}

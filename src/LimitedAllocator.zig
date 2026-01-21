// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

/// Per-session memory limiting allocator.
/// Wraps a backing allocator and enforces a maximum memory limit.
/// Thread-local: each SessionThread creates its own LimitedAllocator.
const LimitedAllocator = @This();

backing: Allocator,
bytes_allocated: usize,
max_bytes: usize,

pub fn init(backing: Allocator, max_bytes: usize) LimitedAllocator {
    return .{
        .backing = backing,
        .bytes_allocated = 0,
        .max_bytes = max_bytes,
    };
}

pub fn allocator(self: *LimitedAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn bytesAllocated(self: *const LimitedAllocator) usize {
    return self.bytes_allocated;
}

pub fn bytesRemaining(self: *const LimitedAllocator) usize {
    return self.max_bytes -| self.bytes_allocated;
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));

    if (self.bytes_allocated +| len > self.max_bytes) {
        return null; // Out of memory for this session
    }

    const result = self.backing.rawAlloc(len, alignment, ret_addr);
    if (result != null) {
        self.bytes_allocated += len;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));

    if (new_len > buf.len) {
        const additional = new_len - buf.len;
        if (self.bytes_allocated +| additional > self.max_bytes) {
            return false; // Would exceed limit
        }
    }

    if (self.backing.rawResize(buf, alignment, new_len, ret_addr)) {
        if (new_len > buf.len) {
            self.bytes_allocated += new_len - buf.len;
        } else {
            self.bytes_allocated -= buf.len - new_len;
        }
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));

    if (new_len > buf.len) {
        const additional = new_len - buf.len;
        if (self.bytes_allocated +| additional > self.max_bytes) {
            return null; // Would exceed limit
        }
    }

    const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
    if (result != null) {
        if (new_len > buf.len) {
            self.bytes_allocated += new_len - buf.len;
        } else {
            self.bytes_allocated -= buf.len - new_len;
        }
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
    self.bytes_allocated -|= buf.len;
    self.backing.rawFree(buf, alignment, ret_addr);
}

const testing = std.testing;

test "LimitedAllocator: basic allocation" {
    var limited = LimitedAllocator.init(testing.allocator, 1024);
    const alloc_ = limited.allocator();

    const slice = try alloc_.alloc(u8, 100);
    defer alloc_.free(slice);

    try testing.expectEqual(100, limited.bytesAllocated());
    try testing.expectEqual(924, limited.bytesRemaining());
}

test "LimitedAllocator: exceeds limit" {
    var limited = LimitedAllocator.init(testing.allocator, 100);
    const alloc_ = limited.allocator();

    // Allocation should fail with OutOfMemory when exceeding limit
    try testing.expectError(error.OutOfMemory, alloc_.alloc(u8, 200));
    try testing.expectEqual(0, limited.bytesAllocated());
}

test "LimitedAllocator: free updates counter" {
    var limited = LimitedAllocator.init(testing.allocator, 1024);
    const alloc_ = limited.allocator();

    const slice = try alloc_.alloc(u8, 100);
    try testing.expectEqual(100, limited.bytesAllocated());

    alloc_.free(slice);
    try testing.expectEqual(0, limited.bytesAllocated());
}

test "LimitedAllocator: multiple allocations" {
    var limited = LimitedAllocator.init(testing.allocator, 1024);
    const alloc_ = limited.allocator();

    const s1 = try alloc_.alloc(u8, 100);
    const s2 = try alloc_.alloc(u8, 200);
    const s3 = try alloc_.alloc(u8, 300);

    try testing.expectEqual(600, limited.bytesAllocated());

    alloc_.free(s2);
    try testing.expectEqual(400, limited.bytesAllocated());

    alloc_.free(s1);
    alloc_.free(s3);
    try testing.expectEqual(0, limited.bytesAllocated());
}

test "LimitedAllocator: allocation at limit boundary" {
    var limited = LimitedAllocator.init(testing.allocator, 100);
    const alloc_ = limited.allocator();

    const s1 = try alloc_.alloc(u8, 50);
    defer alloc_.free(s1);

    const s2 = try alloc_.alloc(u8, 50);
    defer alloc_.free(s2);

    // Should fail - at limit
    try testing.expectError(error.OutOfMemory, alloc_.alloc(u8, 1));
}

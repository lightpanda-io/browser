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

const libcurl = @import("../sys/libcurl.zig");

const Allocator = std.mem.Allocator;

const CurlDebugAllocator = @This();

// C11 requires malloc to return memory aligned to max_align_t (16 bytes on x86_64).
// We match this guarantee since libcurl expects malloc-compatible alignment.
const alignment = 16;

var instance: ?CurlDebugAllocator = null;

allocator: Allocator,

pub fn init(allocator: Allocator) void {
    lp.assert(instance == null, "Initialization of curl must happen only once", .{});
    instance = .{ .allocator = allocator };
}

pub fn interface() libcurl.CurlAllocator {
    return .{
        .free = free,
        .strdup = strdup,
        .malloc = malloc,
        .calloc = calloc,
        .realloc = realloc,
    };
}

fn _allocBlock(size: usize) ?*Block {
    const slice = instance.?.allocator.alignedAlloc(u8, .fromByteUnits(alignment), Block.fullsize(size)) catch return null;
    const block: *Block = @ptrCast(@alignCast(slice.ptr));
    block.size = size;
    return block;
}

fn _freeBlock(header: *Block) void {
    instance.?.allocator.free(header.slice());
}

fn malloc(size: usize) ?*anyopaque {
    const block = _allocBlock(size) orelse return null;
    return @ptrCast(block.data());
}

fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    const total = nmemb * size;
    const block = _allocBlock(total) orelse return null;
    const ptr = block.data();
    @memset(ptr[0..total], 0); // for historical reasons, calloc zeroes memory, but malloc does not.
    return @ptrCast(ptr);
}

fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const p = ptr orelse return malloc(size);
    const block = Block.fromPtr(p);

    const old_size = block.size;
    if (size == old_size) return ptr;

    if (instance.?.allocator.resize(block.slice(), alignment + size)) {
        block.size = size;
        return ptr;
    }

    const copy_size = @min(old_size, size);
    const new_block = _allocBlock(size) orelse return null;
    @memcpy(new_block.data()[0..copy_size], block.data()[0..copy_size]);
    _freeBlock(block);
    return @ptrCast(new_block.data());
}

fn free(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    _freeBlock(Block.fromPtr(p));
}

fn strdup(str: [*:0]const u8) ?[*:0]u8 {
    const len = std.mem.len(str);
    const header = _allocBlock(len + 1) orelse return null;
    const ptr = header.data();
    @memcpy(ptr[0..len], str[0..len]);
    ptr[len] = 0;
    return ptr[0..len :0];
}

const Block = extern struct {
    size: usize = 0,
    _padding: [alignment - @sizeOf(usize)]u8 = .{0} ** (alignment - @sizeOf(usize)),

    inline fn fullsize(bytes: usize) usize {
        return alignment + bytes;
    }

    inline fn fromPtr(ptr: *anyopaque) *Block {
        const raw: [*]u8 = @ptrCast(ptr);
        return @ptrCast(@alignCast(raw - @sizeOf(Block)));
    }

    inline fn data(self: *Block) [*]u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr + @sizeOf(Block);
    }

    inline fn slice(self: *Block) []align(alignment) u8 {
        const base: [*]align(alignment) u8 = @ptrCast(@alignCast(self));
        return base[0 .. alignment + self.size];
    }
};

comptime {
    std.debug.assert(@sizeOf(Block) == alignment);
}

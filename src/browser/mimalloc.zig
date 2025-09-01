// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

// This file makes the glue between mimalloc heap allocation and libdom memory
// management.
// We replace the libdom default usage of allocations with mimalloc heap
// allocation to be able to free all memory used at once, like an arena usage.
const std = @import("std");

const c = @cImport({
    @cInclude("mimalloc.h");
});

const Error = error{
    HeapNotNull,
    HeapNull,
};

var heap: ?*c.mi_heap_t = null;

pub fn create() Error!void {
    std.debug.assert(heap == null);
    heap = c.mi_heap_new();
    std.debug.assert(heap != null);
}

pub fn destroy() void {
    std.debug.assert(heap != null);
    c.mi_heap_destroy(heap.?);
    heap = null;
}

pub export fn m_alloc(size: usize) callconv(.c) ?*anyopaque {
    std.debug.assert(heap != null);
    return c.mi_heap_malloc(heap.?, size);
}

pub export fn re_alloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    std.debug.assert(heap != null);
    return c.mi_heap_realloc(heap.?, ptr, size);
}

pub export fn c_alloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    std.debug.assert(heap != null);
    return c.mi_heap_calloc(heap.?, nmemb, size);
}

pub export fn str_dup(s: [*c]const u8) callconv(.c) [*c]u8 {
    std.debug.assert(heap != null);
    return c.mi_heap_strdup(heap.?, s);
}

pub export fn strn_dup(s: [*c]const u8, size: usize) callconv(.c) [*c]u8 {
    std.debug.assert(heap != null);
    return c.mi_heap_strndup(heap.?, s, size);
}

// NOOP, use destroy to clear all the memory allocated at once.
pub export fn f_ree(_: ?*anyopaque) callconv(.c) void {
    return;
}

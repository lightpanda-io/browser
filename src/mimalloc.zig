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
    if (heap != null) return Error.HeapNotNull;
    heap = c.mi_heap_new();
    if (heap == null) return Error.HeapNull;
}

pub fn destroy() void {
    if (heap == null) return;
    c.mi_heap_destroy(heap.?);
    heap = null;
}

pub export fn m_alloc(size: usize) callconv(.C) ?*anyopaque {
    if (heap == null) return null;
    return c.mi_heap_malloc(heap.?, size);
}

pub export fn re_alloc(ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
    if (heap == null) return null;
    return c.mi_heap_realloc(heap.?, ptr, size);
}

pub export fn c_alloc(nmemb: usize, size: usize) callconv(.C) ?*anyopaque {
    if (heap == null) return null;
    return c.mi_heap_calloc(heap.?, nmemb, size);
}

// NOOP, use destroy to clear all the memory allocated at once.
pub export fn f_ree(_: ?*anyopaque) callconv(.C) void {
    return;
}

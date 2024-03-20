// MIT License
// Copyright 2024 Lightpanda
// Original copyright 2021 pfg and marler8997
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial
// portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// ---------------------------

// This file is a mix between:
// - malloc functions of ziglibc (https://github.com/marler8997/ziglibc/blob/main/src/cstd.zig)
// for the general logic
// - this gist https://gist.github.com/pfgithub/65c13d7dc889a4b2ba25131994be0d20
// for the header "magic" validator
// + some refacto and comments to make the code more clear

const std = @import("std");

// TODO: this uses a global variable
// it does not allow to set a context-based allocator
var alloc: std.mem.Allocator = undefined;

pub fn setCAllocator(allocator: std.mem.Allocator) void {
    alloc = allocator;
}

// Alloc mechanism
// ---------------

// C malloc does not know the type of the buffer allocated,
// instead it uses a metadata header at the begining of the buffer to store the allocated size.
// We copy this behavior by allocating in Zig the size requested + the size of the header.
// On this header we store not only the size allocated but also a "magic" validator
// to check if the C pointer as been allocated through those cutom malloc functions.

// The total buffer looks like that:
// [Zig buf] = [header][C pointer]

const al = @alignOf(std.c.max_align_t);

const Header = struct {
    comptime {
        if (@alignOf(Header) > al) @compileError("oops");
    }

    const len = std.mem.alignForward(usize, al, @sizeOf(Header));

    const MAGIC = 0xABCDEF;
    const NOMAGIC = 0;

    magic: usize = MAGIC,
    size: usize,
};

// Buffer manipulation functions

// setHeader on a buffer allocated in Zig
inline fn setHeader(buf: anytype, size: usize) void {
    // cast buffer to an header
    const header = @as(*Header, @ptrCast(buf));
    // and set the relevant information on it (size and "magic" validator)
    header.* = .{ .size = size };
}

// getHeader from a C pointer
fn getHeader(ptr: [*]u8) *Header {
    // use arithmetic to get (ie. backward) the buffer pointer from the C pointer
    const buf = ptr - Header.len;
    // convert many-item pointer to single pointer and cast to an header
    // return @ptrFromInt(@intFromPtr(buf));
    // and cast it to an header pointer
    return @ptrCast(@as([*]align(@alignOf(*Header)) u8, @alignCast(buf)));
}

// getBuf from an header
fn getBuf(header: *Header) []align(al) u8 {
    // cast header pointer to a many-item buffer pointer
    const buf_ptr = @as([*]u8, @ptrCast(header));
    // return the buffer with corresponding length
    const buf = buf_ptr[0..header.size];
    return @alignCast(buf);
}

inline fn cPtr(buf: [*]align(al) u8) [*]align(al) u8 {
    // use arithmetic to get (ie. forward) the C pointer from the buffer pointer
    return buf + Header.len;
}

// Custom malloc functions

pub export fn m_alloc(size: usize) callconv(.C) ?[*]align(al) u8 {
    std.debug.assert(size > 0); // TODO: what should we do in this case?
    const buf_len = Header.len + size;
    const buf = alloc.alignedAlloc(u8, al, buf_len) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    setHeader(buf, buf_len);
    return cPtr(buf.ptr);
}

pub export fn re_alloc(ptr: ?[*]align(al) u8, size: usize) callconv(.C) ?[*]align(al) u8 {
    if (ptr == null) return m_alloc(size);
    const header = getHeader(ptr.?);
    const buf = getBuf(header);
    if (size == 0) {
        alloc.free(buf);
        return null;
    }

    const buf_len = Header.len + size;
    if (alloc.rawResize(buf, std.math.log2(al), buf_len, @returnAddress())) {
        setHeader(buf.ptr, buf_len);
        return ptr;
    }

    const new_buf = alloc.reallocAdvanced(
        buf,
        buf_len,
        @returnAddress(),
    ) catch |e| switch (e) {
        error.OutOfMemory => return null,
    };
    setHeader(new_buf.ptr, buf_len);
    return cPtr(new_buf.ptr);
}

export fn c_alloc(nmemb: usize, size: usize) callconv(.C) ?[*]align(al) u8 {
    const total = std.math.mul(usize, nmemb, size) catch {
        // TODO: set errno
        // errno = c.ENOMEM;
        return null;
    };
    const ptr = m_alloc(total) orelse return null;
    @memset(ptr[0..total], 0);
    return ptr;
}

pub export fn f_ree(ptr: ?[*]align(al) u8) callconv(.C) void {
    if (ptr == null) return;

    // check header
    const header = getHeader(ptr.?);
    if (header.magic != Header.MAGIC) {
        // either doble-free or allocated outside those custom mallocs
        // TODO: why?
        if (header.magic == Header.NOMAGIC) std.c.free(@as(?*anyopaque, @ptrCast(ptr)));
        return;
    }
    header.magic = Header.NOMAGIC; // prevent double free

    const buf = getBuf(header);
    alloc.free(buf);
}

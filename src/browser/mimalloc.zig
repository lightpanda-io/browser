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

var heap: ?*c.mi_heap_t = null;

pub fn create() void {
    std.debug.assert(heap == null);
    heap = c.mi_heap_new();
    std.debug.assert(heap != null);
}

pub fn destroy() void {
    std.debug.assert(heap != null);
    c.mi_heap_destroy(heap.?);
    heap = null;
}

pub fn getRSS() i64 {
    if (@import("builtin").mode != .Debug) {
        // just don't trust my implementation, plus a caller might not know
        // that this requires parsing some unstructured data
        @compileError("Only available in debug builds");
    }
    var buf: [1024 * 8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var writer = std.Io.Writer.Allocating.init(fba.allocator());

    c.mi_stats_print_out(struct {
        fn print(msg: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
            const w: *std.Io.Writer = @ptrCast(@alignCast(data.?));
            w.writeAll(std.mem.span(msg)) catch |err| {
                std.debug.print("Failed to write mimalloc data: {}\n", .{err});
            };
        }
    }.print, &writer.writer);

    const data = writer.written();
    const index = std.mem.indexOf(u8, data, "rss: ") orelse return -1;
    const sep = std.mem.indexOfScalarPos(u8, data, index + 5, ' ') orelse return -2;
    const value = std.fmt.parseFloat(f64, data[index + 5 .. sep]) catch return -3;
    const unit = data[sep + 1 ..];
    if (std.mem.startsWith(u8, unit, "KiB,")) {
        return @as(i64, @intFromFloat(value)) * 1024;
    }

    if (std.mem.startsWith(u8, unit, "MiB,")) {
        return @as(i64, @intFromFloat(value)) * 1024 * 1024;
    }

    if (std.mem.startsWith(u8, unit, "GiB,")) {
        return @as(i64, @intFromFloat(value)) * 1024 * 1024 * 1024;
    }

    return -4;
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

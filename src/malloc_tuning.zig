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

//! glibc malloc tuning applied at startup.
//!
//! glibc raises its mmap threshold dynamically (up to 32MB) as large blocks
//! are freed, so the MB-sized bursts a page can produce (response bodies,
//! script sources) end up on the brk heap. Once freed, they stay stranded
//! under live chunks and the process holds that memory until it exits.
//! Pinning the threshold at 128KB keeps those blocks mmapped, and freeing them
//! returns them to the OS.
//!
//! glibc's own `MALLOC_MMAP_THRESHOLD_` / `GLIBC_TUNABLES` remain the override:
//! when either sets the threshold, it is left alone.
//!
//! glibc also gives a heap's free memory back only from its top: free memory
//! below a chunk that is still live stays resident. A connection's allocations
//! (on its own thread and on V8's platform worker threads) are freed when it
//! closes, but the few chunks that outlive it keep that memory in the process,
//! so the idle footprint climbs to the largest page served so far. `trim`
//! returns it: the server calls it when a connection's worker is done.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda.zig");

const log = lp.log;

const MMAP_THRESHOLD = 128 * 1024;

const is_glibc = builtin.target.os.tag == .linux and builtin.target.abi.isGnu();

// malloc.h
const M_MMAP_THRESHOLD: c_int = -3;
extern "c" fn mallopt(param: c_int, value: c_int) c_int;
extern "c" fn malloc_trim(pad: usize) c_int;

pub fn apply() void {
    if (comptime !is_glibc) {
        return;
    }
    if (userConfigured()) {
        return;
    }
    if (mallopt(M_MMAP_THRESHOLD, MMAP_THRESHOLD) == 0) {
        log.warn(.app, "mallopt mmap_threshold failed", .{});
    }
}

/// Returns the free memory of every malloc arena to the OS, including the
/// free pages below live chunks that free() never returns.
pub fn trim() void {
    if (comptime !is_glibc) {
        return;
    }
    _ = malloc_trim(0);
}

fn userConfigured() bool {
    if (std.c.getenv("MALLOC_MMAP_THRESHOLD_") != null) {
        return true;
    }
    const tunables = std.c.getenv("GLIBC_TUNABLES") orelse return false;
    return std.mem.find(u8, std.mem.span(tunables), "glibc.malloc.mmap_threshold") != null;
}

const testing = @import("testing.zig");
extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

test "malloc_tuning: glibc env overrides" {
    _ = unsetenv(@constCast("MALLOC_MMAP_THRESHOLD_"));
    _ = unsetenv(@constCast("GLIBC_TUNABLES"));
    try testing.expectEqual(false, userConfigured());

    _ = setenv(@constCast("GLIBC_TUNABLES"), @constCast("glibc.malloc.arena_max=2"), 1);
    defer _ = unsetenv(@constCast("GLIBC_TUNABLES"));
    try testing.expectEqual(false, userConfigured());

    _ = setenv(@constCast("GLIBC_TUNABLES"), @constCast("glibc.malloc.arena_max=2:glibc.malloc.mmap_threshold=65536"), 1);
    try testing.expectEqual(true, userConfigured());

    _ = unsetenv(@constCast("GLIBC_TUNABLES"));
    _ = setenv(@constCast("MALLOC_MMAP_THRESHOLD_"), @constCast("65536"), 1);
    defer _ = unsetenv(@constCast("MALLOC_MMAP_THRESHOLD_"));
    try testing.expectEqual(true, userConfigured());
}

test "malloc_tuning: trim returns the free memory below a live chunk" {
    // TSan replaces malloc/free with its own allocator: glibc's arenas, and
    // so malloc_trim, never see the blocks.
    if (comptime !is_glibc or builtin.sanitize_thread) {
        return error.SkipZigTest;
    }

    const Retained = struct {
        baseline: usize = 0,
        before: usize = 0,
        after: usize = 0,

        // On its own thread, so it works in a thread arena like a
        // connection's worker, away from the other tests' allocations.
        fn run(r: *@This()) void {
            // blocks under the mmap threshold, so they come from the arena
            const block = 16 * 1024;
            const count = 2048; // 32MB, within one 64MB thread heap
            var blocks: [count]?*anyopaque = undefined;

            r.baseline = residentBytes();
            for (&blocks) |*b| {
                b.* = std.c.malloc(block);
                @memset(@as([*]u8, @ptrCast(b.*.?))[0..block], 0xaa);
            }
            // the last block outlives the others, above them. Not a separate
            // small chunk: the thread can get an arena reused from an exited
            // thread, whose free lists can place a small chunk below the
            // blocks, and then free() shrinks the heap by itself.
            const live = blocks[count - 1];
            for (blocks[0 .. count - 1]) |b| {
                std.c.free(b);
            }
            r.before = residentBytes();
            trim();
            r.after = residentBytes();
            std.c.free(live);
        }

        // the resident set of the process, from /proc/self/statm (in pages)
        fn residentBytes() usize {
            var buf: [128]u8 = undefined;
            const fd = std.c.open("/proc/self/statm", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (fd < 0) return 0;
            defer _ = std.c.close(fd);
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
            _ = it.next(); // size
            const resident = std.fmt.parseInt(usize, it.next() orelse return 0, 10) catch return 0;
            return resident * std.heap.pageSize();
        }
    };

    var r: Retained = .{};
    const t = try std.Thread.spawn(.{}, Retained.run, .{&r});
    t.join();
    // free() kept the blocks resident, trim() gave them back
    try testing.expect(r.before -| r.baseline >= 24 * 1024 * 1024);
    try testing.expect(r.before -| r.after >= 24 * 1024 * 1024);
}

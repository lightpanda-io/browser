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

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda.zig");

const log = lp.log;

const MMAP_THRESHOLD = 128 * 1024;

// malloc.h
const M_MMAP_THRESHOLD: c_int = -3;
extern "c" fn mallopt(param: c_int, value: c_int) c_int;

pub fn apply() void {
    if (comptime (builtin.os.tag != .linux or builtin.abi.isGnu() == false)) {
        return;
    }
    if (userConfigured()) {
        return;
    }
    if (mallopt(M_MMAP_THRESHOLD, MMAP_THRESHOLD) == 0) {
        log.warn(.app, "mallopt mmap_threshold failed", .{});
    }
}

fn userConfigured() bool {
    if (std.c.getenv("MALLOC_MMAP_THRESHOLD_") != null) {
        return true;
    }
    const tunables = std.c.getenv("GLIBC_TUNABLES") orelse return false;
    return std.mem.indexOf(u8, std.mem.span(tunables), "glibc.malloc.mmap_threshold") != null;
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

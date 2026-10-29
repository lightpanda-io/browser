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

// Zig's compiler_rt ships an aarch64 __clear_cache that omits the `dsb ish`
// between the `ic ivau` loop and the final `isb`. You can see the original
// llvm emit here:
// https://github.com/llvm/llvm-project/blob/cff0e6b5dc60cce76e85f0d9e9af537e76759315/compiler-rt/lib/builtins/clear_cache.c#L151
// which is not in Zig's port:
// https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/compiler_rt/clear_cache.zig#L145
// Without these barriers can result in fetching a stale instruction and getting
// SIGILL on a invalid instruction.
// See: https://github.com/lightpanda-io/browser/issues/3672

// compiler_rt gives its routines weak linkage, so we can include a strong
// definition with a fix.
// Darwin is unaffected: that path defers to libc's sys_icache_invalidate.
//
// Sequence per ARM ARM B2.4.4, matching llvm-project's clear_cache.c.

const builtin = @import("builtin");

const arm64 = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => true,
    else => false,
};

comptime {
    if (arm64 and builtin.os.tag == .linux) {
        @export(&__clear_cache, .{ .name = "__clear_cache", .linkage = .strong });
    }
}

fn __clear_cache(start: usize, end: usize) callconv(.c) void {
    const ctr_el0 = asm volatile ("mrs %[ctr_el0], ctr_el0"
        : [ctr_el0] "=r" (-> u64),
    );

    var addr: u64 = undefined;

    // CTR_EL0.IDC set means data cache cleaning to the point of unification is
    // not required for instruction to data coherence.
    if ((ctr_el0 >> 28) & 1 == 0) {
        const line_size = @as(usize, 4) << @intCast((ctr_el0 >> 16) & 15);
        addr = start & ~(line_size - 1);
        while (addr < end) : (addr += line_size) {
            asm volatile ("dc cvau, %[addr]"
                :
                : [addr] "r" (addr),
            );
        }
    }
    asm volatile ("dsb ish");

    // CTR_EL0.DIC set means instruction cache invalidation to the point of
    // unification is not required for instruction to data coherence.
    if ((ctr_el0 >> 29) & 1 == 0) {
        const line_size = @as(usize, 4) << @intCast(ctr_el0 & 15);
        addr = start & ~(line_size - 1);
        while (addr < end) : (addr += line_size) {
            asm volatile ("ic ivau, %[addr]"
                :
                : [addr] "r" (addr),
            );
        }
        asm volatile ("dsb ish");
    }

    asm volatile ("isb sy");
}

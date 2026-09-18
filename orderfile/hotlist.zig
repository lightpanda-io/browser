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

//! usage: hotlist <pid> <binary> <out-dir>
//!
//! Writes hot.text and hot.rodata into <out-dir>: the symbols of <binary>
//! that overlap a resident page of its mappings in process <pid>
//! (/proc/<pid>/pagemap), in address order; and resident.txt, every mapping
//! of the process with its resident page count, for looking at what else is
//! resident.
const std = @import("std");
const elf = @import("elf.zig");

const Allocator = std.mem.Allocator;

const page = 4096;

const Mapping = struct {
    lo: u64,
    path: []const u8,
    pages: usize,
    resident: usize,
    /// Per page, for the binary's mappings only.
    present: ?[]const bool,
};

const Hot = std.StringHashMapUnmanaged(void);

pub fn main(init: std.process.Init) !void {
    // One-shot tool: everything lives until exit.
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const pid = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    const binary_arg = args.next() orelse return error.Usage;
    const out_dir = args.next() orelse return error.Usage;
    // /proc/<pid>/maps prints canonical paths.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const binary = path_buf[0..try cwd.realPathFile(io, binary_arg, &path_buf)];

    const mappings = try readMappings(gpa, io, pid, binary);
    var report: std.ArrayList(u8) = .empty;
    var total: usize = 0;
    for (mappings) |m| {
        total += m.resident;
        try report.print(gpa, "{x}-{x} {d}/{d} {s}\n", .{ m.lo, m.lo + m.pages * page, m.resident, m.pages, m.path });
    }
    try report.print(gpa, "resident pages total {d} = {d} KB\n", .{ total, total * page / 1024 });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(gpa, &.{ out_dir, "resident.txt" }), .data = report.items });
    std.debug.print("resident pages total {d} = {d} KB\n", .{ total, total * page / 1024 });

    const obj = try elf.Object.parse(gpa, try elf.mapFile(io, binary)) orelse return error.NotAnElf64Binary;
    var sections: std.ArrayList(elf.Section) = .empty;
    for (obj.sections) |sh| {
        if (sh.addr != 0) try sections.append(gpa, sh);
    }
    std.mem.sortUnstable(elf.Section, sections.items, {}, struct {
        fn lessThan(_: void, a: elf.Section, b: elf.Section) bool {
            return a.addr < b.addr;
        }
    }.lessThan);
    var symbols: std.ArrayList(elf.Symbol) = .empty;
    for (try obj.symbols(gpa)) |sym| {
        if (!sym.definedIn(obj) or sym.name.len == 0) continue;
        if (sym.type == .SECTION or sym.type == .FILE) continue;
        if (obj.sections[sym.shndx].flags & std.elf.SHF_ALLOC == 0) continue;
        try symbols.append(gpa, sym);
    }
    std.mem.sortUnstable(elf.Symbol, symbols.items, {}, struct {
        fn lessThan(_: void, a: elf.Symbol, b: elf.Symbol) bool {
            if (a.value != b.value) return a.value < b.value;
            if (a.size != b.size) return a.size < b.size;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var hot_text: Hot = .empty;
    var hot_rodata: Hot = .empty;
    var per_section: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (mappings) |m| {
        const present = m.present orelse continue;
        for (present, 0..) |is_present, i| {
            if (!is_present) continue;
            const va = m.lo + i * page;
            const section = sectionOf(sections.items, va);
            const kb = try per_section.getOrPut(gpa, section);
            if (!kb.found_existing) kb.value_ptr.* = 0;
            kb.value_ptr.* += page / 1024;
            const hot = if (std.mem.eql(u8, section, ".text") or std.mem.eql(u8, section, ".text.hot"))
                &hot_text
            else if (std.mem.eql(u8, section, ".rodata") or std.mem.eql(u8, section, ".rodata.hot"))
                &hot_rodata
            else
                continue;
            try collect(gpa, symbols.items, va, hot);
        }
    }

    std.debug.print("text: {d} hot symbols\nrodata: {d} hot symbols\n", .{ hot_text.count(), hot_rodata.count() });
    try write(gpa, io, out_dir, "hot.text", symbols.items, &hot_text);
    try write(gpa, io, out_dir, "hot.rodata", symbols.items, &hot_rodata);

    per_section.sort(struct {
        kb: []const usize,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.kb[a] > ctx.kb[b];
        }
    }{ .kb = per_section.values() });
    const top = @min(per_section.count(), 12);
    for (per_section.keys()[0..top], per_section.values()[0..top]) |name, kb| {
        std.debug.print("  {d:7} KB {s}\n", .{ kb, name });
    }
}

/// The process's mappings with their resident page counts; the pages
/// themselves are kept for the mappings of `binary`. Kernel-side mappings
/// (vsyscall) are left out.
fn readMappings(gpa: Allocator, io: std.Io, pid: u32, binary: []const u8) ![]const Mapping {
    const cwd = std.Io.Dir.cwd();
    // procfs reports a size of 0, so the file has to be streamed.
    const maps_file = try cwd.openFile(io, try std.fmt.allocPrint(gpa, "/proc/{d}/maps", .{pid}), .{});
    defer maps_file.close(io);
    var buf: [4096]u8 = undefined;
    var maps_reader = maps_file.readerStreaming(io, &buf);
    const maps = try maps_reader.interface.allocRemaining(gpa, .unlimited);
    const pagemap = try cwd.openFile(io, try std.fmt.allocPrint(gpa, "/proc/{d}/pagemap", .{pid}), .{});
    defer pagemap.close(io);

    var mappings: std.ArrayList(Mapping) = .empty;
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        // lo-hi perms offset dev inode [path]
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        for (0..4) |_| _ = fields.next();
        const path = std.mem.trim(u8, fields.rest(), " ");
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const lo = try std.fmt.parseInt(u64, range[0..dash], 16);
        const hi = try std.fmt.parseInt(u64, range[dash + 1 ..], 16);
        if (lo >= 1 << 47) continue;

        const pages: usize = @intCast((hi - lo) / page);
        const present: ?[]bool = if (std.mem.eql(u8, path, binary)) try gpa.alloc(bool, pages) else null;
        var resident: usize = 0;
        // One pagemap entry (u64, bit 63 = present) per page, read in chunks:
        // V8 reserves tens of GB of address space that is never resident.
        var entries: [1024 * 8]u8 = undefined;
        var done: usize = 0;
        while (done < pages) {
            const count: usize = @min(entries.len / 8, pages - done);
            const chunk = entries[0 .. count * 8];
            if (try pagemap.readPositionalAll(io, chunk, (lo / page + done) * 8) != chunk.len) {
                return error.ShortPagemapRead;
            }
            for (0..chunk.len / 8) |i| {
                const is_present = std.mem.readInt(u64, chunk[i * 8 ..][0..8], .little) >> 63 == 1;
                resident += @intFromBool(is_present);
                if (present) |p| p[done + i] = is_present;
            }
            done += chunk.len / 8;
        }
        try mappings.append(gpa, .{ .lo = lo, .path = path, .pages = pages, .resident = resident, .present = present });
    }
    return mappings.items;
}

fn orderAddr(va: u64, section: elf.Section) std.math.Order {
    return std.math.order(va, section.addr);
}

fn orderValue(va: u64, symbol: elf.Symbol) std.math.Order {
    return std.math.order(va, symbol.value);
}

fn sectionOf(sections: []const elf.Section, va: u64) []const u8 {
    const i = std.sort.upperBound(elf.Section, sections, va, orderAddr);
    if (i == 0) return "?";
    const s = sections[i - 1];
    return if (va < s.addr + s.size) s.name else "?";
}

/// Adds the symbols overlapping the page at `va` to `hot`. Sized symbols
/// count when any byte of them is in the page, sizeless ones when they start
/// in it; the backwards walk stops at the first sized symbol that ends before
/// the page, or 64KB back.
fn collect(gpa: Allocator, symbols: []const elf.Symbol, va: u64, hot: *Hot) !void {
    var i = std.sort.lowerBound(elf.Symbol, symbols, va + page, orderValue);
    while (i > 0) {
        i -= 1;
        const sym = symbols[i];
        const end = sym.value + @max(sym.size, 1);
        if (end <= va and sym.size != 0) break;
        if (end > va or (sym.size == 0 and sym.value >= va)) {
            try hot.put(gpa, sym.name, {});
        }
        if (sym.value + 65536 < va) break;
    }
}

/// The hot symbols in address order, one per line.
fn write(gpa: Allocator, io: std.Io, out_dir: []const u8, name: []const u8, symbols: []const elf.Symbol, hot: *Hot) !void {
    var out: std.ArrayList(u8) = .empty;
    for (symbols) |sym| {
        if (hot.fetchRemove(sym.name) == null) continue;
        try out.appendSlice(gpa, sym.name);
        try out.append(gpa, '\n');
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(gpa, &.{ out_dir, name }), .data = out.items });
}

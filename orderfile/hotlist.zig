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
//! resident. <binary> is matched against the mappings' paths as given.
const std = @import("std");
const elf = @import("elf.zig");

const Allocator = std.mem.Allocator;

const page = 4096;

const Mapping = struct {
    lo: u64,
    hi: u64,
    path: []const u8,
    present: []const bool,
    resident: usize,
};

const Symbol = struct {
    addr: u64,
    size: u64,
    name: []const u8,

    fn lessThan(_: void, a: Symbol, b: Symbol) bool {
        if (a.addr != b.addr) return a.addr < b.addr;
        if (a.size != b.size) return a.size < b.size;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const Section = struct {
    addr: u64,
    size: u64,
    name: []const u8,

    fn lessThan(_: void, a: Section, b: Section) bool {
        return a.addr < b.addr;
    }
};

const Hot = std.StringArrayHashMapUnmanaged(u64);

pub fn main(init: std.process.Init) !void {
    // One-shot tool: everything lives until exit.
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const pid = try std.fmt.parseInt(u32, args.next() orelse return error.Usage, 10);
    const binary = args.next() orelse return error.Usage;
    const out_dir = args.next() orelse return error.Usage;

    const mappings = try readMappings(gpa, io, pid);
    var report: std.ArrayList(u8) = .empty;
    var total: usize = 0;
    for (mappings) |m| {
        total += m.resident;
        try report.print(gpa, "{x}-{x} {d}/{d} {s}\n", .{ m.lo, m.hi, m.resident, m.present.len, m.path });
    }
    try report.print(gpa, "resident pages total {d} = {d} KB\n", .{ total, total * page / 1024 });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(gpa, &.{ out_dir, "resident.txt" }), .data = report.items });
    std.debug.print("resident pages total {d} = {d} KB\n", .{ total, total * page / 1024 });

    const obj = try elf.Object.parse(gpa, try cwd.readFileAlloc(io, binary, gpa, .unlimited)) orelse return error.NotAnElf64Binary;
    var sections: std.ArrayList(Section) = .empty;
    for (obj.sections) |sh| {
        if (sh.addr == 0) continue;
        try sections.append(gpa, .{ .addr = sh.addr, .size = sh.size, .name = sh.name });
    }
    std.mem.sort(Section, sections.items, {}, Section.lessThan);
    var symbols: std.ArrayList(Symbol) = .empty;
    for (try obj.symbols(gpa)) |sym| {
        if (!sym.definedIn(obj) or sym.name.len == 0) continue;
        if (sym.type == elf.STT_SECTION or sym.type == elf.STT_FILE) continue;
        if (obj.sections[sym.shndx].flags & elf.SHF_ALLOC == 0) continue;
        try symbols.append(gpa, .{ .addr = sym.value, .size = sym.size, .name = sym.name });
    }
    std.mem.sort(Symbol, symbols.items, {}, Symbol.lessThan);

    var hot_text: Hot = .empty;
    var hot_rodata: Hot = .empty;
    var per_section: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (mappings) |m| {
        if (!std.mem.eql(u8, m.path, binary)) continue;
        for (m.present, 0..) |present, i| {
            if (!present) continue;
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

    try write(gpa, io, out_dir, "hot.text", &hot_text);
    try write(gpa, io, out_dir, "hot.rodata", &hot_rodata);
    std.debug.print("text: {d} hot symbols\nrodata: {d} hot symbols\n", .{ hot_text.count(), hot_rodata.count() });

    const Entry = struct { name: []const u8, kb: usize };
    var top: std.ArrayList(Entry) = .empty;
    for (per_section.keys(), per_section.values()) |name, kb| {
        try top.append(gpa, .{ .name = name, .kb = kb });
    }
    std.mem.sort(Entry, top.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.kb > b.kb;
        }
    }.lessThan);
    for (top.items[0..@min(top.items.len, 12)]) |entry| {
        std.debug.print("  {d:7} KB {s}\n", .{ entry.kb, entry.name });
    }
}

/// The process's mappings with their resident pages. Kernel-side mappings
/// (vsyscall) are left out.
fn readMappings(gpa: Allocator, io: std.Io, pid: u32) ![]const Mapping {
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
        for (0..4) |_| _ = fields.next() orelse continue;
        const path = std.mem.trim(u8, fields.rest(), " ");
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const lo = try std.fmt.parseInt(u64, range[0..dash], 16);
        const hi = try std.fmt.parseInt(u64, range[dash + 1 ..], 16);
        if (lo >= 1 << 47) continue;

        const n: usize = @intCast((hi - lo) / page);
        const entries = try gpa.alloc(u8, n * 8);
        const read = try pagemap.readPositionalAll(io, entries, lo / page * 8);
        if (read != entries.len) return error.ShortPagemapRead;
        const present = try gpa.alloc(bool, n);
        var resident: usize = 0;
        for (present, 0..) |*p, i| {
            p.* = std.mem.readInt(u64, entries[i * 8 ..][0..8], .little) >> 63 == 1;
            resident += @intFromBool(p.*);
        }
        try mappings.append(gpa, .{ .lo = lo, .hi = hi, .path = path, .present = present, .resident = resident });
    }
    return mappings.items;
}

fn sectionOf(sections: []const Section, va: u64) []const u8 {
    var lo: usize = 0;
    var hi: usize = sections.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sections[mid].addr <= va) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return "?";
    const s = sections[lo - 1];
    return if (va < s.addr + s.size) s.name else "?";
}

/// Adds the symbols overlapping the page at `va` to `hot`. Sized symbols
/// count when any byte of them is in the page, sizeless ones when they start
/// in it; the backwards walk stops at the first sized symbol that ends before
/// the page, or 64KB back.
fn collect(gpa: Allocator, symbols: []const Symbol, va: u64, hot: *Hot) !void {
    // Index of the first symbol starting past the page.
    var lo: usize = 0;
    var hi: usize = symbols.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (symbols[mid].addr < va + page) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i > 0) {
        i -= 1;
        const sym = symbols[i];
        const end = sym.addr + @max(sym.size, 1);
        if (end <= va and sym.size != 0) break;
        if (end > va or (sym.size == 0 and sym.addr >= va)) {
            try hot.put(gpa, sym.name, sym.addr);
        }
        if (sym.addr + 65536 < va) break;
    }
}

/// The symbols in address order, one per line.
fn write(gpa: Allocator, io: std.Io, out_dir: []const u8, name: []const u8, hot: *const Hot) !void {
    const Entry = struct { addr: u64, index: usize, name: []const u8 };
    const entries = try gpa.alloc(Entry, hot.count());
    for (entries, hot.keys(), hot.values(), 0..) |*e, sym, addr, index| {
        e.* = .{ .addr = addr, .index = index, .name = sym };
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return if (a.addr != b.addr) a.addr < b.addr else a.index < b.index;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try out.appendSlice(gpa, e.name);
        try out.append(gpa, '\n');
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(gpa, &.{ out_dir, name }), .data = out.items });
}

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

//! Renames the sections of hot functions in the prebuilt V8 archive so the
//! orderfile linker script can gather them with a single `.text.hot.*` glob.
//!
//! Chromium compiles V8 with `-ffunction-sections -fno-unique-section-names`:
//! every function gets its own section, but they are all called `.text`
//! (`.rodata`, `.text.unlikely.`, ...), so a linker script cannot address
//! them individually. For each ELF member, a section whose defining symbol
//! is in the hot list becomes `.text.hot.<symbol>` / `.rodata.hot.<symbol>`.
//! Names are appended to the member's .shstrtab, which moves to the end of
//! the member (LLVM shares it with .strtab, so each touched member grows by
//! its symbol-name table too — ~25MB over the archive, cache only); nothing
//! else in the object changes. The archive symbol index
//! is rewritten with the shifted member offsets.
//!
//! usage: mark_hot_sections <in.a> <hot-symbols.txt> <out.a>
const std = @import("std");

const Allocator = std.mem.Allocator;
const HotSet = std.StringHashMapUnmanaged(void);

/// Section names left generic by -fno-unique-section-names.
const generic_names = [_][]const u8{ ".text", ".text.unlikely.", ".text.startup.", ".text.exit.", ".rodata" };

pub fn main(init: std.process.Init) !void {
    // One-shot tool: everything lives until exit.
    const gpa = init.arena.allocator();
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const in_path = args.next() orelse return error.Usage;
    const hot_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const archive = try cwd.readFileAlloc(io, in_path, gpa, .unlimited);
    const hot_list = try cwd.readFileAlloc(io, hot_path, gpa, .unlimited);

    var hot: HotSet = .empty;
    var lines = std.mem.splitScalar(u8, hot_list, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len > 0) {
            try hot.put(gpa, name, {});
        }
    }

    var out: std.ArrayList(u8) = .empty;
    const renamed = try rewriteArchive(gpa, archive, &hot, &out);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.items });
    if (renamed == 0) {
        return error.NoHotSections;
    }
}

const Member = struct {
    header: *const [60]u8,
    name: []const u8,
    body: []const u8,
    old_offset: usize,
    new_offset: usize = 0,
};

fn rewriteArchive(gpa: Allocator, archive: []const u8, hot: *const HotSet, out: *std.ArrayList(u8)) !usize {
    if (std.mem.startsWith(u8, archive, "!<arch>\n") == false) {
        return error.NotAnArchive;
    }

    var members: std.ArrayList(Member) = .empty;
    var pos: usize = 8;
    while (pos + 60 <= archive.len) {
        const header = archive[pos..][0..60];
        const size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10);
        if (pos + 60 + size > archive.len) {
            return error.TruncatedArchive;
        }
        try members.append(gpa, .{
            .header = header,
            .name = std.mem.trimEnd(u8, header[0..16], " "),
            .body = archive[pos + 60 ..][0..size],
            .old_offset = pos,
        });
        pos += 60 + size + (size & 1);
    }

    var renamed: usize = 0;
    for (members.items) |*m| {
        if (!std.mem.startsWith(u8, m.body, "\x7fELF")) {
            continue;
        }
        if (try markMember(gpa, m.body, hot, &renamed)) |body| {
            m.body = body;
        }
    }

    var offsets: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    pos = 8;
    for (members.items) |*m| {
        m.new_offset = pos;
        try offsets.put(gpa, m.old_offset, pos);
        pos += 60 + m.body.len + (m.body.len & 1);
    }

    try out.ensureTotalCapacity(gpa, pos);
    out.appendSliceAssumeCapacity("!<arch>\n");
    for (members.items) |m| {
        var header = m.header.*;
        _ = try std.fmt.bufPrint(header[48..58], "{d:<10}", .{m.body.len});
        out.appendSliceAssumeCapacity(&header);
        const start = out.items.len;
        out.appendSliceAssumeCapacity(m.body);
        if (std.mem.eql(u8, m.name, "/")) {
            try remapIndex(u32, out.items[start..], &offsets);
        } else if (std.mem.eql(u8, m.name, "/SYM64/")) {
            try remapIndex(u64, out.items[start..], &offsets);
        }
        if (m.body.len & 1 == 1) {
            out.appendAssumeCapacity('\n');
        }
    }
    return renamed;
}

/// GNU ar symbol index: big-endian count, then one member offset per symbol.
fn remapIndex(comptime T: type, index: []u8, offsets: *const std.AutoHashMapUnmanaged(usize, usize)) !void {
    const w = @sizeOf(T);
    if (index.len < w) {
        return error.BadSymbolIndex;
    }
    const count: usize = @intCast(std.mem.readInt(T, index[0..w], .big));
    if (index.len < w + count * w) {
        return error.BadSymbolIndex;
    }
    for (0..count) |i| {
        const entry = index[w + i * w ..][0..w];
        const old: usize = @intCast(std.mem.readInt(T, entry, .big));
        const new = offsets.get(old) orelse return error.BadSymbolIndex;
        std.mem.writeInt(T, entry, @intCast(new), .big);
    }
}

fn cstr(table: []const u8, offset: usize) ![]const u8 {
    if (offset >= table.len) {
        return error.BadStringOffset;
    }
    return std.mem.sliceTo(table[offset..], 0);
}

/// Returns the rewritten object, or null when no section of it is hot.
fn markMember(gpa: Allocator, elf: []const u8, hot: *const HotSet, renamed: *usize) !?[]const u8 {
    // ELF64 little-endian only; anything else is passed through untouched.
    if (elf.len < 64 or elf[4] != 2 or elf[5] != 1) {
        return null;
    }
    const shoff: usize = @intCast(std.mem.readInt(u64, elf[0x28..][0..8], .little));
    const shentsize = std.mem.readInt(u16, elf[0x3A..][0..2], .little);
    const shnum = std.mem.readInt(u16, elf[0x3C..][0..2], .little);
    const shstrndx = std.mem.readInt(u16, elf[0x3E..][0..2], .little);
    if (shentsize != 64 or shnum == 0 or shstrndx >= shnum) {
        return null;
    }
    if (shoff + @as(usize, shnum) * 64 > elf.len) {
        return error.BadElf;
    }

    const Shdr = struct {
        name: u32,
        type: u32,
        offset: usize,
        size: usize,
        link: u32,

        fn read(e: []const u8, at: usize) @This() {
            return .{
                .name = std.mem.readInt(u32, e[at..][0..4], .little),
                .type = std.mem.readInt(u32, e[at + 4 ..][0..4], .little),
                .offset = @intCast(std.mem.readInt(u64, e[at + 24 ..][0..8], .little)),
                .size = @intCast(std.mem.readInt(u64, e[at + 32 ..][0..8], .little)),
                .link = std.mem.readInt(u32, e[at + 40 ..][0..4], .little),
            };
        }
    };
    const shdrs = try gpa.alloc(Shdr, shnum);
    for (shdrs, 0..) |*sh, i| {
        sh.* = Shdr.read(elf, shoff + i * 64);
    }

    const section = struct {
        fn bytes(e: []const u8, sh: Shdr) ![]const u8 {
            if (sh.offset + sh.size > e.len) {
                return error.BadElf;
            }
            return e[sh.offset..][0..sh.size];
        }
    };
    const shstrtab = try section.bytes(elf, shdrs[shstrndx]);

    // The hot symbol that defines each section, if any.
    const hot_sym = try gpa.alloc(?[]const u8, shnum);
    @memset(hot_sym, null);
    for (shdrs) |sh| {
        if (sh.type != 2) {
            continue; // SHT_SYMTAB
        }
        if (sh.link >= shnum) {
            return error.BadElf;
        }
        const strtab = try section.bytes(elf, shdrs[sh.link]);
        const symtab = try section.bytes(elf, sh);
        var i: usize = 0;
        while (i + 24 <= symtab.len) : (i += 24) {
            const st_name = std.mem.readInt(u32, symtab[i..][0..4], .little);
            const st_type = symtab[i + 4] & 0xf;
            const st_shndx = std.mem.readInt(u16, symtab[i + 6 ..][0..2], .little);
            if (st_shndx == 0 or st_shndx >= shnum) {
                continue;
            }
            if (st_type != 1 and st_type != 2) {
                continue; // STT_OBJECT, STT_FUNC
            }

            if (hot_sym[st_shndx] != null) {
                continue;
            }
            const name = try cstr(strtab, st_name);
            if (hot.contains(name)) {
                hot_sym[st_shndx] = name;
            }
        }
    }

    var new_shstrtab: std.ArrayList(u8) = .empty;
    try new_shstrtab.appendSlice(gpa, shstrtab);
    const new_name = try gpa.alloc(?u32, shnum);
    @memset(new_name, null);
    var count: usize = 0;
    for (shdrs, 0..) |sh, idx| {
        if (sh.type != 1) {
            continue; // SHT_PROGBITS
        }
        const sym = hot_sym[idx] orelse continue;
        // Leave V8's embedded builtins blob (a single multi-symbol .text
        // section, `Builtins_*`) in cold .text. Pulling its 2MB into
        // .text.hot shifts the layout so V8's runtime code range no longer
        // reaches the blob by pc-relative call, and it copies the whole blob
        // into an executable anonymous mapping (+~1.8MB RSS). See
        // orderfile/README.md.
        if (std.mem.startsWith(u8, sym, "Builtins_")) {
            continue;
        }
        const name = try cstr(shstrtab, sh.name);
        const generic = for (generic_names) |g| {
            if (std.mem.eql(u8, name, g)) {
                break true;
            }
        } else false;
        if (generic == false) {
            continue;
        }
        new_name[idx] = @intCast(new_shstrtab.items.len);
        try new_shstrtab.appendSlice(gpa, if (std.mem.startsWith(u8, name, ".text")) ".text.hot." else ".rodata.hot.");
        try new_shstrtab.appendSlice(gpa, sym);
        try new_shstrtab.append(gpa, 0);
        count += 1;
    }
    if (count == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(gpa, elf.len + 8 + new_shstrtab.items.len);
    buf.appendSliceAssumeCapacity(elf);
    while (buf.items.len % 8 != 0) {
        buf.appendAssumeCapacity(0);
    }
    const strtab_offset = buf.items.len;
    buf.appendSliceAssumeCapacity(new_shstrtab.items);

    const shstr_hdr = shoff + @as(usize, shstrndx) * 64;
    std.mem.writeInt(u64, buf.items[shstr_hdr + 24 ..][0..8], strtab_offset, .little);
    std.mem.writeInt(u64, buf.items[shstr_hdr + 32 ..][0..8], new_shstrtab.items.len, .little);
    for (new_name, 0..) |maybe, idx| {
        const off = maybe orelse continue;
        std.mem.writeInt(u32, buf.items[shoff + idx * 64 ..][0..4], off, .little);
    }
    renamed.* += count;
    return buf.items;
}

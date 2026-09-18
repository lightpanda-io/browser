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
const elf = @import("elf.zig");

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
    const archive = try elf.mapFile(io, in_path);
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
    const members = try elf.archiveMembers(gpa, archive) orelse return error.NotAnArchive;
    const renamed = try rewriteArchive(gpa, members, &hot, &out);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.items });
    if (renamed == 0) {
        return error.NoHotSections;
    }
}

const Member = struct {
    member: elf.Member,
    body: []const u8,
    new_offset: usize = 0,
};

fn rewriteArchive(gpa: Allocator, archive: []const elf.Member, hot: *const HotSet, out: *std.ArrayList(u8)) !usize {
    const members = try gpa.alloc(Member, archive.len);
    var renamed: usize = 0;
    for (members, archive) |*m, member| {
        m.* = .{ .member = member, .body = member.body };
        if (try markMember(gpa, member.body, hot, &renamed)) |body| {
            m.body = body;
        }
    }

    var offsets: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    var pos: usize = 8;
    for (members) |*m| {
        m.new_offset = pos;
        try offsets.put(gpa, m.member.offset, pos);
        pos += 60 + m.body.len + (m.body.len & 1);
    }

    try out.ensureTotalCapacity(gpa, pos);
    out.appendSliceAssumeCapacity("!<arch>\n");
    for (members) |m| {
        var header = m.member.header.*;
        _ = try std.fmt.bufPrint(&header.ar_size, "{d:<10}", .{m.body.len});
        out.appendSliceAssumeCapacity(std.mem.asBytes(&header));
        const start = out.items.len;
        out.appendSliceAssumeCapacity(m.body);
        if (header.isSymtab()) {
            try remapIndex(u32, out.items[start..], &offsets);
        } else if (header.isSymtab64()) {
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

/// Returns the rewritten object, or null when no section of it is hot.
fn markMember(gpa: Allocator, bytes: []const u8, hot: *const HotSet, renamed: *usize) !?[]const u8 {
    // Anything but ELF64 little-endian is passed through untouched.
    const obj = try elf.Object.parse(gpa, bytes) orelse return null;
    const shnum = obj.sections.len;

    // The hot symbol that defines each section, if any.
    const hot_sym = try gpa.alloc(?[]const u8, shnum);
    @memset(hot_sym, null);
    for (try obj.symbols(gpa)) |sym| {
        if (!sym.definedIn(obj)) {
            continue;
        }
        if (sym.type != .OBJECT and sym.type != .FUNC) {
            continue;
        }
        if (hot_sym[sym.shndx] != null) {
            continue;
        }
        if (hot.contains(sym.name)) {
            hot_sym[sym.shndx] = sym.name;
        }
    }

    var new_shstrtab: std.ArrayList(u8) = .empty;
    try new_shstrtab.appendSlice(gpa, try obj.bytesOf(obj.sections[obj.header.shstrndx]));
    const new_name = try gpa.alloc(?u32, shnum);
    @memset(new_name, null);
    var count: usize = 0;
    for (obj.sections, 0..) |sh, idx| {
        if (sh.type != std.elf.SHT_PROGBITS) {
            continue;
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
        const generic = for (generic_names) |g| {
            if (std.mem.eql(u8, sh.name, g)) {
                break true;
            }
        } else false;
        if (generic == false) {
            continue;
        }
        new_name[idx] = @intCast(new_shstrtab.items.len);
        try new_shstrtab.appendSlice(gpa, if (std.mem.startsWith(u8, sh.name, ".text")) ".text.hot." else ".rodata.hot.");
        try new_shstrtab.appendSlice(gpa, sym);
        try new_shstrtab.append(gpa, 0);
        count += 1;
    }
    if (count == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(gpa, bytes.len + 8 + new_shstrtab.items.len);
    buf.appendSliceAssumeCapacity(bytes);
    while (buf.items.len % 8 != 0) {
        buf.appendAssumeCapacity(0);
    }
    const strtab_offset = buf.items.len;
    buf.appendSliceAssumeCapacity(new_shstrtab.items);

    const shstr_hdr = obj.headerOffset(obj.header.shstrndx);
    std.mem.writeInt(u64, buf.items[shstr_hdr + 24 ..][0..8], strtab_offset, .little);
    std.mem.writeInt(u64, buf.items[shstr_hdr + 32 ..][0..8], new_shstrtab.items.len, .little);
    for (new_name, 0..) |maybe, idx| {
        const off = maybe orelse continue;
        std.mem.writeInt(u32, buf.items[obj.headerOffset(idx)..][0..4], off, .little);
    }
    renamed.* += count;
    return buf.items;
}

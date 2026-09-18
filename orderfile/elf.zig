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

//! Read-only view of ELF64 objects and GNU archives, as the orderfile tools
//! need them: section headers with names, symbol tables, archive members
//! with their long names resolved.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Section = struct {
    name: []const u8,
    type: u32,
    flags: u64,
    addr: u64,
    offset: usize,
    size: usize,
    link: u32,
};

pub const Symbol = struct {
    name: []const u8,
    value: u64,
    size: u64,
    type: std.elf.STT,
    shndx: u16,

    /// Defined in one of the object's sections (not undefined, absolute or common).
    pub fn definedIn(sym: Symbol, obj: Object) bool {
        return sym.shndx != 0 and sym.shndx < obj.sections.len;
    }
};

pub const Object = struct {
    bytes: []const u8,
    header: std.elf.Header,
    sections: []const Section,

    /// Null for anything but a little-endian ELF64 with section headers:
    /// other targets' objects in Zig's cache, non-ELF archive members.
    pub fn parse(gpa: Allocator, bytes: []const u8) !?Object {
        var reader: std.Io.Reader = .fixed(bytes);
        const header = std.elf.Header.read(&reader) catch return null;
        if (!header.is_64 or header.endian != .little or header.shnum == 0 or header.shstrndx >= header.shnum) {
            return null;
        }
        const shdrs = try gpa.alloc(std.elf.Elf64_Shdr, header.shnum);
        var it = header.iterateSectionHeadersBuffer(bytes);
        for (shdrs) |*shdr| {
            shdr.* = try it.next() orelse return error.BadElf;
        }
        const shstrtab = try sectionBytes(bytes, shdrs[header.shstrndx]);
        const sections = try gpa.alloc(Section, header.shnum);
        for (sections, shdrs) |*s, shdr| {
            s.* = .{
                .name = try cstr(shstrtab, shdr.sh_name),
                .type = shdr.sh_type,
                .flags = shdr.sh_flags,
                .addr = shdr.sh_addr,
                .offset = @intCast(shdr.sh_offset),
                .size = @intCast(shdr.sh_size),
                .link = shdr.sh_link,
            };
        }
        return .{ .bytes = bytes, .header = header, .sections = sections };
    }

    pub fn bytesOf(obj: Object, section: Section) ![]const u8 {
        if (section.offset + section.size > obj.bytes.len) {
            return error.BadElf;
        }
        return obj.bytes[section.offset..][0..section.size];
    }

    /// Offset of section `index`'s header in `bytes`.
    pub fn headerOffset(obj: Object, index: usize) usize {
        return @intCast(obj.header.shoff + index * obj.header.shentsize);
    }

    /// The symbols of every symbol table, in table order, without the null
    /// entry.
    pub fn symbols(obj: Object, gpa: Allocator) ![]const Symbol {
        var list: std.ArrayList(Symbol) = .empty;
        for (obj.sections) |sh| {
            if (sh.type != std.elf.SHT_SYMTAB) {
                continue;
            }
            if (sh.link >= obj.sections.len) {
                return error.BadElf;
            }
            const strtab = try obj.bytesOf(obj.sections[sh.link]);
            const symtab = std.mem.bytesAsSlice(std.elf.Elf64.Sym, try obj.bytesOf(sh));
            for (symtab[@min(1, symtab.len)..]) |sym| {
                try list.append(gpa, .{
                    .name = try cstr(strtab, sym.name),
                    .type = sym.info.type,
                    .shndx = sym.shndx,
                    .value = sym.value,
                    .size = sym.size,
                });
            }
        }
        return list.items;
    }
};

fn sectionBytes(bytes: []const u8, shdr: std.elf.Elf64_Shdr) ![]const u8 {
    if (shdr.sh_offset + shdr.sh_size > bytes.len) {
        return error.BadElf;
    }
    return bytes[@intCast(shdr.sh_offset)..][0..@intCast(shdr.sh_size)];
}

pub const Member = struct {
    header: *align(1) const std.elf.ar_hdr,
    /// The member's file name; empty for the symbol index and the long
    /// names table.
    file_name: []const u8,
    body: []const u8,
    offset: usize,
};

/// The members of a GNU `ar` archive, or null when `archive` is not one.
pub fn archiveMembers(gpa: Allocator, archive: []const u8) !?[]Member {
    if (!std.mem.startsWith(u8, archive, std.elf.ARMAG)) {
        return null;
    }
    var members: std.ArrayList(Member) = .empty;
    var long_names: []const u8 = "";
    var pos: usize = std.elf.ARMAG.len;
    while (pos + @sizeOf(std.elf.ar_hdr) <= archive.len) {
        const header = std.mem.bytesAsValue(std.elf.ar_hdr, archive[pos..][0..@sizeOf(std.elf.ar_hdr)]);
        const size = try header.size();
        const body_pos = pos + @sizeOf(std.elf.ar_hdr);
        if (body_pos + size > archive.len) {
            return error.TruncatedArchive;
        }
        const body = archive[body_pos..][0..size];
        // The long names table precedes every member that refers into it.
        if (header.isStrtab()) {
            long_names = body;
        }
        try members.append(gpa, .{
            .header = header,
            .file_name = try fileName(header, long_names),
            .body = body,
            .offset = pos,
        });
        pos = body_pos + size + (size & 1);
    }
    return members.items;
}

fn fileName(header: *align(1) const std.elf.ar_hdr, long_names: []const u8) ![]const u8 {
    if (header.isSymtab() or header.isSymtab64() or header.isStrtab()) {
        return "";
    }
    if (header.name()) |name| {
        return name;
    }
    const offset = try header.nameOffset() orelse return "";
    if (offset >= long_names.len) {
        return error.BadArchive;
    }
    return std.mem.trimEnd(u8, std.mem.sliceTo(long_names[offset..], '\n'), "/");
}

/// Maps a file read-only. Nothing is copied, and under ReleaseSafe nothing
/// is filled with 0xAA: the tools read a few percent of the hundreds of
/// megabytes of objects they open.
pub fn mapFile(io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len: usize = @intCast(try file.length(io));
    if (len == 0) {
        return "";
    }
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
}

fn cstr(table: []const u8, offset: usize) ![]const u8 {
    if (offset >= table.len) {
        return error.BadStringOffset;
    }
    return std.mem.sliceTo(table[offset..], 0);
}

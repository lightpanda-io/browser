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

pub const SHT_PROGBITS = 1;
pub const SHT_SYMTAB = 2;
pub const SHF_ALLOC = 0x2;

pub const STT_NOTYPE = 0;
pub const STT_OBJECT = 1;
pub const STT_FUNC = 2;
pub const STT_SECTION = 3;
pub const STT_FILE = 4;

pub const Section = struct {
    name: []const u8,
    /// Into .shstrtab; header fields are 64 bytes at `Object.headerOffset`.
    name_offset: u32,
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
    type: u4,
    shndx: u16,

    /// Defined in one of the object's sections (not undefined, absolute or common).
    pub fn definedIn(sym: Symbol, obj: Object) bool {
        return sym.shndx != 0 and sym.shndx < obj.sections.len;
    }
};

pub const Object = struct {
    bytes: []const u8,
    shoff: usize,
    shstrndx: u16,
    sections: []const Section,

    /// Null for anything but a little-endian ELF64 with section headers:
    /// other targets' objects in Zig's cache, non-ELF archive members.
    pub fn parse(gpa: Allocator, bytes: []const u8) !?Object {
        if (bytes.len < 64 or !std.mem.startsWith(u8, bytes, "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) {
            return null;
        }
        const shoff: usize = @intCast(std.mem.readInt(u64, bytes[0x28..][0..8], .little));
        const shentsize = std.mem.readInt(u16, bytes[0x3A..][0..2], .little);
        const shnum = std.mem.readInt(u16, bytes[0x3C..][0..2], .little);
        const shstrndx = std.mem.readInt(u16, bytes[0x3E..][0..2], .little);
        if (shentsize != 64 or shnum == 0 or shstrndx >= shnum) {
            return null;
        }
        if (shoff + @as(usize, shnum) * 64 > bytes.len) {
            return error.BadElf;
        }

        const sections = try gpa.alloc(Section, shnum);
        for (sections, 0..) |*s, i| {
            const at = shoff + i * 64;
            s.* = .{
                .name = "",
                .name_offset = std.mem.readInt(u32, bytes[at..][0..4], .little),
                .type = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little),
                .flags = std.mem.readInt(u64, bytes[at + 8 ..][0..8], .little),
                .addr = std.mem.readInt(u64, bytes[at + 16 ..][0..8], .little),
                .offset = @intCast(std.mem.readInt(u64, bytes[at + 24 ..][0..8], .little)),
                .size = @intCast(std.mem.readInt(u64, bytes[at + 32 ..][0..8], .little)),
                .link = std.mem.readInt(u32, bytes[at + 40 ..][0..4], .little),
            };
        }
        const obj: Object = .{ .bytes = bytes, .shoff = shoff, .shstrndx = shstrndx, .sections = sections };
        const shstrtab = try obj.bytesOf(sections[shstrndx]);
        for (sections) |*s| {
            s.name = try cstr(shstrtab, s.name_offset);
        }
        return obj;
    }

    pub fn bytesOf(obj: Object, section: Section) ![]const u8 {
        if (section.offset + section.size > obj.bytes.len) {
            return error.BadElf;
        }
        return obj.bytes[section.offset..][0..section.size];
    }

    /// Offset of section `index`'s header in `bytes`.
    pub fn headerOffset(obj: Object, index: usize) usize {
        return obj.shoff + index * 64;
    }

    /// The symbols of every symbol table, in table order, without the null
    /// entry.
    pub fn symbols(obj: Object, gpa: Allocator) ![]const Symbol {
        var list: std.ArrayList(Symbol) = .empty;
        for (obj.sections) |sh| {
            if (sh.type != SHT_SYMTAB) {
                continue;
            }
            if (sh.link >= obj.sections.len) {
                return error.BadElf;
            }
            const strtab = try obj.bytesOf(obj.sections[sh.link]);
            const symtab = try obj.bytesOf(sh);
            var i: usize = 24;
            while (i + 24 <= symtab.len) : (i += 24) {
                try list.append(gpa, .{
                    .name = try cstr(strtab, std.mem.readInt(u32, symtab[i..][0..4], .little)),
                    .type = @truncate(symtab[i + 4] & 0xf),
                    .shndx = std.mem.readInt(u16, symtab[i + 6 ..][0..2], .little),
                    .value = std.mem.readInt(u64, symtab[i + 8 ..][0..8], .little),
                    .size = std.mem.readInt(u64, symtab[i + 16 ..][0..8], .little),
                });
            }
        }
        return list.items;
    }
};

pub const Member = struct {
    /// As in the header: `url.o/`, `/123` (long name), `/`, `//`, `/SYM64/`.
    name: []const u8,
    /// The member's file name, long names resolved and the trailing `/` gone.
    file_name: []const u8,
    header: *const [60]u8,
    body: []const u8,
    offset: usize,
};

/// The members of a GNU `ar` archive, or null when `archive` is not one.
pub fn archiveMembers(gpa: Allocator, archive: []const u8) !?[]Member {
    if (!std.mem.startsWith(u8, archive, "!<arch>\n")) {
        return null;
    }
    var members: std.ArrayList(Member) = .empty;
    var long_names: []const u8 = "";
    var pos: usize = 8;
    while (pos + 60 <= archive.len) {
        const header = archive[pos..][0..60];
        const size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10);
        if (pos + 60 + size > archive.len) {
            return error.TruncatedArchive;
        }
        const name = std.mem.trimEnd(u8, header[0..16], " ");
        const body = archive[pos + 60 ..][0..size];
        if (std.mem.eql(u8, name, "//")) {
            long_names = body;
        }
        try members.append(gpa, .{
            .name = name,
            .file_name = "",
            .header = header,
            .body = body,
            .offset = pos,
        });
        pos += 60 + size + (size & 1);
    }
    for (members.items) |*m| {
        m.file_name = try fileName(m.name, long_names);
    }
    return members.items;
}

fn fileName(name: []const u8, long_names: []const u8) ![]const u8 {
    if (name.len > 1 and name[0] == '/' and std.ascii.isDigit(name[1])) {
        const offset = try std.fmt.parseInt(usize, name[1..], 10);
        if (offset >= long_names.len) {
            return error.BadArchive;
        }
        return std.mem.trimEnd(u8, std.mem.sliceTo(long_names[offset..], '\n'), "/");
    }
    return std.mem.trimEnd(u8, name, "/");
}

pub fn cstr(table: []const u8, offset: usize) ![]const u8 {
    if (offset >= table.len) {
        return error.BadStringOffset;
    }
    return std.mem.sliceTo(table[offset..], 0);
}

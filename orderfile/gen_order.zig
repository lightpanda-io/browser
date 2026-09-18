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

//! usage: gen_order <hot.text> <hot.rodata> <out.ld> [--v8 <libc_v8.a> <v8.txt>]
//!                  [--zig-cache <dir>] <obj-or-archive>...
//!
//! Builds a symbol -> (file, section) map from the objects and emits an INSERT
//! linker script that places the hot sections in .text.hot / .rodata.hot ahead
//! of .text / .rodata. Patterns are scoped to their object file (`*api.o(...)`):
//! LLD tests every input section against every unscoped pattern, which turns a
//! 26k-pattern script into an 80s link; scoped, it is a few seconds.
//!
//! With --v8, symbols defined in that archive are written to <v8.txt> for
//! mark_hot_sections.zig instead, and the script matches them with one
//! `.text.hot.*` / `.rodata.hot.*` glob (V8's sections are all named `.text`).
//!
//! --zig-cache names Zig's global cache `o/` directory, where the libc++,
//! libc++abi, libunwind and compiler_rt archives Zig links itself live under
//! unknown hashes. Only their members' names matter to the script, and every
//! copy shares those, so all copies are read (they differ in how they were
//! built, e.g. whether their functions have their own sections).
//!
//! Stats go to stdout.
const std = @import("std");
const elf = @import("elf.zig");

const Allocator = std.mem.Allocator;

const Loc = struct {
    archive: []const u8,
    file: []const u8,
    section: []const u8,

    fn eql(a: Loc, b: Loc) bool {
        return std.mem.eql(u8, a.archive, b.archive) and std.mem.eql(u8, a.file, b.file) and std.mem.eql(u8, a.section, b.section);
    }

    fn lessThan(_: void, a: Loc, b: Loc) bool {
        return switch (std.mem.order(u8, a.archive, b.archive)) {
            .lt => true,
            .gt => false,
            .eq => switch (std.mem.order(u8, a.file, b.file)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, a.section, b.section),
            },
        };
    }
};

const LocOf = std.StringArrayHashMapUnmanaged(std.ArrayList(Loc));

const Stats = struct {
    nomap: usize = 0,
    v8: usize = 0,
    v8_blob_skip: usize = 0,
    generic: usize = 0,
    quote_skip: usize = 0,
    sections: usize = 0,
    files: usize = 0,
};

const zig_cache_archives = [_][]const u8{ "libc++.a", "libc++abi.a", "libunwind.a", "libcompiler_rt.a" };

const Gen = struct {
    gpa: Allocator,
    io: std.Io,
    loc_of: LocOf = .empty,
    v8_archive: ?[]const u8,
    v8_syms: std.StringArrayHashMapUnmanaged(void) = .empty,
    out: std.ArrayList(u8) = .empty,

    /// Records where every .text* / .rodata* symbol of `path` (an object or
    /// an archive) is defined.
    fn index(gen: *Gen, path: []const u8) !void {
        const bytes = try elf.mapFile(gen.io, path);
        const archive = std.fs.path.basename(path);
        if (try elf.archiveMembers(gen.gpa, bytes)) |members| {
            for (members) |m| {
                try gen.indexObject(m.body, archive, std.fs.path.basename(m.file_name));
            }
        } else {
            try gen.indexObject(bytes, archive, archive);
        }
    }

    fn indexObject(gen: *Gen, bytes: []const u8, archive: []const u8, file: []const u8) !void {
        const gpa = gen.gpa;
        const obj = try elf.Object.parse(gpa, bytes) orelse return;
        for (try obj.symbols(gpa)) |sym| {
            if (!sym.definedIn(obj) or sym.name.len == 0) continue;
            if (sym.type == .SECTION or sym.type == .FILE) continue;
            const section = obj.sections[sym.shndx].name;
            if (!std.mem.startsWith(u8, section, ".text") and !std.mem.startsWith(u8, section, ".rodata")) continue;
            const loc: Loc = .{ .archive = archive, .file = file, .section = section };
            const gop = try gen.loc_of.getOrPut(gpa, sym.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |known| {
                if (known.eql(loc)) break;
            } else {
                try gop.value_ptr.append(gpa, loc);
            }
        }
    }

    /// Appends the input-section descriptions for the symbols listed in
    /// `hot_path`.
    fn emit(gen: *Gen, hot_path: []const u8, prefix: []const u8) !Stats {
        const gpa = gen.gpa;
        var stats: Stats = .{};
        var by_file: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty;

        const list = try std.Io.Dir.cwd().readFileAlloc(gen.io, hot_path, gpa, .unlimited);
        var names = std.mem.splitScalar(u8, list, '\n');
        while (names.next()) |name| {
            if (name.len == 0) continue;
            const locs = gen.loc_of.get(name) orelse {
                stats.nomap += 1;
                continue;
            };
            // A canonical order for the few symbols defined in several
            // places, so the script does not depend on the link-input order.
            if (locs.items.len > 1) std.mem.sortUnstable(Loc, locs.items, {}, Loc.lessThan);
            for (locs.items) |loc| {
                if (!std.mem.startsWith(u8, loc.section, prefix)) continue;
                if (gen.v8_archive != null and std.mem.eql(u8, loc.archive, gen.v8_archive.?)) {
                    // The embedded builtins blob is left cold (see
                    // mark_hot_sections.zig); don't emit a pattern for it.
                    if (std.mem.startsWith(u8, name, "Builtins_")) {
                        stats.v8_blob_skip += 1;
                        continue;
                    }
                    try gen.v8_syms.put(gpa, name, {});
                    stats.v8 += 1;
                    continue;
                }
                if (std.mem.eql(u8, loc.section, prefix) or std.mem.endsWith(u8, loc.section, ".")) {
                    stats.generic += 1;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, loc.section, '"') != null or std.mem.indexOfScalar(u8, loc.file, '"') != null) {
                    stats.quote_skip += 1;
                    continue;
                }
                const file = try by_file.getOrPut(gpa, loc.file);
                if (!file.found_existing) file.value_ptr.* = .empty;
                const section = try file.value_ptr.getOrPut(gpa, loc.section);
                if (!section.found_existing) stats.sections += 1;
            }
        }
        stats.files = by_file.count();

        const out = &gen.out;
        var first = true;
        if (gen.v8_archive != null) {
            try out.print(gpa, "    *(\"{s}.hot.*\")", .{prefix});
            first = false;
        }
        // LLD unquotes section names but not the file pattern, so that one
        // stays bare.
        for (by_file.keys(), by_file.values()) |file, sections| {
            if (!first) try out.append(gpa, '\n');
            first = false;
            try out.appendSlice(gpa, "    *");
            try escape(gpa, out, file);
            try out.appendSlice(gpa, "(\n");
            for (sections.keys(), 0..) |section, i| {
                if (i > 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, "      \"");
                try escape(gpa, out, section);
                try out.append(gpa, '"');
            }
            try out.appendSlice(gpa, "\n    )");
        }
        return stats;
    }
};

/// Backslash-escapes the glob characters of `s`.
fn escape(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, "*?[]\\", c) != null) try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
}

pub fn main(init: std.process.Init) !void {
    // One-shot tool: everything lives until exit.
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var positional: std.ArrayList([]const u8) = .empty;
    var v8: ?struct { archive: []const u8, out: []const u8 } = null;
    var zig_cache: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--v8")) {
            v8 = .{
                .archive = args.next() orelse return error.Usage,
                .out = args.next() orelse return error.Usage,
            };
        } else if (std.mem.eql(u8, arg, "--zig-cache")) {
            zig_cache = args.next() orelse return error.Usage;
        } else {
            try positional.append(gpa, arg);
        }
    }
    if (positional.items.len < 3) return error.Usage;
    const hot_text = positional.items[0];
    const hot_rodata = positional.items[1];
    const out_path = positional.items[2];

    var gen: Gen = .{ .gpa = gpa, .io = io, .v8_archive = if (v8) |v| std.fs.path.basename(v.archive) else null };
    var inputs: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (v8) |v| try inputs.put(gpa, v.archive, {});
    for (positional.items[3..]) |path| try inputs.put(gpa, path, {});
    if (zig_cache) |dir_path| {
        for (zig_cache_archives) |name| {
            for (try zigCacheCopies(gpa, io, dir_path, name)) |path| try inputs.put(gpa, path, {});
        }
    }
    for (inputs.keys()) |path| try gen.index(path);

    try gen.out.appendSlice(gpa, "/* Generated by orderfile/gen_order.zig, see orderfile/README.md. */\n");
    try gen.out.appendSlice(gpa, "SECTIONS {\n  .text.hot : {\n");
    const text = try gen.emit(hot_text, ".text");
    try gen.out.appendSlice(gpa, "\n  }\n} INSERT BEFORE .text;\n");
    try gen.out.appendSlice(gpa, "SECTIONS {\n  .rodata.hot : {\n");
    const rodata = try gen.emit(hot_rodata, ".rodata");
    try gen.out.appendSlice(gpa, "\n  }\n} INSERT BEFORE .rodata;\n");
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = gen.out.items });

    if (v8) |v| {
        var list: std.ArrayList(u8) = .empty;
        for (gen.v8_syms.keys()) |name| {
            try list.appendSlice(gpa, name);
            try list.append(gpa, '\n');
        }
        try cwd.writeFile(io, .{ .sub_path = v.out, .data = list.items });
    }

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    inline for (.{ .{ ".text", text }, .{ ".rodata", rodata } }) |report| {
        inline for (std.meta.fields(Stats)) |field| {
            try stdout.interface.print("{s} {s}: {d}\n", .{ report[0], field.name, @field(report[1], field.name) });
        }
    }
    try stdout.interface.flush();
}

/// The copies of `name` under Zig's global cache `o/` directory, in a
/// stable order.
fn zigCacheCopies(gpa: Allocator, io: std.Io, dir_path: []const u8, name: []const u8) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var copies: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name, name });
        cwd.access(io, path, .{}) catch continue;
        try copies.append(gpa, path);
    }
    std.mem.sortUnstable([]const u8, copies.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return copies.items;
}

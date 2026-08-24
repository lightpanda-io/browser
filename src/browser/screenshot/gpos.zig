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

//! Reader for the OpenType GPOS mark-attachment lookups (mark-to-base,
//! mark-to-ligature, mark-to-mark) and GDEF glyph classes, straight off the
//! font bytes. Lookups are gathered from the mark/mkmk features of every
//! script and applied in lookup-index order; the first covering subtable
//! wins. LookupFlag filtering is not applied.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Gpos = @This();

data: []const u8,
glyph_class_def: ?usize,
lookups: []const Lookup,

pub const Lookup = struct {
    kind: Kind,
    subtables: []const usize,

    pub const Kind = enum { mark_base, mark_lig, mark_mark };
};

/// Mark origin relative to its parent's origin, in font units.
pub const Offset = struct {
    dx: i16,
    dy: i16,
};

pub const Error = error{ MalformedFont, OutOfMemory };

const MARK_CLASS: u16 = 3;

pub fn init(allocator: Allocator, data: []const u8) Error!Gpos {
    var self: Gpos = .{ .data = data, .glyph_class_def = null, .lookups = &.{} };
    const gpos = try self.findTable("GPOS") orelse return self;
    if (try self.findTable("GDEF")) |gdef| {
        const off = try self.u16At(gdef + 4);
        if (off != 0) self.glyph_class_def = gdef + off;
    }

    const script_list = gpos + try self.u16At(gpos + 4);
    const feature_list = gpos + try self.u16At(gpos + 6);
    const lookup_list = gpos + try self.u16At(gpos + 8);
    const lookup_count = try self.u16At(lookup_list);
    const wanted = try allocator.alloc(bool, lookup_count);
    @memset(wanted, false);

    const script_count = try self.u16At(script_list);
    for (0..script_count) |i| {
        const script = script_list + try self.u16At(script_list + 2 + i * 6 + 4);
        const default_lang = try self.u16At(script);
        if (default_lang != 0) try self.collectLangSys(script + default_lang, feature_list, wanted);
        const lang_count = try self.u16At(script + 2);
        for (0..lang_count) |j| {
            const lang = script + try self.u16At(script + 4 + j * 6 + 4);
            try self.collectLangSys(lang, feature_list, wanted);
        }
    }

    var lookups: std.ArrayList(Lookup) = .empty;
    for (wanted, 0..) |w, i| {
        if (!w) continue;
        const lookup = lookup_list + try self.u16At(lookup_list + 2 + i * 2);
        var kind_raw = try self.u16At(lookup);
        const sub_count = try self.u16At(lookup + 4);
        var subtables: std.ArrayList(usize) = .empty;
        for (0..sub_count) |j| {
            var sub = lookup + try self.u16At(lookup + 6 + j * 2);
            if (kind_raw == 9) {
                kind_raw = try self.u16At(sub + 2);
                sub += try self.u32At(sub + 4);
            }
            try subtables.append(allocator, sub);
        }
        const kind: Lookup.Kind = switch (kind_raw) {
            4 => .mark_base,
            5 => .mark_lig,
            6 => .mark_mark,
            else => continue,
        };
        try lookups.append(allocator, .{ .kind = kind, .subtables = subtables.items });
    }
    self.lookups = lookups.items;
    return self;
}

fn collectLangSys(self: *const Gpos, lang: usize, feature_list: usize, wanted: []bool) Error!void {
    const feature_count = try self.u16At(lang + 4);
    for (0..feature_count) |i| {
        const fi = try self.u16At(lang + 6 + i * 2);
        const record = feature_list + 2 + @as(usize, fi) * 6;
        const tag = try self.bytesAt(record, 4);
        if (!std.mem.eql(u8, tag, "mark") and !std.mem.eql(u8, tag, "mkmk")) continue;
        const feature = feature_list + try self.u16At(record + 4);
        const lookup_count = try self.u16At(feature + 2);
        for (0..lookup_count) |j| {
            const li = try self.u16At(feature + 4 + j * 2);
            if (li < wanted.len) wanted[li] = true;
        }
    }
}

pub fn isMark(self: *const Gpos, gid: u16) bool {
    const class_def = self.glyph_class_def orelse return false;
    return (self.classOf(class_def, gid) catch 0) == MARK_CLASS;
}

/// Mark-to-base, then mark-to-ligature (last component: the shaper only
/// forms a ligature when no mark sits between its parts).
pub fn attachToBase(self: *const Gpos, base: u16, mark: u16) ?Offset {
    return self.attach(base, mark, false) catch null;
}

pub fn attachToMark(self: *const Gpos, prev_mark: u16, mark: u16) ?Offset {
    return self.attach(prev_mark, mark, true) catch null;
}

fn attach(self: *const Gpos, parent: u16, mark: u16, parent_is_mark: bool) Error!?Offset {
    for (self.lookups) |lookup| {
        if ((lookup.kind == .mark_mark) != parent_is_mark) continue;
        for (lookup.subtables) |sub| {
            if (try self.u16At(sub) != 1) continue;
            const mi = try self.coverage(sub + try self.u16At(sub + 2), mark) orelse continue;
            const pi = try self.coverage(sub + try self.u16At(sub + 4), parent) orelse continue;
            const class_count = try self.u16At(sub + 6);
            const mark_array = sub + try self.u16At(sub + 8);
            const parent_array = sub + try self.u16At(sub + 10);

            const mark_record = mark_array + 2 + @as(usize, mi) * 4;
            const class = try self.u16At(mark_record);
            if (class >= class_count) return error.MalformedFont;
            const mark_anchor = mark_array + try self.u16At(mark_record + 2);

            const record_size = @as(usize, class_count) * 2;
            const parent_anchor_off = switch (lookup.kind) {
                .mark_base, .mark_mark => try self.u16At(parent_array + 2 + @as(usize, pi) * record_size + class * 2),
                .mark_lig => blk: {
                    const lig_attach = parent_array + try self.u16At(parent_array + 2 + @as(usize, pi) * 2);
                    const component_count = try self.u16At(lig_attach);
                    if (component_count == 0) break :blk 0;
                    break :blk try self.u16At(lig_attach + 2 + (component_count - 1) * record_size + class * 2);
                },
            };
            if (parent_anchor_off == 0) continue;
            const parent_anchor = if (lookup.kind == .mark_lig)
                parent_array + try self.u16At(parent_array + 2 + @as(usize, pi) * 2) + parent_anchor_off
            else
                parent_array + parent_anchor_off;

            return .{
                .dx = try self.i16At(parent_anchor + 2) - try self.i16At(mark_anchor + 2),
                .dy = try self.i16At(parent_anchor + 4) - try self.i16At(mark_anchor + 4),
            };
        }
    }
    return null;
}

fn coverage(self: *const Gpos, off: usize, gid: u16) Error!?u16 {
    switch (try self.u16At(off)) {
        1 => {
            const count = try self.u16At(off + 2);
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = try self.u16At(off + 4 + mid * 2);
                if (g == gid) return @intCast(mid);
                if (g < gid) lo = mid + 1 else hi = mid;
            }
            return null;
        },
        2 => {
            const count = try self.u16At(off + 2);
            for (0..count) |i| {
                const record = off + 4 + i * 6;
                const start = try self.u16At(record);
                const end = try self.u16At(record + 2);
                if (gid < start) return null;
                if (gid <= end) return try self.u16At(record + 4) + (gid - start);
            }
            return null;
        },
        else => return error.MalformedFont,
    }
}

fn classOf(self: *const Gpos, off: usize, gid: u16) Error!u16 {
    switch (try self.u16At(off)) {
        1 => {
            const start = try self.u16At(off + 2);
            const count = try self.u16At(off + 4);
            if (gid < start or gid - start >= count) return 0;
            return try self.u16At(off + 6 + (gid - start) * 2);
        },
        2 => {
            const count = try self.u16At(off + 2);
            for (0..count) |i| {
                const record = off + 4 + i * 6;
                const start = try self.u16At(record);
                const end = try self.u16At(record + 2);
                if (gid < start) return 0;
                if (gid <= end) return try self.u16At(record + 4);
            }
            return 0;
        },
        else => return error.MalformedFont,
    }
}

fn findTable(self: *const Gpos, tag: *const [4]u8) Error!?usize {
    const count = try self.u16At(4);
    for (0..count) |i| {
        const record = 12 + i * 16;
        if (std.mem.eql(u8, try self.bytesAt(record, 4), tag)) {
            const off = try self.u32At(record + 8);
            if (off >= self.data.len) return error.MalformedFont;
            return off;
        }
    }
    return null;
}

fn bytesAt(self: *const Gpos, off: usize, len: usize) Error![]const u8 {
    if (off + len > self.data.len) return error.MalformedFont;
    return self.data[off..][0..len];
}

fn u16At(self: *const Gpos, off: usize) Error!u16 {
    return std.mem.readInt(u16, (try self.bytesAt(off, 2))[0..2], .big);
}

fn i16At(self: *const Gpos, off: usize) Error!i16 {
    return std.mem.readInt(i16, (try self.bytesAt(off, 2))[0..2], .big);
}

fn u32At(self: *const Gpos, off: usize) Error!u32 {
    return std.mem.readInt(u32, (try self.bytesAt(off, 4))[0..4], .big);
}

const testing = @import("../../testing.zig");

// Glyph ids and deltas below were read out of DejaVu Sans 2.37 with fontTools.
test "browser.screenshot.gpos: DejaVu Sans mark attachment" {
    const g = try Gpos.init(testing.arena_allocator, @embedFile("fonts/DejaVuSans.ttf"));
    try testing.expectEqual(14, g.lookups.len);

    try testing.expectEqual(true, g.isMark(1398)); // kasratan
    try testing.expectEqual(true, g.isMark(690)); // combining acute
    try testing.expectEqual(false, g.isMark(68)); // a
    try testing.expectEqual(false, g.isMark(5365)); // lam-alef ligature

    const noon_kasratan = g.attachToBase(5344, 1398).?;
    try testing.expectEqual(238, noon_kasratan.dx);
    try testing.expectEqual(-600, noon_kasratan.dy);

    const a_acute = g.attachToBase(68, 690).?;
    try testing.expectEqual(1098, a_acute.dx);
    try testing.expectEqual(0, a_acute.dy);

    const cap_a_acute = g.attachToBase(36, 690).?;
    try testing.expectEqual(1212, cap_a_acute.dx);
    try testing.expectEqual(373, cap_a_acute.dy);

    const beh_shadda = g.attachToBase(5259, 1402).?;
    try testing.expectEqual(-213, beh_shadda.dx);
    try testing.expectEqual(-200, beh_shadda.dy);

    const bet_qamats = g.attachToBase(1320, 1305).?;
    try testing.expectEqual(-58, bet_qamats.dx);
    try testing.expectEqual(0, bet_qamats.dy);

    // Ligature path: fatha on lam-alef attaches to the last component.
    const lamalef_fatha = g.attachToBase(5365, 1399).?;
    try testing.expectEqual(-362, lamalef_fatha.dx);
    try testing.expectEqual(300, lamalef_fatha.dy);

    // Stacking: fatha on shadda.
    const shadda_fatha = g.attachToMark(1402, 1399).?;
    try testing.expectEqual(0, shadda_fatha.dx);
    try testing.expectEqual(600, shadda_fatha.dy);

    // A Latin base never covers an Arabic mark.
    try testing.expectEqual(null, g.attachToBase(68, 1398));
    try testing.expectEqual(null, g.attachToMark(68, 690));
}

test "browser.screenshot.gpos: all bundled faces parse" {
    inline for (.{ "DejaVuSans-Bold.ttf", "DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf" }) |name| {
        const g = try Gpos.init(testing.arena_allocator, @embedFile("fonts/" ++ name));
        try testing.expectEqual(true, g.lookups.len > 0);
        try testing.expectEqual(true, g.glyph_class_def != null);
    }
}

// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const ft = @cImport(@cInclude("freetype/freetype.h"));
const hb = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

pub const FontCache = struct {
    ft_library: ft.FT_Library,
    entries: std.StringHashMap(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        ft_face: ft.FT_Face,
        hb_font: *hb.hb_font_t,
    };

    pub fn init(allocator: std.mem.Allocator) !FontCache {
        var lib: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInitFailed;
        return .{
            .ft_library = lib,
            .entries = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            hb.hb_font_destroy(kv.value_ptr.hb_font);
            _ = ft.FT_Done_Face(kv.value_ptr.ft_face);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
        _ = ft.FT_Done_FreeType(self.ft_library);
    }

    pub fn getOrLoad(self: *FontCache, path: [*:0]const u8, index: c_int, size_px: f64) !Entry {
        const key = std.mem.span(path);
        if (self.entries.get(key)) |entry| return entry;

        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(self.ft_library, path, index, &face) != 0) return error.FaceLoadFailed;

        const size_26_6: ft.FT_F26Dot6 = @intFromFloat(size_px * 64.0);
        if (ft.FT_Set_Char_Size(face, 0, size_26_6, 72, 72) != 0) {
            _ = ft.FT_Done_Face(face);
            return error.SetSizeFailed;
        }

        const hb_font = hb.hb_ft_font_create_referenced(face) orelse {
            _ = ft.FT_Done_Face(face);
            return error.HarfBuzzFontFailed;
        };

        const entry = Entry{ .ft_face = face, .hb_font = hb_font };
        const owned_key = try self.allocator.dupe(u8, key);
        try self.entries.put(owned_key, entry);
        return entry;
    }
};

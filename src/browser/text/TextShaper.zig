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
const hb = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
const ft = @cImport(@cInclude("freetype/freetype.h"));
const FontSpec = @import("FontSpec.zig");
const FontResolver = @import("FontResolver.zig");
const FontCache = @import("FontCache.zig");
const ShapingResult = @import("ShapingResult.zig");

pub const TextShaper = struct {
    resolver: FontResolver.FontResolver,
    cache: FontCache.FontCache,

    pub fn init(allocator: std.mem.Allocator) !TextShaper {
        return .{
            .resolver = FontResolver.FontResolver.init(),
            .cache = try FontCache.FontCache.init(allocator),
        };
    }

    pub fn deinit(self: *TextShaper) void {
        self.cache.deinit();
        self.resolver.deinit();
    }

    pub fn addFontDir(self: *TextShaper, dir: [*:0]const u8) void {
        self.resolver.addFontDir(dir);
    }

    pub fn measureWidth(self: *TextShaper, text: []const u8, spec: FontSpec.FontSpec) f64 {
        const resolved = self.resolver.resolve(spec.family, spec.weight, spec.style) orelse return 0;
        const entry = self.cache.getOrLoad(resolved.file_path, resolved.face_index, spec.size_px) catch return 0;

        const buf = hb.hb_buffer_create() orelse return 0;
        defer hb.hb_buffer_destroy(buf);

        hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_buffer_set_direction(buf, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(buf, hb.HB_SCRIPT_LATIN);
        hb.hb_shape(entry.hb_font, buf, null, 0);

        var glyph_count: u32 = 0;
        const positions = hb.hb_buffer_get_glyph_positions(buf, &glyph_count);
        if (glyph_count == 0) return 0;

        var total: f64 = 0;
        for (0..glyph_count) |i| {
            total += @as(f64, @floatFromInt(positions[i].x_advance)) / 64.0 + spec.letter_spacing;
        }
        return total;
    }

    pub fn shape(self: *TextShaper, text: []const u8, spec: FontSpec.FontSpec, allocator: std.mem.Allocator) ?ShapingResult.ShapingResult {
        const resolved = self.resolver.resolve(spec.family, spec.weight, spec.style) orelse return null;
        const entry = self.cache.getOrLoad(resolved.file_path, resolved.face_index, spec.size_px) catch return null;

        const buf = hb.hb_buffer_create() orelse return null;
        defer hb.hb_buffer_destroy(buf);

        hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_buffer_set_direction(buf, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(buf, hb.HB_SCRIPT_LATIN);
        hb.hb_shape(entry.hb_font, buf, null, 0);

        var glyph_count: u32 = 0;
        const positions = hb.hb_buffer_get_glyph_positions(buf, &glyph_count);
        if (glyph_count == 0) return null;

        const glyphs = allocator.alloc(ShapingResult.ShapingResult.Glyph, glyph_count) catch return null;

        var total_advance: f64 = 0;
        for (0..glyph_count) |i| {
            const pos = positions[i];
            const x_adv = @as(f64, @floatFromInt(pos.x_advance)) / 64.0;
            const y_adv = @as(f64, @floatFromInt(pos.y_advance)) / 64.0;
            glyphs[i] = .{
                .x_advance = x_adv,
                .y_advance = y_adv,
                .x_offset = @as(f64, @floatFromInt(pos.x_offset)) / 64.0,
                .y_offset = @as(f64, @floatFromInt(pos.y_offset)) / 64.0,
                .x_position = total_advance,
            };
            total_advance += x_adv + spec.letter_spacing;
        }

        const face = entry.ft_face;
        const metrics = face.*.size.*.metrics;
        const ascent = @as(f64, @floatFromInt(metrics.ascender)) / 64.0;
        const descent = @as(f64, @floatFromInt(metrics.descender)) / 64.0;

        return .{
            .total_advance = total_advance,
            .glyph_count = glyph_count,
            .ascent = ascent,
            .descent = descent,
            .glyphs = glyphs,
        };
    }
};

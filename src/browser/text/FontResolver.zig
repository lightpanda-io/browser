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
const builtin = @import("builtin");
const FontSpec = @import("FontSpec.zig");

const is_linux = builtin.os.tag == .linux;
const fc = if (is_linux) @cImport(@cInclude("fontconfig/fontconfig.h")) else struct {};

pub const FontResolver = struct {
    config: if (is_linux) ?*fc.FcConfig else void,

    pub const ResolvedFont = struct {
        file_path: [*:0]const u8,
        face_index: c_int,
    };

    pub fn init() FontResolver {
        if (is_linux) {
            return .{ .config = fc.FcInitLoadConfigAndFonts() };
        } else {
            return .{ .config = {} };
        }
    }

    pub fn deinit(self: *FontResolver) void {
        if (is_linux) {
            if (self.config) |c| fc.FcConfigDestroy(c);
            fc.FcFini();
            self.config = null;
        }
    }

    pub fn addFontDir(self: *FontResolver, dir: [*:0]const u8) void {
        if (is_linux) {
            if (self.config) |c| _ = fc.FcConfigAppFontAddDir(c, dir);
        }
    }

    pub fn resolve(self: *FontResolver, family: []const u8, weight: u16, style: FontSpec.Style) ?ResolvedFont {
        if (is_linux) {
            const pattern = fc.FcPatternCreate() orelse return null;
            defer fc.FcPatternDestroy(pattern);

            _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, family.ptr);
            _ = fc.FcPatternAddInteger(pattern, fc.FC_WEIGHT, mapWeight(weight));
            _ = fc.FcPatternAddInteger(pattern, fc.FC_SLANT, mapSlant(style));

            _ = fc.FcConfigSubstitute(self.config, pattern, fc.FcMatchPattern);
            fc.FcDefaultSubstitute(pattern);

            var result: fc.FcResult = undefined;
            const match = fc.FcFontMatch(self.config, pattern, &result) orelse return null;

            var file: [*c]fc.FcChar8 = undefined;
            if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file) != fc.FcResultMatch) return null;

            var index: c_int = 0;
            _ = fc.FcPatternGetInteger(match, fc.FC_INDEX, 0, &index);

            return .{
                .file_path = @ptrCast(file),
                .face_index = index,
            };
        } else {
            _ = .{ self, family, weight, style };
            return null;
        }
    }

    fn mapWeight(w: u16) c_int {
        return switch (w) {
            0...149 => fc.FC_WEIGHT_THIN,
            150...249 => fc.FC_WEIGHT_EXTRALIGHT,
            250...349 => fc.FC_WEIGHT_LIGHT,
            350...449 => fc.FC_WEIGHT_REGULAR,
            450...549 => fc.FC_WEIGHT_MEDIUM,
            550...649 => fc.FC_WEIGHT_SEMIBOLD,
            650...749 => fc.FC_WEIGHT_BOLD,
            750...849 => fc.FC_WEIGHT_EXTRABOLD,
            else => fc.FC_WEIGHT_BLACK,
        };
    }

    fn mapSlant(s: FontSpec.Style) c_int {
        return switch (s) {
            .normal => fc.FC_SLANT_ROMAN,
            .italic => fc.FC_SLANT_ITALIC,
            .oblique => fc.FC_SLANT_OBLIQUE,
        };
    }
};

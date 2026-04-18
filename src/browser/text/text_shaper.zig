// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// Thin wrapper that provides text measurement.
// Currently uses heuristic. When FreeType/HarfBuzz deps are resolved,
// replace with real TextShaper integration from TextShaper.zig.

pub fn measureWidth(text: []const u8, font_size: f64, _font_family: []const u8) f64 {
    _ = _font_family;
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @as(f64, @floatFromInt(count)) * font_size * 0.6;
}

const std = @import("std");

pub fn getAscent(font_size: f64) f64 {
    return font_size * 0.8;
}

pub fn getDescent(font_size: f64) f64 {
    return font_size * 0.2;
}

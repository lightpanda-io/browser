// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

pub const CSSValueAnalyzer = struct {
    pub fn isNumericWithUnit(value: []const u8) bool {
        if (value.len == 0) return false;

        if (!std.ascii.isDigit(value[0]) and
            value[0] != '+' and value[0] != '-' and value[0] != '.')
        {
            return false;
        }

        var i: usize = 0;
        var has_digit = false;
        var decimal_point = false;

        while (i < value.len) : (i += 1) {
            const c = value[i];
            if (std.ascii.isDigit(c)) {
                has_digit = true;
            } else if (c == '.' and !decimal_point) {
                decimal_point = true;
            } else if ((c == 'e' or c == 'E') and has_digit) {
                i += 1;
                if (i < value.len and (value[i] == '+' or value[i] == '-')) {
                    i += 1;
                }
                var has_exp_digits = false;
                while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
                    has_exp_digits = true;
                }
                if (!has_exp_digits) return false;
                break;
            } else if (c != '-' and c != '+') {
                break;
            }
        }

        if (!has_digit) return false;

        if (i == value.len) return true;

        const unit = value[i..];
        return CSSKeywords.isValidUnit(unit);
    }

    pub fn isHexColor(value: []const u8) bool {
        if (!std.mem.startsWith(u8, value, "#")) return false;

        const hex_part = value[1..];
        if (hex_part.len != 3 and hex_part.len != 6 and hex_part.len != 8) return false;

        for (hex_part) |c| {
            if (!std.ascii.isHex(c)) return false;
        }

        return true;
    }

    pub fn isMultiValueProperty(value: []const u8) bool {
        var parts = std.mem.splitAny(u8, value, " ");
        var multi_value_parts: usize = 0;
        var all_parts_valid = true;

        while (parts.next()) |part| {
            if (part.len == 0) continue;
            multi_value_parts += 1;

            const is_numeric = isNumericWithUnit(part);
            const is_hex_color = isHexColor(part);
            const is_known_keyword = CSSKeywords.isKnownKeyword(part);
            const is_function = CSSKeywords.startsWithFunction(part);

            if (!is_numeric and !is_hex_color and !is_known_keyword and !is_function) {
                all_parts_valid = false;
                break;
            }
        }

        return multi_value_parts >= 2 and all_parts_valid;
    }

    pub fn isAlreadyQuoted(value: []const u8) bool {
        return value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\''));
    }

    pub fn isValidPropertyName(name: []const u8) bool {
        if (name.len == 0) return false;

        const first_char = name[0];
        if (!std.ascii.isAlphabetic(first_char) and first_char != '-') {
            return false;
        }

        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-') {
                return false;
            }
        }

        return true;
    }

    pub fn extractImportant(value: []const u8) struct { value: []const u8, is_important: bool } {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);

        if (std.mem.endsWith(u8, trimmed, "!important")) {
            const clean_value = std.mem.trim(u8, trimmed[0 .. trimmed.len - 10], &std.ascii.whitespace);
            return .{ .value = clean_value, .is_important = true };
        }

        return .{ .value = trimmed, .is_important = false };
    }

    pub fn needsQuotes(value: []const u8) bool {
        if (value.len == 0) return true;
        if (isAlreadyQuoted(value)) return false;

        const has_spaces = std.mem.indexOf(u8, value, " ") != null;
        const has_special_chars = CSSKeywords.containsSpecialChar(value);
        const is_url = std.mem.startsWith(u8, value, "url(");
        const is_function = CSSKeywords.startsWithFunction(value);

        const space_requires_quotes = has_spaces and
            !isMultiValueProperty(value) and
            !is_url and
            !is_function;

        return has_special_chars or space_requires_quotes;
    }

    pub fn escapeCSSValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        const writer = out.writer();

        if (isAlreadyQuoted(value)) {
            try writer.writeAll(value);
            return out.toOwnedSlice();
        }

        const needs_quotes = needsQuotes(value);

        if (needs_quotes) {
            try writer.writeByte('"');

            for (value) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\A "),
                    '\r' => try writer.writeAll("\\D "),
                    '\t' => try writer.writeAll("\\9 "),
                    0...8, 11, 12, 14...31, 127 => {
                        try writer.print("\\{x}", .{c});
                        if (c + 1 < value.len and std.ascii.isHex(value[c + 1])) {
                            try writer.writeByte(' ');
                        }
                    },
                    else => try writer.writeByte(c),
                }
            }

            try writer.writeByte('"');
        } else {
            try writer.writeAll(value);
        }

        return out.toOwnedSlice();
    }

    pub fn isKnownKeyword(value: []const u8) bool {
        return CSSKeywords.isKnownKeyword(value);
    }

    pub fn containsSpecialChar(value: []const u8) bool {
        return CSSKeywords.containsSpecialChar(value);
    }
};

const CSSKeywords = struct {
    const BorderStyles = [_][]const u8{
        "none", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset",
    };

    const ColorNames = [_][]const u8{
        "black",        "white",   "red", "green", "blue", "yellow", "purple", "gray", "transparent",
        "currentColor", "inherit",
    };

    const PositionKeywords = [_][]const u8{
        "auto", "center", "left", "right", "top", "bottom",
    };

    const BackgroundRepeat = [_][]const u8{
        "repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round",
    };

    const FontStyles = [_][]const u8{
        "normal", "italic", "oblique", "bold", "bolder", "lighter",
    };

    const FontSizes = [_][]const u8{
        "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
        "smaller",  "larger",
    };

    const FontFamilies = [_][]const u8{
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
    };

    const CSSGlobal = [_][]const u8{
        "initial", "inherit", "unset", "revert",
    };

    const DisplayValues = [_][]const u8{
        "block", "inline", "inline-block", "flex", "grid", "none",
    };

    const LengthUnits = [_][]const u8{
        "px", "em", "rem", "vw", "vh", "vmin", "vmax", "%", "pt", "pc", "in", "cm", "mm",
        "ex", "ch", "fr",
    };

    const AngleUnits = [_][]const u8{
        "deg", "rad", "grad", "turn",
    };

    const TimeUnits = [_][]const u8{
        "s", "ms",
    };

    const FrequencyUnits = [_][]const u8{
        "Hz", "kHz",
    };

    const ResolutionUnits = [_][]const u8{
        "dpi", "dpcm", "dppx",
    };

    const SpecialChars = [_]u8{
        '"', '\'', ';', '{', '}', '\\', '<', '>', '/',
    };

    const Functions = [_][]const u8{
        "rgb",             "rgba",            "hsl",            "hsla",      "url",    "calc",  "var",  "attr",
        "linear-gradient", "radial-gradient", "conic-gradient", "translate", "rotate", "scale", "skew", "matrix",
    };

    pub fn isKnownKeyword(value: []const u8) bool {
        const all_categories = [_][]const []const u8{
            &BorderStyles,  &ColorNames, &PositionKeywords, &BackgroundRepeat,
            &FontStyles,    &FontSizes,  &FontFamilies,     &CSSGlobal,
            &DisplayValues,
        };

        for (all_categories) |category| {
            for (category) |keyword| {
                if (std.mem.eql(u8, value, keyword)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn containsSpecialChar(value: []const u8) bool {
        for (value) |c| {
            for (SpecialChars) |special| {
                if (c == special) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn isValidUnit(unit: []const u8) bool {
        const all_units = [_][]const []const u8{
            &LengthUnits, &AngleUnits, &TimeUnits, &FrequencyUnits, &ResolutionUnits,
        };

        for (all_units) |category| {
            for (category) |valid_unit| {
                if (std.mem.eql(u8, unit, valid_unit)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn startsWithFunction(value: []const u8) bool {
        for (Functions) |func| {
            if (value.len >= func.len + 1 and
                std.mem.startsWith(u8, value, func) and
                value[func.len] == '(')
            {
                return true;
            }
        }

        return std.mem.indexOf(u8, value, "(") != null and
            std.mem.indexOf(u8, value, ")") != null;
    }
};

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
                if (i + 1 >= value.len) return false;
                if (value[i + 1] != '+' and value[i + 1] != '-' and !std.ascii.isDigit(value[i + 1])) break;
                i += 1;
                if (value[i] == '+' or value[i] == '-') {
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

        if (std.mem.startsWith(u8, name, "--")) {
            if (name.len == 2) return false;
            for (name[2..]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                    return false;
                }
            }
            return true;
        }

        const first_char = name[0];
        if (!std.ascii.isAlphabetic(first_char) and first_char != '-') {
            return false;
        }

        if (first_char == '-') {
            if (name.len < 2) return false;

            if (!std.ascii.isAlphabetic(name[1])) {
                return false;
            }

            for (name[2..]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') {
                    return false;
                }
            }
        } else {
            for (name[1..]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') {
                    return false;
                }
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
        var out = std.ArrayListUnmanaged(u8){};
        const writer = out.writer(allocator);

        if (isAlreadyQuoted(value)) {
            try writer.writeAll(value);
            return out.items;
        }

        const needs_quotes = needsQuotes(value);

        if (needs_quotes) {
            try writer.writeByte('"');

            for (value, 0..) |c, i| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\A "),
                    '\r' => try writer.writeAll("\\D "),
                    '\t' => try writer.writeAll("\\9 "),
                    0...8, 11, 12, 14...31, 127 => {
                        try writer.print("\\{x}", .{c});
                        if (i + 1 < value.len and std.ascii.isHex(value[i + 1])) {
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

        return out.items;
    }

    pub fn isKnownKeyword(value: []const u8) bool {
        return CSSKeywords.isKnownKeyword(value);
    }

    pub fn containsSpecialChar(value: []const u8) bool {
        return CSSKeywords.containsSpecialChar(value);
    }
};

const CSSKeywords = struct {
    const border_styles = [_][]const u8{
        "none", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset",
    };

    const color_names = [_][]const u8{
        "black",        "white",   "red", "green", "blue", "yellow", "purple", "gray", "transparent",
        "currentColor", "inherit",
    };

    const position_keywords = [_][]const u8{
        "auto", "center", "left", "right", "top", "bottom",
    };

    const background_repeat = [_][]const u8{
        "repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round",
    };

    const font_styles = [_][]const u8{
        "normal", "italic", "oblique", "bold", "bolder", "lighter",
    };

    const font_sizes = [_][]const u8{
        "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
        "smaller",  "larger",
    };

    const font_families = [_][]const u8{
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
    };

    const css_global = [_][]const u8{
        "initial", "inherit", "unset", "revert",
    };

    const display_values = [_][]const u8{
        "block", "inline", "inline-block", "flex", "grid", "none",
    };

    const length_units = [_][]const u8{
        "px", "em", "rem", "vw", "vh", "vmin", "vmax", "%", "pt", "pc", "in", "cm", "mm",
        "ex", "ch", "fr",
    };

    const angle_units = [_][]const u8{
        "deg", "rad", "grad", "turn",
    };

    const time_units = [_][]const u8{
        "s", "ms",
    };

    const frequency_units = [_][]const u8{
        "Hz", "kHz",
    };

    const resolution_units = [_][]const u8{
        "dpi", "dpcm", "dppx",
    };

    const special_chars = [_]u8{
        '"', '\'', ';', '{', '}', '\\', '<', '>', '/', '\n', '\t', '\r', '\x00', '\x7F',
    };

    const functions = [_][]const u8{
        "rgb(",             "rgba(",            "hsl(",            "hsla(",      "url(",    "calc(",  "var(",  "attr(",
        "linear-gradient(", "radial-gradient(", "conic-gradient(", "translate(", "rotate(", "scale(", "skew(", "matrix(",
    };

    pub fn isKnownKeyword(value: []const u8) bool {
        const all_categories = [_][]const []const u8{
            &border_styles,  &color_names, &position_keywords, &background_repeat,
            &font_styles,    &font_sizes,  &font_families,     &css_global,
            &display_values,
        };

        for (all_categories) |category| {
            for (category) |keyword| {
                if (std.ascii.eqlIgnoreCase(value, keyword)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn containsSpecialChar(value: []const u8) bool {
        for (value) |c| {
            for (special_chars) |special| {
                if (c == special) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn isValidUnit(unit: []const u8) bool {
        const all_units = [_][]const []const u8{
            &length_units, &angle_units, &time_units, &frequency_units, &resolution_units,
        };

        for (all_units) |category| {
            for (category) |valid_unit| {
                if (std.ascii.eqlIgnoreCase(unit, valid_unit)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn startsWithFunction(value: []const u8) bool {
        const open_paren = std.mem.indexOf(u8, value, "(");
        const close_paren = std.mem.indexOf(u8, value, ")");

        if (open_paren == null or close_paren == null) return false;
        if (open_paren == 0) return false;

        const function_name = value[0..open_paren.?];
        return isValidFunctionName(function_name);
    }

    fn isValidFunctionName(name: []const u8) bool {
        if (name.len == 0) return false;

        const first = name[0];
        if (!std.ascii.isAlphabetic(first) and first != '_' and first != '-') {
            return false;
        }

        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                return false;
            }
        }

        return true;
    }
};

const testing = @import("../../testing.zig");

test "isNumericWithUnit - valid numbers with units" {
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("10px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("3.14em"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("-5rem"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("+12.5%"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("0vh"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit(".5vw"));
}

test "isNumericWithUnit - scientific notation" {
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("1e5px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("2.5E-3em"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("1e+2rem"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("-3.14e10px"));
}

test "isNumericWithUnit - edge cases and invalid inputs" {
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(""));

    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("px"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("--px"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(".px"));

    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("1e"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("1epx"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("1e+"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("1e+px"));

    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("1.2.3px"));

    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("10xyz"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("5invalid"));

    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("10"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("3.14"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("-5"));
}

test "isHexColor - valid hex colors" {
    try testing.expect(CSSValueAnalyzer.isHexColor("#000"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#fff"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#123456"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#abcdef"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#ABCDEF"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#12345678"));
}

test "isHexColor - invalid hex colors" {
    try testing.expect(!CSSValueAnalyzer.isHexColor(""));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("000"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#00"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#0000"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#00000"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#0000000"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#000000000"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#gggggg"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#123xyz"));
}

test "isMultiValueProperty - valid multi-value properties" {
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("10px 20px"));
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("solid red"));
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("#fff black"));
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("1em 2em 3em 4em"));
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("rgb(255,0,0) solid"));
}

test "isMultiValueProperty - invalid multi-value properties" {
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty(""));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("10px"));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("invalid unknown"));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("10px invalid"));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("   "));
}

test "isAlreadyQuoted - various quoting scenarios" {
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("\"hello\""));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("'world'"));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("\"\""));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("''"));

    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted(""));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("hello"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("\""));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("'"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("\"hello'"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("'hello\""));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("\"hello"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("hello\""));
}

test "isValidPropertyName - valid property names" {
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("color"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("background-color"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("-webkit-transform"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("font-size"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("margin-top"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("z-index"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("line-height"));
}

test "isValidPropertyName - invalid property names" {
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName(""));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("123color"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("color!"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("color space"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("@color"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("color.test"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("color_test"));
}

test "extractImportant - with and without !important" {
    var result = CSSValueAnalyzer.extractImportant("red !important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red", result.value);

    result = CSSValueAnalyzer.extractImportant("blue");
    try testing.expect(!result.is_important);
    try testing.expectEqual("blue", result.value);

    result = CSSValueAnalyzer.extractImportant("  green  !important  ");
    try testing.expect(result.is_important);
    try testing.expectEqual("green", result.value);

    result = CSSValueAnalyzer.extractImportant("!important");
    try testing.expect(result.is_important);
    try testing.expectEqual("", result.value);

    result = CSSValueAnalyzer.extractImportant("important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("important", result.value);
}

test "needsQuotes - various scenarios" {
    try testing.expect(CSSValueAnalyzer.needsQuotes(""));
    try testing.expect(CSSValueAnalyzer.needsQuotes("hello world"));
    try testing.expect(CSSValueAnalyzer.needsQuotes("test;"));
    try testing.expect(CSSValueAnalyzer.needsQuotes("a{b}"));
    try testing.expect(CSSValueAnalyzer.needsQuotes("test\"quote"));

    try testing.expect(!CSSValueAnalyzer.needsQuotes("\"already quoted\""));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("'already quoted'"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("url(image.png)"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("rgb(255, 0, 0)"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("10px 20px"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("simple"));
}

test "escapeCSSValue - escaping various characters" {
    const allocator = testing.arena_allocator;

    var result = try CSSValueAnalyzer.escapeCSSValue(allocator, "simple");
    try testing.expectEqual("simple", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "\"already quoted\"");
    try testing.expectEqual("\"already quoted\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\"quote");
    try testing.expectEqual("\"test\\\"quote\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\nline");
    try testing.expectEqual("\"test\\A line\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\\back");
    try testing.expectEqual("\"test\\\\back\"", result);
}

test "CSSKeywords.isKnownKeyword - case sensitivity" {
    try testing.expect(CSSKeywords.isKnownKeyword("red"));
    try testing.expect(CSSKeywords.isKnownKeyword("solid"));
    try testing.expect(CSSKeywords.isKnownKeyword("center"));
    try testing.expect(CSSKeywords.isKnownKeyword("inherit"));

    try testing.expect(CSSKeywords.isKnownKeyword("RED"));
    try testing.expect(CSSKeywords.isKnownKeyword("Red"));
    try testing.expect(CSSKeywords.isKnownKeyword("SOLID"));
    try testing.expect(CSSKeywords.isKnownKeyword("Center"));

    try testing.expect(!CSSKeywords.isKnownKeyword("invalid"));
    try testing.expect(!CSSKeywords.isKnownKeyword("unknown"));
    try testing.expect(!CSSKeywords.isKnownKeyword(""));
}

test "CSSKeywords.containsSpecialChar - various special characters" {
    try testing.expect(CSSKeywords.containsSpecialChar("test\"quote"));
    try testing.expect(CSSKeywords.containsSpecialChar("test'quote"));
    try testing.expect(CSSKeywords.containsSpecialChar("test;end"));
    try testing.expect(CSSKeywords.containsSpecialChar("test{brace"));
    try testing.expect(CSSKeywords.containsSpecialChar("test}brace"));
    try testing.expect(CSSKeywords.containsSpecialChar("test\\back"));
    try testing.expect(CSSKeywords.containsSpecialChar("test<angle"));
    try testing.expect(CSSKeywords.containsSpecialChar("test>angle"));
    try testing.expect(CSSKeywords.containsSpecialChar("test/slash"));

    try testing.expect(!CSSKeywords.containsSpecialChar("normal-text"));
    try testing.expect(!CSSKeywords.containsSpecialChar("text123"));
    try testing.expect(!CSSKeywords.containsSpecialChar(""));
}

test "CSSKeywords.isValidUnit - various units" {
    try testing.expect(CSSKeywords.isValidUnit("px"));
    try testing.expect(CSSKeywords.isValidUnit("em"));
    try testing.expect(CSSKeywords.isValidUnit("rem"));
    try testing.expect(CSSKeywords.isValidUnit("%"));

    try testing.expect(CSSKeywords.isValidUnit("deg"));
    try testing.expect(CSSKeywords.isValidUnit("rad"));

    try testing.expect(CSSKeywords.isValidUnit("s"));
    try testing.expect(CSSKeywords.isValidUnit("ms"));

    try testing.expect(CSSKeywords.isValidUnit("PX"));

    try testing.expect(!CSSKeywords.isValidUnit("invalid"));
    try testing.expect(!CSSKeywords.isValidUnit(""));
}

test "CSSKeywords.startsWithFunction - function detection" {
    try testing.expect(CSSKeywords.startsWithFunction("rgb(255, 0, 0)"));
    try testing.expect(CSSKeywords.startsWithFunction("rgba(255, 0, 0, 0.5)"));
    try testing.expect(CSSKeywords.startsWithFunction("url(image.png)"));
    try testing.expect(CSSKeywords.startsWithFunction("calc(100% - 20px)"));
    try testing.expect(CSSKeywords.startsWithFunction("var(--custom-property)"));
    try testing.expect(CSSKeywords.startsWithFunction("linear-gradient(to right, red, blue)"));

    try testing.expect(CSSKeywords.startsWithFunction("custom-function(args)"));
    try testing.expect(CSSKeywords.startsWithFunction("unknown(test)"));

    try testing.expect(!CSSKeywords.startsWithFunction("not-a-function"));
    try testing.expect(!CSSKeywords.startsWithFunction("missing-paren)"));
    try testing.expect(!CSSKeywords.startsWithFunction("missing-close("));
    try testing.expect(!CSSKeywords.startsWithFunction(""));
    try testing.expect(!CSSKeywords.startsWithFunction("rgb"));
}

test "isNumericWithUnit - whitespace handling" {
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(" 10px"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("10 px"));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("10px "));
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(" 10 px "));
}

test "extractImportant - whitespace edge cases" {
    var result = CSSValueAnalyzer.extractImportant("   ");
    try testing.expect(!result.is_important);
    try testing.expectEqual("", result.value);

    result = CSSValueAnalyzer.extractImportant("\t\n\r !important\t\n");
    try testing.expect(result.is_important);
    try testing.expectEqual("", result.value);

    result = CSSValueAnalyzer.extractImportant("red\t!important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red", result.value);
}

test "isHexColor - mixed case handling" {
    try testing.expect(CSSValueAnalyzer.isHexColor("#AbC"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#123aBc"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#FFffFF"));
    try testing.expect(CSSValueAnalyzer.isHexColor("#000FFF"));
}

test "edge case - very long inputs" {
    const long_valid = "a" ** 1000 ++ "px";
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(long_valid)); // not numeric

    const long_property = "a-" ** 100 ++ "property";
    try testing.expect(CSSValueAnalyzer.isValidPropertyName(long_property));

    const long_hex = "#" ++ "a" ** 20;
    try testing.expect(!CSSValueAnalyzer.isHexColor(long_hex));
}

test "boundary conditions - numeric parsing" {
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("0px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("0.0px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit(".0px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("0.px"));

    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("999999999px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("1.7976931348623157e+308px"));

    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("0.000000001px"));
    try testing.expect(CSSValueAnalyzer.isNumericWithUnit("1e-100px"));
}

test "extractImportant - malformed important declarations" {
    var result = CSSValueAnalyzer.extractImportant("red ! important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red ! important", result.value);

    result = CSSValueAnalyzer.extractImportant("red !Important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red !Important", result.value);

    result = CSSValueAnalyzer.extractImportant("red !IMPORTANT");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red !IMPORTANT", result.value);

    result = CSSValueAnalyzer.extractImportant("!importantred");
    try testing.expect(!result.is_important);
    try testing.expectEqual("!importantred", result.value);

    result = CSSValueAnalyzer.extractImportant("red !important !important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red !important", result.value);
}

test "isMultiValueProperty - complex spacing scenarios" {
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("10px    20px"));
    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("solid     red"));

    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("  10px 20px  "));

    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("10px\t20px"));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("10px\n20px"));

    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("10px   20px   30px"));
}

test "isAlreadyQuoted - edge cases with quotes" {
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("\"'hello'\""));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("'\"hello\"'"));

    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("\"hello\\\"world\""));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("'hello\\'world'"));

    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("\"hello"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("hello\""));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("'hello"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("hello'"));

    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("\"a\""));
    try testing.expect(CSSValueAnalyzer.isAlreadyQuoted("'b'"));
}

test "needsQuotes - function and URL edge cases" {
    try testing.expect(!CSSValueAnalyzer.needsQuotes("rgb(255, 0, 0)"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("calc(100% - 20px)"));

    try testing.expect(!CSSValueAnalyzer.needsQuotes("url(path with spaces.jpg)"));

    try testing.expect(!CSSValueAnalyzer.needsQuotes("linear-gradient(to right, red, blue)"));

    try testing.expect(CSSValueAnalyzer.needsQuotes("rgb(255, 0, 0"));
}

test "escapeCSSValue - control characters and Unicode" {
    const allocator = testing.arena_allocator;

    var result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\ttab");
    try testing.expectEqual("\"test\\9 tab\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\rreturn");
    try testing.expectEqual("\"test\\D return\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\x00null");
    try testing.expectEqual("\"test\\0null\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\x7Fdel");
    try testing.expectEqual("\"test\\7f del\"", result);

    result = try CSSValueAnalyzer.escapeCSSValue(allocator, "test\"quote\nline\\back");
    try testing.expectEqual("\"test\\\"quote\\A line\\\\back\"", result);
}

test "isValidPropertyName - CSS custom properties and vendor prefixes" {
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("--custom-color"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("--my-variable"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("--123"));

    try testing.expect(CSSValueAnalyzer.isValidPropertyName("-webkit-transform"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("-moz-border-radius"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("-ms-filter"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("-o-transition"));

    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("-123invalid"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("--"));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName("-"));
}

test "startsWithFunction - case sensitivity and partial matches" {
    try testing.expect(CSSKeywords.startsWithFunction("RGB(255, 0, 0)"));
    try testing.expect(CSSKeywords.startsWithFunction("Rgb(255, 0, 0)"));
    try testing.expect(CSSKeywords.startsWithFunction("URL(image.png)"));

    try testing.expect(CSSKeywords.startsWithFunction("rg(something)"));
    try testing.expect(CSSKeywords.startsWithFunction("ur(something)"));

    try testing.expect(CSSKeywords.startsWithFunction("rgb(1,2,3)"));
    try testing.expect(CSSKeywords.startsWithFunction("rgba(1,2,3,4)"));

    try testing.expect(CSSKeywords.startsWithFunction("my-custom-function(args)"));
    try testing.expect(CSSKeywords.startsWithFunction("function-with-dashes(test)"));

    try testing.expect(!CSSKeywords.startsWithFunction("123function(test)"));
}

test "isHexColor - Unicode and invalid characters" {
    try testing.expect(!CSSValueAnalyzer.isHexColor("#ghijkl"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#12345g"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#xyz"));

    try testing.expect(!CSSValueAnalyzer.isHexColor("#АВС"));

    try testing.expect(!CSSValueAnalyzer.isHexColor("#1234567g"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("#g2345678"));
}

test "complex integration scenarios" {
    const allocator = testing.arena_allocator;

    try testing.expect(CSSValueAnalyzer.isMultiValueProperty("rgb(255,0,0) url(bg.jpg)"));

    try testing.expect(!CSSValueAnalyzer.needsQuotes("calc(100% - 20px)"));

    const result = try CSSValueAnalyzer.escapeCSSValue(allocator, "fake(function with spaces");
    try testing.expectEqual("\"fake(function with spaces\"", result);

    const important_result = CSSValueAnalyzer.extractImportant("rgb(255,0,0) !important");
    try testing.expect(important_result.is_important);
    try testing.expectEqual("rgb(255,0,0)", important_result.value);
}

test "performance edge cases - empty and minimal inputs" {
    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit(""));
    try testing.expect(!CSSValueAnalyzer.isHexColor(""));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty(""));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted(""));
    try testing.expect(!CSSValueAnalyzer.isValidPropertyName(""));
    try testing.expect(CSSValueAnalyzer.needsQuotes(""));
    try testing.expect(!CSSKeywords.isKnownKeyword(""));
    try testing.expect(!CSSKeywords.containsSpecialChar(""));
    try testing.expect(!CSSKeywords.isValidUnit(""));
    try testing.expect(!CSSKeywords.startsWithFunction(""));

    try testing.expect(!CSSValueAnalyzer.isNumericWithUnit("a"));
    try testing.expect(!CSSValueAnalyzer.isHexColor("a"));
    try testing.expect(!CSSValueAnalyzer.isMultiValueProperty("a"));
    try testing.expect(!CSSValueAnalyzer.isAlreadyQuoted("a"));
    try testing.expect(CSSValueAnalyzer.isValidPropertyName("a"));
    try testing.expect(!CSSValueAnalyzer.needsQuotes("a"));
}

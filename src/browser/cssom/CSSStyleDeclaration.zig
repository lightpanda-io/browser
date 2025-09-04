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

const Page = @import("../page.zig").Page;
const CSSRule = @import("CSSRule.zig");
const CSSParser = @import("CSSParser.zig");

const Property = struct {
    value: []const u8,
    priority: bool,
};

const CSSStyleDeclaration = @This();

properties: std.StringArrayHashMapUnmanaged(Property),

pub const empty: CSSStyleDeclaration = .{
    .properties = .empty,
};

pub fn get_cssFloat(self: *const CSSStyleDeclaration) []const u8 {
    return self._getPropertyValue("float");
}

pub fn set_cssFloat(self: *CSSStyleDeclaration, value: ?[]const u8, page: *Page) !void {
    const final_value = value orelse "";
    return self._setProperty("float", final_value, null, page);
}

pub fn get_cssText(self: *const CSSStyleDeclaration, page: *Page) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buffer.writer(page.call_arena);
    var it = self.properties.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const property = entry.value_ptr;
        const escaped = try escapeCSSValue(page.call_arena, property.value);
        try writer.print("{s}: {s}", .{ name, escaped });
        if (property.priority) {
            try writer.writeAll(" !important; ");
        } else {
            try writer.writeAll("; ");
        }
    }
    return buffer.items;
}

// TODO Propagate also upward to parent node
pub fn set_cssText(self: *CSSStyleDeclaration, text: []const u8, page: *Page) !void {
    self.properties.clearRetainingCapacity();

    // call_arena is safe here, because _setProperty will dupe the name
    // using the page's longer-living arena.
    const declarations = try CSSParser.parseDeclarations(page.call_arena, text);

    for (declarations) |decl| {
        if (!isValidPropertyName(decl.name)) {
            continue;
        }
        const priority: ?[]const u8 = if (decl.is_important) "important" else null;
        try self._setProperty(decl.name, decl.value, priority, page);
    }
}

pub fn get_length(self: *const CSSStyleDeclaration) usize {
    return self.properties.count();
}

pub fn get_parentRule(_: *const CSSStyleDeclaration) ?CSSRule {
    return null;
}

pub fn _getPropertyPriority(self: *const CSSStyleDeclaration, name: []const u8) []const u8 {
    const property = self.properties.getPtr(name) orelse return "";
    return if (property.priority) "important" else "";
}

// TODO should handle properly shorthand properties and canonical forms
pub fn _getPropertyValue(self: *const CSSStyleDeclaration, name: []const u8) []const u8 {
    if (self.properties.getPtr(name)) |property| {
        return property.value;
    }

    // default to everything being visible (unless it's been explicitly set)
    if (std.mem.eql(u8, name, "visibility")) {
        return "visible";
    }

    return "";
}

pub fn _item(self: *const CSSStyleDeclaration, index: usize) []const u8 {
    const values = self.properties.entries.items(.key);
    if (index >= values.len) {
        return "";
    }
    return values[index];
}

pub fn _removeProperty(self: *CSSStyleDeclaration, name: []const u8) ![]const u8 {
    const property = self.properties.fetchOrderedRemove(name) orelse return "";
    return property.value.value;
}

pub fn _setProperty(self: *CSSStyleDeclaration, name: []const u8, value: []const u8, priority: ?[]const u8, page: *Page) !void {
    const gop = try self.properties.getOrPut(page.arena, name);
    if (!gop.found_existing) {
        const owned_name = try page.arena.dupe(u8, name);
        gop.key_ptr.* = owned_name;
    }

    const owned_value = try page.arena.dupe(u8, value);
    const is_important = priority != null and std.ascii.eqlIgnoreCase(priority.?, "important");
    gop.value_ptr.* = .{ .value = owned_value, .priority = is_important };
}

pub fn named_get(self: *const CSSStyleDeclaration, name: []const u8, _: *bool) []const u8 {
    return self._getPropertyValue(name);
}

pub fn named_set(self: *CSSStyleDeclaration, name: []const u8, value: []const u8, _: *bool, page: *Page) !void {
    return self._setProperty(name, value, null, page);
}

fn isNumericWithUnit(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    const first = value[0];

    if (!std.ascii.isDigit(first) and first != '+' and first != '-' and first != '.') {
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

    if (!has_digit) {
        return false;
    }

    if (i == value.len) {
        return true;
    }

    const unit = value[i..];
    return CSSKeywords.isValidUnit(unit);
}

fn isHexColor(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }
    if (value[0] != '#') {
        return false;
    }

    const hex_part = value[1..];
    if (hex_part.len != 3 and hex_part.len != 6 and hex_part.len != 8) {
        return false;
    }

    for (hex_part) |c| {
        if (!std.ascii.isHex(c)) {
            return false;
        }
    }

    return true;
}

fn isMultiValueProperty(value: []const u8) bool {
    var parts = std.mem.splitAny(u8, value, " ");
    var multi_value_parts: usize = 0;
    var all_parts_valid = true;

    while (parts.next()) |part| {
        if (part.len == 0) continue;
        multi_value_parts += 1;

        if (isNumericWithUnit(part)) {
            continue;
        }
        if (isHexColor(part)) {
            continue;
        }
        if (CSSKeywords.isKnownKeyword(part)) {
            continue;
        }
        if (CSSKeywords.startsWithFunction(part)) {
            continue;
        }

        all_parts_valid = false;
        break;
    }

    return multi_value_parts >= 2 and all_parts_valid;
}

fn isAlreadyQuoted(value: []const u8) bool {
    return value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\''));
}

fn isValidPropertyName(name: []const u8) bool {
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

fn extractImportant(value: []const u8) struct { value: []const u8, is_important: bool } {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);

    if (std.mem.endsWith(u8, trimmed, "!important")) {
        const clean_value = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 10], &std.ascii.whitespace);
        return .{ .value = clean_value, .is_important = true };
    }

    return .{ .value = trimmed, .is_important = false };
}

fn needsQuotes(value: []const u8) bool {
    if (value.len == 0) return true;
    if (isAlreadyQuoted(value)) return false;

    if (CSSKeywords.containsSpecialChar(value)) {
        return true;
    }

    if (std.mem.indexOfScalar(u8, value, ' ') == null) {
        return false;
    }

    const is_url = std.mem.startsWith(u8, value, "url(");
    const is_function = CSSKeywords.startsWithFunction(value);

    return !isMultiValueProperty(value) and
        !is_url and
        !is_function;
}

fn escapeCSSValue(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (!needsQuotes(value)) {
        return value;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;

    // We'll need at least this much space, +2 for the quotes
    try out.ensureTotalCapacity(arena, value.len + 2);
    const writer = out.writer(arena);

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
    return out.items;
}

fn isKnownKeyword(value: []const u8) bool {
    return CSSKeywords.isKnownKeyword(value);
}

fn containsSpecialChar(value: []const u8) bool {
    return CSSKeywords.containsSpecialChar(value);
}

const CSSKeywords = struct {
    const BORDER_STYLES = [_][]const u8{
        "none", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset",
    };

    const COLOR_NAMES = [_][]const u8{
        "black",        "white",   "red", "green", "blue", "yellow", "purple", "gray", "transparent",
        "currentColor", "inherit",
    };

    const POSITION_KEYWORDS = [_][]const u8{
        "auto", "center", "left", "right", "top", "bottom",
    };

    const BACKGROUND_REPEAT = [_][]const u8{
        "repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round",
    };

    const FONT_STYLES = [_][]const u8{
        "normal", "italic", "oblique", "bold", "bolder", "lighter",
    };

    const FONT_SIZES = [_][]const u8{
        "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
        "smaller",  "larger",
    };

    const FONT_FAMILIES = [_][]const u8{
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
    };

    const CSS_GLOBAL = [_][]const u8{
        "initial", "inherit", "unset", "revert",
    };

    const DISPLAY_VALUES = [_][]const u8{
        "block", "inline", "inline-block", "flex", "grid", "none",
    };

    const UNITS = [_][]const u8{
        // LENGTH
        "px",   "em", "rem", "vw",  "vh",  "vmin", "vmax", "%", "pt", "pc", "in",  "cm",  "mm",
        "ex",   "ch", "fr",

        // ANGLE
         "deg", "rad", "grad", "turn",

        // TIME
        "s", "ms",

        // FREQUENCY
        "hz", "khz",

        // RESOLUTION
        "dpi", "dpcm",
        "dppx",
    };

    const SPECIAL_CHARS = [_]u8{
        '"', '\'', ';', '{', '}', '\\', '<', '>', '/', '\n', '\t', '\r', '\x00', '\x7F',
    };

    const FUNCTIONS = [_][]const u8{
        "rgb(",             "rgba(",            "hsl(",            "hsla(",      "url(",    "calc(",  "var(",  "attr(",
        "linear-gradient(", "radial-gradient(", "conic-gradient(", "translate(", "rotate(", "scale(", "skew(", "matrix(",
    };

    const KEYWORDS = BORDER_STYLES ++ COLOR_NAMES ++ POSITION_KEYWORDS ++
        BACKGROUND_REPEAT ++ FONT_STYLES ++ FONT_SIZES ++ FONT_FAMILIES ++
        CSS_GLOBAL ++ DISPLAY_VALUES;

    const MAX_KEYWORD_LEN = lengthOfLongestValue(&KEYWORDS);

    pub fn isKnownKeyword(value: []const u8) bool {
        if (value.len > MAX_KEYWORD_LEN) {
            return false;
        }
        var buf: [MAX_KEYWORD_LEN]u8 = undefined;
        const normalized = std.ascii.lowerString(&buf, value);

        for (KEYWORDS) |keyword| {
            if (std.ascii.eqlIgnoreCase(normalized, keyword)) {
                return true;
            }
        }

        return false;
    }

    pub fn containsSpecialChar(value: []const u8) bool {
        return std.mem.indexOfAny(u8, value, &SPECIAL_CHARS) != null;
    }

    const MAX_UNIT_LEN = lengthOfLongestValue(&UNITS);

    pub fn isValidUnit(unit: []const u8) bool {
        if (unit.len > MAX_UNIT_LEN) {
            return false;
        }
        var buf: [MAX_UNIT_LEN]u8 = undefined;
        const normalized = std.ascii.lowerString(&buf, unit);

        for (UNITS) |u| {
            if (std.mem.eql(u8, normalized, u)) {
                return true;
            }
        }
        return false;
    }

    pub fn startsWithFunction(value: []const u8) bool {
        const pos = std.mem.indexOfScalar(u8, value, '(') orelse return false;
        if (pos == 0) return false;

        if (std.mem.indexOfScalarPos(u8, value, pos, ')') == null) {
            return false;
        }
        const function_name = value[0..pos];
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

fn lengthOfLongestValue(values: []const []const u8) usize {
    var max: usize = 0;
    for (values) |v| {
        max = @max(v.len, max);
    }
    return max;
}

const testing = @import("../../testing.zig");
test "Browser: CSS.StyleDeclaration" {
    try testing.htmlRunner("cssom/css_style_declaration.html");
}

test "Browser: CSS.StyleDeclaration: isNumericWithUnit - valid numbers with units" {
    try testing.expect(isNumericWithUnit("10px"));
    try testing.expect(isNumericWithUnit("3.14em"));
    try testing.expect(isNumericWithUnit("-5rem"));
    try testing.expect(isNumericWithUnit("+12.5%"));
    try testing.expect(isNumericWithUnit("0vh"));
    try testing.expect(isNumericWithUnit(".5vw"));
}

test "Browser: CSS.StyleDeclaration: isNumericWithUnit - scientific notation" {
    try testing.expect(isNumericWithUnit("1e5px"));
    try testing.expect(isNumericWithUnit("2.5E-3em"));
    try testing.expect(isNumericWithUnit("1e+2rem"));
    try testing.expect(isNumericWithUnit("-3.14e10px"));
}

test "Browser: CSS.StyleDeclaration: isNumericWithUnit - edge cases and invalid inputs" {
    try testing.expect(!isNumericWithUnit(""));

    try testing.expect(!isNumericWithUnit("px"));
    try testing.expect(!isNumericWithUnit("--px"));
    try testing.expect(!isNumericWithUnit(".px"));

    try testing.expect(!isNumericWithUnit("1e"));
    try testing.expect(!isNumericWithUnit("1epx"));
    try testing.expect(!isNumericWithUnit("1e+"));
    try testing.expect(!isNumericWithUnit("1e+px"));

    try testing.expect(!isNumericWithUnit("1.2.3px"));

    try testing.expect(!isNumericWithUnit("10xyz"));
    try testing.expect(!isNumericWithUnit("5invalid"));

    try testing.expect(isNumericWithUnit("10"));
    try testing.expect(isNumericWithUnit("3.14"));
    try testing.expect(isNumericWithUnit("-5"));
}

test "Browser: CSS.StyleDeclaration: isHexColor - valid hex colors" {
    try testing.expect(isHexColor("#000"));
    try testing.expect(isHexColor("#fff"));
    try testing.expect(isHexColor("#123456"));
    try testing.expect(isHexColor("#abcdef"));
    try testing.expect(isHexColor("#ABCDEF"));
    try testing.expect(isHexColor("#12345678"));
}

test "Browser: CSS.StyleDeclaration: isHexColor - invalid hex colors" {
    try testing.expect(!isHexColor(""));
    try testing.expect(!isHexColor("#"));
    try testing.expect(!isHexColor("000"));
    try testing.expect(!isHexColor("#00"));
    try testing.expect(!isHexColor("#0000"));
    try testing.expect(!isHexColor("#00000"));
    try testing.expect(!isHexColor("#0000000"));
    try testing.expect(!isHexColor("#000000000"));
    try testing.expect(!isHexColor("#gggggg"));
    try testing.expect(!isHexColor("#123xyz"));
}

test "Browser: CSS.StyleDeclaration: isMultiValueProperty - valid multi-value properties" {
    try testing.expect(isMultiValueProperty("10px 20px"));
    try testing.expect(isMultiValueProperty("solid red"));
    try testing.expect(isMultiValueProperty("#fff black"));
    try testing.expect(isMultiValueProperty("1em 2em 3em 4em"));
    try testing.expect(isMultiValueProperty("rgb(255,0,0) solid"));
}

test "Browser: CSS.StyleDeclaration: isMultiValueProperty - invalid multi-value properties" {
    try testing.expect(!isMultiValueProperty(""));
    try testing.expect(!isMultiValueProperty("10px"));
    try testing.expect(!isMultiValueProperty("invalid unknown"));
    try testing.expect(!isMultiValueProperty("10px invalid"));
    try testing.expect(!isMultiValueProperty("   "));
}

test "Browser: CSS.StyleDeclaration: isAlreadyQuoted - various quoting scenarios" {
    try testing.expect(isAlreadyQuoted("\"hello\""));
    try testing.expect(isAlreadyQuoted("'world'"));
    try testing.expect(isAlreadyQuoted("\"\""));
    try testing.expect(isAlreadyQuoted("''"));

    try testing.expect(!isAlreadyQuoted(""));
    try testing.expect(!isAlreadyQuoted("hello"));
    try testing.expect(!isAlreadyQuoted("\""));
    try testing.expect(!isAlreadyQuoted("'"));
    try testing.expect(!isAlreadyQuoted("\"hello'"));
    try testing.expect(!isAlreadyQuoted("'hello\""));
    try testing.expect(!isAlreadyQuoted("\"hello"));
    try testing.expect(!isAlreadyQuoted("hello\""));
}

test "Browser: CSS.StyleDeclaration: isValidPropertyName - valid property names" {
    try testing.expect(isValidPropertyName("color"));
    try testing.expect(isValidPropertyName("background-color"));
    try testing.expect(isValidPropertyName("-webkit-transform"));
    try testing.expect(isValidPropertyName("font-size"));
    try testing.expect(isValidPropertyName("margin-top"));
    try testing.expect(isValidPropertyName("z-index"));
    try testing.expect(isValidPropertyName("line-height"));
}

test "Browser: CSS.StyleDeclaration: isValidPropertyName - invalid property names" {
    try testing.expect(!isValidPropertyName(""));
    try testing.expect(!isValidPropertyName("123color"));
    try testing.expect(!isValidPropertyName("color!"));
    try testing.expect(!isValidPropertyName("color space"));
    try testing.expect(!isValidPropertyName("@color"));
    try testing.expect(!isValidPropertyName("color.test"));
    try testing.expect(!isValidPropertyName("color_test"));
}

test "Browser: CSS.StyleDeclaration: extractImportant - with and without !important" {
    var result = extractImportant("red !important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red", result.value);

    result = extractImportant("blue");
    try testing.expect(!result.is_important);
    try testing.expectEqual("blue", result.value);

    result = extractImportant("  green  !important  ");
    try testing.expect(result.is_important);
    try testing.expectEqual("green", result.value);

    result = extractImportant("!important");
    try testing.expect(result.is_important);
    try testing.expectEqual("", result.value);

    result = extractImportant("important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("important", result.value);
}

test "Browser: CSS.StyleDeclaration: needsQuotes - various scenarios" {
    try testing.expect(needsQuotes(""));
    try testing.expect(needsQuotes("hello world"));
    try testing.expect(needsQuotes("test;"));
    try testing.expect(needsQuotes("a{b}"));
    try testing.expect(needsQuotes("test\"quote"));

    try testing.expect(!needsQuotes("\"already quoted\""));
    try testing.expect(!needsQuotes("'already quoted'"));
    try testing.expect(!needsQuotes("url(image.png)"));
    try testing.expect(!needsQuotes("rgb(255, 0, 0)"));
    try testing.expect(!needsQuotes("10px 20px"));
    try testing.expect(!needsQuotes("simple"));
}

test "Browser: CSS.StyleDeclaration: escapeCSSValue - escaping various characters" {
    const allocator = testing.arena_allocator;

    var result = try escapeCSSValue(allocator, "simple");
    try testing.expectEqual("simple", result);

    result = try escapeCSSValue(allocator, "\"already quoted\"");
    try testing.expectEqual("\"already quoted\"", result);

    result = try escapeCSSValue(allocator, "test\"quote");
    try testing.expectEqual("\"test\\\"quote\"", result);

    result = try escapeCSSValue(allocator, "test\nline");
    try testing.expectEqual("\"test\\A line\"", result);

    result = try escapeCSSValue(allocator, "test\\back");
    try testing.expectEqual("\"test\\\\back\"", result);
}

test "Browser: CSS.StyleDeclaration: CSSKeywords.isKnownKeyword - case sensitivity" {
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

test "Browser: CSS.StyleDeclaration: CSSKeywords.containsSpecialChar - various special characters" {
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

test "Browser: CSS.StyleDeclaration: CSSKeywords.isValidUnit - various units" {
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

test "Browser: CSS.StyleDeclaration: CSSKeywords.startsWithFunction - function detection" {
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

test "Browser: CSS.StyleDeclaration: isNumericWithUnit - whitespace handling" {
    try testing.expect(!isNumericWithUnit(" 10px"));
    try testing.expect(!isNumericWithUnit("10 px"));
    try testing.expect(!isNumericWithUnit("10px "));
    try testing.expect(!isNumericWithUnit(" 10 px "));
}

test "Browser: CSS.StyleDeclaration: extractImportant - whitespace edge cases" {
    var result = extractImportant("   ");
    try testing.expect(!result.is_important);
    try testing.expectEqual("", result.value);

    result = extractImportant("\t\n\r !important\t\n");
    try testing.expect(result.is_important);
    try testing.expectEqual("", result.value);

    result = extractImportant("red\t!important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red", result.value);
}

test "Browser: CSS.StyleDeclaration: isHexColor - mixed case handling" {
    try testing.expect(isHexColor("#AbC"));
    try testing.expect(isHexColor("#123aBc"));
    try testing.expect(isHexColor("#FFffFF"));
    try testing.expect(isHexColor("#000FFF"));
}

test "Browser: CSS.StyleDeclaration: edge case - very long inputs" {
    const long_valid = "a" ** 1000 ++ "px";
    try testing.expect(!isNumericWithUnit(long_valid)); // not numeric

    const long_property = "a-" ** 100 ++ "property";
    try testing.expect(isValidPropertyName(long_property));

    const long_hex = "#" ++ "a" ** 20;
    try testing.expect(!isHexColor(long_hex));
}

test "Browser: CSS.StyleDeclaration: boundary conditions - numeric parsing" {
    try testing.expect(isNumericWithUnit("0px"));
    try testing.expect(isNumericWithUnit("0.0px"));
    try testing.expect(isNumericWithUnit(".0px"));
    try testing.expect(isNumericWithUnit("0.px"));

    try testing.expect(isNumericWithUnit("999999999px"));
    try testing.expect(isNumericWithUnit("1.7976931348623157e+308px"));

    try testing.expect(isNumericWithUnit("0.000000001px"));
    try testing.expect(isNumericWithUnit("1e-100px"));
}

test "Browser: CSS.StyleDeclaration: extractImportant - malformed important declarations" {
    var result = extractImportant("red ! important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red ! important", result.value);

    result = extractImportant("red !Important");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red !Important", result.value);

    result = extractImportant("red !IMPORTANT");
    try testing.expect(!result.is_important);
    try testing.expectEqual("red !IMPORTANT", result.value);

    result = extractImportant("!importantred");
    try testing.expect(!result.is_important);
    try testing.expectEqual("!importantred", result.value);

    result = extractImportant("red !important !important");
    try testing.expect(result.is_important);
    try testing.expectEqual("red !important", result.value);
}

test "Browser: CSS.StyleDeclaration: isMultiValueProperty - complex spacing scenarios" {
    try testing.expect(isMultiValueProperty("10px    20px"));
    try testing.expect(isMultiValueProperty("solid     red"));

    try testing.expect(isMultiValueProperty("  10px 20px  "));

    try testing.expect(!isMultiValueProperty("10px\t20px"));
    try testing.expect(!isMultiValueProperty("10px\n20px"));

    try testing.expect(isMultiValueProperty("10px   20px   30px"));
}

test "Browser: CSS.StyleDeclaration: isAlreadyQuoted - edge cases with quotes" {
    try testing.expect(isAlreadyQuoted("\"'hello'\""));
    try testing.expect(isAlreadyQuoted("'\"hello\"'"));

    try testing.expect(isAlreadyQuoted("\"hello\\\"world\""));
    try testing.expect(isAlreadyQuoted("'hello\\'world'"));

    try testing.expect(!isAlreadyQuoted("\"hello"));
    try testing.expect(!isAlreadyQuoted("hello\""));
    try testing.expect(!isAlreadyQuoted("'hello"));
    try testing.expect(!isAlreadyQuoted("hello'"));

    try testing.expect(isAlreadyQuoted("\"a\""));
    try testing.expect(isAlreadyQuoted("'b'"));
}

test "Browser: CSS.StyleDeclaration: needsQuotes - function and URL edge cases" {
    try testing.expect(!needsQuotes("rgb(255, 0, 0)"));
    try testing.expect(!needsQuotes("calc(100% - 20px)"));

    try testing.expect(!needsQuotes("url(path with spaces.jpg)"));

    try testing.expect(!needsQuotes("linear-gradient(to right, red, blue)"));

    try testing.expect(needsQuotes("rgb(255, 0, 0"));
}

test "Browser: CSS.StyleDeclaration: escapeCSSValue - control characters and Unicode" {
    const allocator = testing.arena_allocator;

    var result = try escapeCSSValue(allocator, "test\ttab");
    try testing.expectEqual("\"test\\9 tab\"", result);

    result = try escapeCSSValue(allocator, "test\rreturn");
    try testing.expectEqual("\"test\\D return\"", result);

    result = try escapeCSSValue(allocator, "test\x00null");
    try testing.expectEqual("\"test\\0null\"", result);

    result = try escapeCSSValue(allocator, "test\x7Fdel");
    try testing.expectEqual("\"test\\7f del\"", result);

    result = try escapeCSSValue(allocator, "test\"quote\nline\\back");
    try testing.expectEqual("\"test\\\"quote\\A line\\\\back\"", result);
}

test "Browser: CSS.StyleDeclaration: isValidPropertyName - CSS custom properties and vendor prefixes" {
    try testing.expect(isValidPropertyName("--custom-color"));
    try testing.expect(isValidPropertyName("--my-variable"));
    try testing.expect(isValidPropertyName("--123"));

    try testing.expect(isValidPropertyName("-webkit-transform"));
    try testing.expect(isValidPropertyName("-moz-border-radius"));
    try testing.expect(isValidPropertyName("-ms-filter"));
    try testing.expect(isValidPropertyName("-o-transition"));

    try testing.expect(!isValidPropertyName("-123invalid"));
    try testing.expect(!isValidPropertyName("--"));
    try testing.expect(!isValidPropertyName("-"));
}

test "Browser: CSS.StyleDeclaration: startsWithFunction - case sensitivity and partial matches" {
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

test "Browser: CSS.StyleDeclaration: isHexColor - Unicode and invalid characters" {
    try testing.expect(!isHexColor("#ghijkl"));
    try testing.expect(!isHexColor("#12345g"));
    try testing.expect(!isHexColor("#xyz"));

    try testing.expect(!isHexColor("#АВС"));

    try testing.expect(!isHexColor("#1234567g"));
    try testing.expect(!isHexColor("#g2345678"));
}

test "Browser: CSS.StyleDeclaration: complex integration scenarios" {
    const allocator = testing.arena_allocator;

    try testing.expect(isMultiValueProperty("rgb(255,0,0) url(bg.jpg)"));

    try testing.expect(!needsQuotes("calc(100% - 20px)"));

    const result = try escapeCSSValue(allocator, "fake(function with spaces");
    try testing.expectEqual("\"fake(function with spaces\"", result);

    const important_result = extractImportant("rgb(255,0,0) !important");
    try testing.expect(important_result.is_important);
    try testing.expectEqual("rgb(255,0,0)", important_result.value);
}

test "Browser: CSS.StyleDeclaration: performance edge cases - empty and minimal inputs" {
    try testing.expect(!isNumericWithUnit(""));
    try testing.expect(!isHexColor(""));
    try testing.expect(!isMultiValueProperty(""));
    try testing.expect(!isAlreadyQuoted(""));
    try testing.expect(!isValidPropertyName(""));
    try testing.expect(needsQuotes(""));
    try testing.expect(!CSSKeywords.isKnownKeyword(""));
    try testing.expect(!CSSKeywords.containsSpecialChar(""));
    try testing.expect(!CSSKeywords.isValidUnit(""));
    try testing.expect(!CSSKeywords.startsWithFunction(""));

    try testing.expect(!isNumericWithUnit("a"));
    try testing.expect(!isHexColor("a"));
    try testing.expect(!isMultiValueProperty("a"));
    try testing.expect(!isAlreadyQuoted("a"));
    try testing.expect(isValidPropertyName("a"));
    try testing.expect(!needsQuotes("a"));
}

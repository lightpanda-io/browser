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
const Allocator = std.mem.Allocator;

const CSSConstants = struct {
    const IMPORTANT = "!important";
    const URL_PREFIX = "url(";
};

const CSSParserState = enum {
    seek_name,
    in_name,
    seek_colon,
    seek_value,
    in_value,
    in_quoted_value,
    in_single_quoted_value,
    in_url,
    in_important,
};

const CSSDeclaration = struct {
    name: []const u8,
    value: []const u8,
    is_important: bool,
};

const CSSParser = @This();
state: CSSParserState,
name_start: usize,
name_end: usize,
value_start: usize,
position: usize,
paren_depth: usize,
escape_next: bool,

pub fn init() CSSParser {
    return .{
        .state = .seek_name,
        .name_start = 0,
        .name_end = 0,
        .value_start = 0,
        .position = 0,
        .paren_depth = 0,
        .escape_next = false,
    };
}

pub fn parseDeclarations(arena: Allocator, text: []const u8) ![]CSSDeclaration {
    var parser = init();
    var declarations: std.ArrayListUnmanaged(CSSDeclaration) = .empty;

    while (parser.position < text.len) {
        const c = text[parser.position];

        switch (parser.state) {
            .seek_name => {
                if (!std.ascii.isWhitespace(c)) {
                    parser.name_start = parser.position;
                    parser.state = .in_name;
                    continue;
                }
            },
            .in_name => {
                if (c == ':') {
                    parser.name_end = parser.position;
                    parser.state = .seek_value;
                } else if (std.ascii.isWhitespace(c)) {
                    parser.name_end = parser.position;
                    parser.state = .seek_colon;
                }
            },
            .seek_colon => {
                if (c == ':') {
                    parser.state = .seek_value;
                } else if (!std.ascii.isWhitespace(c)) {
                    parser.state = .seek_name;
                    continue;
                }
            },
            .seek_value => {
                if (!std.ascii.isWhitespace(c)) {
                    parser.value_start = parser.position;
                    if (c == '"') {
                        parser.state = .in_quoted_value;
                    } else if (c == '\'') {
                        parser.state = .in_single_quoted_value;
                    } else if (c == 'u' and parser.position + CSSConstants.URL_PREFIX.len <= text.len and std.mem.startsWith(u8, text[parser.position..], CSSConstants.URL_PREFIX)) {
                        parser.state = .in_url;
                        parser.paren_depth = 1;
                        parser.position += 3;
                    } else {
                        parser.state = .in_value;
                        continue;
                    }
                }
            },
            .in_value => {
                if (parser.escape_next) {
                    parser.escape_next = false;
                } else if (c == '\\') {
                    parser.escape_next = true;
                } else if (c == '(') {
                    parser.paren_depth += 1;
                } else if (c == ')' and parser.paren_depth > 0) {
                    parser.paren_depth -= 1;
                } else if (c == ';' and parser.paren_depth == 0) {
                    try parser.finishDeclaration(arena, &declarations, text);
                    parser.state = .seek_name;
                }
            },
            .in_quoted_value => {
                if (parser.escape_next) {
                    parser.escape_next = false;
                } else if (c == '\\') {
                    parser.escape_next = true;
                } else if (c == '"') {
                    parser.state = .in_value;
                }
            },
            .in_single_quoted_value => {
                if (parser.escape_next) {
                    parser.escape_next = false;
                } else if (c == '\\') {
                    parser.escape_next = true;
                } else if (c == '\'') {
                    parser.state = .in_value;
                }
            },
            .in_url => {
                if (parser.escape_next) {
                    parser.escape_next = false;
                } else if (c == '\\') {
                    parser.escape_next = true;
                } else if (c == '(') {
                    parser.paren_depth += 1;
                } else if (c == ')') {
                    parser.paren_depth -= 1;
                    if (parser.paren_depth == 0) {
                        parser.state = .in_value;
                    }
                }
            },
            .in_important => {},
        }

        parser.position += 1;
    }

    try parser.finalize(arena, &declarations, text);

    return declarations.items;
}

fn finishDeclaration(self: *CSSParser, arena: Allocator, declarations: *std.ArrayListUnmanaged(CSSDeclaration), text: []const u8) !void {
    const name = std.mem.trim(u8, text[self.name_start..self.name_end], &std.ascii.whitespace);
    if (name.len == 0) return;

    const raw_value = text[self.value_start..self.position];
    const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);

    var final_value = value;
    var is_important = false;

    if (std.mem.endsWith(u8, value, CSSConstants.IMPORTANT)) {
        is_important = true;
        final_value = std.mem.trimRight(u8, value[0 .. value.len - CSSConstants.IMPORTANT.len], &std.ascii.whitespace);
    }

    try declarations.append(arena, .{
        .name = name,
        .value = final_value,
        .is_important = is_important,
    });
}

fn finalize(self: *CSSParser, arena: Allocator, declarations: *std.ArrayListUnmanaged(CSSDeclaration), text: []const u8) !void {
    if (self.state != .in_value) {
        return;
    }
    return self.finishDeclaration(arena, declarations, text);
}

const testing = @import("../../testing.zig");
test "Browser: CSS.Parser - Simple property" {
    defer testing.reset();

    const text = "color: red;";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expectEqual(1, declarations.len);
    try testing.expectEqual("color", declarations[0].name);
    try testing.expectEqual("red", declarations[0].value);
    try testing.expectEqual(false, declarations[0].is_important);
}

test "Browser: CSS.Parser - Property with !important" {
    defer testing.reset();
    const text = "margin: 10px !important;";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expectEqual(1, declarations.len);
    try testing.expectEqual("margin", declarations[0].name);
    try testing.expectEqual("10px", declarations[0].value);
    try testing.expectEqual(true, declarations[0].is_important);
}

test "Browser: CSS.Parser - Multiple properties" {
    defer testing.reset();
    const text = "color: red; font-size: 12px; margin: 5px !important;";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expect(declarations.len == 3);

    try testing.expectEqual("color", declarations[0].name);
    try testing.expectEqual("red", declarations[0].value);
    try testing.expectEqual(false, declarations[0].is_important);

    try testing.expectEqual("font-size", declarations[1].name);
    try testing.expectEqual("12px", declarations[1].value);
    try testing.expectEqual(false, declarations[1].is_important);

    try testing.expectEqual("margin", declarations[2].name);
    try testing.expectEqual("5px", declarations[2].value);
    try testing.expectEqual(true, declarations[2].is_important);
}

test "Browser: CSS.Parser - Quoted value with semicolon" {
    defer testing.reset();
    const text = "content: \"Hello; world!\";";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expectEqual(1, declarations.len);
    try testing.expectEqual("content", declarations[0].name);
    try testing.expectEqual("\"Hello; world!\"", declarations[0].value);
    try testing.expectEqual(false, declarations[0].is_important);
}

test "Browser: CSS.Parser - URL value" {
    defer testing.reset();
    const text = "background-image: url(\"test.png\");";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expectEqual(1, declarations.len);
    try testing.expectEqual("background-image", declarations[0].name);
    try testing.expectEqual("url(\"test.png\")", declarations[0].value);
    try testing.expectEqual(false, declarations[0].is_important);
}

test "Browser: CSS.Parser - Whitespace handling" {
    defer testing.reset();
    const text = "  color  :  purple  ;  margin  :  10px  ;  ";
    const allocator = testing.arena_allocator;

    const declarations = try CSSParser.parseDeclarations(allocator, text);

    try testing.expectEqual(2, declarations.len);
    try testing.expectEqual("color", declarations[0].name);
    try testing.expectEqual("purple", declarations[0].value);
    try testing.expectEqual("margin", declarations[1].name);
    try testing.expectEqual("10px", declarations[1].value);
}

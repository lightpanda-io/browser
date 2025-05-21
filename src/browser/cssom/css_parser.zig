const std = @import("std");

const CSSConstants = struct {
    const IMPORTANT_KEYWORD = "!important";
    const IMPORTANT_LENGTH = IMPORTANT_KEYWORD.len;
    const URL_PREFIX = "url(";
    const URL_PREFIX_LENGTH = URL_PREFIX.len;
};

pub const CSSParserState = enum {
    seekName,
    inName,
    seekColon,
    seekValue,
    inValue,
    inQuotedValue,
    inSingleQuotedValue,
    inUrl,
    inImportant,
};

pub const CSSDeclaration = struct {
    name: []const u8,
    value: []const u8,
    is_important: bool,

    pub fn init(name: []const u8, value: []const u8, is_important: bool) CSSDeclaration {
        return .{
            .name = name,
            .value = value,
            .is_important = is_important,
        };
    }
};

pub const CSSParser = struct {
    state: CSSParserState,
    name_start: usize,
    name_end: usize,
    value_start: usize,
    position: usize,
    paren_depth: usize,
    escape_next: bool,

    pub fn init() CSSParser {
        return .{
            .state = .seekName,
            .name_start = 0,
            .name_end = 0,
            .value_start = 0,
            .position = 0,
            .paren_depth = 0,
            .escape_next = false,
        };
    }

    pub fn parseDeclarations(text: []const u8, allocator: std.mem.Allocator) ![]CSSDeclaration {
        var parser = init();
        var declarations = std.ArrayList(CSSDeclaration).init(allocator);
        errdefer declarations.deinit();

        while (parser.position < text.len) {
            const c = text[parser.position];

            switch (parser.state) {
                .seekName => {
                    if (!std.ascii.isWhitespace(c)) {
                        parser.name_start = parser.position;
                        parser.state = .inName;
                        continue;
                    }
                },
                .inName => {
                    if (c == ':') {
                        parser.name_end = parser.position;
                        parser.state = .seekValue;
                    } else if (std.ascii.isWhitespace(c)) {
                        parser.name_end = parser.position;
                        parser.state = .seekColon;
                    }
                },
                .seekColon => {
                    if (c == ':') {
                        parser.state = .seekValue;
                    } else if (!std.ascii.isWhitespace(c)) {
                        parser.state = .seekName;
                        continue;
                    }
                },
                .seekValue => {
                    if (!std.ascii.isWhitespace(c)) {
                        parser.value_start = parser.position;
                        if (c == '"') {
                            parser.state = .inQuotedValue;
                        } else if (c == '\'') {
                            parser.state = .inSingleQuotedValue;
                        } else if (c == 'u' and parser.position + 3 < text.len and
                            std.mem.eql(u8, text[parser.position .. parser.position + 4], CSSConstants.URL_PREFIX))
                        {
                            parser.state = .inUrl;
                            parser.paren_depth = 1;
                            parser.position += 3;
                        } else {
                            parser.state = .inValue;
                            continue;
                        }
                    }
                },
                .inValue => {
                    if (parser.escape_next) {
                        parser.escape_next = false;
                    } else if (c == '\\') {
                        parser.escape_next = true;
                    } else if (c == '(') {
                        parser.paren_depth += 1;
                    } else if (c == ')' and parser.paren_depth > 0) {
                        parser.paren_depth -= 1;
                    } else if (c == ';' and parser.paren_depth == 0) {
                        try parser.finishDeclaration(text, &declarations);
                        parser.state = .seekName;
                    }
                },
                .inQuotedValue => {
                    if (parser.escape_next) {
                        parser.escape_next = false;
                    } else if (c == '\\') {
                        parser.escape_next = true;
                    } else if (c == '"') {
                        parser.state = .inValue;
                    }
                },
                .inSingleQuotedValue => {
                    if (parser.escape_next) {
                        parser.escape_next = false;
                    } else if (c == '\\') {
                        parser.escape_next = true;
                    } else if (c == '\'') {
                        parser.state = .inValue;
                    }
                },
                .inUrl => {
                    if (parser.escape_next) {
                        parser.escape_next = false;
                    } else if (c == '\\') {
                        parser.escape_next = true;
                    } else if (c == '(') {
                        parser.paren_depth += 1;
                    } else if (c == ')') {
                        parser.paren_depth -= 1;
                        if (parser.paren_depth == 0) {
                            parser.state = .inValue;
                        }
                    }
                },
                .inImportant => {},
            }

            parser.position += 1;
        }

        try parser.finalize(text, &declarations);

        return declarations.toOwnedSlice();
    }

    fn finishDeclaration(self: *CSSParser, text: []const u8, declarations: *std.ArrayList(CSSDeclaration)) !void {
        const name = std.mem.trim(u8, text[self.name_start..self.name_end], &std.ascii.whitespace);
        if (name.len == 0) return;

        const raw_value = text[self.value_start..self.position];
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);

        var final_value = value;
        var is_important = false;

        if (std.mem.endsWith(u8, value, CSSConstants.IMPORTANT_KEYWORD)) {
            is_important = true;
            final_value = std.mem.trim(u8, value[0 .. value.len - CSSConstants.IMPORTANT_LENGTH], &std.ascii.whitespace);
        }

        const declaration = CSSDeclaration.init(name, final_value, is_important);
        try declarations.append(declaration);
    }

    fn finalize(self: *CSSParser, text: []const u8, declarations: *std.ArrayList(CSSDeclaration)) !void {
        if (self.state == .inValue) {
            const name = text[self.name_start..self.name_end];
            const trimmed_name = std.mem.trim(u8, name, &std.ascii.whitespace);

            if (trimmed_name.len > 0) {
                const raw_value = text[self.value_start..self.position];
                const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);

                var final_value = value;
                var is_important = false;
                if (std.mem.endsWith(u8, value, CSSConstants.IMPORTANT_KEYWORD)) {
                    is_important = true;
                    final_value = std.mem.trim(u8, value[0 .. value.len - CSSConstants.IMPORTANT_LENGTH], &std.ascii.whitespace);
                }

                const declaration = CSSDeclaration.init(trimmed_name, final_value, is_important);
                try declarations.append(declaration);
            }
        }
    }

    pub fn getState(self: *const CSSParser) CSSParserState {
        return self.state;
    }

    pub fn getPosition(self: *const CSSParser) usize {
        return self.position;
    }

    pub fn reset(self: *CSSParser) void {
        self.* = init();
    }
};

const testing = std.testing;

test "CSSParser - Simple property" {
    const text = "color: red;";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 1);
    try testing.expectEqualStrings("color", declarations[0].name);
    try testing.expectEqualStrings("red", declarations[0].value);
    try testing.expect(!declarations[0].is_important);
}

test "CSSParser - Property with !important" {
    const text = "margin: 10px !important;";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 1);
    try testing.expectEqualStrings("margin", declarations[0].name);
    try testing.expectEqualStrings("10px", declarations[0].value);
    try testing.expect(declarations[0].is_important);
}

test "CSSParser - Multiple properties" {
    const text = "color: red; font-size: 12px; margin: 5px !important;";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 3);

    try testing.expectEqualStrings("color", declarations[0].name);
    try testing.expectEqualStrings("red", declarations[0].value);
    try testing.expect(!declarations[0].is_important);

    try testing.expectEqualStrings("font-size", declarations[1].name);
    try testing.expectEqualStrings("12px", declarations[1].value);
    try testing.expect(!declarations[1].is_important);

    try testing.expectEqualStrings("margin", declarations[2].name);
    try testing.expectEqualStrings("5px", declarations[2].value);
    try testing.expect(declarations[2].is_important);
}

test "CSSParser - Quoted value with semicolon" {
    const text = "content: \"Hello; world!\";";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 1);
    try testing.expectEqualStrings("content", declarations[0].name);
    try testing.expectEqualStrings("\"Hello; world!\"", declarations[0].value);
    try testing.expect(!declarations[0].is_important);
}

test "CSSParser - URL value" {
    const text = "background-image: url(\"test.png\");";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 1);
    try testing.expectEqualStrings("background-image", declarations[0].name);
    try testing.expectEqualStrings("url(\"test.png\")", declarations[0].value);
    try testing.expect(!declarations[0].is_important);
}

test "CSSParser - Whitespace handling" {
    const text = "  color  :  purple  ;  margin  :  10px  ;  ";
    const allocator = testing.allocator;

    const declarations = try CSSParser.parseDeclarations(text, allocator);
    defer allocator.free(declarations);

    try testing.expect(declarations.len == 2);
    try testing.expectEqualStrings("color", declarations[0].name);
    try testing.expectEqualStrings("purple", declarations[0].value);
    try testing.expectEqualStrings("margin", declarations[1].name);
    try testing.expectEqualStrings("10px", declarations[1].value);
}

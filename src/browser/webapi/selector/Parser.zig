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

const Allocator = std.mem.Allocator;

const Page = @import("../../Page.zig");

const Node = @import("../Node.zig");
const Selector = @import("Selector.zig");
const Part = Selector.Part;
const Combinator = Selector.Combinator;
const Segment = Selector.Segment;
const Attribute = @import("../element/Attribute.zig");

const Parser = @This();

input: []const u8,

// need an explicit error set because the function is recursive
const ParseError = error{
    OutOfMemory,
    InvalidIDSelector,
    InvalidClassSelector,
    InvalidAttributeSelector,
    InvalidPseudoClass,
    InvalidNthPattern,
    UnknownPseudoClass,
    InvalidTagSelector,
    InvalidSelector,
};

pub fn parseList(arena: Allocator, input: []const u8, page: *Page) ParseError![]const Selector.Selector {
    var selectors: std.ArrayList(Selector.Selector) = .empty;

    var remaining = input;
    while (true) {
        const trimmed = std.mem.trimLeft(u8, remaining, &std.ascii.whitespace);
        if (trimmed.len == 0) break;

        var comma_pos: usize = trimmed.len;
        var depth: usize = 0;
        for (trimmed, 0..) |c, i| {
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        comma_pos = i;
                        break;
                    }
                },
                else => {},
            }
        }

        const selector_input = std.mem.trimRight(u8, trimmed[0..comma_pos], &std.ascii.whitespace);

        if (selector_input.len > 0) {
            const selector = try parse(arena, selector_input, page);
            try selectors.append(arena, selector);
        }

        if (comma_pos >= trimmed.len) break;
        remaining = trimmed[comma_pos + 1 ..];
    }

    if (selectors.items.len == 0) {
        return error.InvalidSelector;
    }

    return selectors.items;
}

pub fn parse(arena: Allocator, input: []const u8, page: *Page) ParseError!Selector.Selector {
    var parser = Parser{ .input = input };
    var segments: std.ArrayList(Segment) = .empty;
    var current_compound: std.ArrayList(Part) = .empty;

    // Parse the first compound (no combinator before it)
    while (parser.skipSpaces()) {
        if (parser.peek() == 0) break;

        const part = try parser.parsePart(arena, page);
        try current_compound.append(arena, part);

        // Check what comes after this part
        const start_pos = parser.input;
        const has_whitespace = parser.skipSpacesConsumed();
        const next = parser.peek();

        if (next == 0) {
            // End of input
            break;
        }

        if (next == '>' or next == '+' or next == '~') {
            // Explicit combinator
            break;
        }

        if (has_whitespace and isStartOfPart(next)) {
            // Whitespace followed by another selector part = descendant combinator
            // Restore position before the whitespace so the segment loop can handle it
            parser.input = start_pos;
            break;
        }

        // If we have a non-whitespace character that could start a part,
        // it's part of this compound (like "div.class" or "div#id")
        if (!has_whitespace and isStartOfPart(next)) {
            // Continue parsing this compound
            continue;
        }

        // Otherwise, end of compound
        break;
    }

    if (current_compound.items.len == 0) {
        return error.InvalidSelector;
    }

    const first_compound = current_compound.items;
    current_compound = .empty;

    // Parse remaining segments with combinators
    while (parser.skipSpaces()) {
        const next = parser.peek();
        if (next == 0) break;

        // Parse combinator
        const combinator: Combinator = switch (next) {
            '>' => blk: {
                parser.input = parser.input[1..];
                break :blk .child;
            },
            '+' => blk: {
                parser.input = parser.input[1..];
                break :blk .next_sibling;
            },
            '~' => blk: {
                parser.input = parser.input[1..];
                break :blk .subsequent_sibling;
            },
            else => .descendant, // whitespace = descendant combinator
        };

        // Parse the compound that follows the combinator
        _ = parser.skipSpaces();
        if (parser.peek() == 0) {
            return error.InvalidSelector; // Combinator with nothing after it
        }

        while (parser.skipSpaces()) {
            if (parser.peek() == 0) break;

            const part = try parser.parsePart(arena, page);
            try current_compound.append(arena, part);

            // Check what comes after this part
            const seg_start_pos = parser.input;
            const seg_has_whitespace = parser.skipSpacesConsumed();
            const peek_next = parser.peek();

            if (peek_next == 0) {
                // End of input
                break;
            }

            if (peek_next == '>' or peek_next == '+' or peek_next == '~') {
                // Next combinator found
                break;
            }

            if (seg_has_whitespace and isStartOfPart(peek_next)) {
                // Whitespace followed by another part = new segment
                // Restore position before whitespace
                parser.input = seg_start_pos;
                break;
            }

            // If no whitespace and it's a start of part, continue compound
            if (!seg_has_whitespace and isStartOfPart(peek_next)) {
                continue;
            }

            // Otherwise, end of compound
            break;
        }

        if (current_compound.items.len == 0) {
            return error.InvalidSelector;
        }

        try segments.append(arena, .{
            .combinator = combinator,
            .compound = .{ .parts = current_compound.items },
        });
        current_compound = .empty;
    }

    return .{
        .first = .{ .parts = first_compound },
        .segments = segments.items,
    };
}

fn parsePart(self: *Parser, arena: Allocator, page: *Page) !Part {
    return switch (self.peek()) {
        '#' => .{ .id = try self.id() },
        '.' => .{ .class = try self.class() },
        '*' => blk: {
            self.input = self.input[1..];
            break :blk .universal;
        },
        '[' => .{ .attribute = try self.attribute(arena, page) },
        ':' => .{ .pseudo_class = try self.pseudoClass(arena, page) },
        'a'...'z', 'A'...'Z', '_' => blk: {
            const tag_name = try self.tag();
            if (tag_name.len > 256) {
                return error.InvalidTagSelector;
            }
            // Try to match as a known tag enum for optimization
            const lower = std.ascii.lowerString(&page.buf, tag_name);
            if (Node.Element.Tag.parseForMatch(lower)) |known_tag| {
                break :blk .{ .tag = known_tag };
            }
            // Store lowercased for fast comparison
            const lower_tag = try arena.dupe(u8, lower);
            break :blk .{ .tag_name = lower_tag };
        },
        else => error.InvalidSelector,
    };
}

fn isStartOfPart(c: u8) bool {
    return switch (c) {
        '#', '.', '*', '[', ':', 'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

// Returns true if there's more input after trimming whitespace
fn skipSpaces(self: *Parser) bool {
    const trimmed = std.mem.trimLeft(u8, self.input, &std.ascii.whitespace);
    self.input = trimmed;
    return trimmed.len > 0;
}

// Returns true if whitespace was actually removed
fn skipSpacesConsumed(self: *Parser) bool {
    const original_len = self.input.len;
    const trimmed = std.mem.trimLeft(u8, self.input, &std.ascii.whitespace);
    self.input = trimmed;
    return trimmed.len < original_len;
}

fn peek(self: *const Parser) u8 {
    const input = self.input;
    if (input.len == 0) {
        return 0;
    }
    return input[0];
}

fn consumeUntilCommaOrParen(self: *Parser) []const u8 {
    const input = self.input;
    var depth: usize = 0;
    var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',' => {
                if (depth == 0) break;
            },
            else => {},
        }
    }

    const result = input[0..i];
    self.input = input[i..];
    return result;
}

fn pseudoClass(self: *Parser, arena: Allocator, page: *Page) !Selector.PseudoClass {
    // Must be called when we're at a ':'
    std.debug.assert(self.peek() == ':');
    self.input = self.input[1..];

    // Parse the pseudo-class name
    const start = self.input;
    var i: usize = 0;
    while (i < start.len) : (i += 1) {
        const c = start[i];
        if (!std.ascii.isAlphanumeric(c) and c != '-') {
            break;
        }
    }

    if (i == 0) {
        return error.InvalidPseudoClass;
    }

    const name = start[0..i];
    self.input = start[i..];

    const next = self.peek();

    // Check for functional pseudo-classes like :nth-child(2n+1) or :not(...)
    if (next == '(') {
        self.input = self.input[1..]; // Skip '('

        if (std.mem.eql(u8, name, "nth-child")) {
            const pattern = try self.parseNthPattern();
            if (self.peek() != ')') return error.InvalidPseudoClass;
            self.input = self.input[1..];
            return .{ .nth_child = pattern };
        }

        if (std.mem.eql(u8, name, "nth-last-child")) {
            const pattern = try self.parseNthPattern();
            if (self.peek() != ')') return error.InvalidPseudoClass;
            self.input = self.input[1..];
            return .{ .nth_last_child = pattern };
        }

        if (std.mem.eql(u8, name, "nth-of-type")) {
            const pattern = try self.parseNthPattern();
            if (self.peek() != ')') return error.InvalidPseudoClass;
            self.input = self.input[1..];
            return .{ .nth_of_type = pattern };
        }

        if (std.mem.eql(u8, name, "nth-last-of-type")) {
            const pattern = try self.parseNthPattern();
            if (self.peek() != ')') return error.InvalidPseudoClass;
            self.input = self.input[1..];
            return .{ .nth_last_of_type = pattern };
        }

        if (std.mem.eql(u8, name, "not")) {
            // CSS Level 4: :not() can contain a full selector list (comma-separated selectors)
            // e.g., :not(div, .class, #id > span)
            var selectors: std.ArrayList(Selector.Selector) = .empty;

            _ = self.skipSpaces();

            // Parse comma-separated selectors
            while (true) {
                if (self.peek() == ')') break;
                if (self.peek() == 0) return error.InvalidPseudoClass;

                // Parse a full selector (with potential combinators and compounds)
                const selector = try parse(arena, self.consumeUntilCommaOrParen(), page);
                try selectors.append(arena, selector);

                _ = self.skipSpaces();
                if (self.peek() == ',') {
                    self.input = self.input[1..]; // Skip comma
                    _ = self.skipSpaces();
                    continue;
                }
                break;
            }

            if (self.peek() != ')') return error.InvalidPseudoClass;
            self.input = self.input[1..]; // Skip ')'

            if (selectors.items.len == 0) return error.InvalidPseudoClass;
            return .{ .not = selectors.items };
        }

        return error.UnknownPseudoClass;
    }

    // Simple pseudo-classes without arguments
    if (std.mem.eql(u8, name, "first-child")) {
        return .first_child;
    }

    if (std.mem.eql(u8, name, "last-child")) {
        return .last_child;
    }

    if (std.mem.eql(u8, name, "only-child")) {
        return .only_child;
    }

    if (std.mem.eql(u8, name, "first-of-type")) {
        return .first_of_type;
    }

    if (std.mem.eql(u8, name, "last-of-type")) {
        return .last_of_type;
    }

    if (std.mem.eql(u8, name, "only-of-type")) {
        return .only_of_type;
    }

    return error.UnknownPseudoClass;
}

fn parseNthPattern(self: *Parser) !Selector.NthPattern {
    _ = self.skipSpaces();

    const start = self.input;

    // Check for special keywords
    if (std.mem.startsWith(u8, start, "odd")) {
        self.input = start[3..];
        return .{ .a = 2, .b = 1 };
    }

    if (std.mem.startsWith(u8, start, "even")) {
        self.input = start[4..];
        return .{ .a = 2, .b = 0 };
    }

    // Parse An+B notation
    var a: i32 = 0;
    var b: i32 = 0;
    var has_n = false;

    // Try to parse coefficient 'a'
    var p = self.peek();
    const sign_a: i32 = if (p == '-') blk: {
        self.input = self.input[1..];
        break :blk -1;
    } else if (p == '+') blk: {
        self.input = self.input[1..];
        break :blk 1;
    } else 1;

    p = self.peek();
    if (p == 'n' or p == 'N') {
        // Just 'n' means a=1
        a = sign_a;
        has_n = true;
        self.input = self.input[1..];
    } else {
        // Parse numeric coefficient
        var num: i32 = 0;
        var digit_count: usize = 0;
        p = self.peek();
        while (std.ascii.isDigit(p)) {
            num = num * 10 + @as(i32, p - '0');
            self.input = self.input[1..];
            digit_count += 1;
            p = self.peek();
        }

        if (digit_count > 0) {
            p = self.peek();
            if (p == 'n' or p == 'N') {
                a = sign_a * num;
                has_n = true;
                self.input = self.input[1..];
            } else {
                // Just a number, no 'n', so this is 'b'
                b = sign_a * num;
                return .{ .a = 0, .b = b };
            }
        } else if (sign_a != 1) {
            // We had a sign but no number and no 'n'
            return error.InvalidNthPattern;
        }
    }

    if (!has_n) {
        return error.InvalidNthPattern;
    }

    // Parse offset 'b'
    _ = self.skipSpaces();
    p = self.peek();
    if (p == '+' or p == '-') {
        const sign_b: i32 = if (p == '-') -1 else 1;
        self.input = self.input[1..];
        _ = self.skipSpaces();

        var num: i32 = 0;
        var digit_count: usize = 0;
        p = self.peek();
        while (std.ascii.isDigit(p)) {
            num = num * 10 + @as(i32, p - '0');
            self.input = self.input[1..];
            digit_count += 1;
            p = self.peek();
        }

        if (digit_count == 0) {
            return error.InvalidNthPattern;
        }

        b = sign_b * num;
    }

    return .{ .a = a, .b = b };
}

pub fn id(self: *Parser) ![]const u8 {
    // Must be called when we're at a '#'
    std.debug.assert(self.peek() == '#');

    // trim the leading #
    var input = self.input[1..];

    if (input.len == 0) {
        @branchHint(.cold);
        return error.InvalidIDSelector;
    }

    // First character: must be letter, underscore, or non-ASCII (>= 0x80)
    // Can also be hyphen if not followed by digit or another hyphen
    const first = input[0];
    if (first == '-') {
        if (input.len < 2) {
            @branchHint(.cold);
            return error.InvalidIDSelector;
        }
        const second = input[1];
        if (second == '-' or std.ascii.isDigit(second)) {
            @branchHint(.cold);
            return error.InvalidIDSelector;
        }
    } else if (!std.ascii.isAlphabetic(first) and first != '_' and first < 0x80) {
        @branchHint(.cold);
        return error.InvalidIDSelector;
    }

    var i: usize = 1;
    for (input[1..]) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            0x80...0xFF => {}, // non-ASCII characters
            ' ', '\t', '\n', '\r' => break,
            // Stop at selector delimiters
            '.', '#', '>', '+', '~', '[', ':', ')', ']' => break,
            else => {
                @branchHint(.cold);
                return error.InvalidIDSelector;
            },
        }
        i += 1;
    }

    self.input = input[i..];
    return input[0..i];
}

fn class(self: *Parser) ![]const u8 {
    // Must be called when we're at a '.'
    std.debug.assert(self.peek() == '.');

    // trim the leading .
    var input = self.input[1..];

    if (input.len == 0) {
        @branchHint(.cold);
        return error.InvalidClassSelector;
    }

    // First character: must be letter, underscore, or non-ASCII (>= 0x80)
    // Can also be hyphen if not followed by digit or another hyphen
    const first = input[0];
    if (first == '-') {
        if (input.len < 2) {
            @branchHint(.cold);
            return error.InvalidClassSelector;
        }
        const second = input[1];
        if (second == '-' or std.ascii.isDigit(second)) {
            @branchHint(.cold);
            return error.InvalidClassSelector;
        }
    } else if (!std.ascii.isAlphabetic(first) and first != '_' and first < 0x80) {
        @branchHint(.cold);
        return error.InvalidClassSelector;
    }

    var i: usize = 1;
    for (input[1..]) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            0x80...0xFF => {}, // non-ASCII characters
            ' ', '\t', '\n', '\r' => break,
            // Stop at selector delimiters
            '.', '#', '>', '+', '~', '[', ':', ')', ']' => break,
            else => {
                @branchHint(.cold);
                return error.InvalidClassSelector;
            },
        }
        i += 1;
    }

    self.input = input[i..];
    return input[0..i];
}

fn tag(self: *Parser) ![]const u8 {
    var input = self.input;

    // First character: must be letter, underscore, or non-ASCII (>= 0x80)
    // Can also be hyphen if not followed by digit or another hyphen
    const first = input[0];
    if (first == '-') {
        if (input.len < 2) {
            @branchHint(.cold);
            return error.InvalidTagSelector;
        }
        const second = input[1];
        if (second == '-' or std.ascii.isDigit(second)) {
            @branchHint(.cold);
            return error.InvalidTagSelector;
        }
    } else if (!std.ascii.isAlphabetic(first) and first != '_' and first < 0x80) {
        @branchHint(.cold);
        return error.InvalidTagSelector;
    }

    var i: usize = 1;
    for (input[1..]) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            0x80...0xFF => {}, // non-ASCII characters
            ' ', '\t', '\n', '\r' => break,
            // Stop at selector delimiters
            '.', '#', '>', '+', '~', '[', ':', ')', ']' => break,
            else => {
                @branchHint(.cold);
                return error.InvalidTagSelector;
            },
        }
        i += 1;
    }

    self.input = input[i..];
    return input[0..i];
}

fn attribute(self: *Parser, arena: Allocator, page: *Page) !Selector.Attribute {
    // Must be called when we're at a '['
    std.debug.assert(self.peek() == '[');

    self.input = self.input[1..];
    _ = self.skipSpaces();

    const attr_name = try self.attributeName();
    // Normalize the name to lowercase for fast matching (consistent with Attribute.normalizeNameForLookup)
    const normalized = try Attribute.normalizeNameForLookup(attr_name, page);
    const name = try arena.dupe(u8, normalized);
    _ = self.skipSpaces();

    if (self.peek() == ']') {
        self.input = self.input[1..];
        return .{ .name = name, .matcher = .presence };
    }

    const matcher_type = try self.attributeMatcher();
    _ = self.skipSpaces();

    const value_raw = try self.attributeValue();
    const value = try arena.dupe(u8, value_raw);
    _ = self.skipSpaces();

    if (self.peek() != ']') {
        return error.InvalidAttributeSelector;
    }
    self.input = self.input[1..];

    const matcher: Selector.AttributeMatcher = switch (matcher_type) {
        .exact => .{ .exact = value },
        .word => .{ .word = value },
        .prefix_dash => .{ .prefix_dash = value },
        .starts_with => .{ .starts_with = value },
        .ends_with => .{ .ends_with = value },
        .substring => .{ .substring = value },
        .presence => unreachable,
    };

    return .{ .name = name, .matcher = matcher };
}

fn attributeName(self: *Parser) ![]const u8 {
    const input = self.input;
    if (input.len == 0) {
        return error.InvalidAttributeSelector;
    }

    const first = input[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first < 0x80) {
        return error.InvalidAttributeSelector;
    }

    var i: usize = 1;
    for (input[1..]) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            0x80...0xFF => {},
            else => break,
        }
        i += 1;
    }

    self.input = input[i..];
    return input[0..i];
}

fn attributeMatcher(self: *Parser) !std.meta.FieldEnum(Selector.AttributeMatcher) {
    const input = self.input;
    if (input.len < 2) {
        return error.InvalidAttributeSelector;
    }

    if (input[0] == '=') {
        self.input = input[1..];
        return .exact;
    }

    self.input = input[2..];
    return switch (@as(u16, @bitCast(input[0..2].*))) {
        asUint("~=") => .word,
        asUint("|=") => .prefix_dash,
        asUint("^=") => .starts_with,
        asUint("$=") => .ends_with,
        asUint("*=") => .substring,
        else => return error.InvalidAttributeSelector,
    };
}

fn attributeValue(self: *Parser) ![]const u8 {
    const input = self.input;
    if (input.len == 0) {
        return error.InvalidAttributeSelector;
    }

    const quote = input[0];
    if (quote == '"' or quote == '\'') {
        const end = std.mem.indexOfScalarPos(u8, input, 1, quote) orelse return error.InvalidAttributeSelector;
        const value = input[1..end];
        self.input = input[end + 1 ..];
        return value;
    }

    var i: usize = 0;
    for (input) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            0x80...0xFF => {},
            else => break,
        }
        i += 1;
    }

    if (i == 0) {
        return error.InvalidAttributeSelector;
    }

    const value = input[0..i];
    self.input = input[i..];
    return value;
}

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const testing = @import("../../../testing.zig");
test "Selector: Parser.ID" {
    {
        var parser = Parser{ .input = "#" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "# " };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#1" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#9abc" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#-1" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#-5abc" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#--" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#--test" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#-" };
        try testing.expectError(error.InvalidIDSelector, parser.id());
    }

    {
        var parser = Parser{ .input = "#over" };
        try testing.expectEqual("over", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#myID123" };
        try testing.expectEqual("myID123", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#_test" };
        try testing.expectEqual("_test", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#test_123" };
        try testing.expectEqual("test_123", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#-test" };
        try testing.expectEqual("-test", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#my-id" };
        try testing.expectEqual("my-id", try parser.id());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "#test other" };
        try testing.expectEqual("test", try parser.id());
        try testing.expectEqual(" other", parser.input);
    }

    {
        var parser = Parser{ .input = "#id.class" };
        try testing.expectEqual("id", try parser.id());
        try testing.expectEqual(".class", parser.input);
    }

    {
        var parser = Parser{ .input = "#id:hover" };
        try testing.expectEqual("id", try parser.id());
        try testing.expectEqual(":hover", parser.input);
    }

    {
        var parser = Parser{ .input = "#id>child" };
        try testing.expectEqual("id", try parser.id());
        try testing.expectEqual(">child", parser.input);
    }

    {
        var parser = Parser{ .input = "#id[attr]" };
        try testing.expectEqual("id", try parser.id());
        try testing.expectEqual("[attr]", parser.input);
    }
}

test "Selector: Parser.class" {
    {
        var parser = Parser{ .input = "." };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ". " };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".1" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".9abc" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".-1" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".-5abc" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".--" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".--test" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".-" };
        try testing.expectError(error.InvalidClassSelector, parser.class());
    }

    {
        var parser = Parser{ .input = ".active" };
        try testing.expectEqual("active", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = ".myClass123" };
        try testing.expectEqual("myClass123", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "._test" };
        try testing.expectEqual("_test", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = ".test_123" };
        try testing.expectEqual("test_123", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = ".-test" };
        try testing.expectEqual("-test", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = ".my-class" };
        try testing.expectEqual("my-class", try parser.class());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = ".test other" };
        try testing.expectEqual("test", try parser.class());
        try testing.expectEqual(" other", parser.input);
    }

    {
        var parser = Parser{ .input = ".class1.class2" };
        try testing.expectEqual("class1", try parser.class());
        try testing.expectEqual(".class2", parser.input);
    }

    {
        var parser = Parser{ .input = ".class:hover" };
        try testing.expectEqual("class", try parser.class());
        try testing.expectEqual(":hover", parser.input);
    }

    {
        var parser = Parser{ .input = ".class>child" };
        try testing.expectEqual("class", try parser.class());
        try testing.expectEqual(">child", parser.input);
    }

    {
        var parser = Parser{ .input = ".class[attr]" };
        try testing.expectEqual("class", try parser.class());
        try testing.expectEqual("[attr]", parser.input);
    }
}

test "Selector: Parser.tag" {
    {
        var parser = Parser{ .input = "1" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "9abc" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "-1" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "-5abc" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "--" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "--test" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "-" };
        try testing.expectError(error.InvalidTagSelector, parser.tag());
    }

    {
        var parser = Parser{ .input = "div" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "p" };
        try testing.expectEqual("p", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "MyCustomElement" };
        try testing.expectEqual("MyCustomElement", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "_test" };
        try testing.expectEqual("_test", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "test_123" };
        try testing.expectEqual("test_123", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "-test" };
        try testing.expectEqual("-test", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "my-element" };
        try testing.expectEqual("my-element", try parser.tag());
        try testing.expectEqual("", parser.input);
    }

    {
        var parser = Parser{ .input = "div other" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual(" other", parser.input);
    }

    {
        var parser = Parser{ .input = "div.class" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual(".class", parser.input);
    }

    {
        var parser = Parser{ .input = "div#id" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual("#id", parser.input);
    }

    {
        var parser = Parser{ .input = "div:hover" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual(":hover", parser.input);
    }

    {
        var parser = Parser{ .input = "div>child" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual(">child", parser.input);
    }

    {
        var parser = Parser{ .input = "div[attr]" };
        try testing.expectEqual("div", try parser.tag());
        try testing.expectEqual("[attr]", parser.input);
    }
}

test "Selector: Parser.parseNthPattern" {
    {
        var parser = Parser{ .input = "odd)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(2, pattern.a);
        try testing.expectEqual(1, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "even)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(2, pattern.a);
        try testing.expectEqual(0, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "3)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(0, pattern.a);
        try testing.expectEqual(3, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "2n)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(2, pattern.a);
        try testing.expectEqual(0, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "2n+1)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(2, pattern.a);
        try testing.expectEqual(1, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "3n-2)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(3, pattern.a);
        try testing.expectEqual(-2, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "n)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(1, pattern.a);
        try testing.expectEqual(0, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "-n)" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(-1, pattern.a);
        try testing.expectEqual(0, pattern.b);
        try testing.expectEqual(")", parser.input);
    }

    {
        var parser = Parser{ .input = "  2n + 1  )" };
        const pattern = try parser.parseNthPattern();
        try testing.expectEqual(2, pattern.a);
        try testing.expectEqual(1, pattern.b);
        try testing.expectEqual("  )", parser.input);
    }
}

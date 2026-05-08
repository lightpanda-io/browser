// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! XPath 1.0 expression tokenizer.
//!
//! HTML-pragmatic behavior: lenient whitespace, case-preserving names,
//! no escape processing in string literals (use the other quote type
//! to embed), unknown characters silently skipped.
//!
//! The tokenizer borrows from the input slice and never allocates.
//! `next()` always returns a token; `.eof` is terminal and idempotent.

const std = @import("std");

const Tokenizer = @This();

pub const Token = union(enum) {
    /// String literal: `'foo'` or `"foo"`. Quotes are stripped; escapes
    /// are not interpreted (the polyfill takes the raw substring).
    string: []const u8,

    /// Numeric literal: `123`, `1.5`, `.5`, `5.`. f64 matches the
    /// runtime number type.
    number: f64,

    /// Bare identifier — element/function/axis name, an `or`/`and`/
    /// `div`/`mod` keyword, or a namespace-prefixed name (`prefix:local`,
    /// `prefix:*`). The colon and optional wildcard are preserved
    /// verbatim so the parser can split.
    name: []const u8,

    slash, // `/`
    double_slash, // `//`
    dot, // `.`
    double_dot, // `..`
    at, // `@`
    lparen, // `(`
    rparen, // `)`
    lbracket, // `[`
    rbracket, // `]`
    comma, // `,`
    pipe, // `|`
    eq, // `=`
    neq, // `!=`
    lt, // `<`
    lte, // `<=`
    gt, // `>`
    gte, // `>=`
    plus, // `+`
    minus, // `-`
    star, // `*`
    dollar, // `$`
    double_colon, // `::`
    eof,
};

input: []const u8,
position: usize = 0,

fn isEof(self: *const Tokenizer) bool {
    return self.position >= self.input.len;
}

// True iff the input has at least `n` bytes left after the current one
// — i.e. `byteAt(n)` will not read past the end.
fn hasAtLeast(self: *const Tokenizer, n: usize) bool {
    return self.position + n < self.input.len;
}

fn byteAt(self: *const Tokenizer, offset: usize) u8 {
    return self.input[self.position + offset];
}

fn skipWhitespace(self: *Tokenizer) void {
    while (!self.isEof()) {
        switch (self.input[self.position]) {
            ' ', '\t', '\n', '\r' => self.position += 1,
            else => return,
        }
    }
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
}

fn consumeString(self: *Tokenizer, quote: u8) Token {
    self.position += 1; // opening quote
    const start = self.position;
    while (!self.isEof() and self.input[self.position] != quote) {
        self.position += 1;
    }
    const value = self.input[start..self.position];
    // Closing quote skipped; at EOF we just emit what we have (polyfill parity).
    if (!self.isEof()) self.position += 1;
    return .{ .string = value };
}

fn consumeNumber(self: *Tokenizer) Token {
    const start = self.position;
    while (!self.isEof() and std.ascii.isDigit(self.input[self.position])) {
        self.position += 1;
    }
    if (!self.isEof() and self.input[self.position] == '.') {
        self.position += 1;
        while (!self.isEof() and std.ascii.isDigit(self.input[self.position])) {
            self.position += 1;
        }
    }
    // Caller only enters consumeNumber on a digit or `.digit`, so the
    // slice is always `\d+(\.\d*)?` or `\.\d+` — both accepted by
    // parseFloat (verified against Zig 0.15.2).
    const value = std.fmt.parseFloat(f64, self.input[start..self.position]) catch unreachable;
    return .{ .number = value };
}

fn consumeName(self: *Tokenizer) Token {
    const start = self.position;
    while (!self.isEof() and isNameContinue(self.input[self.position])) {
        self.position += 1;
    }

    // Optional namespace prefix: `prefix:local` or `prefix:*`. A `::`
    // is the axis separator and belongs to the next token, so peek
    // for a single `:` not followed by another `:`.
    if (!self.isEof() and self.input[self.position] == ':' and
        (self.position + 1 >= self.input.len or self.input[self.position + 1] != ':'))
    {
        self.position += 1; // `:`
        if (!self.isEof() and self.input[self.position] == '*') {
            self.position += 1;
        } else {
            while (!self.isEof() and isNameContinue(self.input[self.position])) {
                self.position += 1;
            }
        }
    }

    return .{ .name = self.input[start..self.position] };
}

pub fn next(self: *Tokenizer) Token {
    while (true) {
        self.skipWhitespace();
        if (self.isEof()) return .eof;

        const c = self.byteAt(0);

        if (c == '"' or c == '\'') {
            return self.consumeString(c);
        }

        if (std.ascii.isDigit(c) or (c == '.' and self.hasAtLeast(1) and std.ascii.isDigit(self.byteAt(1)))) {
            return self.consumeNumber();
        }

        if (self.hasAtLeast(1)) {
            const c2 = self.byteAt(1);
            switch (c) {
                '/' => if (c2 == '/') {
                    self.position += 2;
                    return .double_slash;
                },
                ':' => if (c2 == ':') {
                    self.position += 2;
                    return .double_colon;
                },
                '!' => if (c2 == '=') {
                    self.position += 2;
                    return .neq;
                },
                '<' => if (c2 == '=') {
                    self.position += 2;
                    return .lte;
                },
                '>' => if (c2 == '=') {
                    self.position += 2;
                    return .gte;
                },
                '.' => if (c2 == '.') {
                    self.position += 2;
                    return .double_dot;
                },
                else => {},
            }
        }

        const single: ?Token = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            '|' => .pipe,
            '=' => .eq,
            '<' => .lt,
            '>' => .gt,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '$' => .dollar,
            '/' => .slash,
            '@' => .at,
            '.' => .dot,
            else => null,
        };
        if (single) |tok| {
            self.position += 1;
            return tok;
        }

        if (isNameStart(c)) {
            return self.consumeName();
        }

        // Polyfill parity (decision #2): unknown characters are
        // silently skipped, never an error.
        self.position += 1;
    }
}

const testing = std.testing;

fn expectTokens(input: []const u8, expected: []const Token) !void {
    var tokenizer = Tokenizer{ .input = input };
    for (expected) |exp| {
        const got = tokenizer.next();
        try testing.expectEqualDeep(exp, got);
    }
}

test "XPath.Tokenizer: empty input emits EOF" {
    try expectTokens("", &.{.eof});
}

test "XPath.Tokenizer: only whitespace emits EOF" {
    try expectTokens("   \t\n\r  ", &.{.eof});
}

test "XPath.Tokenizer: EOF idempotent past end" {
    var t = Tokenizer{ .input = "" };
    try testing.expectEqual(Token.eof, t.next());
    try testing.expectEqual(Token.eof, t.next());
    try testing.expectEqual(Token.eof, t.next());
}

test "XPath.Tokenizer: single-char operators" {
    try expectTokens("()[],|=<>+-*$/@.", &.{
        .lparen, .rparen, .lbracket, .rbracket, .comma, .pipe,
        .eq,     .lt,     .gt,       .plus,     .minus, .star,
        .dollar, .slash,  .at,       .dot,      .eof,
    });
}

test "XPath.Tokenizer: two-char operators" {
    try expectTokens("// :: != <= >= ..", &.{
        .double_slash, .double_colon, .neq, .lte, .gte, .double_dot, .eof,
    });
}

test "XPath.Tokenizer: two-char vs single-char disambiguation" {
    try expectTokens("/a/b", &.{
        .slash, .{ .name = "a" }, .slash, .{ .name = "b" }, .eof,
    });
    try expectTokens("//a", &.{ .double_slash, .{ .name = "a" }, .eof });
    try expectTokens("a<b", &.{
        .{ .name = "a" }, .lt, .{ .name = "b" }, .eof,
    });
    try expectTokens("a<=b", &.{
        .{ .name = "a" }, .lte, .{ .name = "b" }, .eof,
    });
}

test "XPath.Tokenizer: string literal double quote" {
    try expectTokens("\"hello world\"", &.{ .{ .string = "hello world" }, .eof });
}

test "XPath.Tokenizer: string literal single quote" {
    try expectTokens("'hello world'", &.{ .{ .string = "hello world" }, .eof });
}

test "XPath.Tokenizer: string embeds the other quote type" {
    try expectTokens("\"it's\"", &.{ .{ .string = "it's" }, .eof });
    try expectTokens("'say \"hi\"'", &.{ .{ .string = "say \"hi\"" }, .eof });
}

test "XPath.Tokenizer: empty string literal" {
    try expectTokens("''", &.{ .{ .string = "" }, .eof });
    try expectTokens("\"\"", &.{ .{ .string = "" }, .eof });
}

test "XPath.Tokenizer: unterminated string emits partial — polyfill parity" {
    try expectTokens("'unterminated", &.{ .{ .string = "unterminated" }, .eof });
    try expectTokens("\"oops", &.{ .{ .string = "oops" }, .eof });
}

test "XPath.Tokenizer: integer literals" {
    try expectTokens("0", &.{ .{ .number = 0 }, .eof });
    try expectTokens("42", &.{ .{ .number = 42 }, .eof });
    try expectTokens("12345", &.{ .{ .number = 12345 }, .eof });
}

test "XPath.Tokenizer: float literals" {
    try expectTokens("3.14", &.{ .{ .number = 3.14 }, .eof });
    try expectTokens("0.5", &.{ .{ .number = 0.5 }, .eof });
}

test "XPath.Tokenizer: leading-dot float (.5)" {
    try expectTokens(".5", &.{ .{ .number = 0.5 }, .eof });
    try expectTokens(".25", &.{ .{ .number = 0.25 }, .eof });
}

test "XPath.Tokenizer: trailing-dot float (5.)" {
    try expectTokens("5.", &.{ .{ .number = 5 }, .eof });
}

test "XPath.Tokenizer: leading zeros are decimal, not octal" {
    try expectTokens("007", &.{ .{ .number = 7 }, .eof });
    try expectTokens("0042", &.{ .{ .number = 42 }, .eof });
}

test "XPath.Tokenizer: multi-digit fraction parses with parseFloat precision" {
    // Anchors that the slice is round-tripped through parseFloat (the
    // polyfill calls Number()). The old hand-rolled `place *= 0.1`
    // accumulator drifted on long fractions.
    try expectTokens("0.123456789", &.{ .{ .number = 0.123456789 }, .eof });
    try expectTokens("123.456", &.{ .{ .number = 123.456 }, .eof });
}

test "XPath.Tokenizer: dot followed by non-digit emits dot token" {
    try expectTokens(".x", &.{ .dot, .{ .name = "x" }, .eof });
    try expectTokens(".", &.{ .dot, .eof });
    try expectTokens(". 3", &.{ .dot, .{ .number = 3 }, .eof });
}

test "XPath.Tokenizer: bare identifier" {
    try expectTokens("foo", &.{ .{ .name = "foo" }, .eof });
    try expectTokens("_x", &.{ .{ .name = "_x" }, .eof });
    try expectTokens("MixedCase", &.{ .{ .name = "MixedCase" }, .eof });
}

test "XPath.Tokenizer: identifier with digits, dashes, dots" {
    try expectTokens("foo-bar", &.{ .{ .name = "foo-bar" }, .eof });
    try expectTokens("foo.bar", &.{ .{ .name = "foo.bar" }, .eof });
    try expectTokens("a1b2", &.{ .{ .name = "a1b2" }, .eof });
}

test "XPath.Tokenizer: namespace-prefixed name" {
    try expectTokens("xhtml:div", &.{ .{ .name = "xhtml:div" }, .eof });
    try expectTokens("svg:*", &.{ .{ .name = "svg:*" }, .eof });
}

test "XPath.Tokenizer: name followed by `::` keeps the colon for the axis token" {
    try expectTokens("child::node", &.{
        .{ .name = "child" }, .double_colon, .{ .name = "node" }, .eof,
    });
}

test "XPath.Tokenizer: name immediately followed by `(` is two tokens" {
    // Function-call detection happens in the parser.
    try expectTokens("count()", &.{
        .{ .name = "count" }, .lparen, .rparen, .eof,
    });
}

test "XPath.Tokenizer: keywords or/and/div/mod tokenize as plain names" {
    try expectTokens("a or b", &.{
        .{ .name = "a" }, .{ .name = "or" }, .{ .name = "b" }, .eof,
    });
    try expectTokens("3 div 4", &.{
        .{ .number = 3 }, .{ .name = "div" }, .{ .number = 4 }, .eof,
    });
}

test "XPath.Tokenizer: unknown character silently skipped" {
    try expectTokens("?foo", &.{ .{ .name = "foo" }, .eof });
    try expectTokens("foo?bar", &.{
        .{ .name = "foo" }, .{ .name = "bar" }, .eof,
    });
}

test "XPath.Tokenizer: representative path expression" {
    try expectTokens("//div[@class='x']/p[2]", &.{
        .double_slash,
        .{ .name = "div" },
        .lbracket,
        .at,
        .{ .name = "class" },
        .eq,
        .{ .string = "x" },
        .rbracket,
        .slash,
        .{ .name = "p" },
        .lbracket,
        .{ .number = 2 },
        .rbracket,
        .eof,
    });
}

test "XPath.Tokenizer: representative axis + predicate expression" {
    try expectTokens(
        "ancestor-or-self::section/following-sibling::*[position()<=last()-1]",
        &.{
            .{ .name = "ancestor-or-self" },
            .double_colon,
            .{ .name = "section" },
            .slash,
            .{ .name = "following-sibling" },
            .double_colon,
            .star,
            .lbracket,
            .{ .name = "position" },
            .lparen,
            .rparen,
            .lte,
            .{ .name = "last" },
            .lparen,
            .rparen,
            .minus,
            .{ .number = 1 },
            .rbracket,
            .eof,
        },
    );
}

test "XPath.Tokenizer: parent-axis abbreviation" {
    try expectTokens("../foo", &.{
        .double_dot, .slash, .{ .name = "foo" }, .eof,
    });
}

test "XPath.Tokenizer: filter expression with predicate" {
    try expectTokens("(//a)[1]", &.{
        .lparen,   .double_slash,    .{ .name = "a" }, .rparen,
        .lbracket, .{ .number = 1 }, .rbracket,        .eof,
    });
}

test "XPath.Tokenizer: variable reference" {
    try expectTokens("$x + 1", &.{
        .dollar, .{ .name = "x" }, .plus, .{ .number = 1 }, .eof,
    });
}

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

//! This file implements the tokenization step defined in the CSS Syntax Module Level 3 specification.
//!
//! The algorithm accepts a valid UTF-8 string and returns a stream of tokens.
//! The tokenization step never fails, even for complete gibberish.
//! Validity must then be checked by the parser.
//!
//! NOTE: The tokenizer is not thread-safe and does not own any memory, and does not check the validity of utf8.
//!
//! See spec for more info: https://drafts.csswg.org/css-syntax/#tokenization

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Tokenizer = @This();

pub const Token = union(enum) {
    /// A `<ident-token>`
    ident: []const u8,

    /// A `<function-token>`
    ///
    /// The value (name) does not include the `(` marker.
    function: []const u8,

    /// A `<at-keyword-token>`
    ///
    /// The value does not include the `@` marker.
    at_keyword: []const u8,

    /// A `<hash-token>` with the type flag set to "id"
    ///
    /// The value does not include the `#` marker.
    id_hash: []const u8, // Hash that is a valid ID selector.

    /// A `<hash-token>` with the type flag set to "unrestricted"
    ///
    /// The value does not include the `#` marker.
    unrestricted_hash: []const u8,

    /// A `<string-token>`
    ///
    /// The value does not include the quotes.
    string: []const u8,

    /// A `<bad-string-token>`
    ///
    /// This token always indicates a parse error.
    bad_string: []const u8,

    /// A `<url-token>`
    ///
    /// The value does not include the `url(` `)` markers.  Note that `url( <string-token> )` is represented by a
    /// `Function` token.
    url: []const u8,

    /// A `<bad-url-token>`
    ///
    /// This token always indicates a parse error.
    bad_url: []const u8,

    /// A `<delim-token>`
    delim: u8,

    /// A `<number-token>`
    number: struct {
        /// Whether the number had a `+` or `-` sign.
        ///
        /// This is used is some cases like the <An+B> micro syntax. (See the `parse_nth` function.)
        has_sign: bool,

        /// If the origin source did not include a fractional part, the value as an integer.
        int_value: ?i32,

        /// The value as a float
        value: f32,
    },

    /// A `<percentage-token>`
    percentage: struct {
        /// Whether the number had a `+` or `-` sign.
        has_sign: bool,

        /// If the origin source did not include a fractional part, the value as an integer.
        /// It is **not** divided by 100.
        int_value: ?i32,

        /// The value as a float, divided by 100 so that the nominal range is 0.0 to 1.0.
        unit_value: f32,
    },

    /// A `<dimension-token>`
    dimension: struct {
        /// Whether the number had a `+` or `-` sign.
        ///
        /// This is used is some cases like the <An+B> micro syntax. (See the `parse_nth` function.)
        has_sign: bool,

        /// If the origin source did not include a fractional part, the value as an integer.
        int_value: ?i32,

        /// The value as a float
        value: f32,

        /// The unit, e.g. "px" in `12px`
        unit: []const u8,
    },

    /// A `<unicode-range-token>`
    unicode_range: struct { bgn: u32, end: i32 },

    /// A `<whitespace-token>`
    white_space: []const u8,

    /// A `<!--` `<CDO-token>`
    cdo,

    /// A `-->` `<CDC-token>`
    cdc,

    /// A `:` `<colon-token>`
    colon, // :

    /// A `;` `<semicolon-token>`
    semicolon, // ;

    /// A `,` `<comma-token>`
    comma, // ,

    /// A `<[-token>`
    square_bracket_block,

    /// A `<]-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    close_square_bracket,

    /// A `<(-token>`
    parenthesis_block,

    /// A `<)-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    close_parenthesis,

    /// A `<{-token>`
    curly_bracket_block,

    /// A `<}-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    close_curly_bracket,

    /// A comment.
    ///
    /// The CSS Syntax spec does not generate tokens for comments,
    /// But we do for simplicity of the interface.
    ///
    /// The value does not include the `/*` `*/` markers.
    comment: []const u8,
};

input: []const u8,

/// Counted in bytes, not code points. From 0.
position: usize = 0,

// If true, the input has at least `n` bytes left *after* the current one.
// That is, `Lexer.byteAt(n)` will not panic.
fn hasAtLeast(self: *const Tokenizer, n: usize) bool {
    return self.position + n < self.input.len;
}

fn isEof(self: *const Tokenizer) bool {
    return !self.hasAtLeast(0);
}

fn byteAt(self: *const Tokenizer, offset: usize) u8 {
    return self.input[self.position + offset];
}

// Assumes non-EOF
fn nextByteUnchecked(self: *const Tokenizer) u8 {
    return self.byteAt(0);
}

fn nextByte(self: *const Tokenizer) ?u8 {
    return if (self.isEof())
        null
    else
        self.input[self.position];
}

fn startsWith(self: *const Tokenizer, needle: []const u8) bool {
    return std.mem.startsWith(u8, self.input[self.position..], needle);
}

fn slice(self: *const Tokenizer, start: usize, end: usize) []const u8 {
    return self.input[start..end];
}

fn sliceFrom(self: *const Tokenizer, start_pos: usize) []const u8 {
    return self.slice(start_pos, self.position);
}

// Advance over N bytes in the input.  This function can advance
// over ASCII bytes (excluding newlines), or UTF-8 sequence
// leaders (excluding leaders for 4-byte sequences).
fn advance(self: *Tokenizer, n: usize) void {
    if (builtin.mode == .Debug) {
        // Each byte must either be an ASCII byte or a sequence leader,
        // but not a 4-byte leader; also newlines are rejected.
        for (0..n) |i| {
            const b = self.byteAt(i);
            assert(b != '\r' and b != '\n' and b != '\x0C');
            assert(b <= 0x7F or (b & 0xF0 != 0xF0 and b & 0xC0 != 0x80));
        }
    }
    self.position += n;
}

fn hasNewlineAt(self: *const Tokenizer, offset: usize) bool {
    if (!self.hasAtLeast(offset)) return false;

    return switch (self.byteAt(offset)) {
        '\n', '\r', '\x0C' => true,
        else => false,
    };
}

fn hasNonAsciiAt(self: *const Tokenizer, offset: usize) bool {
    if (!self.hasAtLeast(offset)) return false;

    const byte = self.byteAt(offset);
    const len_utf8 = std.unicode.utf8ByteSequenceLength(byte) catch return false;

    if (!self.hasAtLeast(offset + len_utf8 - 1)) return false;

    const start = self.position + offset;
    const bytes = self.slice(start, start + len_utf8);

    const codepoint = std.unicode.utf8Decode(bytes) catch return false;

    // https://drafts.csswg.org/css-syntax/#non-ascii-ident-code-point
    return switch (codepoint) {
        '\u{00B7}', '\u{200C}', '\u{200D}', '\u{203F}', '\u{2040}' => true,
        '\u{00C0}'...'\u{00D6}' => true,
        '\u{00D8}'...'\u{00F6}' => true,
        '\u{00F8}'...'\u{037D}' => true,
        '\u{037F}'...'\u{1FFF}' => true,
        '\u{2070}'...'\u{218F}' => true,
        '\u{2C00}'...'\u{2FEF}' => true,
        '\u{3001}'...'\u{D7FF}' => true,
        '\u{F900}'...'\u{FDCF}' => true,
        '\u{FDF0}'...'\u{FFFD}' => true,
        else => codepoint >= '\u{10000}',
    };
}

fn isIdentStart(self: *Tokenizer) bool {
    if (self.isEof()) return false;

    var b = self.nextByteUnchecked();
    if (b == '-') {
        b = if (self.hasAtLeast(1)) self.byteAt(1) else return false;
    }

    return switch (b) {
        'a'...'z', 'A'...'Z', '_', 0x0 => true,
        '\\' => !self.hasNewlineAt(1),
        else => b > 0x7F, // not is ascii
    };
}

fn consumeChar(self: *Tokenizer) void {
    const byte = self.nextByteUnchecked();
    const len_utf8 = std.unicode.utf8ByteSequenceLength(byte) catch 1;
    self.position += len_utf8;
}

// Given that a newline has been seen, advance over the newline
// and update the state.
fn consumeNewline(self: *Tokenizer) void {
    const byte = self.nextByteUnchecked();
    assert(byte == '\r' or byte == '\n' or byte == '\x0C');

    self.position += 1;
    if (byte == '\r' and self.nextByte() == '\n') {
        self.position += 1;
    }
}

fn consumeWhiteSpace(self: *Tokenizer, newline: bool) Token {
    const start_position = self.position;
    if (newline) {
        self.consumeNewline();
    } else {
        self.advance(1);
    }
    while (!self.isEof()) {
        const b = self.nextByteUnchecked();
        switch (b) {
            ' ', '\t' => {
                self.advance(1);
            },
            '\n', '\x0C', '\r' => {
                self.consumeNewline();
            },
            else => break,
        }
    }
    return .{ .white_space = self.sliceFrom(start_position) };
}

fn consumeComment(self: *Tokenizer) []const u8 {
    self.advance(2); // consume "/*"
    const start_position = self.position;
    while (!self.isEof()) {
        switch (self.nextByteUnchecked()) {
            '*' => {
                const end_position = self.position;
                self.advance(1);
                if (self.nextByte() == '/') {
                    self.advance(1);
                    return self.slice(start_position, end_position);
                }
            },
            '\n', '\x0C', '\r' => {
                self.consumeNewline();
            },
            0x0 => self.advance(1),
            else => self.consumeChar(),
        }
    }
    return self.sliceFrom(start_position);
}

fn byteToHexDigit(b: u8) ?u32 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => null,
    };
}

fn byteToDecimalDigit(b: u8) ?u32 {
    return if (std.ascii.isDigit(b)) b - '0' else null;
}

// (value, number of digits up to 6)
fn consumeHexDigits(self: *Tokenizer) void {
    var value: u32 = 0;
    var digits: u32 = 0;

    while (digits < 6 and !self.isEof()) {
        if (byteToHexDigit(self.nextByteUnchecked())) |digit| {
            value = value * 16 + digit;
            digits += 1;
            self.advance(1);
        } else {
            break;
        }
    }

    _ = &value;
}

// Assumes that the U+005C REVERSE SOLIDUS (\) has already been consumed
// and that the next input character has already been verified
// to not be a newline.
fn consumeEscape(self: *Tokenizer) void {
    if (self.isEof())
        return; // Escaped EOF

    switch (self.nextByteUnchecked()) {
        '0'...'9', 'A'...'F', 'a'...'f' => {
            consumeHexDigits(self);

            if (!self.isEof()) {
                switch (self.nextByteUnchecked()) {
                    ' ', '\t' => {
                        self.advance(1);
                    },
                    '\n', '\x0C', '\r' => {
                        self.consumeNewline();
                    },
                    else => {},
                }
            }
        },
        else => self.consumeChar(),
    }
}

/// https://drafts.csswg.org/css-syntax/#consume-string-token
fn consumeString(self: *Tokenizer, single_quote: bool) Token {
    self.advance(1); // Skip the initial quote

    // start_pos is at code point boundary, after " or '
    const start_pos = self.position;

    while (!self.isEof()) {
        switch (self.nextByteUnchecked()) {
            '"' => {
                if (!single_quote) {
                    const value = self.sliceFrom(start_pos);
                    self.advance(1);
                    return .{ .string = value };
                }
                self.advance(1);
            },
            '\'' => {
                if (single_quote) {
                    const value = self.sliceFrom(start_pos);
                    self.advance(1);
                    return .{ .string = value };
                }
                self.advance(1);
            },
            '\n', '\r', '\x0C' => {
                return .{ .bad_string = self.sliceFrom(start_pos) };
            },
            '\\' => {
                self.advance(1);
                if (self.isEof())
                    continue; // escaped EOF, do nothing.

                switch (self.nextByteUnchecked()) {
                    // Escaped newline
                    '\n', '\x0C', '\r' => self.consumeNewline(),

                    // Spec calls for replacing escape sequences with characters,
                    // but this would require allocating a new string.
                    // Therefore, we leave it as is and let the parser handle the escaping.
                    else => self.consumeEscape(),
                }
            },
            else => self.consumeChar(),
        }
    }

    return .{ .string = self.sliceFrom(start_pos) };
}

fn consumeName(self: *Tokenizer) []const u8 {
    // start_pos is the end of the previous token, therefore at a code point boundary
    const start_pos = self.position;

    while (!self.isEof()) {
        switch (self.nextByteUnchecked()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => self.advance(1),
            '\\' => {
                if (self.hasNewlineAt(1)) {
                    break;
                }

                self.advance(1);
                self.consumeEscape();
            },
            0x0 => self.advance(1),
            '\x80'...'\xBF', '\xC0'...'\xEF', '\xF0'...'\xFF' => {
                // This byte *is* part of a multi-byte code point,
                // we’ll end up copying the whole code point before this loop does something else.
                self.advance(1);
            },
            else => {
                if (self.hasNonAsciiAt(0)) {
                    self.consumeChar();
                } else {
                    break; // ASCII
                }
            },
        }
    }

    return self.sliceFrom(start_pos);
}

fn consumeMark(self: *Tokenizer) Token {
    const byte = self.nextByteUnchecked();
    self.advance(1);
    return switch (byte) {
        ',' => .comma,
        ':' => .colon,
        ';' => .semicolon,
        '(' => .parenthesis_block,
        ')' => .close_parenthesis,
        '{' => .curly_bracket_block,
        '}' => .close_curly_bracket,
        '[' => .square_bracket_block,
        ']' => .close_square_bracket,
        else => unreachable,
    };
}

fn consumeNumeric(self: *Tokenizer) Token {
    // Parse [+-]?\d*(\.\d+)?([eE][+-]?\d+)?
    // But this is always called so that there is at least one digit in \d*(\.\d+)?

    // Do all the math in f64 so that large numbers overflow to +/-inf
    // and i32::{MIN, MAX} are within range.

    var sign: f64 = 1.0;
    var has_sign = false;
    switch (self.nextByteUnchecked()) {
        '+' => {
            has_sign = true;
        },
        '-' => {
            has_sign = true;
            sign = -1.0;
        },
        else => {},
    }
    if (has_sign) {
        self.advance(1);
    }

    var is_integer = true;
    var integral_part: f64 = 0.0;
    var fractional_part: f64 = 0.0;

    while (!self.isEof()) {
        if (byteToDecimalDigit(self.nextByteUnchecked())) |digit| {
            integral_part = integral_part * 10.0 + @as(f64, @floatFromInt(digit));
            self.advance(1);
        } else {
            break;
        }
    }

    if (self.hasAtLeast(1) and self.nextByteUnchecked() == '.' and std.ascii.isDigit(self.byteAt(1))) {
        is_integer = false;
        self.advance(1); // Consume '.'

        var factor: f64 = 0.1;
        while (!self.isEof()) {
            if (byteToDecimalDigit(self.nextByteUnchecked())) |digit| {
                fractional_part += @as(f64, @floatFromInt(digit)) * factor;
                factor *= 0.1;
                self.advance(1);
            } else {
                break;
            }
        }
    }

    var value = sign * (integral_part + fractional_part);

    blk: {
        const e = self.nextByte() orelse break :blk;
        if (e != 'e' and e != 'E') break :blk;

        var mul: f64 = 1.0;

        if (self.hasAtLeast(2) and (self.byteAt(1) == '+' or self.byteAt(1) == '-') and std.ascii.isDigit(self.byteAt(2))) {
            mul = switch (self.byteAt(1)) {
                '-' => -1.0,
                '+' => 1.0,
                else => unreachable,
            };

            self.advance(2);
        } else if (self.hasAtLeast(2) and std.ascii.isDigit(self.byteAt(2))) {
            self.advance(1);
        } else {
            break :blk;
        }

        is_integer = false;

        var exponent: f64 = 0.0;
        while (!self.isEof()) {
            if (byteToDecimalDigit(self.nextByteUnchecked())) |digit| {
                exponent = exponent * 10.0 + @as(f64, @floatFromInt(digit));
                self.advance(1);
            } else {
                break;
            }
        }
        value *= std.math.pow(f64, 10.0, mul * exponent);
    }

    const int_value: ?i32 = if (is_integer) blk: {
        if (value >= std.math.maxInt(i32)) {
            break :blk std.math.maxInt(i32);
        }

        if (value <= std.math.minInt(i32)) {
            break :blk std.math.minInt(i32);
        }

        break :blk @as(i32, @intFromFloat(value));
    } else null;

    if (!self.isEof() and self.nextByteUnchecked() == '%') {
        self.advance(1);

        return .{ .percentage = .{
            .has_sign = has_sign,
            .int_value = int_value,
            .unit_value = @as(f32, @floatCast(value / 100.0)),
        } };
    }

    if (isIdentStart(self)) {
        return .{ .dimension = .{
            .has_sign = has_sign,
            .int_value = int_value,
            .value = @as(f32, @floatCast(value)),
            .unit = consumeName(self),
        } };
    }

    return .{ .number = .{
        .has_sign = has_sign,
        .int_value = int_value,
        .value = @as(f32, @floatCast(value)),
    } };
}

fn consumeUnquotedUrl(self: *Tokenizer) ?Token {
    // TODO: true url parser
    if (self.nextByte()) |it| {
        return self.consumeString(it == '\'');
    }

    return null;
}

fn consumeIdentLike(self: *Tokenizer) Token {
    const value = self.consumeName();

    if (!self.isEof() and self.nextByteUnchecked() == '(') {
        self.advance(1);

        if (std.ascii.eqlIgnoreCase(value, "url")) {
            if (self.consumeUnquotedUrl()) |result| {
                return result;
            }
        }

        return .{ .function = value };
    }

    return .{ .ident = value };
}

pub fn next(self: *Tokenizer) ?Token {
    if (self.isEof()) {
        return null;
    }

    const b = self.nextByteUnchecked();
    return switch (b) {
        // Consume comments
        '/' => {
            if (self.startsWith("/*")) {
                return .{ .comment = self.consumeComment() };
            } else {
                self.advance(1);
                return .{ .delim = '/' };
            }
        },

        // Consume marks
        '(', ')', '{', '}', '[', ']', ',', ':', ';' => {
            return self.consumeMark();
        },

        // Consume as much whitespace as possible. Return a <whitespace-token>.
        ' ', '\t' => self.consumeWhiteSpace(false),
        '\n', '\x0C', '\r' => self.consumeWhiteSpace(true),

        // Consume a string token and return it.
        '"' => self.consumeString(false),
        '\'' => self.consumeString(true),

        '0'...'9' => self.consumeNumeric(),
        'a'...'z', 'A'...'Z', '_', 0x0 => self.consumeIdentLike(),

        '+' => {
            if ((self.hasAtLeast(1) and std.ascii.isDigit(self.byteAt(1))) or
                (self.hasAtLeast(2) and self.byteAt(1) == '.' and std.ascii.isDigit(self.byteAt(2))))
            {
                return self.consumeNumeric();
            }
            self.advance(1);
            return .{ .delim = '+' };
        },
        '-' => {
            if ((self.hasAtLeast(1) and std.ascii.isDigit(self.byteAt(1))) or
                (self.hasAtLeast(2) and self.byteAt(1) == '.' and std.ascii.isDigit(self.byteAt(2))))
            {
                return self.consumeNumeric();
            }

            if (self.startsWith("-->")) {
                self.advance(3);
                return .cdc;
            }

            if (isIdentStart(self)) {
                return self.consumeIdentLike();
            }

            self.advance(1);
            return .{ .delim = '-' };
        },
        '.' => {
            if (self.hasAtLeast(1) and std.ascii.isDigit(self.byteAt(1))) {
                return self.consumeNumeric();
            }
            self.advance(1);
            return .{ .delim = '.' };
        },

        // Consume hash token
        '#' => {
            self.advance(1);
            if (self.isIdentStart()) {
                return .{ .id_hash = self.consumeName() };
            }
            if (self.nextByte()) |it| {
                switch (it) {
                    // Any other valid case here already resulted in IDHash.
                    '0'...'9', '-' => return .{ .unrestricted_hash = self.consumeName() },
                    else => {},
                }
            }
            return .{ .delim = '#' };
        },

        // Consume at-rules
        '@' => {
            self.advance(1);
            return if (isIdentStart(self))
                .{ .at_keyword = consumeName(self) }
            else
                .{ .delim = '@' };
        },

        '<' => {
            if (self.startsWith("<!--")) {
                self.advance(4);
                return .cdo;
            } else {
                self.advance(1);
                return .{ .delim = '<' };
            }
        },

        '\\' => {
            if (!self.hasNewlineAt(1)) {
                return self.consumeIdentLike();
            }

            self.advance(1);
            return .{ .delim = '\\' };
        },

        else => {
            if (b > 0x7F) { // not is ascii
                return self.consumeIdentLike();
            }

            self.advance(1);
            return .{ .delim = b };
        },
    };
}

const testing = std.testing;

fn expectTokensEqual(input: []const u8, tokens: []const Token) !void {
    var lexer = Tokenizer{ .input = input };

    var i: usize = 0;
    while (lexer.next()) |token| : (i += 1) {
        assert(i < tokens.len);
        try testing.expectEqualDeep(tokens[i], token);
    }

    try testing.expectEqual(i, tokens.len);
    try testing.expectEqualDeep(null, lexer.next());
}

test "smoke" {
    try expectTokensEqual(
        \\.lightpanda  {color:red;}
    , &.{
        .{ .delim = '.' },
        .{ .ident = "lightpanda" },
        .{ .white_space = "  " },
        .curly_bracket_block,
        .{ .ident = "color" },
        .colon,
        .{ .ident = "red" },
        .semicolon,
        .close_curly_bracket,
    });
}

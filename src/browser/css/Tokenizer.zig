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
    Ident: []const u8,

    /// A `<function-token>`
    ///
    /// The value (name) does not include the `(` marker.
    Function: []const u8,

    /// A `<at-keyword-token>`
    ///
    /// The value does not include the `@` marker.
    AtKeyword: []const u8,

    /// A `<hash-token>` with the type flag set to "id"
    ///
    /// The value does not include the `#` marker.
    IdHash: []const u8, // Hash that is a valid ID selector.

    /// A `<hash-token>` with the type flag set to "unrestricted"
    ///
    /// The value does not include the `#` marker.
    UnrestrictedHash: []const u8,

    /// A `<string-token>`
    ///
    /// The value does not include the quotes.
    String: []const u8,

    /// A `<bad-string-token>`
    ///
    /// This token always indicates a parse error.
    BadString: []const u8,

    /// A `<url-token>`
    ///
    /// The value does not include the `url(` `)` markers.  Note that `url( <string-token> )` is represented by a
    /// `Function` token.
    Url: []const u8,

    /// A `<bad-url-token>`
    ///
    /// This token always indicates a parse error.
    BadUrl: []const u8,

    /// A `<delim-token>`
    Delim: u8,

    /// A `<number-token>`
    Number: struct {
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
    Percentage: struct {
        /// Whether the number had a `+` or `-` sign.
        has_sign: bool,

        /// If the origin source did not include a fractional part, the value as an integer.
        /// It is **not** divided by 100.
        int_value: ?i32,

        /// The value as a float, divided by 100 so that the nominal range is 0.0 to 1.0.
        unit_value: f32,
    },

    /// A `<dimension-token>`
    Dimension: struct {
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
    UnicodeRange: struct { bgn: u32, end: i32 },

    /// A `<whitespace-token>`
    WhiteSpace: []const u8,

    /// A `<!--` `<CDO-token>`
    CDO,

    /// A `-->` `<CDC-token>`
    CDC,

    /// A `:` `<colon-token>`
    Colon, // :

    /// A `;` `<semicolon-token>`
    Semicolon, // ;

    /// A `,` `<comma-token>`
    Comma, // ,

    /// A `<[-token>`
    SquareBracketBlock,

    /// A `<]-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    CloseSquareBracket,

    /// A `<(-token>`
    ParenthesisBlock,

    /// A `<)-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    CloseParenthesis,

    /// A `<{-token>`
    CurlyBracketBlock,

    /// A `<}-token>`
    ///
    /// When obtained from one of the `Parser::next*` methods,
    /// this token is always unmatched and indicates a parse error.
    CloseCurlyBracket,

    /// A comment.
    ///
    /// The CSS Syntax spec does not generate tokens for comments,
    /// But we do for simplicity of the interface.
    ///
    /// The value does not include the `/*` `*/` markers.
    Comment: []const u8,
};

input: []const u8,

/// Counted in bytes, not code points. From 0.
position: usize = 0,

// If true, the input has at least `n` bytes left *after* the current one.
// That is, `Lexer.byte_at(n)` will not panic.
fn has_at_least(self: *const Tokenizer, n: usize) bool {
    return self.position + n < self.input.len;
}

fn is_eof(self: *const Tokenizer) bool {
    return !self.has_at_least(0);
}

fn byte_at(self: *const Tokenizer, offset: usize) u8 {
    return self.input[self.position + offset];
}

// Assumes non-EOF
fn next_byte_unchecked(self: *const Tokenizer) u8 {
    return self.byte_at(0);
}

fn next_byte(self: *const Tokenizer) ?u8 {
    return if (self.is_eof())
        null
    else
        self.input[self.position];
}

fn starts_with(self: *const Tokenizer, needle: []const u8) bool {
    return std.mem.startsWith(u8, self.input[self.position..], needle);
}

fn slice(self: *const Tokenizer, start: usize, end: usize) []const u8 {
    return self.input[start..end];
}

fn slice_from(self: *const Tokenizer, start_pos: usize) []const u8 {
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
            const b = self.byte_at(i);
            assert(b != '\r' and b != '\n' and b != '\x0C');
            assert(b <= 0x7F or (b & 0xF0 != 0xF0 and b & 0xC0 != 0x80));
        }
    }
    self.position += n;
}

fn has_newline_at(self: *const Tokenizer, offset: usize) bool {
    if (!self.has_at_least(offset)) return false;

    return switch (self.byte_at(offset)) {
        '\n', '\r', '\x0C' => true,
        else => false,
    };
}

fn has_non_ascii_at(self: *const Tokenizer, offset: usize) bool {
    if (!self.has_at_least(offset)) return false;

    const byte = self.byte_at(offset);
    const len_utf8 = std.unicode.utf8ByteSequenceLength(byte) catch return false;

    if (!self.has_at_least(offset + len_utf8 - 1)) return false;

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

fn is_ident_start(self: *Tokenizer) bool {
    if (self.is_eof()) return false;

    var b = self.next_byte_unchecked();
    if (b == '-') {
        b = self.next_byte() orelse return false;
    }

    return switch (b) {
        'a'...'z', 'A'...'Z', '_', 0x0 => true,
        '\\' => !self.has_newline_at(1),
        else => b > 0x7F, // not is ascii
    };
}

fn consume_char(self: *Tokenizer) void {
    const byte = self.next_byte_unchecked();
    const len_utf8 = std.unicode.utf8ByteSequenceLength(byte) catch 1;
    self.position += len_utf8;
}

// Given that a newline has been seen, advance over the newline
// and update the state.
fn consume_newline(self: *Tokenizer) void {
    const byte = self.next_byte_unchecked();
    assert(byte == '\r' or byte == '\n' or byte == '\x0C');

    self.position += 1;
    if (byte == '\r' and self.next_byte() == '\n') {
        self.position += 1;
    }
}

fn consume_whitespace(self: *Tokenizer, newline: bool) Token {
    const start_position = self.position;
    if (newline) {
        self.consume_newline();
    } else {
        self.advance(1);
    }
    while (!self.is_eof()) {
        const b = self.next_byte_unchecked();
        switch (b) {
            ' ', '\t' => {
                self.advance(1);
            },
            '\n', '\x0C', '\r' => {
                self.consume_newline();
            },
            else => break,
        }
    }
    return .{ .WhiteSpace = self.slice_from(start_position) };
}

fn consume_comment(self: *Tokenizer) []const u8 {
    self.advance(2); // consume "/*"
    const start_position = self.position;
    while (!self.is_eof()) {
        switch (self.next_byte_unchecked()) {
            '*' => {
                const end_position = self.position;
                self.advance(1);
                if (self.next_byte() == '/') {
                    self.advance(1);
                    return self.slice(start_position, end_position);
                }
            },
            '\n', '\x0C', '\r' => {
                self.consume_newline();
            },
            0x0 => self.advance(1),
            else => self.consume_char(),
        }
    }
    return self.slice_from(start_position);
}

fn byte_to_hex_digit(b: u8) ?u32 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => null,
    };
}

fn byte_to_decimal_digit(b: u8) ?u32 {
    return if (std.ascii.isDigit(b)) b - '0' else null;
}

// (value, number of digits up to 6)
fn consume_hex_digits(self: *Tokenizer) void {
    var value: u32 = 0;
    var digits: u32 = 0;

    while (digits < 6 and !self.is_eof()) {
        if (byte_to_hex_digit(self.next_byte_unchecked())) |digit| {
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
fn consume_escape(self: *Tokenizer) void {
    if (self.is_eof())
        return; // Escaped EOF

    switch (self.next_byte_unchecked()) {
        '0'...'9', 'A'...'F', 'a'...'f' => {
            consume_hex_digits(self);

            if (!self.is_eof()) {
                switch (self.next_byte_unchecked()) {
                    ' ', '\t' => {
                        self.advance(1);
                    },
                    '\n', '\x0C', '\r' => {
                        self.consume_newline();
                    },
                    else => {},
                }
            }
        },
        else => self.consume_char(),
    }
}

/// https://drafts.csswg.org/css-syntax/#consume-string-token
fn consume_string(self: *Tokenizer, single_quote: bool) Token {
    self.advance(1); // Skip the initial quote

    // start_pos is at code point boundary, after " or '
    const start_pos = self.position;

    while (self.is_eof()) {
        switch (self.next_byte_unchecked()) {
            '"' => {
                if (!single_quote) {
                    const value = self.slice_from(start_pos);
                    self.advance(1);
                    return .{ .String = value };
                }
                self.advance(1);
            },
            '\'' => {
                if (single_quote) {
                    const value = self.slice_from(start_pos);
                    self.advance(1);
                    return .{ .String = value };
                }
                self.advance(1);
            },
            '\n', '\r', '\x0C' => {
                return .{ .BadString = self.slice_from(start_pos) };
            },
            '\\' => {
                self.advance(1);
                if (self.is_eof())
                    continue; // escaped EOF, do nothing.

                switch (self.next_byte_unchecked()) {
                    // Escaped newline
                    '\n', '\x0C', '\r' => self.consume_newline(),

                    // Spec calls for replacing escape sequences with characters,
                    // but this would require allocating a new string.
                    // Therefore, we leave it as is and let the parser handle the escaping.
                    else => self.consume_escape(),
                }
            },
            else => self.consume_char(),
        }
    }

    return .{ .String = self.slice_from(start_pos) };
}

fn consume_name(self: *Tokenizer) []const u8 {
    // start_pos is the end of the previous token, therefore at a code point boundary
    const start_pos = self.position;

    while (!self.is_eof()) {
        switch (self.next_byte_unchecked()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => self.advance(1),
            '\\' => {
                if (self.has_newline_at(1)) {
                    break;
                }

                self.advance(1);
                self.consume_escape();
            },
            0x0 => self.advance(1),
            '\x80'...'\xBF', '\xC0'...'\xEF', '\xF0'...'\xFF' => {
                // This byte *is* part of a multi-byte code point,
                // we’ll end up copying the whole code point before this loop does something else.
                self.advance(1);
            },
            else => {
                if (self.has_non_ascii_at(0)) {
                    self.consume_char();
                } else {
                    break; // ASCII
                }
            },
        }
    }

    return self.slice_from(start_pos);
}

fn consume_mark(self: *Tokenizer) Token {
    const byte = self.next_byte_unchecked();
    self.advance(1);
    return switch (byte) {
        ',' => .Comma,
        ':' => .Colon,
        ';' => .Semicolon,
        '(' => .ParenthesisBlock,
        ')' => .CloseParenthesis,
        '{' => .CurlyBracketBlock,
        '}' => .CloseCurlyBracket,
        '[' => .SquareBracketBlock,
        ']' => .CloseSquareBracket,
        else => unreachable,
    };
}

fn consume_numeric(self: *Tokenizer) Token {
    // Parse [+-]?\d*(\.\d+)?([eE][+-]?\d+)?
    // But this is always called so that there is at least one digit in \d*(\.\d+)?

    // Do all the math in f64 so that large numbers overflow to +/-inf
    // and i32::{MIN, MAX} are within range.

    var sign: f64 = 1.0;
    var has_sign = false;
    switch (self.next_byte_unchecked()) {
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

    while (!self.is_eof()) {
        if (byte_to_decimal_digit(self.next_byte_unchecked())) |digit| {
            integral_part = integral_part * 10.0 + @as(f64, @floatFromInt(digit));
            self.advance(1);
        } else {
            break;
        }
    }

    if (self.has_at_least(1) and self.next_byte_unchecked() == '.' and std.ascii.isDigit(self.byte_at(1))) {
        is_integer = false;
        self.advance(1); // Consume '.'

        var factor: f64 = 0.1;
        while (!self.is_eof()) {
            if (byte_to_decimal_digit(self.next_byte_unchecked())) |digit| {
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
        const e = self.next_byte() orelse break :blk;
        if (e != 'e' and e != 'E') break :blk;

        var mul: f64 = 1.0;

        if (self.has_at_least(2) and (self.byte_at(1) == '+' or self.byte_at(1) == '-') and std.ascii.isDigit(self.byte_at(2))) {
            mul = switch (self.byte_at(1)) {
                '-' => -1.0,
                '+' => 1.0,
                else => unreachable,
            };

            self.advance(2);
        } else if (self.has_at_least(1) and std.ascii.isDigit(self.byte_at(2))) {
            self.advance(1);
        } else {
            break :blk;
        }

        is_integer = false;

        var exponent: f64 = 0.0;
        while (!self.is_eof()) {
            if (byte_to_decimal_digit(self.next_byte_unchecked())) |digit| {
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

    if (!self.is_eof() and self.next_byte_unchecked() == '%') {
        self.advance(1);

        return .{ .Percentage = .{
            .has_sign = has_sign,
            .int_value = int_value,
            .unit_value = @as(f32, @floatCast(value / 100.0)),
        } };
    }

    if (is_ident_start(self)) {
        return .{ .Dimension = .{
            .has_sign = has_sign,
            .int_value = int_value,
            .value = @as(f32, @floatCast(value)),
            .unit = consume_name(self),
        } };
    }

    return .{ .Number = .{
        .has_sign = has_sign,
        .int_value = int_value,
        .value = @as(f32, @floatCast(value)),
    } };
}

fn consume_unquoted_url(self: *Tokenizer) ?Token {
    _ = self;
    @panic("unimplemented");
}

fn consume_ident_like(self: *Tokenizer) Token {
    const value = self.consume_name();

    if (!self.is_eof() and self.next_byte_unchecked() == '(') {
        self.advance(1);

        if (std.ascii.eqlIgnoreCase(value, "url")) {
            if (self.consume_unquoted_url()) |result| {
                return result;
            }
        }

        return .{ .Function = value };
    }

    return .{ .Ident = value };
}

pub fn next(self: *Tokenizer) ?Token {
    if (self.is_eof()) {
        return null;
    }

    const b = self.next_byte_unchecked();
    return switch (b) {
        // Consume comments
        '/' => {
            if (self.starts_with("/*")) {
                return .{ .Comment = self.consume_comment() };
            } else {
                self.advance(1);
                return .{ .Delim = '/' };
            }
        },

        // Consume marks
        '(', ')', '{', '}', '[', ']', ',', ':', ';' => {
            return self.consume_mark();
        },

        // Consume as much whitespace as possible. Return a <whitespace-token>.
        ' ', '\t' => self.consume_whitespace(false),
        '\n', '\x0C', '\r' => self.consume_whitespace(true),

        // Consume a string token and return it.
        '"' => self.consume_string(false),
        '\'' => self.consume_string(true),

        '0'...'9' => self.consume_numeric(),
        'a'...'z', 'A'...'Z', '_', 0x0 => self.consume_ident_like(),

        '+' => {
            if ((self.has_at_least(1) and std.ascii.isDigit(self.byte_at(1))) or
                (self.has_at_least(2) and self.byte_at(1) == '.' and std.ascii.isDigit(self.byte_at(2))))
            {
                return self.consume_numeric();
            }
            self.advance(1);
            return .{ .Delim = '+' };
        },
        '-' => {
            if ((self.has_at_least(1) and std.ascii.isDigit(self.byte_at(1))) or
                (self.has_at_least(2) and self.byte_at(1) == '.' and std.ascii.isDigit(self.byte_at(2))))
            {
                return self.consume_numeric();
            }

            if (self.starts_with("-->")) {
                self.advance(3);
                return .CDC;
            }

            if (is_ident_start(self)) {
                return self.consume_ident_like();
            }

            self.advance(1);
            return .{ .Delim = '-' };
        },
        '.' => {
            if (self.has_at_least(1) and std.ascii.isDigit(self.byte_at(1))) {
                return self.consume_numeric();
            }
            self.advance(1);
            return .{ .Delim = '.' };
        },

        // Consume hash token
        '#' => {
            self.advance(1);
            if (self.is_ident_start()) {
                return .{ .IdHash = self.consume_name() };
            }
            if (self.next_byte()) |it| {
                switch (it) {
                    // Any other valid case here already resulted in IDHash.
                    '0'...'9', '-' => return .{ .UnrestrictedHash = self.consume_name() },
                    else => {},
                }
            }
            return .{ .Delim = '#' };
        },

        // Consume at-rules
        '@' => {
            self.advance(1);
            return if (is_ident_start(self))
                .{ .AtKeyword = consume_name(self) }
            else
                .{ .Delim = '@' };
        },

        '<' => {
            if (self.starts_with("<!--")) {
                self.advance(4);
                return .CDO;
            } else {
                self.advance(1);
                return .{ .Delim = '<' };
            }
        },

        '\\' => {
            if (!self.has_newline_at(1)) {
                return self.consume_ident_like();
            }

            self.advance(1);
            return .{ .Delim = '\\' };
        },

        else => {
            if (b > 0x7F) { // not is ascii
                return self.consume_ident_like();
            }

            self.advance(1);
            return .{ .Delim = b };
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
        .{ .Delim = '.' },
        .{ .Ident = "lightpanda" },
        .{ .WhiteSpace = "  " },
        .CurlyBracketBlock,
        .{ .Ident = "color" },
        .Colon,
        .{ .Ident = "red" },
        .Semicolon,
        .CloseCurlyBracket,
    });
}

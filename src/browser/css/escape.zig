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

//! CSS escapes. The tokenizer leaves them in its tokens' source, so whoever
//! needs a token's value decodes them here: the selector parser for its
//! identifiers and strings, computed `content` for the strings it serializes.

const std = @import("std");

const REPLACEMENT = 0xFFFD;

pub const Escape = struct {
    codepoint: u21,
    /// How many bytes of the input, after the backslash, the escape spans.
    len: usize,
};

/// The code point an escape stands for. `input` starts after the backslash,
/// which the caller has checked starts a valid escape (it isn't followed by a
/// newline).
/// https://drafts.csswg.org/css-syntax/#consume-escaped-code-point
pub fn decode(input: []const u8) Escape {
    if (input.len == 0) {
        return .{ .codepoint = REPLACEMENT, .len = 0 };
    }

    if (std.ascii.isHex(input[0]) == false) {
        // Any other code point stands for itself.
        const len = std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
        if (len > input.len) {
            return .{ .codepoint = REPLACEMENT, .len = input.len };
        }
        const codepoint = std.unicode.utf8Decode(input[0..len]) catch REPLACEMENT;
        return .{ .codepoint = codepoint, .len = len };
    }

    var value: u32 = 0;
    var i: usize = 0;
    while (i < input.len and i < 6 and std.ascii.isHex(input[i])) : (i += 1) {
        value = value * 16 + (std.fmt.charToDigit(input[i], 16) catch unreachable);
    }
    // One whitespace ends the hex digits and belongs to the escape.
    if (i < input.len and (input[i] == ' ' or input[i] == '\t')) {
        i += 1;
    } else if (i < input.len) {
        i += newlineLen(input[i..]);
    }

    const codepoint: u21 = switch (value) {
        1...0xD7FF, 0xE000...0x10FFFF => @intCast(value),
        else => REPLACEMENT,
    };
    return .{ .codepoint = codepoint, .len = i };
}

/// Writes a string token's value, `raw` being its source between the quotes,
/// as CSSOM serializes a string: in double quotes, its escapes resolved.
/// https://drafts.csswg.org/cssom/#serialize-a-string
pub fn writeString(writer: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        i += 1;
        if (c != '\\') {
            // A multi-byte code point's bytes are copied as they come.
            if (c < 0x80) {
                try writeStringCodepoint(writer, c);
            } else {
                try writer.writeByte(c);
            }
            continue;
        }
        if (i == raw.len) {
            // An escape at the end of a string stands for nothing.
            break;
        }
        const newline = newlineLen(raw[i..]);
        if (newline > 0) {
            // An escaped newline continues the string on the next line.
            i += newline;
            continue;
        }
        const escape = decode(raw[i..]);
        i += escape.len;
        try writeStringCodepoint(writer, escape.codepoint);
    }
    try writer.writeByte('"');
}

fn writeStringCodepoint(writer: *std.Io.Writer, codepoint: u21) std.Io.Writer.Error!void {
    switch (codepoint) {
        0 => try writer.writeAll("\u{FFFD}"),
        0x01...0x1F, 0x7F => try writer.print("\\{x} ", .{codepoint}),
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(@intCast(codepoint));
        },
        else => {
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8) catch unreachable;
            try writer.writeAll(utf8[0..len]);
        },
    }
}

/// The length of the newline `s` starts with, CRLF counting as one, or 0.
fn newlineLen(s: []const u8) usize {
    return switch (s[0]) {
        '\r' => if (s.len > 1 and s[1] == '\n') 2 else 1,
        '\n', '\x0C' => 1,
        else => 0,
    };
}

const testing = @import("../../testing.zig");

test "css escape: decode" {
    try testing.expectEqual(Escape{ .codepoint = 'A', .len = 3 }, decode("41 B"));
    try testing.expectEqual(Escape{ .codepoint = 0x41B, .len = 3 }, decode("41B"));
    try testing.expectEqual(Escape{ .codepoint = 'A', .len = 4 }, decode("41\r\nB"));
    // Six hex digits at most
    try testing.expectEqual(Escape{ .codepoint = REPLACEMENT, .len = 6 }, decode("1100001"));
    try testing.expectEqual(Escape{ .codepoint = REPLACEMENT, .len = 1 }, decode("0"));
    try testing.expectEqual(Escape{ .codepoint = REPLACEMENT, .len = 4 }, decode("D800"));
    try testing.expectEqual(Escape{ .codepoint = 'g', .len = 1 }, decode("g1"));
    try testing.expectEqual(Escape{ .codepoint = 0xE9, .len = 2 }, decode("\u{E9}x"));
    try testing.expectEqual(Escape{ .codepoint = REPLACEMENT, .len = 0 }, decode(""));
}

test "css escape: writeString" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "abc", "\"abc\"" },
        .{ "it\\'s \"q\"", "\"it's \\\"q\\\"\"" },
        .{ "\\2014 x", "\"\u{2014}x\"" },
        .{ "a\\\r\nb", "\"ab\"" },
        .{ "\\0", "\"\u{FFFD}\"" },
        .{ "\\1 \\7f", "\"\\1 \\7f \"" },
        .{ "\\\u{E9}t\u{E9}", "\"\u{E9}t\u{E9}\"" },
        .{ "end\\", "\"end\"" },
    };
    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try writeString(&buf.writer, case[0]);
        try testing.expectString(case[1], buf.written());
    }
}

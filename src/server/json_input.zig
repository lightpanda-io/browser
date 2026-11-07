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

const std = @import("std");

const Allocator = std.mem.Allocator;

// std.json.parseFromSliceLeaky for JSON sent by a client. std.json rejects
// the \u escape of an unpaired UTF-16 surrogate, which is valid JSON and which
// clients send: JSON.stringify keeps a lone surrogate, as in a string cut in
// the middle of an emoji, as an escape. So after a failed parse, those escapes
// are replaced by \ufffd (a lone surrogate has no UTF-8 encoding, so it becomes
// U+FFFD, as TextEncoder does) in a copy, which is parsed instead. Well-formed
// messages pay nothing extra.
//
// `str` is updated to point to the copy when one is used: the result may
// reference the bytes it was parsed from.
pub fn parseLeaky(comptime T: type, arena: Allocator, str: *[]const u8, opts: std.json.ParseOptions) !T {
    return std.json.parseFromSliceLeaky(T, arena, str.*, opts) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        const fixed = try arena.dupe(u8, str.*);
        if (replaceLoneSurrogates(fixed) == false) {
            return err;
        }
        str.* = fixed;
        return std.json.parseFromSliceLeaky(T, arena, fixed, opts);
    };
}

// Rewrites each \u escape of an unpaired surrogate to \ufffd, in place (both
// are 6 bytes). Returns whether anything was replaced.
fn replaceLoneSurrogates(buf: []u8) bool {
    var replaced = false;
    var i: usize = 0;
    while (i + 1 < buf.len) {
        if (buf[i] != '\\') {
            i += 1;
            continue;
        }
        const unit = surrogateEscape(buf[i..]) orelse {
            // Any other escape, including an escaped backslash: skip
            // the escaped character too.
            i += 2;
            continue;
        };
        if (unit < 0xDC00) {
            if (surrogateEscape(buf[i + 6 ..])) |next| {
                if (next >= 0xDC00) {
                    // A valid pair.
                    i += 12;
                    continue;
                }
            }
        }
        @memcpy(buf[i..][0..6], "\\ufffd");
        replaced = true;
        i += 6;
    }
    return replaced;
}

// The code unit of a \uXXXX escape at the start of buf, if it is a surrogate.
fn surrogateEscape(buf: []const u8) ?u16 {
    if (buf.len < 6 or buf[0] != '\\' or buf[1] != 'u') {
        return null;
    }
    const unit = std.fmt.parseInt(u16, buf[2..6], 16) catch return null;
    if (unit < 0xD800 or unit > 0xDFFF) {
        return null;
    }
    return unit;
}

const testing = @import("../testing.zig");
test "json_input: replaceLoneSurrogates" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "\"\\ud800\"", "\"\\ufffd\"", true },
        .{ "\"\\udc00x\"", "\"\\ufffdx\"", true },
        .{ "\"\\uD800\\uD800\"", "\"\\ufffd\\ufffd\"", true },
        .{ "\"\\ud83d\\ude00\"", "\"\\ud83d\\ude00\"", false },
        .{ "\"\\udc00\\ud800\"", "\"\\ufffd\\ufffd\"", true },
        .{ "\"\\\\ud800\"", "\"\\\\ud800\"", false },
        .{ "\"\\u00e9\\n\"", "\"\\u00e9\\n\"", false },
        .{ "\"\\ud80", "\"\\ud80", false },
    };
    for (cases) |c| {
        const buf = try testing.allocator.dupe(u8, c[0]);
        defer testing.allocator.free(buf);
        try testing.expectEqual(c[2], replaceLoneSurrogates(buf));
        try testing.expectString(c[1], buf);
    }
}

test "json_input: parseLeaky" {
    const arena = testing.arena_allocator;
    {
        // well-formed: parsed from the input as-is
        const input = "{\"a\":\"\\ud83d\\ude00\"}";
        var str: []const u8 = input;
        const v = try parseLeaky(struct { a: []const u8 }, arena, &str, .{});
        try testing.expectString("\u{1F600}", v.a);
        try testing.expect(str.ptr == input.ptr);
    }
    {
        var str: []const u8 = "{\"a\":\"x\\ud800y\"}";
        const v = try parseLeaky(struct { a: []const u8 }, arena, &str, .{});
        try testing.expectString("x\u{FFFD}y", v.a);
        try testing.expectString("{\"a\":\"x\\ufffdy\"}", str);
    }
    {
        // nothing to replace: the original error
        var str: []const u8 = "{\"a\":";
        try testing.expectError(error.UnexpectedEndOfInput, parseLeaky(struct { a: []const u8 }, arena, &str, .{}));
    }
}

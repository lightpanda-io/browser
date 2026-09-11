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

/// Wraps bytes that may not be valid UTF-8 — raw network octets like header
/// values. std.json serializes invalid UTF-8 as a JSON array of numbers,
/// which crashes CDP clients that expect a string (#2972, #2992). Non-UTF-8
/// bytes are interpreted as Latin-1 (ISO-8859-1) and transcoded, matching
/// Chrome's behavior for DevTools.
const std = @import("std");

const SafeString = @This();

bytes: []const u8,

pub fn wrap(bytes: []const u8) SafeString {
    return .{ .bytes = bytes };
}

pub fn jsonStringify(self: *const SafeString, jws: anytype) !void {
    if (std.unicode.utf8ValidateSlice(self.bytes)) {
        return jws.write(self.bytes);
    }
    try jws.beginWriteRaw();
    try writeQuoted(jws, self.bytes);
    jws.endWriteRaw();
}

// Object keys can't take std.json's byte-array fallback: objectField writes
// invalid UTF-8 straight into the frame, and RFC 6455 lets strict clients
// kill the connection over an invalid UTF-8 text frame.
pub fn writeObjectField(jws: anytype, name: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(name)) {
        return jws.objectField(name);
    }
    try jws.beginObjectFieldRaw();
    try writeQuoted(jws, name);
    jws.endObjectFieldRaw();
}

// Latin-1 -> UTF-8: each byte is a codepoint U+0000..U+00FF (max 2 bytes)
fn writeQuoted(jws: anytype, value: []const u8) !void {
    try jws.writer.writeByte('"');
    var start: usize = 0;
    for (value, 0..) |b, i| {
        if (b < 0x80) {
            continue;
        }
        try std.json.Stringify.encodeJsonStringChars(value[start..i], jws.options, jws.writer);
        var buf: [2]u8 = undefined;
        const n = std.unicode.utf8Encode(b, &buf) catch unreachable;
        try jws.writer.writeAll(buf[0..n]);
        start = i + 1;
    }
    try std.json.Stringify.encodeJsonStringChars(value[start..], jws.options, jws.writer);
    try jws.writer.writeByte('"');
}

test "cdp.SafeString: jsonStringify" {
    const expectJson = struct {
        fn expect(expected: []const u8, value: []const u8) !void {
            var buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            var jws: std.json.Stringify = .{ .writer = &writer };
            try jws.write(wrap(value));
            try std.testing.expectEqualStrings(expected, writer.buffered());
        }
    }.expect;

    // valid UTF-8 is written as-is
    try expectJson(
        "\"mié, 15 jul 2026 13:19:10 GMT\"",
        "mié, 15 jul 2026 13:19:10 GMT",
    );

    // Latin-1 bytes are transcoded to UTF-8 instead of a byte array
    try expectJson(
        "\"mié, 15 jul 2026 13:19:10 GMT\"",
        "mi\xE9, 15 jul 2026 13:19:10 GMT",
    );

    // JSON escaping still applies around transcoded bytes
    try expectJson(
        "\"a\\\"é\\nb\"",
        "a\"\xE9\nb",
    );

    // pure ASCII untouched
    try expectJson(
        "\"max-age=180, s-maxage=180, public\"",
        "max-age=180, s-maxage=180, public",
    );
}

test "cdp.SafeString: writeObjectField" {
    const expectJson = struct {
        fn expect(expected: []const u8, name: []const u8) !void {
            var buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            var jws: std.json.Stringify = .{ .writer = &writer };
            try jws.beginObject();
            try writeObjectField(&jws, name);
            try jws.write(true);
            try jws.endObject();
            try std.testing.expectEqualStrings(expected, writer.buffered());
        }
    }.expect;

    try expectJson("{\"etag\":true}", "etag");
    try expectJson("{\"naïve\":true}", "na\xEFve");
    try expectJson("{\"a\\\"é\":true}", "a\"\xE9");
}

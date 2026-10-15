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

//! Decoding of fetched stylesheet bytes into the UTF-8 the tokenizer requires.
//!
//! See https://drafts.csswg.org/css-syntax/#input-byte-stream

const std = @import("std");
const h5e = @import("../parser/html5ever.zig");

const Allocator = std.mem.Allocator;
const EncodingInfo = h5e.EncodingInfo;

/// Decodes `bytes` to UTF-8. A BOM wins, then `protocol_charset` (the
/// Content-Type charset), then a leading `@charset` rule, then
/// `environment_charset` (the document's encoding). Malformed sequences
/// become U+FFFD. Returns `bytes` itself when it is already valid UTF-8.
pub fn decode(allocator: Allocator, bytes: []const u8, protocol_charset: ?[]const u8, environment_charset: []const u8) ![]const u8 {
    return h5e.validUtf8(allocator, fallbackEncoding(bytes, protocol_charset, environment_charset), bytes);
}

/// https://drafts.csswg.org/css-syntax/#determine-the-fallback-encoding
fn fallbackEncoding(bytes: []const u8, protocol_charset: ?[]const u8, environment_charset: []const u8) EncodingInfo {
    if (EncodingInfo.forLabel(protocol_charset)) |info| return info;
    if (EncodingInfo.forLabel(charsetRuleLabel(bytes))) |info| return if (info.isUtf16()) .utf8() else info;
    return EncodingInfo.forLabel(environment_charset) orelse .utf8();
}

/// The label of a `@charset "<label>";` rule opening the first 1024 bytes,
/// matched byte for byte as the spec requires.
fn charsetRuleLabel(bytes: []const u8) ?[]const u8 {
    const prefix = "@charset \"";
    const head = bytes[0..@min(bytes.len, 1024)];
    if (!std.mem.startsWith(u8, head, prefix)) return null;

    const rest = head[prefix.len..];
    const end = std.mem.findAny(u8, rest, "\";") orelse return null;
    if (!std.mem.startsWith(u8, rest[end..], "\";")) return null;
    return rest[0..end];
}

const testing = std.testing;

fn expectDecoded(expected: []const u8, bytes: []const u8, protocol_charset: ?[]const u8, environment_charset: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try decode(arena.allocator(), bytes, protocol_charset, environment_charset));
}

test "css charset: valid UTF-8 is returned as is" {
    const bytes = "a{content:\"é\"}";
    try testing.expectEqual(bytes.ptr, (try decode(testing.allocator, bytes, null, "UTF-8")).ptr);
}

test "css charset: invalid UTF-8 is replaced" {
    try expectDecoded("a{content:\"\u{FFFD}\";color:red}", "a{content:\"\xE9\";color:red}", null, "UTF-8");
    try expectDecoded("a{}\u{FFFD}", "a{}\xE2", null, "UTF-8");
}

test "css charset: protocol charset" {
    try expectDecoded("/* café */", "/* caf\xE9 */", "iso-8859-1", "UTF-8");
}

test "css charset: protocol charset wins over @charset" {
    try expectDecoded("@charset \"utf-8\";é", "@charset \"utf-8\";\xE9", "windows-1252", "UTF-8");
}

test "css charset: @charset" {
    try expectDecoded("@charset \"windows-1252\";é", "@charset \"windows-1252\";\xE9", null, "UTF-8");
    try expectDecoded("@charset \"utf-16le\";\u{FFFD}", "@charset \"utf-16le\";\xE9", null, "windows-1252");
    // Not byte-exact: single quotes, or a missing space.
    try expectDecoded("@charset 'windows-1252';\u{FFFD}", "@charset 'windows-1252';\xE9", null, "UTF-8");
    try expectDecoded("@charset\"windows-1252\";\u{FFFD}", "@charset\"windows-1252\";\xE9", null, "UTF-8");
    // Unknown label falls through to the environment.
    try expectDecoded("@charset \"bogus\";é", "@charset \"bogus\";\xE9", null, "windows-1252");
}

test "css charset: environment charset" {
    try expectDecoded("é", "\xE9", null, "windows-1252");
}

test "css charset: BOM wins and is stripped" {
    try expectDecoded("é", "\xEF\xBB\xBF\xC3\xA9", "windows-1252", "windows-1252");
    try expectDecoded("a", "\xFF\xFEa\x00", null, "UTF-8");
    try expectDecoded("a", "\xEF\xBB\xBFa", null, "UTF-8");
}

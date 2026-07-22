// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// "data: URL processor" — https://fetch.spec.whatwg.org/#data-url-processor.
// The single home for data: parsing: the HttpClient synthetic-scheme path and
// ScriptManager (<script src="data:...">) both go through here.

const std = @import("std");
const URL = @import("URL.zig");
const base64 = @import("webapi/encoding/base64.zig");

const Allocator = std.mem.Allocator;

pub const Parsed = struct {
    body: []const u8,
    content_type: []const u8,
};

pub fn parse(arena: Allocator, url: []const u8) !Parsed {
    if (std.mem.startsWith(u8, url, "data:") == false) {
        return error.InvalidDataUrl;
    }

    const after = url["data:".len..];

    const comma = std.mem.indexOfScalarPos(u8, after, 0, ',') orelse return error.InvalidDataUrl;
    var meta = std.mem.trim(u8, after[0..comma], &std.ascii.whitespace);
    const encoded_body = after[comma + 1 ..];

    // A trailing ";" + optional spaces + "base64" selects base64 decoding.
    const is_base64 = blk: {
        if (meta.len < "base64".len) break :blk false;
        const tail = meta[meta.len - "base64".len ..];
        if (!std.ascii.eqlIgnoreCase(tail, "base64")) break :blk false;
        const head = std.mem.trimEnd(u8, meta[0 .. meta.len - "base64".len], " ");
        if (head.len == 0 or head[head.len - 1] != ';') break :blk false;
        meta = head[0 .. head.len - 1];
        break :blk true;
    };

    var content_type: []const u8 = meta;
    if (content_type.len == 0) {
        content_type = "text/plain;charset=US-ASCII";
    } else if (content_type[0] == ';') {
        // e.g. "data:;charset=utf-8,x" -> "text/plain;charset=utf-8"
        content_type = try std.fmt.allocPrint(arena, "text/plain{s}", .{content_type});
    }

    const body_text = try URL.unescape(arena, encoded_body);
    const body = if (is_base64) try base64Decode(arena, body_text) else body_text;

    return .{ .content_type = content_type, .body = body };
}

fn base64Decode(arena: Allocator, input: []const u8) ![]const u8 {
    // Forgiving-base64 decode — https://infra.spec.whatwg.org/#forgiving-base64-decode.
    // Shared with atob via the encoding helper; remap to this module's error name.
    return base64.decode(arena, .{ .raw = input }) catch return error.InvalidBase64;
}

const testing = @import("../testing.zig");
test "data_url: plain text, default content-type" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:,Hello%2C%20World");
    try testing.expectString("text/plain;charset=US-ASCII", r.content_type);
    try testing.expectString("Hello, World", r.body);
}

test "data_url: explicit mediatype" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:text/html,<b>hi</b>");
    try testing.expectString("text/html", r.content_type);
    try testing.expectString("<b>hi</b>", r.body);
}

test "data_url: base64" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:text/plain;base64,SGVsbG8=");
    try testing.expectString("text/plain", r.content_type);
    try testing.expectString("Hello", r.body);
}

test "data_url: base64 without padding decodes (forgiving)" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:application/octet-stream;base64,SGVsbG8");
    try testing.expectString("Hello", r.body);

    // 2- and 3-char unpadded tails decode (non-canonical trailing bits are ok).
    try testing.expectString("i", (try parse(testing.arena_allocator, "data:;base64,ab")).body);
    try testing.expectString("a", (try parse(testing.arena_allocator, "data:;base64,YR")).body);

    // ASCII whitespace inside the payload is ignored.
    try testing.expectString("Hello", (try parse(testing.arena_allocator, "data:;base64,SGVs bG8=")).body);
}

test "data_url: forgiving-base64 rejects misplaced/over-padding" {
    defer testing.reset();
    const arena = testing.arena_allocator;
    try std.testing.expectError(error.InvalidBase64, parse(arena, "data:;base64,abcd=")); // len % 4 == 1
    try std.testing.expectError(error.InvalidBase64, parse(arena, "data:;base64,="));
    try std.testing.expectError(error.InvalidBase64, parse(arena, "data:;base64,ab=c")); // interior "="
    try std.testing.expectError(error.InvalidBase64, parse(arena, "data:;base64,==")); // no data
}

test "data_url: bare charset gets text/plain prefix" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:;charset=utf-8,x");
    try testing.expectString("text/plain;charset=utf-8", r.content_type);
}

test "data_url: empty body" {
    defer testing.reset();
    const r = try parse(testing.arena_allocator, "data:text/plain,");
    try testing.expectString("", r.body);
}

test "data_url: missing comma is an error" {
    defer testing.reset();
    try std.testing.expectError(error.InvalidDataUrl, parse(testing.arena_allocator, "data:text/plain"));
}

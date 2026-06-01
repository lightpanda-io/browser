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

const std = @import("std");

const Allocator = std.mem.Allocator;

// WHATWG "domain to ASCII" lives in the rust-url FFI (src/html5ever/url.rs),
// which uses the UTS#46-conformant `idna` crate — the same engine rust-url
// itself uses.
extern "c" fn lpurl_domain_to_ascii(
    host_ptr: [*]const u8,
    host_len: usize,
    out_ptr: *?[*]u8,
    out_len: *usize,
) i32;

extern "c" fn lpurl_free(ptr: ?[*]u8, len: usize) void;

/// True if `host` contains any non-ASCII byte and therefore needs IDNA
/// processing. Pure-ASCII hostnames are returned unchanged by `toAscii`,
/// so callers can use this as a fast path to skip the C call entirely.
pub fn needsAscii(host: []const u8) bool {
    for (host) |byte| {
        if (byte >= 0x80) {
            return true;
        }
    }
    return false;
}

/// Convert a UTF-8 hostname to its ASCII (Punycode) form per UTS#46
/// non-transitional processing — the algorithm WHATWG URL invokes as
/// "domain to ASCII". Returns an allocator-owned slice.
pub fn toAscii(allocator: Allocator, host: []const u8) ![]u8 {
    var out_len: usize = 0;
    var out_ptr: ?[*]u8 = null;
    if (lpurl_domain_to_ascii(host.ptr, host.len, &out_ptr, &out_len) != 0) {
        return error.Idna;
    }
    defer lpurl_free(out_ptr, out_len);
    return allocator.dupe(u8, out_ptr.?[0..out_len]);
}

const testing = @import("../testing.zig");

test "idna: ASCII passthrough" {
    try testing.expectEqual(false, needsAscii("example.com"));
    const out = try toAscii(testing.allocator, "example.com");
    defer testing.allocator.free(out);
    try testing.expectString("example.com", out);
}

test "idna: non-ASCII to punycode" {
    try testing.expectEqual(true, needsAscii("räksmörgås.se"));
    const out = try toAscii(testing.allocator, "räksmörgås.se");
    defer testing.allocator.free(out);
    try testing.expectString("xn--rksmrgs-5wao1o.se", out);
}

test "idna: German sharp s with non-transitional processing" {
    // UTS#46 non-transitional preserves ß rather than mapping to ss.
    const out = try toAscii(testing.allocator, "faß.de");
    defer testing.allocator.free(out);
    try testing.expectString("xn--fa-hia.de", out);
}

test "idna: needsAscii" {
    try testing.expectEqual(false, needsAscii(""));
    try testing.expectEqual(false, needsAscii("xn--fa-hia.de"));
    try testing.expectEqual(true, needsAscii("faß.de"));
    try testing.expectEqual(true, needsAscii("\xff"));
}

test "idna: UTS#46 lowercases ASCII" {
    const out = try toAscii(testing.allocator, "EXAMPLE.COM");
    defer testing.allocator.free(out);
    try testing.expectString("example.com", out);
}

test "idna: already-punycode is idempotent" {
    const out = try toAscii(testing.allocator, "xn--rksmrgs-5wao1o.se");
    defer testing.allocator.free(out);
    try testing.expectString("xn--rksmrgs-5wao1o.se", out);
}

test "idna: mixed ASCII and non-ASCII labels" {
    const out = try toAscii(testing.allocator, "münchen.example.com");
    defer testing.allocator.free(out);
    try testing.expectString("xn--mnchen-3ya.example.com", out);
}

test "idna: multi-label CJK" {
    const out = try toAscii(testing.allocator, "日本.jp");
    defer testing.allocator.free(out);
    try testing.expectString("xn--wgv71a.jp", out);
}

test "idna: invalid domain returns error" {
    // U+FFFD (REPLACEMENT CHARACTER) is disallowed under UTS#46.
    try testing.expectError(error.Idna, toAscii(testing.allocator, "\u{FFFD}.com"));
}

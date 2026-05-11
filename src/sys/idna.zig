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

const c = @cImport({
    @cInclude("idn2.h");
});

const Allocator = std.mem.Allocator;
pub const Error = error{Idna} || Allocator.Error;

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
/// IDNA 2008 with non-transitional processing — the algorithm WHATWG URL
/// invokes as "domain to ASCII". Returns an allocator-owned slice.
pub fn toAscii(allocator: Allocator, host: []const u8) Error![]u8 {
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);

    var out_ptr: [*c]u8 = undefined;
    const flags: c_int = c.IDN2_NFC_INPUT | c.IDN2_NONTRANSITIONAL;
    const rc = c.idn2_to_ascii_8z(host_z.ptr, &out_ptr, flags);
    if (rc != c.IDN2_OK) {
        return error.Idna;
    }
    defer c.idn2_free(out_ptr);

    return try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(out_ptr))));
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

// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const testing = std.testing;

const Reader = @import("../str/parser.zig").Reader;

const Self = @This();

const MimeError = error{
    Empty,
    TooBig,
    Invalid,
    InvalidChar,
};

mtype: []const u8,
msubtype: []const u8,
params: []const u8 = "",

charset: ?[]const u8 = null,
boundary: ?[]const u8 = null,

pub const Empty = Self{ .mtype = "", .msubtype = "" };
pub const HTML = Self{ .mtype = "text", .msubtype = "html" };
pub const Javascript = Self{ .mtype = "application", .msubtype = "javascript" };

// https://mimesniff.spec.whatwg.org/#http-token-code-point
fn isHTTPCodePoint(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^' => return true,
        '_', '`', '|', '~' => return true,
        else => std.ascii.isAlphanumeric(c),
    };
}

fn valid(s: []const u8) bool {
    const ln = s.len;
    var i: usize = 0;
    while (i < ln) {
        if (!isHTTPCodePoint(s[i])) return false;
        i += 1;
    }
    return true;
}

// https://mimesniff.spec.whatwg.org/#parsing-a-mime-type
pub fn parse(s: []const u8) Self.MimeError!Self {
    const ln = s.len;
    if (ln == 0) return MimeError.Empty;
    // limit input size
    if (ln > 255) return MimeError.TooBig;

    var res = Self{ .mtype = "", .msubtype = "" };
    var r = Reader{ .data = s };

    res.mtype = trim(r.until('/'));
    if (res.mtype.len == 0) return MimeError.Invalid;
    if (!valid(res.mtype)) return MimeError.InvalidChar;

    if (!r.skip()) return MimeError.Invalid;
    res.msubtype = trim(r.until(';'));
    if (res.msubtype.len == 0) return MimeError.Invalid;
    if (!valid(res.msubtype)) return MimeError.InvalidChar;

    if (!r.skip()) return res;
    res.params = trim(r.tail());
    if (res.params.len == 0) return MimeError.Invalid;

    // parse well known parameters.
    // don't check invalid parameter format.
    var rp = Reader{ .data = res.params };
    while (true) {
        const name = trim(rp.until('='));
        if (!rp.skip()) return res;
        const value = trim(rp.until(';'));

        if (std.ascii.eqlIgnoreCase(name, "charset")) {
            res.charset = value;
        }
        if (std.ascii.eqlIgnoreCase(name, "boundary")) {
            res.boundary = value;
        }

        if (!rp.skip()) return res;
    }

    return res;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

test "parse valid" {
    for ([_][]const u8{
        "text/html",
        " \ttext/html",
        "text \t/html",
        "text/ \thtml",
        "text/html \t",
    }) |tc| {
        const m = try Self.parse(tc);
        try testing.expectEqualStrings("text", m.mtype);
        try testing.expectEqualStrings("html", m.msubtype);
    }
    const m2 = try Self.parse("text/javascript1.5");
    try testing.expectEqualStrings("text", m2.mtype);
    try testing.expectEqualStrings("javascript1.5", m2.msubtype);

    const m3 = try Self.parse("text/html; charset=utf-8");
    try testing.expectEqualStrings("text", m3.mtype);
    try testing.expectEqualStrings("html", m3.msubtype);
    try testing.expectEqualStrings("charset=utf-8", m3.params);
    try testing.expectEqualStrings("utf-8", m3.charset.?);

    const m4 = try Self.parse("text/html; boundary=----");
    try testing.expectEqualStrings("text", m4.mtype);
    try testing.expectEqualStrings("html", m4.msubtype);
    try testing.expectEqualStrings("boundary=----", m4.params);
    try testing.expectEqualStrings("----", m4.boundary.?);
}

test "parse invalid" {
    for ([_][]const u8{
        "",
        "te xt/html;",
        "te@xt/html;",
        "text/ht@ml;",
        "text/html;",
        "/text/html",
        "/html",
    }) |tc| {
        _ = Self.parse(tc) catch continue;
        try testing.expect(false);
    }
}

// Compare type and subtype.
pub fn eql(self: Self, b: Self) bool {
    if (!std.mem.eql(u8, self.mtype, b.mtype)) return false;
    return std.mem.eql(u8, self.msubtype, b.msubtype);
}

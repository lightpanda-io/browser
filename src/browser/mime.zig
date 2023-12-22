const std = @import("std");
const testing = std.testing;

const Self = @This();

const MimeError = error{
    Empty,
    TooBig,
    Invalid,
    InvalidChar,
};

mtype: []const u8,
msubtype: []const u8,
params: []const u8,

pub const HTML = Self{ .mtype = "text", .msubtype = "html", .params = "" };
pub const Javascript = Self{ .mtype = "application", .msubtype = "javascript", .params = "" };

const reader = struct {
    s: []const u8,
    i: usize = 0,

    fn until(self: *reader, c: u8) []const u8 {
        const ln = self.s.len;
        const start = self.i;
        while (self.i < ln) {
            if (c == self.s[self.i]) return self.s[start..self.i];
            self.i += 1;
        }

        return self.s[start..self.i];
    }

    fn tail(self: *reader) []const u8 {
        if (self.i > self.s.len) return "";
        defer self.i = self.s.len;
        return self.s[self.i..];
    }

    fn skip(self: *reader) bool {
        if (self.i >= self.s.len) return false;
        self.i += 1;
        return true;
    }
};

test "reader.skip" {
    var r = reader{ .s = "foo" };
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(!r.skip());
    try testing.expect(!r.skip());
}

test "reader.tail" {
    var r = reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.tail());
    try testing.expectEqualStrings("", r.tail());
}

test "reader.until" {
    var r = reader{ .s = "foo.bar.baz" };
    try testing.expectEqualStrings("foo", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("bar", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("baz", r.until('.'));

    r = reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.until('.'));

    r = reader{ .s = "" };
    try testing.expectEqualStrings("", r.until('.'));
}

fn trim(s: []const u8) []const u8 {
    const ln = s.len;
    if (ln == 0) {
        return "";
    }
    var start: usize = 0;
    while (start < ln) {
        if (!std.ascii.isWhitespace(s[start])) break;
        start += 1;
    }

    var end: usize = ln;
    while (end > 0) {
        if (!std.ascii.isWhitespace(s[end - 1])) break;
        end -= 1;
    }

    return s[start..end];
}

test "trim" {
    try testing.expectEqualStrings("", trim(""));
    try testing.expectEqualStrings("foo", trim("foo"));
    try testing.expectEqualStrings("foo", trim(" \n\tfoo"));
    try testing.expectEqualStrings("foo", trim("foo \n\t"));
}

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

    var res = Self{ .mtype = "", .msubtype = "", .params = "" };
    var r = reader{ .s = s };

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

    return res;
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

    const m3 = try Self.parse("text/html; charset=UTF-8");
    try testing.expectEqualStrings("text", m3.mtype);
    try testing.expectEqualStrings("html", m3.msubtype);
    try testing.expectEqualStrings("charset=UTF-8", m3.params);
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

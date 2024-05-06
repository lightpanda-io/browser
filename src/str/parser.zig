// some utils to parser strings.
const std = @import("std");
const testing = std.testing;

pub const Reader = struct {
    s: []const u8,
    i: usize = 0,

    pub fn until(self: *Reader, c: u8) []const u8 {
        const ln = self.s.len;
        const start = self.i;
        while (self.i < ln) {
            if (c == self.s[self.i]) return self.s[start..self.i];
            self.i += 1;
        }

        return self.s[start..self.i];
    }

    pub fn tail(self: *Reader) []const u8 {
        if (self.i > self.s.len) return "";
        defer self.i = self.s.len;
        return self.s[self.i..];
    }

    pub fn skip(self: *Reader) bool {
        if (self.i >= self.s.len) return false;
        self.i += 1;
        return true;
    }
};

test "Reader.skip" {
    var r = Reader{ .s = "foo" };
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(r.skip());
    try testing.expect(!r.skip());
    try testing.expect(!r.skip());
}

test "Reader.tail" {
    var r = Reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.tail());
    try testing.expectEqualStrings("", r.tail());
}

test "Reader.until" {
    var r = Reader{ .s = "foo.bar.baz" };
    try testing.expectEqualStrings("foo", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("bar", r.until('.'));
    _ = r.skip();
    try testing.expectEqualStrings("baz", r.until('.'));

    r = Reader{ .s = "foo" };
    try testing.expectEqualStrings("foo", r.until('.'));

    r = Reader{ .s = "" };
    try testing.expectEqualStrings("", r.until('.'));
}

pub fn trim(s: []const u8) []const u8 {
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

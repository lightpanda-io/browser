const std = @import("std");
const testing = std.testing;

const Self = @This();

const MimeError = error{
    Empty,
    TooBig,
    InvalidChar,
    Invalid,
};

mtype: []const u8,
msubtype: []const u8,
params: []const u8,

// https://mimesniff.spec.whatwg.org/#http-token-code-point
fn isHTTPCodePoint(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^' => return true,
        '_', '`', '|', '~' => return true,
        else => std.ascii.isAlphanumeric(c),
    };
}

// https://mimesniff.spec.whatwg.org/#parsing-a-mime-type
// The parser disallows trailing spaces.
pub fn parse(s: []const u8) Self.MimeError!Self {
    const ln = s.len;
    if (ln == 0) return MimeError.Empty;
    // limit input size
    if (ln > 255) return MimeError.TooBig;

    const states = enum { startmtype, mtype, startmsubtype, msubtype, startparams, params };
    var state: states = .startmtype;

    var res = Self{
        .mtype = "",
        .msubtype = "",
        .params = "",
    };

    var i: usize = 0;
    var start: usize = 0;
    while (i < ln) {
        defer i += 1;
        const c = s[i];
        switch (state) {
            .startmtype => {
                // ignore leading spaces
                if (std.ascii.isWhitespace(c)) continue;
                if (!isHTTPCodePoint(c)) return MimeError.InvalidChar;
                state = .mtype;
                start = i;
            },
            .mtype => {
                if (c == '/') {
                    if (start == i - 1) return MimeError.Empty;
                    res.mtype = s[start..i];
                    state = .startmsubtype;
                    continue;
                }
                if (!isHTTPCodePoint(c)) return MimeError.InvalidChar;
            },
            .startmsubtype => {
                // ignore leading spaces
                if (std.ascii.isWhitespace(c)) continue;
                if (!isHTTPCodePoint(c)) return MimeError.InvalidChar;
                state = .msubtype;
                start = i;
            },
            .msubtype => {
                if (c == ';') {
                    if (start == i - 1) return MimeError.Empty;
                    res.msubtype = s[start..i];
                    state = .startparams;
                    continue;
                }
            },
            .startparams => {
                // ignore leading spaces
                if (std.ascii.isWhitespace(c)) continue;
                if (!isHTTPCodePoint(c)) return MimeError.InvalidChar;
                state = .msubtype;
                start = i;
            },
            .params => {
                if (start == i - 1) return MimeError.Empty;
                //TODO parse params
                res.params = s[i..];
            },
        }
    }

    if (state != .msubtype and state != .params) {
        return MimeError.Invalid;
    }

    if (state == .msubtype) {
        if (start == i - 1) return MimeError.Invalid;
        res.msubtype = s[start..i];
    }

    return res;
}

test "parse valid" {
    for ([_][]const u8{
        "text/html",
        "text/javascript1.1",
        "text/plain; charset=UTF-8",
        " \ttext/html",
        "text/ \thtml",
    }) |tc| {
        std.debug.print("case {s}\n", .{tc});
        const m = try Self.parse(tc);
        std.debug.print("res: {s}/{s}\n", .{ m.mtype, m.msubtype });
    }
}

test "parse invalid" {
    for ([_][]const u8{
        "",
        "text/html;",
        "/text/html",
        "/html",
    }) |tc| {
        std.debug.print("case {s}\n", .{tc});
        _ = Self.parse(tc) catch continue;
        try testing.expect(false);
    }
}

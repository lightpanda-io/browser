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
const Allocator = std.mem.Allocator;

pub const Mime = struct {
    content_type: ContentType,
    params: []const u8 = "",
    charset: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub const ContentTypeEnum = enum {
        text_xml,
        text_html,
        text_plain,
        other,
    };

    pub const ContentType = union(ContentTypeEnum) {
        text_xml: void,
        text_html: void,
        text_plain: void,
        other: struct { type: []const u8, sub_type: []const u8 },
    };

    pub fn parse(allocator: Allocator, input: []const u8) !Mime {
        if (input.len > 255) {
            return error.TooBig;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var trimmed = trim(input);

        const content_type, const type_len = try parseContentType(trimmed);
        if (type_len >= trimmed.len) {
            return .{ .arena = arena, .content_type = content_type };
        }

        const params = trimLeft(trimmed[type_len..]);

        var charset: ?[]const u8 = null;

        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |attr| {
            const i = std.mem.indexOfScalarPos(u8, attr, 0, '=') orelse return error.Invalid;
            const name = trimLeft(attr[0..i]);

            const value = trimRight(attr[i + 1 ..]);
            if (value.len == 0) {
                return error.Invalid;
            }

            switch (name.len) {
                7 => if (isCaseEqual("charset", name)) {
                    charset = try parseValue(arena.allocator(), value);
                },
                else => {},
            }
        }

        return .{
            .arena = arena,
            .params = params,
            .charset = charset,
            .content_type = content_type,
        };
    }

    pub fn deinit(self: *Mime) void {
        self.arena.deinit();
    }

    pub fn isHTML(self: *const Mime) bool {
        return self.content_type == .text_html;
    }

    fn parseContentType(value: []const u8) !struct { ContentType, usize } {
        const separator = std.mem.indexOfScalarPos(u8, value, 0, '/') orelse {
            return error.Invalid;
        };
        const end = std.mem.indexOfScalarPos(u8, value, separator, ';') orelse blk: {
            break :blk value.len;
        };

        const main_type = value[0..separator];
        const sub_type = trimRight(value[separator + 1 .. end]);

        if (parseCommonContentType(main_type, sub_type)) |content_type| {
            return .{ content_type, end + 1 };
        }

        if (main_type.len == 0) {
            return error.Invalid;
        }
        if (validType(main_type) == false) {
            return error.Invalid;
        }

        if (sub_type.len == 0) {
            return error.Invalid;
        }
        if (validType(sub_type) == false) {
            return error.Invalid;
        }

        const content_type = ContentType{ .other = .{
            .type = main_type,
            .sub_type = sub_type,
        } };

        return .{ content_type, end + 1 };
    }

    fn parseCommonContentType(main_type: []const u8, sub_type: []const u8) ?ContentType {
        switch (main_type.len) {
            4 => if (isCaseEqual("text", main_type)) {
                switch (sub_type.len) {
                    3 => if (isCaseEqual("xml", sub_type)) {
                        return .{ .text_xml = {} };
                    },
                    4 => if (isCaseEqual("html", sub_type)) {
                        return .{ .text_html = {} };
                    },
                    5 => if (isCaseEqual("plain", sub_type)) {
                        return .{ .text_plain = {} };
                    },
                    else => {},
                }
            },
            else => {},
        }
        return null;
    }

    const T_SPECIAL = blk: {
        var v = [_]bool{false} ** 256;
        for ("()<>@,;:\\\"/[]?=") |b| {
            v[b] = true;
        }
        break :blk v;
    };

    fn parseValue(allocator: Allocator, value: []const u8) ![]const u8 {
        if (value[0] != '"') {
            return value;
        }

        // 1 to skip the opening quote
        var value_pos: usize = 1;
        var unescaped_len: usize = 0;
        const last = value.len - 1;

        while (value_pos < value.len) {
            switch (value[value_pos]) {
                '"' => break,
                '\\' => {
                    if (value_pos == last) {
                        return error.Invalid;
                    }
                    const next = value[value_pos + 1];
                    if (T_SPECIAL[next] == false) {
                        return error.Invalid;
                    }
                    value_pos += 2;
                },
                else => value_pos += 1,
            }
            unescaped_len += 1;
        }

        if (unescaped_len == 0) {
            return error.Invalid;
        }

        value_pos = 1;
        const owned = try allocator.alloc(u8, unescaped_len);
        for (0..unescaped_len) |i| {
            switch (value[value_pos]) {
                '"' => break,
                '\\' => {
                    owned[i] = value[value_pos + 1];
                    value_pos += 2;
                },
                else => |c| {
                    owned[i] = c;
                    value_pos += 1;
                },
            }
        }
        return owned;
    }

    const VALID_CODEPOINTS = blk: {
        var v: [256]bool = undefined;
        for (0..256) |i| {
            v[i] = std.ascii.isAlphanumeric(i);
        }
        for ("!#$%&\\*+-.^'_`|~") |b| {
            v[b] = true;
        }
        break :blk v;
    };

    fn validType(value: []const u8) bool {
        for (value) |b| {
            if (VALID_CODEPOINTS[b] == false) {
                return false;
            }
        }
        return true;
    }

    fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, &std.ascii.whitespace);
    }

    fn trimLeft(s: []const u8) []const u8 {
        return std.mem.trimLeft(u8, s, &std.ascii.whitespace);
    }

    fn trimRight(s: []const u8) []const u8 {
        return std.mem.trimRight(u8, s, &std.ascii.whitespace);
    }

    fn isCaseEqual(comptime target: anytype, value: []const u8) bool {
        // - 8 beause we don't care about the sentinel
        const bit_len = @bitSizeOf(@TypeOf(target.*)) - 8;
        const byte_len = bit_len / 8;

        const T = @Type(.{ .int = .{
            .bits = bit_len,
            .signedness = .unsigned,
        } });

        const bit_target: T = @bitCast(@as(*const [byte_len]u8, target).*);

        if (@as(T, @bitCast(value[0..byte_len].*)) == bit_target) {
            return true;
        }
        return std.ascii.eqlIgnoreCase(value, target);
    }
};

const testing = std.testing;
test "Mime: invalid " {
    const invalids = [_][]const u8{
        "",
        "text",
        "text /html",
        "text/ html",
        "text / html",
        "text/html other",
        "text/html; x",
        "text/html; x=",
        "text/html; x=  ",
        "text/html; = ",
        "text/html;=",
        "text/html; charset=\"\"",
        "text/html; charset=\"",
        "text/html; charset=\"\\",
        "text/html; charset=\"\\a\"", // invalid to escape non special characters
    };

    for (invalids) |invalid| {
        try testing.expectError(error.Invalid, Mime.parse(undefined, invalid));
    }
}

test "Mime: parse common" {
    try expect(.{ .content_type = .{ .text_xml = {} } }, "text/xml");
    try expect(.{ .content_type = .{ .text_html = {} } }, "text/html");
    try expect(.{ .content_type = .{ .text_plain = {} } }, "text/plain");

    try expect(.{ .content_type = .{ .text_xml = {} } }, "text/xml;");
    try expect(.{ .content_type = .{ .text_html = {} } }, "text/html;");
    try expect(.{ .content_type = .{ .text_plain = {} } }, "text/plain;");

    try expect(.{ .content_type = .{ .text_xml = {} } }, "  \ttext/xml");
    try expect(.{ .content_type = .{ .text_html = {} } }, "text/html   ");
    try expect(.{ .content_type = .{ .text_plain = {} } }, "text/plain \t\t");

    try expect(.{ .content_type = .{ .text_xml = {} } }, "TEXT/xml");
    try expect(.{ .content_type = .{ .text_html = {} } }, "text/Html");
    try expect(.{ .content_type = .{ .text_plain = {} } }, "TEXT/PLAIN");

    try expect(.{ .content_type = .{ .text_xml = {} } }, " TeXT/xml");
    try expect(.{ .content_type = .{ .text_html = {} } }, "teXt/HtML  ;");
    try expect(.{ .content_type = .{ .text_plain = {} } }, "tExT/PlAiN;");
}

test "Mime: parse uncommon" {
    const text_javascript = Expectation{
        .content_type = .{ .other = .{ .type = "text", .sub_type = "javascript" } },
    };
    try expect(text_javascript, "text/javascript");
    try expect(text_javascript, "text/javascript;");
    try expect(text_javascript, "  text/javascript\t  ");
    try expect(text_javascript, "  text/javascript\t  ;");

    try expect(
        .{ .content_type = .{ .other = .{ .type = "Text", .sub_type = "Javascript" } } },
        "Text/Javascript",
    );
}

test "Mime: parse charset" {
    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "utf-8",
        .params = "charset=utf-8",
    }, "text/xml; charset=utf-8");

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "utf-8",
        .params = "charset=\"utf-8\"",
    }, "text/xml;charset=\"utf-8\"");

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "\\ \" ",
        .params = "charset=\"\\\\ \\\" \"",
    }, "text/xml;charset=\"\\\\ \\\" \"   ");
}

test "Mime: isHTML" {
    const isHTML = struct {
        fn isHTML(expected: bool, input: []const u8) !void {
            var mime = try Mime.parse(testing.allocator, input);
            defer mime.deinit();
            try testing.expectEqual(expected, mime.isHTML());
        }
    }.isHTML;
    try isHTML(true, "text/html");
    try isHTML(true, "text/html;");
    try isHTML(true, "text/html; charset=utf-8");
    try isHTML(false, "text/htm"); // htm not html
    try isHTML(false, "text/plain");
    try isHTML(false, "over/9000");
}

const Expectation = struct {
    content_type: Mime.ContentType,
    params: []const u8 = "",
    charset: ?[]const u8 = null,
};

fn expect(expected: Expectation, input: []const u8) !void {
    var actual = try Mime.parse(testing.allocator, input);
    defer actual.deinit();

    try testing.expectEqual(
        std.meta.activeTag(expected.content_type),
        std.meta.activeTag(actual.content_type),
    );

    switch (expected.content_type) {
        .other => |e| {
            const a = actual.content_type.other;
            try testing.expectEqualStrings(e.type, a.type);
            try testing.expectEqualStrings(e.sub_type, a.sub_type);
        },
        else => {}, // already asserted above
    }

    try testing.expectEqualStrings(expected.params, actual.params);

    if (expected.charset) |ec| {
        try testing.expectEqualStrings(ec, actual.charset.?);
    } else {
        try testing.expectEqual(null, actual.charset);
    }
}

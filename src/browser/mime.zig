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

    pub const unknown = Mime{
        .params = "",
        .charset = "",
        .content_type = .{ .unknown = {} },
    };

    pub const ContentTypeEnum = enum {
        text_xml,
        text_html,
        text_javascript,
        text_plain,
        unknown,
        other,
    };

    pub const ContentType = union(ContentTypeEnum) {
        text_xml: void,
        text_html: void,
        text_javascript: void,
        text_plain: void,
        unknown: void,
        other: struct { type: []const u8, sub_type: []const u8 },
    };

    pub fn parse(arena: Allocator, input: []u8) !Mime {
        if (input.len > 255) {
            return error.TooBig;
        }

        // Zig's trim API is broken. The return type is always `[]const u8`,
        // even if the input type is `[]u8`. @constCast is safe here.
        var normalized = @constCast(std.mem.trim(u8, input, &std.ascii.whitespace));
        _ = std.ascii.lowerString(normalized, normalized);

        const content_type, const type_len = try parseContentType(normalized);
        if (type_len >= normalized.len) {
            return .{ .content_type = content_type };
        }

        const params = trimLeft(normalized[type_len..]);

        var charset: ?[]const u8 = null;

        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |attr| {
            const i = std.mem.indexOfScalarPos(u8, attr, 0, '=') orelse return error.Invalid;
            const name = trimLeft(attr[0..i]);

            const value = trimRight(attr[i + 1 ..]);
            if (value.len == 0) {
                return error.Invalid;
            }

            const attribute_name = std.meta.stringToEnum(enum {
                charset,
            }, name) orelse continue;

            switch (attribute_name) {
                .charset => charset = try parseAttributeValue(arena, value),
            }
        }

        return .{
            .params = params,
            .charset = charset,
            .content_type = content_type,
        };
    }

    pub fn sniff(body: []const u8) ?Mime {
        // 0x0C is form feed
        const content = std.mem.trimLeft(u8, body, &.{ ' ', '\t', '\n', '\r', 0x0C });
        if (content.len == 0) {
            return null;
        }

        if (content[0] != '<') {
            if (std.mem.startsWith(u8, content, &.{ 0xEF, 0xBB, 0xBF })) {
                // UTF-8 BOM
                return .{ .content_type = .{ .text_plain = {} } };
            }
            if (std.mem.startsWith(u8, content, &.{ 0xFE, 0xFF })) {
                // UTF-16 big-endian BOM
                return .{ .content_type = .{ .text_plain = {} } };
            }
            if (std.mem.startsWith(u8, content, &.{ 0xFF, 0xFE })) {
                // UTF-16 little-endian BOM
                return .{ .content_type = .{ .text_plain = {} } };
            }
            return null;
        }

        // The longest prefix we have is "<!DOCTYPE HTML ", 15 bytes. If we're
        // here, we already know content[0] == '<', so we can skip that. So 14
        // bytes.

        // +1 because we don't need the leading '<'
        var buf: [14]u8 = undefined;

        const stripped = content[1..];
        const prefix_len = @min(stripped.len, buf.len);
        const prefix = std.ascii.lowerString(&buf, stripped[0..prefix_len]);

        // we already know it starts with a <
        const known_prefixes = [_]struct { []const u8, ContentType }{
            .{ "!doctype html", .{ .text_html = {} } },
            .{ "html", .{ .text_html = {} } },
            .{ "script", .{ .text_html = {} } },
            .{ "iframe", .{ .text_html = {} } },
            .{ "h1", .{ .text_html = {} } },
            .{ "div", .{ .text_html = {} } },
            .{ "font", .{ .text_html = {} } },
            .{ "table", .{ .text_html = {} } },
            .{ "a", .{ .text_html = {} } },
            .{ "style", .{ .text_html = {} } },
            .{ "title", .{ .text_html = {} } },
            .{ "b", .{ .text_html = {} } },
            .{ "body", .{ .text_html = {} } },
            .{ "br", .{ .text_html = {} } },
            .{ "p", .{ .text_html = {} } },
            .{ "!--", .{ .text_html = {} } },
            .{ "xml", .{ .text_xml = {} } },
        };
        inline for (known_prefixes) |kp| {
            const known_prefix = kp.@"0";
            if (std.mem.startsWith(u8, prefix, known_prefix) and prefix.len > known_prefix.len) {
                const next = prefix[known_prefix.len];
                // a "tag-terminating-byte"
                if (next == ' ' or next == '>') {
                    return .{ .content_type = kp.@"1" };
                }
            }
        }

        return null;
    }

    pub fn isHTML(self: *const Mime) bool {
        return self.content_type == .text_html;
    }

    // we expect value to be lowercase
    fn parseContentType(value: []const u8) !struct { ContentType, usize } {
        const end = std.mem.indexOfScalarPos(u8, value, 0, ';') orelse value.len;
        const type_name = trimRight(value[0..end]);
        const attribute_start = end + 1;

        if (std.meta.stringToEnum(enum {
            @"text/xml",
            @"text/html",

            @"text/javascript",
            @"application/javascript",
            @"application/x-javascript",

            @"text/plain",
        }, type_name)) |known_type| {
            const ct: ContentType = switch (known_type) {
                .@"text/xml" => .{ .text_xml = {} },
                .@"text/html" => .{ .text_html = {} },
                .@"text/javascript", .@"application/javascript", .@"application/x-javascript" => .{ .text_javascript = {} },
                .@"text/plain" => .{ .text_plain = {} },
            };
            return .{ ct, attribute_start };
        }

        const separator = std.mem.indexOfScalarPos(u8, type_name, 0, '/') orelse return error.Invalid;

        const main_type = value[0..separator];
        const sub_type = trimRight(value[separator + 1 .. end]);

        if (main_type.len == 0 or validType(main_type) == false) {
            return error.Invalid;
        }
        if (sub_type.len == 0 or validType(sub_type) == false) {
            return error.Invalid;
        }

        return .{ .{ .other = .{
            .type = main_type,
            .sub_type = sub_type,
        } }, attribute_start };
    }

    const T_SPECIAL = blk: {
        var v = [_]bool{false} ** 256;
        for ("()<>@,;:\\\"/[]?=") |b| {
            v[b] = true;
        }
        break :blk v;
    };

    fn parseAttributeValue(arena: Allocator, value: []const u8) ![]const u8 {
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
        const owned = try arena.alloc(u8, unescaped_len);
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

    fn trimLeft(s: []const u8) []const u8 {
        return std.mem.trimLeft(u8, s, &std.ascii.whitespace);
    }

    fn trimRight(s: []const u8) []const u8 {
        return std.mem.trimRight(u8, s, &std.ascii.whitespace);
    }
};

const testing = @import("../testing.zig");
test "Mime: invalid " {
    defer testing.reset();

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
        const mutable_input = try testing.arena_allocator.dupe(u8, invalid);
        try testing.expectError(error.Invalid, Mime.parse(undefined, mutable_input));
    }
}

test "Mime: parse common" {
    defer testing.reset();

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

    try expect(.{ .content_type = .{ .text_javascript = {} } }, "text/javascript");
    try expect(.{ .content_type = .{ .text_javascript = {} } }, "Application/JavaScript");
    try expect(.{ .content_type = .{ .text_javascript = {} } }, "application/x-javascript");
}

test "Mime: parse uncommon" {
    defer testing.reset();

    const text_csv = Expectation{
        .content_type = .{ .other = .{ .type = "text", .sub_type = "csv" } },
    };
    try expect(text_csv, "text/csv");
    try expect(text_csv, "text/csv;");
    try expect(text_csv, "  text/csv\t  ");
    try expect(text_csv, "  text/csv\t  ;");

    try expect(
        .{ .content_type = .{ .other = .{ .type = "text", .sub_type = "csv" } } },
        "Text/CSV",
    );
}

test "Mime: parse charset" {
    defer testing.reset();

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
    defer testing.reset();

    const isHTML = struct {
        fn isHTML(expected: bool, input: []const u8) !void {
            const mutable_input = try testing.arena_allocator.dupe(u8, input);
            var mime = try Mime.parse(testing.arena_allocator, mutable_input);
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

test "Mime: sniff" {
    try testing.expectEqual(null, Mime.sniff(""));
    try testing.expectEqual(null, Mime.sniff("<htm"));
    try testing.expectEqual(null, Mime.sniff("<html!"));
    try testing.expectEqual(null, Mime.sniff("<a_"));
    try testing.expectEqual(null, Mime.sniff("<!doctype html"));
    try testing.expectEqual(null, Mime.sniff("<!doctype  html>"));
    try testing.expectEqual(null, Mime.sniff("\n  <!doctype  html>"));
    try testing.expectEqual(null, Mime.sniff("\n \t <font/>"));

    const expectHTML = struct {
        fn expect(input: []const u8) !void {
            try testing.expectEqual(.text_html, std.meta.activeTag(Mime.sniff(input).?.content_type));
        }
    }.expect;

    try expectHTML("<!doctype html ");
    try expectHTML("\n  \t    <!DOCTYPE HTML ");

    try expectHTML("<html ");
    try expectHTML("\n  \t    <HtmL> even more stufff");

    try expectHTML("<script>");
    try expectHTML("\n  \t    <SCRIpt >alert(document.cookies)</script>");

    try expectHTML("<iframe>");
    try expectHTML(" \t    <ifRAME >");

    try expectHTML("<h1>");
    try expectHTML("  <H1>");

    try expectHTML("<div>");
    try expectHTML("\n\r\r  <DiV>");

    try expectHTML("<font>");
    try expectHTML("  <fonT>");

    try expectHTML("<table>");
    try expectHTML("\t\t<TAblE>");

    try expectHTML("<a>");
    try expectHTML("\n\n<A>");

    try expectHTML("<style>");
    try expectHTML("    \n\t <STyLE>");

    try expectHTML("<title>");
    try expectHTML("    \n\t <TITLE>");

    try expectHTML("<b>");
    try expectHTML("    \n\t <B>");

    try expectHTML("<body>");
    try expectHTML("    \n\t <BODY>");

    try expectHTML("<br>");
    try expectHTML("    \n\t <BR>");

    try expectHTML("<p>");
    try expectHTML("    \n\t <P>");

    try expectHTML("<!-->");
    try expectHTML("    \n\t <!-->");
}

const Expectation = struct {
    content_type: Mime.ContentType,
    params: []const u8 = "",
    charset: ?[]const u8 = null,
};

fn expect(expected: Expectation, input: []const u8) !void {
    const mutable_input = try testing.arena_allocator.dupe(u8, input);

    const actual = try Mime.parse(testing.arena_allocator, mutable_input);
    try testing.expectEqual(
        std.meta.activeTag(expected.content_type),
        std.meta.activeTag(actual.content_type),
    );

    switch (expected.content_type) {
        .other => |e| {
            const a = actual.content_type.other;
            try testing.expectEqual(e.type, a.type);
            try testing.expectEqual(e.sub_type, a.sub_type);
        },
        else => {}, // already asserted above
    }

    try testing.expectEqual(expected.params, actual.params);

    if (expected.charset) |ec| {
        try testing.expectEqual(ec, actual.charset.?);
    } else {
        try testing.expectEqual(null, actual.charset);
    }
}

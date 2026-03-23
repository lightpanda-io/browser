// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const Mime = @This();
content_type: ContentType,
params: []const u8 = "",
// IANA defines max. charset value length as 40.
// We keep 41 for null-termination since HTML parser expects in this format.
charset: [41]u8 = default_charset,
charset_len: usize = default_charset_len,
is_default_charset: bool = true,

type_buf: [127]u8 = @splat(0),
sub_type_buf: [127]u8 = @splat(0),

/// String "UTF-8" continued by null characters.
const default_charset = .{ 'U', 'T', 'F', '-', '8' } ++ .{0} ** 36;
const default_charset_len = 5;

/// Mime with unknown Content-Type, empty params and empty charset.
pub const unknown = Mime{ .content_type = .{ .unknown = {} } };

pub const ContentTypeEnum = enum {
    text_xml,
    text_html,
    text_javascript,
    text_plain,
    text_css,
    image_jpeg,
    image_gif,
    image_png,
    image_webp,
    application_json,
    unknown,
    other,
};

pub const ContentType = union(ContentTypeEnum) {
    text_xml: void,
    text_html: void,
    text_javascript: void,
    text_plain: void,
    text_css: void,
    image_jpeg: void,
    image_gif: void,
    image_png: void,
    image_webp: void,
    application_json: void,
    unknown: void,
    other: struct {
        type: []const u8,
        sub_type: []const u8,
    },
};

pub fn contentTypeString(mime: *const Mime) []const u8 {
    return switch (mime.content_type) {
        .text_xml => "text/xml",
        .text_html => "text/html",
        .text_javascript => "application/javascript",
        .text_plain => "text/plain",
        .text_css => "text/css",
        .image_jpeg => "image/jpeg",
        .image_png => "image/png",
        .image_gif => "image/gif",
        .image_webp => "image/webp",
        .application_json => "application/json",
        else => "",
    };
}

/// Returns the null-terminated charset value.
pub fn charsetStringZ(mime: *const Mime) [:0]const u8 {
    return mime.charset[0..mime.charset_len :0];
}

pub fn charsetString(mime: *const Mime) []const u8 {
    return mime.charset[0..mime.charset_len];
}

/// Removes quotes of value if quotes are given.
///
/// Currently we don't validate the charset.
/// See section 2.3 Naming Requirements:
/// https://datatracker.ietf.org/doc/rfc2978/
fn parseCharset(value: []const u8) error{ CharsetTooBig, Invalid }![]const u8 {
    // Cannot be larger than 40.
    // https://datatracker.ietf.org/doc/rfc2978/
    if (value.len > 40) return error.CharsetTooBig;

    // If the first char is a quote, look for a pair.
    if (value[0] == '"') {
        if (value.len < 3 or value[value.len - 1] != '"') {
            return error.Invalid;
        }

        return value[1 .. value.len - 1];
    }

    // No quotes.
    return value;
}

pub fn parse(input: []const u8) !Mime {
    if (input.len > 255) {
        return error.TooBig;
    }

    var buf: [255]u8 = undefined;
    const normalized = std.ascii.lowerString(&buf, std.mem.trim(u8, input, &std.ascii.whitespace));
    _ = std.ascii.lowerString(normalized, normalized);

    var mime = Mime{ .content_type = undefined };

    const content_type, const type_len = try parseContentType(normalized, &mime.type_buf, &mime.sub_type_buf);
    if (type_len >= normalized.len) {
        return .{ .content_type = content_type };
    }

    const params = trimLeft(normalized[type_len..]);

    var charset: [41]u8 = default_charset;
    var charset_len: usize = default_charset_len;
    var has_explicit_charset = false;

    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |attr| {
        const i = std.mem.indexOfScalarPos(u8, attr, 0, '=') orelse continue;
        const name = trimLeft(attr[0..i]);

        const value = trimRight(attr[i + 1 ..]);
        if (value.len == 0) {
            continue;
        }

        const attribute_name = std.meta.stringToEnum(enum {
            charset,
        }, name) orelse continue;

        switch (attribute_name) {
            .charset => {
                if (value.len == 0) {
                    break;
                }

                const attribute_value = parseCharset(value) catch continue;
                @memcpy(charset[0..attribute_value.len], attribute_value);
                // Null-terminate right after attribute value.
                charset[attribute_value.len] = 0;
                charset_len = attribute_value.len;
                has_explicit_charset = true;
            },
        }
    }

    mime.params = params;
    mime.charset = charset;
    mime.charset_len = charset_len;
    mime.content_type = content_type;
    mime.is_default_charset = !has_explicit_charset;
    return mime;
}

/// Prescan the first 1024 bytes of an HTML document for a charset declaration.
/// Looks for `<meta charset="X">` and `<meta http-equiv="Content-Type" content="...;charset=X">`.
/// Returns the charset value or null if none found.
/// See: https://www.w3.org/International/questions/qa-html-encoding-declarations
pub fn prescanCharset(html: []const u8) ?[]const u8 {
    const limit = @min(html.len, 1024);
    const data = html[0..limit];

    // Scan for <meta tags
    var pos: usize = 0;
    while (pos < data.len) {
        // Find next '<'
        pos = std.mem.indexOfScalarPos(u8, data, pos, '<') orelse return null;
        pos += 1;
        if (pos >= data.len) return null;

        // Check for "meta" (case-insensitive)
        if (pos + 4 >= data.len) return null;
        var tag_buf: [4]u8 = undefined;
        _ = std.ascii.lowerString(&tag_buf, data[pos..][0..4]);
        if (!std.mem.eql(u8, &tag_buf, "meta")) {
            continue;
        }
        pos += 4;

        // Must be followed by whitespace or end of tag
        if (pos >= data.len) return null;
        if (data[pos] != ' ' and data[pos] != '\t' and data[pos] != '\n' and
            data[pos] != '\r' and data[pos] != '/')
        {
            continue;
        }

        // Scan attributes within this meta tag
        const tag_end = std.mem.indexOfScalarPos(u8, data, pos, '>') orelse return null;
        const attrs = data[pos..tag_end];

        // Look for charset= attribute directly
        if (findAttrValue(attrs, "charset")) |charset| {
            if (charset.len > 0 and charset.len <= 40) return charset;
        }

        // Look for http-equiv="content-type" with content="...;charset=X"
        if (findAttrValue(attrs, "http-equiv")) |he| {
            if (std.ascii.eqlIgnoreCase(he, "content-type")) {
                if (findAttrValue(attrs, "content")) |content| {
                    if (extractCharsetFromContentType(content)) |charset| {
                        return charset;
                    }
                }
            }
        }

        pos = tag_end + 1;
    }
    return null;
}

fn findAttrValue(attrs: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < attrs.len) {
        // Skip whitespace
        while (pos < attrs.len and (attrs[pos] == ' ' or attrs[pos] == '\t' or
            attrs[pos] == '\n' or attrs[pos] == '\r'))
        {
            pos += 1;
        }
        if (pos >= attrs.len) return null;

        // Read attribute name
        const attr_start = pos;
        while (pos < attrs.len and attrs[pos] != '=' and attrs[pos] != ' ' and
            attrs[pos] != '\t' and attrs[pos] != '>' and attrs[pos] != '/')
        {
            pos += 1;
        }
        const attr_name = attrs[attr_start..pos];

        // Skip whitespace around =
        while (pos < attrs.len and (attrs[pos] == ' ' or attrs[pos] == '\t')) pos += 1;
        if (pos >= attrs.len or attrs[pos] != '=') {
            // No '=' found - skip this token. Advance at least one byte to avoid infinite loop.
            if (pos == attr_start) pos += 1;
            continue;
        }
        pos += 1; // skip '='
        while (pos < attrs.len and (attrs[pos] == ' ' or attrs[pos] == '\t')) pos += 1;
        if (pos >= attrs.len) return null;

        // Read attribute value
        const value = blk: {
            if (attrs[pos] == '"' or attrs[pos] == '\'') {
                const quote = attrs[pos];
                pos += 1;
                const val_start = pos;
                while (pos < attrs.len and attrs[pos] != quote) pos += 1;
                const val = attrs[val_start..pos];
                if (pos < attrs.len) pos += 1; // skip closing quote
                break :blk val;
            } else {
                const val_start = pos;
                while (pos < attrs.len and attrs[pos] != ' ' and attrs[pos] != '\t' and
                    attrs[pos] != '>' and attrs[pos] != '/')
                {
                    pos += 1;
                }
                break :blk attrs[val_start..pos];
            }
        };

        if (std.ascii.eqlIgnoreCase(attr_name, name)) return value;
    }
    return null;
}

fn extractCharsetFromContentType(content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trimLeft(u8, part, &.{ ' ', '\t' });
        if (trimmed.len > 8 and std.ascii.eqlIgnoreCase(trimmed[0..8], "charset=")) {
            const val = std.mem.trim(u8, trimmed[8..], &.{ ' ', '\t', '"', '\'' });
            if (val.len > 0 and val.len <= 40) return val;
        }
    }
    return null;
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
            return .{
                .content_type = .{ .text_plain = {} },
                .charset = default_charset,
                .charset_len = default_charset_len,
                .is_default_charset = false,
            };
        }
        if (std.mem.startsWith(u8, content, &.{ 0xFE, 0xFF })) {
            // UTF-16 big-endian BOM
            return .{
                .content_type = .{ .text_plain = {} },
                .charset = .{ 'U', 'T', 'F', '-', '1', '6', 'B', 'E' } ++ .{0} ** 33,
                .charset_len = 8,
                .is_default_charset = false,
            };
        }
        if (std.mem.startsWith(u8, content, &.{ 0xFF, 0xFE })) {
            // UTF-16 little-endian BOM
            return .{
                .content_type = .{ .text_plain = {} },
                .charset = .{ 'U', 'T', 'F', '-', '1', '6', 'L', 'E' } ++ .{0} ** 33,
                .charset_len = 8,
                .is_default_charset = false,
            };
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

pub fn isText(mime: *const Mime) bool {
    return switch (mime.content_type) {
        .text_xml, .text_html, .text_javascript, .text_plain, .text_css => true,
        .application_json => true,
        else => false,
    };
}

// we expect value to be lowercase
fn parseContentType(value: []const u8, type_buf: []u8, sub_type_buf: []u8) !struct { ContentType, usize } {
    const end = std.mem.indexOfScalarPos(u8, value, 0, ';') orelse value.len;
    const type_name = trimRight(value[0..end]);
    const attribute_start = end + 1;

    if (std.meta.stringToEnum(enum {
        @"text/xml",
        @"text/html",
        @"text/css",
        @"text/plain",

        @"text/javascript",
        @"application/javascript",
        @"application/x-javascript",

        @"image/jpeg",
        @"image/png",
        @"image/gif",
        @"image/webp",

        @"application/json",
    }, type_name)) |known_type| {
        const ct: ContentType = switch (known_type) {
            .@"text/xml" => .{ .text_xml = {} },
            .@"text/html" => .{ .text_html = {} },
            .@"text/javascript", .@"application/javascript", .@"application/x-javascript" => .{ .text_javascript = {} },
            .@"text/plain" => .{ .text_plain = {} },
            .@"text/css" => .{ .text_css = {} },
            .@"image/jpeg" => .{ .image_jpeg = {} },
            .@"image/png" => .{ .image_png = {} },
            .@"image/gif" => .{ .image_gif = {} },
            .@"image/webp" => .{ .image_webp = {} },
            .@"application/json" => .{ .application_json = {} },
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

    @memcpy(type_buf[0..main_type.len], main_type);
    @memcpy(sub_type_buf[0..sub_type.len], sub_type);

    return .{
        .{
            .other = .{
                .type = type_buf[0..main_type.len],
                .sub_type = sub_type_buf[0..sub_type.len],
            },
        },
        attribute_start,
    };
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

pub fn typeString(self: *const Mime) []const u8 {
    return switch (self.content_type) {
        .other => |o| o.type[0..o.type_len],
        else => "",
    };
}

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

const testing = @import("../testing.zig");
test "Mime: invalid" {
    defer testing.reset();

    const invalids = [_][]const u8{
        "",
        "text",
        "text /html",
        "text/ html",
        "text / html",
        "text/html other",
    };

    for (invalids) |invalid| {
        const mutable_input = try testing.arena_allocator.dupe(u8, invalid);
        try testing.expectError(error.Invalid, Mime.parse(mutable_input));
    }
}

test "Mime: malformed parameters are ignored" {
    defer testing.reset();

    // These should all parse successfully as text/html with malformed params ignored
    const valid_with_malformed_params = [_][]const u8{
        "text/html; x",
        "text/html; x=",
        "text/html; x=  ",
        "text/html; = ",
        "text/html;=",
        "text/html; charset=\"\"",
        "text/html; charset=\"",
        "text/html; charset=\"\\",
        "text/html;\"",
    };

    for (valid_with_malformed_params) |input| {
        const mutable_input = try testing.arena_allocator.dupe(u8, input);
        const mime = try Mime.parse(mutable_input);
        try testing.expectEqual(.text_html, std.meta.activeTag(mime.content_type));
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

    try expect(.{ .content_type = .{ .application_json = {} } }, "application/json");
    try expect(.{ .content_type = .{ .text_css = {} } }, "text/css");

    try expect(.{ .content_type = .{ .image_jpeg = {} } }, "image/jpeg");
    try expect(.{ .content_type = .{ .image_png = {} } }, "image/png");
    try expect(.{ .content_type = .{ .image_gif = {} } }, "image/gif");
    try expect(.{ .content_type = .{ .image_webp = {} } }, "image/webp");
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
    }, "text/xml;charset=\"UTF-8\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "iso-8859-1",
        .params = "charset=\"iso-8859-1\"",
    }, "text/html; charset=\"iso-8859-1\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "iso-8859-1",
        .params = "charset=\"iso-8859-1\"",
    }, "text/html; charset=\"ISO-8859-1\"");

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "custom-non-standard-charset-value",
        .params = "charset=\"custom-non-standard-charset-value\"",
    }, "text/xml;charset=\"custom-non-standard-charset-value\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "UTF-8",
        .params = "x=\"",
    }, "text/html;x=\"");
}

test "Mime: isHTML" {
    defer testing.reset();

    const assert = struct {
        fn assert(expected: bool, input: []const u8) !void {
            const mutable_input = try testing.arena_allocator.dupe(u8, input);
            var mime = try Mime.parse(mutable_input);
            try testing.expectEqual(expected, mime.isHTML());
        }
    }.assert;
    try assert(true, "text/html");
    try assert(true, "text/html;");
    try assert(true, "text/html; charset=utf-8");
    try assert(false, "text/htm"); // htm not html
    try assert(false, "text/plain");
    try assert(false, "over/9000");
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

    {
        const mime = Mime.sniff(&.{ 0xEF, 0xBB, 0xBF }).?;
        try testing.expectEqual(.text_plain, std.meta.activeTag(mime.content_type));
        try testing.expectEqual("UTF-8", mime.charsetString());
    }

    {
        const mime = Mime.sniff(&.{ 0xFE, 0xFF }).?;
        try testing.expectEqual(.text_plain, std.meta.activeTag(mime.content_type));
        try testing.expectEqual("UTF-16BE", mime.charsetString());
    }

    {
        const mime = Mime.sniff(&.{ 0xFF, 0xFE }).?;
        try testing.expectEqual(.text_plain, std.meta.activeTag(mime.content_type));
        try testing.expectEqual("UTF-16LE", mime.charsetString());
    }
}

const Expectation = struct {
    content_type: Mime.ContentType,
    params: []const u8 = "",
    charset: ?[]const u8 = null,
};

fn expect(expected: Expectation, input: []const u8) !void {
    const mutable_input = try testing.arena_allocator.dupe(u8, input);

    const actual = try Mime.parse(mutable_input);
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
        // We remove the null characters for testing purposes here.
        try testing.expectEqual(ec, actual.charsetString());
    } else {
        const m: Mime = .unknown;
        try testing.expectEqual(m.charsetStringZ(), actual.charsetStringZ());
    }
}

test "Mime: prescanCharset" {
    // <meta charset="X">
    try testing.expectEqual("utf-8", Mime.prescanCharset("<html><head><meta charset=\"utf-8\">").?);
    try testing.expectEqual("iso-8859-1", Mime.prescanCharset("<html><head><meta charset=\"iso-8859-1\">").?);
    try testing.expectEqual("shift_jis", Mime.prescanCharset("<meta charset='shift_jis'>").?);

    // Case-insensitive tag matching
    try testing.expectEqual("utf-8", Mime.prescanCharset("<META charset=\"utf-8\">").?);
    try testing.expectEqual("utf-8", Mime.prescanCharset("<Meta charset=\"utf-8\">").?);

    // <meta http-equiv="Content-Type" content="text/html; charset=X">
    try testing.expectEqual(
        "iso-8859-1",
        Mime.prescanCharset("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\">").?,
    );

    // No charset found
    try testing.expectEqual(null, Mime.prescanCharset("<html><head><title>Test</title>"));
    try testing.expectEqual(null, Mime.prescanCharset(""));
    try testing.expectEqual(null, Mime.prescanCharset("no html here"));

    // Self-closing meta without charset must not loop forever
    try testing.expectEqual(null, Mime.prescanCharset("<meta foo=\"bar\"/>"));

    // Charset after 1024 bytes should not be found
    var long_html: [1100]u8 = undefined;
    @memset(&long_html, ' ');
    const suffix = "<meta charset=\"windows-1252\">";
    @memcpy(long_html[1050 .. 1050 + suffix.len], suffix);
    try testing.expectEqual(null, Mime.prescanCharset(&long_html));
}

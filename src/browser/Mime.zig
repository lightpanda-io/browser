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
const Allocator = std.mem.Allocator;

const Mime = @This();
content_type: ContentType,
// IANA defines max. charset value length as 40.
// We keep 41 for null-termination since HTML parser expects in this format.
charset: [41]u8 = default_charset,
charset_len: usize = default_charset_len,
is_default_charset: bool = true,

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
    text_markdown,
    text_event_stream,
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
    text_markdown: void,
    text_event_stream: void,
    image_jpeg: void,
    image_gif: void,
    image_png: void,
    image_webp: void,
    application_json: void,
    unknown: void,
    // A valid but unrecognized type/subtype. Keeping it would require some
    // memory management of the input. Nothing needs it right now, so why bother.
    other: void,
};

pub fn contentTypeString(mime: *const Mime) []const u8 {
    return switch (mime.content_type) {
        .text_xml => "text/xml",
        .text_html => "text/html",
        .text_javascript => "application/javascript",
        .text_plain => "text/plain",
        .text_markdown => "text/markdown",
        .text_css => "text/css",
        .text_event_stream => "text/event-stream",
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

pub fn parse(input: []const u8) !Mime {
    if (input.len > 255) {
        return error.TooBig;
    }

    var buf: [255]u8 = undefined;
    const normalized = std.ascii.lowerString(&buf, std.mem.trim(u8, input, &std.ascii.whitespace));

    var mime = Mime{ .content_type = undefined };

    const content_type, const type_len = try parseContentType(normalized);
    if (type_len >= normalized.len) {
        return .{ .content_type = content_type };
    }

    var charset: [41]u8 = default_charset;
    var charset_len: usize = default_charset_len;
    var has_explicit_charset = false;

    // normalized[type_len - 1] is the ';' that terminated the type.
    var value_buf: [40]u8 = undefined;
    if (firstCharsetValue(normalized[type_len - 1 ..], &value_buf)) |value| {
        @memcpy(charset[0..value.len], value);
        charset[value.len] = 0;
        charset_len = value.len;
        has_explicit_charset = true;
    }

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
        .text_xml, .text_html, .text_javascript, .text_plain, .text_css, .text_markdown => true,
        .application_json => true,
        else => false,
    };
}

// we expect value to be lowercase
fn parseContentType(value: []const u8) !struct { ContentType, usize } {
    const end = std.mem.indexOfScalarPos(u8, value, 0, ';') orelse value.len;
    const type_name = trimRight(value[0..end]);
    const attribute_start = end + 1;

    if (std.meta.stringToEnum(enum {
        @"text/xml",
        @"text/html",
        @"text/css",
        @"text/plain",
        @"text/markdown",
        @"text/event-stream",

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
            .@"text/markdown" => .{ .text_markdown = {} },
            .@"text/event-stream" => .{ .text_event_stream = {} },
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

    return .{ .{ .other = {} }, attribute_start };
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

/// Parse `input` as a MIME type and return its serialization, or "" on
/// failure. Unlike `parse` (which classifies a Content-Type for sniffing
/// and only tracks charset), this preserves every parameter.
pub fn serialize(arena: Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, &HTTP_WHITESPACE);
    if (trimmed.len == 0) {
        return "";
    }

    // type "/" subtype
    const slash = std.mem.indexOfScalarPos(u8, trimmed, 0, '/') orelse return "";
    const type_name = trimmed[0..slash];
    if (isHttpToken(type_name) == false) {
        return "";
    }

    var rest = trimmed[slash + 1 ..];
    const subtype_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const subtype = std.mem.trimRight(u8, rest[0..subtype_end], &HTTP_WHITESPACE);
    if (isHttpToken(subtype) == false) {
        return "";
    }

    var out: std.ArrayList(u8) = try .initCapacity(arena, type_name.len + 1 + subtype.len);
    for (type_name) |c| {
        out.appendAssumeCapacity(std.ascii.toLower(c));
    }
    out.appendAssumeCapacity('/');
    for (subtype) |c| {
        out.appendAssumeCapacity(std.ascii.toLower(c));
    }

    if (subtype_end >= rest.len) {
        return out.items;
    }

    rest = rest[subtype_end..]; // positioned at the first ';'

    // The serialized output is the input length plus quoting overhead; reserve
    // the input length so the common (no-escape) case appends without growing.
    try out.ensureTotalCapacity(arena, trimmed.len);

    // Lowercased names already emitted, for first-wins dedupe.
    var seen: std.ArrayList([]const u8) = .empty;
    // One scratch buffer, reused to unescape quoted values across iterations.
    var quoted: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < rest.len) {
        i += 1; // skip ';'
        while (i < rest.len and isHttpWhitespace(rest[i])) i += 1;

        // parameter name: up to ';' or '='
        const name_start = i;
        while (i < rest.len and rest[i] != ';' and rest[i] != '=') i += 1;
        const name = rest[name_start..i];

        if (i >= rest.len) break;
        if (rest[i] == ';') continue;
        i += 1; // skip '='

        // A quoted value is unescaped into `quoted`; an unquoted value is used
        // in place.
        var value: []const u8 = undefined;
        if (i < rest.len and rest[i] == '"') {
            quoted.clearRetainingCapacity();
            i += 1; // opening quote
            while (i < rest.len) : (i += 1) {
                const c = rest[i];
                if (c == '\\') {
                    if (i + 1 < rest.len) {
                        i += 1;
                        try quoted.append(arena, rest[i]);
                    } else {
                        try quoted.append(arena, '\\');
                    }
                } else if (c == '"') {
                    i += 1; // closing quote
                    break;
                } else {
                    try quoted.append(arena, c);
                }
            }
            // ignore any remaining bytes up to the next ';'
            while (i < rest.len and rest[i] != ';') i += 1;
            value = quoted.items;
        } else {
            const value_start = i;
            while (i < rest.len and rest[i] != ';') i += 1;
            value = std.mem.trimRight(u8, rest[value_start..i], &HTTP_WHITESPACE);
            if (value.len == 0) continue; // empty unquoted value is dropped
        }

        if (isHttpToken(name) == false) continue;
        if (isQuotedStringValue(value) == false) continue;

        const lname = try std.ascii.allocLowerString(arena, name);
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, lname)) break;
        } else {
            try seen.append(arena, lname);
            try out.append(arena, ';');
            try out.appendSlice(arena, lname);
            try out.append(arena, '=');
            try appendParameterValue(arena, &out, value);
        }
    }

    return out.items;
}

/// HTTP token code points (RFC 7230 §3.2.6). Note these differ from
/// `VALID_CODEPOINTS` above (which also allows `\`).
const HTTP_TOKEN = blk: {
    var v: [256]bool = undefined;
    for (0..256) |i| {
        v[i] = switch (i) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => std.ascii.isAlphanumeric(@intCast(i)),
        };
    }
    break :blk v;
};

/// Whether `s` is a non-empty sequence of HTTP token code points. This is also
/// the definition of a valid header name, so `Headers` reuses it.
pub fn isHttpToken(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }
    for (s) |b| {
        if (HTTP_TOKEN[b] == false) {
            return false;
        }
    }
    return true;
}

/// Whether every code point in `value` is an "HTTP quoted-string token code
/// point" (HT, 0x20-0x7E, or 0x80-0xFF). Decodes UTF-8 so that a code point
/// above U+00FF (e.g. U+FFFD) is rejected even though its bytes are each >=
/// 0x80 — the algorithm operates on code points, not bytes.
/// https://mimesniff.spec.whatwg.org/#http-quoted-string-token-code-point
fn isQuotedStringValue(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        const n = std.unicode.utf8ByteSequenceLength(value[i]) catch return false;
        if (i + n > value.len) {
            return false;
        }
        const cp = std.unicode.utf8Decode(value[i..][0..n]) catch return false;

        if (!(cp == 0x09 or (cp >= 0x20 and cp <= 0x7E) or (cp >= 0x80 and cp <= 0xFF))) {
            return false;
        }
        i += n;
    }
    return true;
}

/// HTTP whitespace: HT, LF, CR, SP. Deliberately excludes FF (0x0C) and VT
/// (0x0B), both of which `std.ascii.whitespace` includes — neither is HTTP
/// whitespace, so `\x0cx/x` must fail rather than strip to `x/x`.
pub const HTTP_WHITESPACE = [_]u8{ 0x09, 0x0A, 0x0D, 0x20 };

fn isHttpWhitespace(b: u8) bool {
    inline for (HTTP_WHITESPACE) |whitespace| {
        if (b == whitespace) {
            return true;
        }
    }
    return false;
}

/// Append a parameter value, quoting (and escaping `"`/`\`) when it is empty
/// or contains a non-HTTP-token byte.
fn appendParameterValue(arena: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len == 0) {
        return out.appendSlice(arena, "\"\"");
    }

    // The clean prefix (up to the first non-token byte) needs no quoting; if
    // the whole value is tokens, it needs no quotes at all. Neither `"` nor `\`
    // is a token byte, so the prefix can be copied without escaping.
    const quote_from = for (value, 0..) |b, i| {
        if (HTTP_TOKEN[b] == false) break i;
    } else return out.appendSlice(arena, value);

    // Upper bound: two quotes plus, worst case, a '\' escape for every byte.
    try out.ensureUnusedCapacity(arena, 2 * value.len + 2);
    out.appendAssumeCapacity('"');
    out.appendSliceAssumeCapacity(value[0..quote_from]);
    for (value[quote_from..]) |b| {
        if (b == '"' or b == '\\') {
            out.appendAssumeCapacity('\\');
        }
        out.appendAssumeCapacity(b);
    }
    out.appendAssumeCapacity('"');
}

/// Find the value of the first valid `charset` parameter, per the WHATWG MIME
/// parameter algorithm: parameters are scanned in order, quoted strings honor
/// `\` escapes and may contain `;`, and the first parameter whose name is
/// `charset` and whose value is non-empty and contains only HTTP
/// quoted-string token code points wins. The (unescaped) value is written into
/// `out`; values longer than `out` are treated as no match. `rest` must begin
/// at the ';' that ends the subtype, and the input must already be lowercased
/// (names are matched case-sensitively against "charset").
fn firstCharsetValue(rest: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < rest.len) {
        i += 1; // skip ';'
        while (i < rest.len and isHttpWhitespace(rest[i])) {
            i += 1;
        }

        const name_start = i;
        while (i < rest.len and rest[i] != ';' and rest[i] != '=') {
            i += 1;
        }

        if (i >= rest.len) {
            break;
        }
        if (rest[i] == ';') {
            continue;
        }

        const want = std.mem.eql(u8, rest[name_start..i], "charset");
        i += 1; // skip '='

        var len: usize = 0;
        var overflow = false;
        const put = struct {
            fn put(o: []u8, l: *usize, of: *bool, b: u8) void {
                if (l.* < o.len) {
                    o[l.*] = b;
                    l.* += 1;
                } else of.* = true;
            }
        }.put;

        if (i < rest.len and rest[i] == '"') {
            i += 1; // opening quote
            while (i < rest.len) : (i += 1) {
                const c = rest[i];
                if (c == '\\') {
                    if (i + 1 < rest.len) {
                        i += 1;
                        if (want) {
                            put(out, &len, &overflow, rest[i]);
                        }
                    } else if (want) {
                        put(out, &len, &overflow, '\\');
                    }
                } else if (c == '"') {
                    i += 1; // closing quote
                    break;
                } else if (want) {
                    put(out, &len, &overflow, c);
                }
            }
            while (i < rest.len and rest[i] != ';') {
                i += 1;
            }
        } else {
            const value_start = i;
            while (i < rest.len and rest[i] != ';') {
                i += 1;
            }

            const v = std.mem.trimRight(u8, rest[value_start..i], &HTTP_WHITESPACE);
            if (v.len == 0) {
                // empty unquoted value is dropped
                continue;
            }

            if (want) {
                if (v.len <= out.len) {
                    @memcpy(out[0..v.len], v);
                    len = v.len;
                } else overflow = true;
            }
        }

        // First *valid* charset wins; otherwise keep scanning.
        if (want and overflow == false and isQuotedStringValue(out[0..len])) {
            return out[0..len];
        }
    }
    return null;
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
    try expect(.{ .content_type = .{ .text_markdown = {} } }, "text/markdown");

    try expect(.{ .content_type = .{ .image_jpeg = {} } }, "image/jpeg");
    try expect(.{ .content_type = .{ .image_png = {} } }, "image/png");
    try expect(.{ .content_type = .{ .image_gif = {} } }, "image/gif");
    try expect(.{ .content_type = .{ .image_webp = {} } }, "image/webp");
}

test "Mime: parse uncommon" {
    defer testing.reset();

    const text_csv = Expectation{
        .content_type = .{ .other = {} },
    };
    try expect(text_csv, "text/csv");
    try expect(text_csv, "text/csv;");
    try expect(text_csv, "  text/csv\t  ");
    try expect(text_csv, "  text/csv\t  ;");

    try expect(.{ .content_type = .{ .other = {} } }, "Text/CSV");
}

test "Mime: parse charset" {
    defer testing.reset();

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "utf-8",
    }, "text/xml; charset=utf-8");

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "utf-8",
    }, "text/xml;charset=\"UTF-8\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "iso-8859-1",
    }, "text/html; charset=\"iso-8859-1\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "iso-8859-1",
    }, "text/html; charset=\"ISO-8859-1\"");

    try expect(.{
        .content_type = .{ .text_xml = {} },
        .charset = "custom-non-standard-charset-value",
    }, "text/xml;charset=\"custom-non-standard-charset-value\"");

    try expect(.{
        .content_type = .{ .text_html = {} },
        .charset = "UTF-8",
    }, "text/html;x=\"");
}

test "Mime: parse charset (WHATWG parameter semantics)" {
    defer testing.reset();

    // First charset wins (not last).
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "gbk" }, "text/html;charset=gbk;charset=utf-8");

    // Backslash escapes inside a quoted value are unescaped.
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "gbk" }, "text/html;charset=\"\\g\\b\\k\"");

    // A ';' inside a quoted value is part of the value, not a separator.
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "a;b" }, "text/html;charset=\"a;b\";charset=utf-8");

    // A charset whose value isn't all quoted-string tokens (VT here) is
    // skipped, so the next valid charset wins.
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "utf-8" }, "text/html;charset=\x0bgbk;charset=utf-8");

    // A trailing space makes the name "charset " (not "charset"): no charset.
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "UTF-8" }, "text/html;charset =gbk");

    // A long preceding parameter doesn't hide a later charset.
    try expect(.{ .content_type = .{ .text_html = {} }, .charset = "gbk" }, "text/html;" ++ ("a" ** 130) ++ "=x;charset=gbk");
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
    charset: ?[]const u8 = null,
};

fn expect(expected: Expectation, input: []const u8) !void {
    const mutable_input = try testing.arena_allocator.dupe(u8, input);

    const actual = try Mime.parse(mutable_input);
    try testing.expectEqual(
        std.meta.activeTag(expected.content_type),
        std.meta.activeTag(actual.content_type),
    );

    if (expected.charset) |ec| {
        // We remove the null characters for testing purposes here.
        try testing.expectEqual(ec, actual.charsetString());
    } else {
        const m: Mime = .unknown;
        try testing.expectEqual(m.charsetStringZ(), actual.charsetStringZ());
    }
}

test "Mime: serialize" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    const expectSerialize = struct {
        fn call(a: Allocator, input: []const u8, expected: []const u8) !void {
            try testing.expectString(expected, try Mime.serialize(a, input));
        }
    }.call;

    // Essence: lowercased, params preserved verbatim where valid.
    try expectSerialize(arena, "x/x;bonus=x", "x/x;bonus=x");
    try expectSerialize(arena, "TEXT/HTML;CHARSET=GBK", "text/html;charset=GBK");
    try expectSerialize(arena, "text/html;charset=gbk;charset=windows-1255", "text/html;charset=gbk"); // first wins
    try expectSerialize(arena, "text/html;test;charset=gbk", "text/html;charset=gbk"); // valueless param dropped

    // Quoting on serialize.
    try expectSerialize(arena, "text/html;charset=gbk(", "text/html;charset=\"gbk(\"");
    try expectSerialize(arena, "text/html;charset= gbk", "text/html;charset=\" gbk\"");
    try expectSerialize(arena, "text/html;charset=gbk\"", "text/html;charset=\"gbk\\\"\"");
    try expectSerialize(arena, "text/html;charset=\"\\g\\b\\k\"", "text/html;charset=gbk"); // unescape
    try expectSerialize(arena, "text/html;charset=\"\";charset=GBK", "text/html;charset=\"\""); // empty quoted kept

    // Leading/trailing HTTP whitespace (TAB LF CR SP) is stripped; FF/VT are not.
    try expectSerialize(arena, "\n\r\t x/x;x=x \n\r\t ", "x/x;x=x");
    try expectSerialize(arena, "\x0cx/x", ""); // FF is not HTTP whitespace -> invalid type
    try expectSerialize(arena, "x/x\x0c", ""); // FF in subtype -> invalid
    try expectSerialize(arena, "text/html;\x0ccharset=gbk", "text/html"); // FF before name -> dropped

    // A parameter value containing a code point above U+00FF (here U+FFFD) is
    // dropped, even though its UTF-8 bytes are each >= 0x80.
    try expectSerialize(arena, "x/x;test=\u{FFFD};x=x", "x/x;x=x");
    // 0x80-0xFF round-trips (kept, quoted).
    try expectSerialize(arena, "x/x;x=\u{00A1};bonus=x", "x/x;x=\"\u{00A1}\";bonus=x");

    // Total failures.
    try expectSerialize(arena, "", "");
    try expectSerialize(arena, "x", "");
    try expectSerialize(arena, "/x", "");
    try expectSerialize(arena, "x/", "");
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

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
const Io = std.Io;

const Tokenizer = @import("css/Tokenizer.zig");

fn isHexColor(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    if (value[0] != '#') {
        return false;
    }

    const hex_part = value[1..];
    switch (hex_part.len) {
        3, 4, 6, 8 => for (hex_part) |c| if (!std.ascii.isHex(c)) return false,
        else => return false,
    }

    return true;
}

pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    /// Opaque by default.
    a: u8 = std.math.maxInt(u8),

    pub const Named = struct {
        // Basic colors (CSS Level 1)
        pub const black: RGBA = .init(0, 0, 0, 1);
        pub const silver: RGBA = .init(192, 192, 192, 1);
        pub const gray: RGBA = .init(128, 128, 128, 1);
        pub const white: RGBA = .init(255, 255, 255, 1);
        pub const maroon: RGBA = .init(128, 0, 0, 1);
        pub const red: RGBA = .init(255, 0, 0, 1);
        pub const purple: RGBA = .init(128, 0, 128, 1);
        pub const fuchsia: RGBA = .init(255, 0, 255, 1);
        pub const green: RGBA = .init(0, 128, 0, 1);
        pub const lime: RGBA = .init(0, 255, 0, 1);
        pub const olive: RGBA = .init(128, 128, 0, 1);
        pub const yellow: RGBA = .init(255, 255, 0, 1);
        pub const navy: RGBA = .init(0, 0, 128, 1);
        pub const blue: RGBA = .init(0, 0, 255, 1);
        pub const teal: RGBA = .init(0, 128, 128, 1);
        pub const aqua: RGBA = .init(0, 255, 255, 1);

        // Extended colors (CSS Level 2+)
        pub const aliceblue: RGBA = .init(240, 248, 255, 1);
        pub const antiquewhite: RGBA = .init(250, 235, 215, 1);
        pub const aquamarine: RGBA = .init(127, 255, 212, 1);
        pub const azure: RGBA = .init(240, 255, 255, 1);
        pub const beige: RGBA = .init(245, 245, 220, 1);
        pub const bisque: RGBA = .init(255, 228, 196, 1);
        pub const blanchedalmond: RGBA = .init(255, 235, 205, 1);
        pub const blueviolet: RGBA = .init(138, 43, 226, 1);
        pub const brown: RGBA = .init(165, 42, 42, 1);
        pub const burlywood: RGBA = .init(222, 184, 135, 1);
        pub const cadetblue: RGBA = .init(95, 158, 160, 1);
        pub const chartreuse: RGBA = .init(127, 255, 0, 1);
        pub const chocolate: RGBA = .init(210, 105, 30, 1);
        pub const coral: RGBA = .init(255, 127, 80, 1);
        pub const cornflowerblue: RGBA = .init(100, 149, 237, 1);
        pub const cornsilk: RGBA = .init(255, 248, 220, 1);
        pub const crimson: RGBA = .init(220, 20, 60, 1);
        pub const cyan: RGBA = .init(0, 255, 255, 1); // Synonym of aqua
        pub const darkblue: RGBA = .init(0, 0, 139, 1);
        pub const darkcyan: RGBA = .init(0, 139, 139, 1);
        pub const darkgoldenrod: RGBA = .init(184, 134, 11, 1);
        pub const darkgray: RGBA = .init(169, 169, 169, 1);
        pub const darkgreen: RGBA = .init(0, 100, 0, 1);
        pub const darkgrey: RGBA = .init(169, 169, 169, 1); // Synonym of darkgray
        pub const darkkhaki: RGBA = .init(189, 183, 107, 1);
        pub const darkmagenta: RGBA = .init(139, 0, 139, 1);
        pub const darkolivegreen: RGBA = .init(85, 107, 47, 1);
        pub const darkorange: RGBA = .init(255, 140, 0, 1);
        pub const darkorchid: RGBA = .init(153, 50, 204, 1);
        pub const darkred: RGBA = .init(139, 0, 0, 1);
        pub const darksalmon: RGBA = .init(233, 150, 122, 1);
        pub const darkseagreen: RGBA = .init(143, 188, 143, 1);
        pub const darkslateblue: RGBA = .init(72, 61, 139, 1);
        pub const darkslategray: RGBA = .init(47, 79, 79, 1);
        pub const darkslategrey: RGBA = .init(47, 79, 79, 1); // Synonym of darkslategray
        pub const darkturquoise: RGBA = .init(0, 206, 209, 1);
        pub const darkviolet: RGBA = .init(148, 0, 211, 1);
        pub const deeppink: RGBA = .init(255, 20, 147, 1);
        pub const deepskyblue: RGBA = .init(0, 191, 255, 1);
        pub const dimgray: RGBA = .init(105, 105, 105, 1);
        pub const dimgrey: RGBA = .init(105, 105, 105, 1); // Synonym of dimgray
        pub const dodgerblue: RGBA = .init(30, 144, 255, 1);
        pub const firebrick: RGBA = .init(178, 34, 34, 1);
        pub const floralwhite: RGBA = .init(255, 250, 240, 1);
        pub const forestgreen: RGBA = .init(34, 139, 34, 1);
        pub const gainsboro: RGBA = .init(220, 220, 220, 1);
        pub const ghostwhite: RGBA = .init(248, 248, 255, 1);
        pub const gold: RGBA = .init(255, 215, 0, 1);
        pub const goldenrod: RGBA = .init(218, 165, 32, 1);
        pub const greenyellow: RGBA = .init(173, 255, 47, 1);
        pub const grey: RGBA = .init(128, 128, 128, 1); // Synonym of gray
        pub const honeydew: RGBA = .init(240, 255, 240, 1);
        pub const hotpink: RGBA = .init(255, 105, 180, 1);
        pub const indianred: RGBA = .init(205, 92, 92, 1);
        pub const indigo: RGBA = .init(75, 0, 130, 1);
        pub const ivory: RGBA = .init(255, 255, 240, 1);
        pub const khaki: RGBA = .init(240, 230, 140, 1);
        pub const lavender: RGBA = .init(230, 230, 250, 1);
        pub const lavenderblush: RGBA = .init(255, 240, 245, 1);
        pub const lawngreen: RGBA = .init(124, 252, 0, 1);
        pub const lemonchiffon: RGBA = .init(255, 250, 205, 1);
        pub const lightblue: RGBA = .init(173, 216, 230, 1);
        pub const lightcoral: RGBA = .init(240, 128, 128, 1);
        pub const lightcyan: RGBA = .init(224, 255, 255, 1);
        pub const lightgoldenrodyellow: RGBA = .init(250, 250, 210, 1);
        pub const lightgray: RGBA = .init(211, 211, 211, 1);
        pub const lightgreen: RGBA = .init(144, 238, 144, 1);
        pub const lightgrey: RGBA = .init(211, 211, 211, 1); // Synonym of lightgray
        pub const lightpink: RGBA = .init(255, 182, 193, 1);
        pub const lightsalmon: RGBA = .init(255, 160, 122, 1);
        pub const lightseagreen: RGBA = .init(32, 178, 170, 1);
        pub const lightskyblue: RGBA = .init(135, 206, 250, 1);
        pub const lightslategray: RGBA = .init(119, 136, 153, 1);
        pub const lightslategrey: RGBA = .init(119, 136, 153, 1); // Synonym of lightslategray
        pub const lightsteelblue: RGBA = .init(176, 196, 222, 1);
        pub const lightyellow: RGBA = .init(255, 255, 224, 1);
        pub const limegreen: RGBA = .init(50, 205, 50, 1);
        pub const linen: RGBA = .init(250, 240, 230, 1);
        pub const magenta: RGBA = .init(255, 0, 255, 1); // Synonym of fuchsia
        pub const mediumaquamarine: RGBA = .init(102, 205, 170, 1);
        pub const mediumblue: RGBA = .init(0, 0, 205, 1);
        pub const mediumorchid: RGBA = .init(186, 85, 211, 1);
        pub const mediumpurple: RGBA = .init(147, 112, 219, 1);
        pub const mediumseagreen: RGBA = .init(60, 179, 113, 1);
        pub const mediumslateblue: RGBA = .init(123, 104, 238, 1);
        pub const mediumspringgreen: RGBA = .init(0, 250, 154, 1);
        pub const mediumturquoise: RGBA = .init(72, 209, 204, 1);
        pub const mediumvioletred: RGBA = .init(199, 21, 133, 1);
        pub const midnightblue: RGBA = .init(25, 25, 112, 1);
        pub const mintcream: RGBA = .init(245, 255, 250, 1);
        pub const mistyrose: RGBA = .init(255, 228, 225, 1);
        pub const moccasin: RGBA = .init(255, 228, 181, 1);
        pub const navajowhite: RGBA = .init(255, 222, 173, 1);
        pub const oldlace: RGBA = .init(253, 245, 230, 1);
        pub const olivedrab: RGBA = .init(107, 142, 35, 1);
        pub const orange: RGBA = .init(255, 165, 0, 1);
        pub const orangered: RGBA = .init(255, 69, 0, 1);
        pub const orchid: RGBA = .init(218, 112, 214, 1);
        pub const palegoldenrod: RGBA = .init(238, 232, 170, 1);
        pub const palegreen: RGBA = .init(152, 251, 152, 1);
        pub const paleturquoise: RGBA = .init(175, 238, 238, 1);
        pub const palevioletred: RGBA = .init(219, 112, 147, 1);
        pub const papayawhip: RGBA = .init(255, 239, 213, 1);
        pub const peachpuff: RGBA = .init(255, 218, 185, 1);
        pub const peru: RGBA = .init(205, 133, 63, 1);
        pub const pink: RGBA = .init(255, 192, 203, 1);
        pub const plum: RGBA = .init(221, 160, 221, 1);
        pub const powderblue: RGBA = .init(176, 224, 230, 1);
        pub const rebeccapurple: RGBA = .init(102, 51, 153, 1);
        pub const rosybrown: RGBA = .init(188, 143, 143, 1);
        pub const royalblue: RGBA = .init(65, 105, 225, 1);
        pub const saddlebrown: RGBA = .init(139, 69, 19, 1);
        pub const salmon: RGBA = .init(250, 128, 114, 1);
        pub const sandybrown: RGBA = .init(244, 164, 96, 1);
        pub const seagreen: RGBA = .init(46, 139, 87, 1);
        pub const seashell: RGBA = .init(255, 245, 238, 1);
        pub const sienna: RGBA = .init(160, 82, 45, 1);
        pub const skyblue: RGBA = .init(135, 206, 235, 1);
        pub const slateblue: RGBA = .init(106, 90, 205, 1);
        pub const slategray: RGBA = .init(112, 128, 144, 1);
        pub const slategrey: RGBA = .init(112, 128, 144, 1); // Synonym of slategray
        pub const snow: RGBA = .init(255, 250, 250, 1);
        pub const springgreen: RGBA = .init(0, 255, 127, 1);
        pub const steelblue: RGBA = .init(70, 130, 180, 1);
        pub const tan: RGBA = .init(210, 180, 140, 1);
        pub const thistle: RGBA = .init(216, 191, 216, 1);
        pub const tomato: RGBA = .init(255, 99, 71, 1);
        pub const transparent: RGBA = .init(0, 0, 0, 0);
        pub const turquoise: RGBA = .init(64, 224, 208, 1);
        pub const violet: RGBA = .init(238, 130, 238, 1);
        pub const wheat: RGBA = .init(245, 222, 179, 1);
        pub const whitesmoke: RGBA = .init(245, 245, 245, 1);
        pub const yellowgreen: RGBA = .init(154, 205, 50, 1);
    };

    fn init(r: u8, g: u8, b: u8, a: f32) RGBA {
        const clamped = std.math.clamp(a, 0, 1);
        return .{ .r = r, .g = g, .b = b, .a = @trunc(clamped * 255) };
    }

    /// Finds a color by its name.
    fn find(name: []const u8) ?RGBA {
        const match = std.meta.stringToEnum(std.meta.DeclEnum(Named), name) orelse return null;

        return switch (match) {
            inline else => |comptime_enum| @field(Named, @tagName(comptime_enum)),
        };
    }

    /// Parses the given color.
    /// Currently we only parse hex colors and named colors; other variants
    /// require CSS evaluation.
    pub fn parse(input: []const u8) !RGBA {
        if (!isHexColor(input)) {
            // Try named colors.
            return find(input) orelse return error.Invalid;
        }

        const slice = input[1..];
        switch (slice.len) {
            // This means the digit for a color is repeated.
            // Given HEX is #f0c, its interpreted the same as #FF00CC.
            3 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            4 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                const a = try std.fmt.parseInt(u8, &.{ slice[3], slice[3] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            // Regular HEX format.
            6 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            8 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                const a = try std.fmt.parseInt(u8, slice[6..8], 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            else => return error.Invalid,
        }
    }

    /// By default, browsers prefer lowercase formatting.
    const format_upper = false;

    /// Formats the `Color` according to web expectations.
    /// If color is opaque, HEX is preferred; RGBA otherwise.
    pub fn format(self: *const RGBA, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.isOpaque()) {
            // Convert RGB to HEX.
            // https://gristle.tripod.com/hexconv.html
            // Hexadecimal characters up to 15.
            const char: []const u8 = "0123456789" ++ if (format_upper) "ABCDEF" else "abcdef";
            // This variant always prefers 6 digit format, +1 is for hash char.
            const buffer = [7]u8{
                '#',
                char[self.r >> 4],
                char[self.r & 15],
                char[self.g >> 4],
                char[self.g & 15],
                char[self.b >> 4],
                char[self.b & 15],
            };

            return writer.writeAll(&buffer);
        }

        // Prefer RGBA format for everything else.
        return writer.print("rgba({d}, {d}, {d}, {d:.2})", .{ self.r, self.g, self.b, self.normalizedAlpha() });
    }

    /// Returns true if `Color` is opaque.
    inline fn isOpaque(self: *const RGBA) bool {
        return self.a == std.math.maxInt(u8);
    }

    /// Returns the normalized alpha value.
    inline fn normalizedAlpha(self: *const RGBA) f32 {
        return @as(f32, @floatFromInt(self.a)) / 255;
    }
};

// CSS <color> values: parsing and the CSSOM serializations of the sRGB forms
// (named, hex, rgb(), hsl(), hwb()).
// https://drafts.csswg.org/css-color-4/#serializing-sRGB-values

/// What `parse` made of a CSS `<color>` value.
const Parsed = union(enum) {
    invalid,
    // possibly valid, but we don't support it (e.g. lab(), color-mix(), var())
    // written as-is.
    unsupported,
    value: Value,
};

const Value = union(enum) {
    /// A named color or `transparent`.
    named: struct { name: []const u8, rgb: Rgb },

    /// `currentcolor`, a system color or a CSS-wide keyword, lowercased.
    keyword: []const u8,

    rgb: Rgb,

    /// An rgb()/hsl()/hwb() with a `none` component.
    missing: Missing,

    pub fn writeSpecified(self: Value, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .named => |n| try writer.writeAll(n.name),
            .keyword => |k| try writer.writeAll(k),
            .rgb => |rgb| try rgb.writeLegacy(writer),
            .missing => |m| switch (m.function) {
                // Legacy serialization, with none as 0.
                .rgb => try (Rgb{
                    .r = m.channels[0] orelse 0,
                    .g = m.channels[1] orelse 0,
                    .b = m.channels[2] orelse 0,
                    .alpha = m.alpha orelse 0,
                }).writeLegacy(writer),
                .hsl, .hwb => try m.writeModern(writer, ""),
            },
        }
    }

    pub fn writeComputed(self: Value, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .named => |n| try n.rgb.writeLegacy(writer),
            .keyword => |k| try writer.writeAll(k),
            .rgb => |rgb| try rgb.writeLegacy(writer),
            .missing => |m| switch (m.function) {
                // Missing components survive computation, which legacy
                // rgb() can't express.
                .rgb => {
                    try writer.writeAll("color(srgb");
                    for (m.channels) |channel| {
                        try writer.writeByte(' ');
                        try writeComponent(writer, if (channel) |c| c / 255 else null, 8, "");
                    }
                    try m.writeAlpha(writer);
                    try writer.writeByte(')');
                },
                .hsl, .hwb => try m.writeModern(writer, "%"),
            },
        }
    }
};

/// Channels 0-255 and alpha 0-1, both clamped.
const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,
    alpha: f64 = 1,

    fn writeLegacy(self: Rgb, writer: *Io.Writer) Io.Writer.Error!void {
        const r = channelByte(self.r);
        const g = channelByte(self.g);
        const b = channelByte(self.b);
        if (self.alpha == 1) {
            return writer.print("rgb({d}, {d}, {d})", .{ r, g, b });
        }
        try writer.print("rgba({d}, {d}, {d}, ", .{ r, g, b });
        try writeNumber(writer, self.alpha, 6);
        try writer.writeByte(')');
    }

    fn fromRGBA(rgba: RGBA) Rgb {
        return .{
            .r = @floatFromInt(rgba.r),
            .g = @floatFromInt(rgba.g),
            .b = @floatFromInt(rgba.b),
            .alpha = byteAlpha(rgba.a),
        };
    }
};

const Missing = struct {
    function: enum { rgb, hsl, hwb },
    /// rgb: 0-255. hsl/hwb: hue in degrees, then two 0-100 values.
    channels: [3]?f64,
    alpha: ?f64,

    fn writeModern(self: Missing, writer: *Io.Writer, percent: []const u8) Io.Writer.Error!void {
        try writer.writeAll(@tagName(self.function));
        try writer.writeByte('(');
        try writeComponent(writer, self.channels[0], 6, "");
        try writer.writeByte(' ');
        try writeComponent(writer, self.channels[1], 6, percent);
        try writer.writeByte(' ');
        try writeComponent(writer, self.channels[2], 6, percent);
        try self.writeAlpha(writer);
        try writer.writeByte(')');
    }

    fn writeAlpha(self: Missing, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.alpha == 1) return;
        try writer.writeAll(" / ");
        try writeComponent(writer, self.alpha, 6, "");
    }
};

fn writeComponent(writer: *Io.Writer, value: ?f64, decimals: usize, unit: []const u8) Io.Writer.Error!void {
    const v = value orelse return writer.writeAll("none");
    try writeNumber(writer, v, decimals);
    try writer.writeAll(unit);
}

fn writeNumber(writer: *Io.Writer, value: f64, decimals: usize) Io.Writer.Error!void {
    var buf: [400]u8 = undefined;
    var str: []const u8 = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ value, decimals }) catch unreachable;
    if (std.mem.indexOfScalar(u8, str, '.') != null) {
        str = std.mem.trimEnd(u8, std.mem.trimEnd(u8, str, "0"), ".");
    }
    try writer.writeAll(if (std.mem.eql(u8, str, "-0")) "0" else str);
}

fn channelByte(value: f64) u8 {
    // The epsilon keeps a computed exact half (hwb(320 30% 40%)'s blue is
    // 127.5) from rounding down after float error.
    return @intFromFloat(@floor(std.math.clamp(value, 0, 255) + 0.5 + 1e-6));
}

// An 8-bit alpha serializes as the shortest decimal that maps back to the
// same byte: #ffffff80 is rgba(255, 255, 255, 0.5).
fn byteAlpha(a: u8) f64 {
    const byte: f64 = @floatFromInt(a);
    const two = @round(byte / 255 * 100) / 100;
    if (@round(two * 255) == byte) {
        return two;
    }
    return @round(byte / 255 * 1000) / 1000;
}

pub fn parse(input: []const u8) Parsed {
    if (usesSubstitution(input)) {
        return .unsupported;
    }

    var stream: Stream = .{ .tokenizer = .{ .input = input } };
    const token = stream.next() orelse return .invalid;
    const parsed: Parsed = switch (token) {
        .ident => |raw| parseKeyword(raw),
        .id_hash, .unrestricted_hash => |hex| parseHex(hex),
        .function => |raw| parseFunction(raw, &stream),
        else => .invalid,
    };
    if (parsed != .value) {
        return parsed;
    }
    if (stream.next() != null) {
        return .invalid;
    }
    return parsed;
}

const Stream = struct {
    tokenizer: Tokenizer,
    peeked: ?Tokenizer.Token = null,

    fn next(self: *Stream) ?Tokenizer.Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        while (self.tokenizer.next()) |token| {
            switch (token) {
                .white_space, .comment => {},
                else => return token,
            }
        }
        return null;
    }

    fn peek(self: *Stream) ?Tokenizer.Token {
        if (self.peeked == null) {
            self.peeked = self.next();
        }
        return self.peeked;
    }
};

// var() and friends substitute at computed-value time; the value can't be
// checked before then.
fn usesSubstitution(input: []const u8) bool {
    var tokenizer: Tokenizer = .{ .input = input };
    while (tokenizer.next()) |token| {
        const raw = switch (token) {
            .function => |raw| raw,
            else => continue,
        };
        var buf: [8]u8 = undefined;
        const name = lowerName(raw, &buf) orelse continue;
        for ([_][]const u8{ "var", "env", "attr", "if", "inherit" }) |substitution| {
            if (std.mem.eql(u8, name, substitution)) {
                return true;
            }
        }
    }
    return false;
}

/// The ASCII-lowercased ident with escapes decoded, or null when it doesn't
/// fit `buf` or decodes to a non-ASCII code point (no keyword we match has
/// one).
fn lowerName(raw: []const u8, buf: []u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        var c = raw[i];
        i += 1;
        if (c == '\\' and i < raw.len) {
            if (std.ascii.isHex(raw[i])) {
                var code: u32 = 0;
                var digits: usize = 0;
                while (i < raw.len and digits < 6 and std.ascii.isHex(raw[i])) : (digits += 1) {
                    code = code * 16 + (std.fmt.charToDigit(raw[i], 16) catch unreachable);
                    i += 1;
                }
                if (i < raw.len and std.ascii.isWhitespace(raw[i])) {
                    i += 1;
                }
                if (code == 0 or code > 127) {
                    return null;
                }
                c = @intCast(code);
            } else {
                c = raw[i];
                i += 1;
            }
        }
        if (len == buf.len) {
            return null;
        }
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    return buf[0..len];
}

const keywords = [_][]const u8{
    "currentcolor",
    // CSS-wide keywords
    "inherit",
    "initial",
    "unset",
    "revert",
    "revert-layer",
    // System colors
    "accentcolor",
    "accentcolortext",
    "activetext",
    "buttonborder",
    "buttonface",
    "buttontext",
    "canvas",
    "canvastext",
    "field",
    "fieldtext",
    "graytext",
    "highlight",
    "highlighttext",
    "linktext",
    "mark",
    "marktext",
    "selecteditem",
    "selecteditemtext",
    "visitedtext",
    // Deprecated system colors
    "activeborder",
    "activecaption",
    "appworkspace",
    "background",
    "buttonhighlight",
    "buttonshadow",
    "captiontext",
    "inactiveborder",
    "inactivecaption",
    "inactivecaptiontext",
    "infobackground",
    "infotext",
    "menu",
    "menutext",
    "scrollbar",
    "threeddarkshadow",
    "threedface",
    "threedhighlight",
    "threedlightshadow",
    "threedshadow",
    "window",
    "windowframe",
    "windowtext",
};

fn parseKeyword(raw: []const u8) Parsed {
    // Vendor keywords (-webkit-link, ...)
    if (std.mem.startsWith(u8, raw, "-")) return .unsupported;

    var buf: [32]u8 = undefined;
    const name = lowerName(raw, &buf) orelse return .invalid;
    if (std.meta.stringToEnum(std.meta.DeclEnum(RGBA.Named), name)) |match| {
        const rgba = switch (match) {
            inline else => |comptime_enum| @field(RGBA.Named, @tagName(comptime_enum)),
        };
        return .{ .value = .{ .named = .{ .name = @tagName(match), .rgb = .fromRGBA(rgba) } } };
    }
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) {
            return .{ .value = .{ .keyword = keyword } };
        }
    }
    return .invalid;
}

fn parseHex(hex: []const u8) Parsed {
    var buf: [9]u8 = undefined;
    if (hex.len >= buf.len) {
        return .invalid;
    }
    buf[0] = '#';
    @memcpy(buf[1..][0..hex.len], hex);
    const rgba = RGBA.parse(buf[0 .. hex.len + 1]) catch return .invalid;
    return .{ .value = .{ .rgb = .fromRGBA(rgba) } };
}

// Color functions we don't parse but mustn't reject.
const unsupported_functions = [_][]const u8{
    "lab",        "lch",   "oklab",       "oklch",        "color",          "color-mix",
    "light-dark", "alpha", "device-cmyk", "color-layers", "contrast-color",
};

fn parseFunction(raw: []const u8, stream: *Stream) Parsed {
    if (std.mem.startsWith(u8, raw, "-")) {
        return .unsupported;
    }

    var buf: [16]u8 = undefined;
    const name = lowerName(raw, &buf) orelse return .invalid;
    if (std.mem.eql(u8, name, "rgb") or std.mem.eql(u8, name, "rgba")) {
        return parseRgb(stream) catch |err| fromError(err);
    }
    if (std.mem.eql(u8, name, "hsl") or std.mem.eql(u8, name, "hsla")) {
        return parseHslLike(stream, .hsl) catch |err| fromError(err);
    }
    if (std.mem.eql(u8, name, "hwb")) {
        return parseHslLike(stream, .hwb) catch |err| fromError(err);
    }
    for (unsupported_functions) |unsupported| {
        if (std.mem.eql(u8, name, unsupported)) {
            return .unsupported;
        }
    }
    return .invalid;
}

const ParseError = error{ Invalid, Unsupported };

fn fromError(err: ParseError) Parsed {
    return switch (err) {
        error.Invalid => .invalid,
        error.Unsupported => .unsupported,
    };
}

/// A function argument. Percentages are in percent (50% is 50), angles in
/// degrees.
const Component = union(enum) {
    number: f64,
    percent: f64,
    angle: f64,
    none,
};

const Arg = union(enum) {
    comma,
    slash,
    value: Component,
};

/// The arguments of a color function: legacy (comma-separated, no `none`)
/// or modern (space-separated, `/ alpha`).
const Args = struct {
    legacy: bool,
    channels: [3]Component,
    alpha: ?Component,
};

fn readArgs(stream: *Stream) ParseError!Args {
    var buf: [8]Arg = undefined;
    var len: usize = 0;
    while (stream.next()) |token| {
        const arg: Arg = switch (token) {
            .close_parenthesis => break,
            .comma => .comma,
            .delim => |d| if (d == '/') .slash else return error.Invalid,
            .ident => |raw| blk: {
                var name_buf: [8]u8 = undefined;
                const name = lowerName(raw, &name_buf) orelse return error.Invalid;
                if (std.mem.eql(u8, name, "none")) {
                    break :blk .{ .value = .none };
                }
                if (std.mem.eql(u8, name, "from")) {
                    // Relative color syntax
                    return error.Unsupported;
                }
                return error.Invalid;
            },
            .function => |raw| .{ .value = try calcFunction(raw, stream) },
            else => .{ .value = try numeric(token) },
        };
        if (len == buf.len) return error.Invalid;
        buf[len] = arg;
        len += 1;
    }
    // An unclosed function at the end of the input closes there.

    const args = buf[0..len];
    var comma_count: usize = 0;
    for (args) |arg| {
        if (arg == .comma) {
            comma_count += 1;
        }
    }

    if (comma_count > 0) {
        if (len != 5 and len != 7) {
            return error.Invalid;
        }
        var values: [4]Component = undefined;
        for (0..len / 2 + 1) |i| {
            values[i] = switch (args[i * 2]) {
                .value => |v| if (v == .none) return error.Invalid else v,
                else => return error.Invalid,
            };
            if (i * 2 + 1 < len and args[i * 2 + 1] != .comma) {
                return error.Invalid;
            }
        }
        return .{
            .legacy = true,
            .channels = values[0..3].*,
            .alpha = if (len == 7) values[3] else null,
        };
    }

    if (len != 3 and len != 5) {
        return error.Invalid;
    }
    var values: [4]Component = undefined;
    for (args, 0..) |arg, i| {
        if (i == 3) {
            if (arg != .slash) {
                return error.Invalid;
            }
            continue;
        }
        values[if (i == 4) 3 else i] = switch (arg) {
            .value => |v| v,
            else => return error.Invalid,
        };
    }
    return .{
        .legacy = false,
        .channels = values[0..3].*,
        .alpha = if (len == 5) values[3] else null,
    };
}

fn numeric(token: Tokenizer.Token) ParseError!Component {
    switch (token) {
        .number => |n| return .{ .number = widen(n.value) },
        .percentage => |p| return .{
            .percent = if (p.int_value) |int| @floatFromInt(int) else widen(p.unit_value) * 100,
        },
        .dimension => |d| {
            const value = widen(d.value);
            var buf: [8]u8 = undefined;
            const unit = lowerName(d.unit, &buf) orelse return error.Invalid;
            if (std.mem.eql(u8, unit, "deg")) {
                return .{ .angle = value };
            }
            if (std.mem.eql(u8, unit, "grad")) {
                return .{ .angle = value * 0.9 };
            }
            if (std.mem.eql(u8, unit, "rad")) {
                return .{ .angle = std.math.radiansToDegrees(value) };
            }
            if (std.mem.eql(u8, unit, "turn")) {
                return .{ .angle = value * 360 };
            }
            return error.Invalid;
        },
        else => return error.Invalid,
    }
}

// The tokenizer's f32, as the shortest decimal that reads back the same: 0.8
// stays 0.8, not 0.800000011920929.
fn widen(value: f32) f64 {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return value;
    return std.fmt.parseFloat(f64, str) catch value;
}

// A calc() whose operands are all numbers, percentages or angles. Anything
// needing layout (1em, sign(), min()) is left unevaluated.
fn calcFunction(raw: []const u8, stream: *Stream) ParseError!Component {
    var buf: [8]u8 = undefined;
    const name = lowerName(raw, &buf) orelse return error.Unsupported;
    if (std.mem.eql(u8, name, "calc") == false) {
        return error.Unsupported;
    }

    var result = try calcBlock(stream);
    // NaN is censored to zero at the top level of a calculation.
    switch (result) {
        .number, .percent, .angle => |*v| if (std.math.isNan(v.*)) {
            v.* = 0;
        },
        .none => unreachable,
    }
    return result;
}

// A sum, closed by `)` (or the end of the input).
fn calcBlock(stream: *Stream) ParseError!Component {
    const result = try calcSum(stream);
    if (stream.next()) |token| {
        if (token != .close_parenthesis) {
            return error.Invalid;
        }
    }
    return result;
}

fn calcSum(stream: *Stream) ParseError!Component {
    var acc = try calcProduct(stream);
    while (stream.peek()) |token| {
        const op = switch (token) {
            .delim => |d| if (d == '+' or d == '-') d else return acc,
            else => return acc,
        };
        _ = stream.next();
        const rhs = try calcProduct(stream);
        if (std.meta.activeTag(acc) != std.meta.activeTag(rhs)) {
            return error.Invalid;
        }
        const value = if (op == '+') magnitude(acc) + magnitude(rhs) else magnitude(acc) - magnitude(rhs);
        acc = withMagnitude(acc, value);
    }
    return acc;
}

fn calcProduct(stream: *Stream) ParseError!Component {
    var acc = try calcValue(stream);
    while (stream.peek()) |token| {
        const op = switch (token) {
            .delim => |d| if (d == '*' or d == '/') d else return acc,
            else => return acc,
        };
        _ = stream.next();
        const rhs = try calcValue(stream);
        if (op == '*') {
            const value = magnitude(acc) * magnitude(rhs);
            if (acc == .number) {
                acc = withMagnitude(rhs, value);
            } else if (rhs == .number) {
                acc = withMagnitude(acc, value);
            } else {
                return error.Invalid;
            }
        } else {
            if (rhs != .number) return error.Invalid;
            acc = withMagnitude(acc, magnitude(acc) / magnitude(rhs));
        }
    }
    return acc;
}

fn calcValue(stream: *Stream) ParseError!Component {
    const token = stream.next() orelse return error.Invalid;
    switch (token) {
        .parenthesis_block => return calcBlock(stream),
        .function => |raw| {
            var buf: [8]u8 = undefined;
            const name = lowerName(raw, &buf) orelse return error.Unsupported;
            if (std.mem.eql(u8, name, "calc") == false) {
                return error.Unsupported;
            }
            return calcBlock(stream);
        },
        .ident => |raw| {
            var buf: [16]u8 = undefined;
            const name = lowerName(raw, &buf) orelse return error.Invalid;
            const constants = [_]struct { []const u8, f64 }{
                .{ "e", std.math.e },
                .{ "pi", std.math.pi },
                .{ "infinity", std.math.inf(f64) },
                .{ "-infinity", -std.math.inf(f64) },
                .{ "nan", std.math.nan(f64) },
            };
            for (constants) |constant| {
                if (std.mem.eql(u8, name, constant[0])) {
                    return .{ .number = constant[1] };
                }
            }
            return error.Invalid;
        },
        else => return numeric(token),
    }
}

fn magnitude(component: Component) f64 {
    return switch (component) {
        .number, .percent, .angle => |v| v,
        .none => unreachable,
    };
}

fn withMagnitude(component: Component, value: f64) Component {
    return switch (component) {
        .number => .{ .number = value },
        .percent => .{ .percent = value },
        .angle => .{ .angle = value },
        .none => unreachable,
    };
}

fn parseRgb(stream: *Stream) ParseError!Parsed {
    const args = try readArgs(stream);
    if (args.legacy) {
        // Legacy channels are all numbers or all percentages.
        const tag = std.meta.activeTag(args.channels[0]);
        for (args.channels) |channel| {
            if (std.meta.activeTag(channel) != tag) {
                return error.Invalid;
            }
        }
    }

    var channels: [3]?f64 = undefined;
    var missing = false;
    for (args.channels, &channels) |component, *channel| {
        channel.* = switch (component) {
            .number => |n| std.math.clamp(n, 0, 255),
            .percent => |p| std.math.clamp(p / 100 * 255, 0, 255),
            .none => null,
            .angle => return error.Invalid,
        };
        if (channel.* == null) missing = true;
    }
    const alpha = try parseAlpha(args.alpha);
    if (missing or alpha == null) {
        return .{ .value = .{ .missing = .{ .function = .rgb, .channels = channels, .alpha = alpha } } };
    }
    return .{ .value = .{ .rgb = .{ .r = channels[0].?, .g = channels[1].?, .b = channels[2].?, .alpha = alpha.? } } };
}

fn parseAlpha(component: ?Component) ParseError!?f64 {
    return switch (component orelse return 1) {
        .number => |n| std.math.clamp(n, 0, 1),
        .percent => |p| std.math.clamp(p / 100, 0, 1),
        .none => null,
        .angle => error.Invalid,
    };
}

fn parseHslLike(stream: *Stream, function: @FieldType(Missing, "function")) ParseError!Parsed {
    const args = try readArgs(stream);
    if (args.legacy and function == .hwb) {
        return error.Invalid;
    }

    var channels: [3]?f64 = undefined;
    channels[0] = switch (args.channels[0]) {
        // Hue normalization sends infinities to 0 too.
        .number, .angle => |h| if (std.math.isFinite(h)) h else 0,
        .none => null,
        .percent => return error.Invalid,
    };
    for (args.channels[1..], channels[1..]) |component, *channel| {
        channel.* = switch (component) {
            .percent => |p| p,
            // Legacy hsl() only takes percentages.
            .number => |n| if (args.legacy) return error.Invalid else n,
            .none => null,
            .angle => return error.Invalid,
        };
    }
    // Negative saturation clamps to 0 at parse time.
    if (function == .hsl) {
        if (channels[1]) |*s| s.* = @max(s.*, 0);
    }

    const alpha = try parseAlpha(args.alpha);
    const hue = channels[0] orelse return missingValue(function, channels, alpha);
    const second = channels[1] orelse return missingValue(function, channels, alpha);
    const third = channels[2] orelse return missingValue(function, channels, alpha);
    const a = alpha orelse return missingValue(function, channels, alpha);

    const rgb = switch (function) {
        .hsl => hslToRgb(hue, std.math.clamp(second / 100, 0, 1), std.math.clamp(third / 100, 0, 1)),
        .hwb => hwbToRgb(hue, @max(second / 100, 0), @max(third / 100, 0)),
        .rgb => unreachable,
    };
    return .{ .value = .{ .rgb = .{
        .r = std.math.clamp(rgb[0] * 255, 0, 255),
        .g = std.math.clamp(rgb[1] * 255, 0, 255),
        .b = std.math.clamp(rgb[2] * 255, 0, 255),
        .alpha = a,
    } } };
}

fn missingValue(function: @FieldType(Missing, "function"), channels: [3]?f64, alpha: ?f64) Parsed {
    return .{ .value = .{ .missing = .{ .function = function, .channels = channels, .alpha = alpha } } };
}

// https://drafts.csswg.org/css-color-4/#hsl-to-rgb
fn hslToRgb(hue: f64, saturation: f64, lightness: f64) [3]f64 {
    var h = @mod(hue, 360);
    if (h < 0) h += 360;
    const a = saturation * @min(lightness, 1 - lightness);
    var rgb: [3]f64 = undefined;
    for ([_]f64{ 0, 8, 4 }, &rgb) |n, *channel| {
        const k = @mod(n + h / 30, 12);
        channel.* = lightness - a * @max(-1, @min(@min(k - 3, 9 - k), 1));
    }
    return rgb;
}

// https://drafts.csswg.org/css-color-4/#hwb-to-rgb
fn hwbToRgb(hue: f64, white: f64, black: f64) [3]f64 {
    if (white + black >= 1) {
        const gray = white / (white + black);
        return .{ gray, gray, gray };
    }
    var rgb = hslToRgb(hue, 1, 0.5);
    for (&rgb) |*channel| {
        channel.* = channel.* * (1 - white - black) + white;
    }
    return rgb;
}

fn expectSerialized(input: []const u8, specified: ?[]const u8, computed: []const u8) !void {
    const parsed = parse(input);
    if (parsed != .value) {
        std.debug.print("{s}: {t}\n", .{ input, parsed });
        return error.TestUnexpectedResult;
    }
    var buf: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try parsed.value.writeSpecified(&writer);
    try std.testing.expectEqualStrings(specified orelse computed, writer.buffered());
    writer = .fixed(&buf);
    try parsed.value.writeComputed(&writer);
    try std.testing.expectEqualStrings(computed, writer.buffered());
}

test "color: parse and serialize" {
    try expectSerialized("red", "red", "rgb(255, 0, 0)");
    try expectSerialized(" TransParent\n", "transparent", "rgba(0, 0, 0, 0)");
    try expectSerialized("/**/CyAn", "cyan", "rgb(0, 255, 255)");
    try expectSerialized("currentColor", "currentcolor", "currentcolor");
    try expectSerialized("ButtonFace", "buttonface", "buttonface");
    try expectSerialized("#234", null, "rgb(34, 51, 68)");
    try expectSerialized("#FEDCBA", null, "rgb(254, 220, 186)");
    try expectSerialized("#ffffff80", null, "rgba(255, 255, 255, 0.5)");
    try expectSerialized("rgb(-51, 306, 0)", null, "rgb(0, 255, 0)");
    try expectSerialized("rgb(42%, 3%, 50%)", null, "rgb(107, 8, 128)");
    try expectSerialized("rgb(/* R */0, /* G */51, /* B */255)", null, "rgb(0, 51, 255)");
    try expectSerialized("r\\67 b(00, 51, 102)", null, "rgb(0, 51, 102)");
    try expectSerialized("rgba(0, 51, 255, 0.42)", null, "rgba(0, 51, 255, 0.42)");
    try expectSerialized("rgba(0, 51, 255, 37)", null, "rgb(0, 51, 255)");
    try expectSerialized("rgb(250% 51 40%)", null, "rgb(255, 51, 102)");
    try expectSerialized("rgb(0 0 0 / 50%)", null, "rgba(0, 0, 0, 0.5)");
    try expectSerialized("rgb(calc(infinity), 0, 0)", null, "rgb(255, 0, 0)");
    try expectSerialized("rgba(0, 0, 0, calc(0 / 0))", null, "rgba(0, 0, 0, 0)");
    try expectSerialized("rgb(calc(10 + 20 * 2) 0 0)", null, "rgb(50, 0, 0)");
    try expectSerialized("rgb(128 none none)", "rgb(128, 0, 0)", "color(srgb 0.50196078 none none)");
    try expectSerialized("rgb(20% none none / none)", "rgba(51, 0, 0, 0)", "color(srgb 0.2 none none / none)");
    try expectSerialized("hsl(120 30% 50%)", null, "rgb(89, 166, 89)");
    try expectSerialized("hsla(-300, 100%, 37.5%, 0.2)", null, "rgba(191, 191, 0, 0.2)");
    try expectSerialized("hsl(30deg, 100%, 100%)", null, "rgb(255, 255, 255)");
    try expectSerialized("hsl(0.5turn 100% 50%)", null, "rgb(0, 255, 255)");
    try expectSerialized("hsl(0 -50% 40%)", null, "rgb(102, 102, 102)");
    try expectSerialized("hsl(calc(infinity) 100% 50%)", null, "rgb(255, 0, 0)");
    try expectSerialized("hsl(120 80% none)", "hsl(120 80 none)", "hsl(120 80% none)");
    try expectSerialized("hsl(120 100% 50% / none)", "hsl(120 100 50 / none)", "hsl(120 100% 50% / none)");
    try expectSerialized("hwb(320deg 30% 40%)", null, "rgb(153, 77, 128)");
    try expectSerialized("hwb(0 70% 60%)", null, "rgb(137, 137, 137)");
    try expectSerialized("hwb(none none none / none)", null, "hwb(none none none / none)");
}

test "color: invalid and unsupported" {
    const invalid = [_][]const u8{
        "",                          " /* hey */\n",       "4",                 "top",
        "current-Color",             "blac\u{212A}",       "red blue",          "#12",
        "#ffg",                      "#123456789",         "rgb",               "rgb()",
        "rgb(1)",                    "rgb(1,2,3,4,5)",     "rgb(10%, 20, 30%)", "rgb(none, none, none)",
        "rgb(0, 0 0)",               "rgb(0, 0, 0,)",      "rgb(0, 0,, 0)",     "rgb(0, 0, 0deg)",
        "rgb(0, 0, light)",          "rgb(257, 0, 5 / 0)", "hsl(10, 50%, 0)",   "hsl(50%, 50%, 0%)",
        "hsl(0, 50, 30%)",           "hwba(120 30% 50%)",  "hwb(90, 50%, 50%)", "hsl(calc(0.56turn * -0.43turn), 47%, 4884.6%)",
        "rgba(-2, 300, 400%, -0.5)", "foo(1)",
    };
    for (invalid) |input| {
        std.testing.expectEqual(Parsed.invalid, parse(input)) catch |err| {
            std.debug.print("expected invalid: {s}\n", .{input});
            return err;
        };
    }

    const unsupported = [_][]const u8{
        "var(--x)",            "rgb(var(--x), 0, 0)",                               "red var(--x)",
        "lab(50% 20 -30)",     "color-mix(in srgb, red, blue)",                     "light-dark(black, white)",
        "rgb(from red r g b)", "rgb(calc(50% + (sign(1em - 10px) * 10%)), 0%, 0%)", "-webkit-link",
    };
    for (unsupported) |input| {
        std.testing.expectEqual(Parsed.unsupported, parse(input)) catch |err| {
            std.debug.print("expected unsupported: {s}\n", .{input});
            return err;
        };
    }
}

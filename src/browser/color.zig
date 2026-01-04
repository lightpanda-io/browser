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

const isHexColor = @import("webapi/css/CSSStyleDeclaration.zig").isHexColor;

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

    pub fn init(r: u8, g: u8, b: u8, a: f32) RGBA {
        const clamped = std.math.clamp(a, 0, 1);
        return .{ .r = r, .g = g, .b = b, .a = @intFromFloat(clamped * 255) };
    }

    /// Finds a color by its name.
    pub fn find(name: []const u8) ?RGBA {
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
    pub inline fn isOpaque(self: *const RGBA) bool {
        return self.a == std.math.maxInt(u8);
    }

    /// Returns the normalized alpha value.
    pub inline fn normalizedAlpha(self: *const RGBA) f32 {
        return @as(f32, @floatFromInt(self.a)) / 255;
    }
};

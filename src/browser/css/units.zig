// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! Shared lexing and conversion for CSS/SVG dimension values: one suffix
//! table and one set of absolute-length factors. Consumers (svg/Length,
//! svg/Angle, webapi/CSS, StyleManager's font-size resolution) map the
//! result onto their own domain, rejecting units that don't apply.
//!
//! css/MediaQuery keeps its own parser on purpose: MQ4 is fail-closed and
//! deliberately more restrictive than this lenient attribute-value lexer.

const std = @import("std");

pub const Unit = enum {
    none, // bare number, no suffix
    percentage,
    em,
    ex,
    px,
    cm,
    mm,
    in,
    pt,
    pc,
    vh,
    vw,
    deg,
    rad,
    grad,
    turn,
};

pub const Parsed = struct {
    value: f64,
    unit: Unit,
};

const WHITESPACE = " \t\r\n\x0c";

// Longer suffixes first: "5grad" must not match the "rad" entry.
const suffixes = [_]struct { []const u8, Unit }{
    .{ "turn", .turn },
    .{ "grad", .grad },
    .{ "deg", .deg },
    .{ "rad", .rad },
    .{ "%", .percentage },
    .{ "em", .em },
    .{ "ex", .ex },
    .{ "px", .px },
    .{ "cm", .cm },
    .{ "mm", .mm },
    .{ "in", .in },
    .{ "pt", .pt },
    .{ "pc", .pc },
    .{ "vh", .vh },
    .{ "vw", .vw },
};

pub fn parse(input: []const u8) error{SyntaxError}!Parsed {
    const value = std.mem.trim(u8, input, WHITESPACE);
    if (value.len == 0) {
        return error.SyntaxError;
    }

    for (suffixes) |entry| {
        const sfx, const unit = entry;
        if (value.len <= sfx.len) {
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(value[value.len - sfx.len ..], sfx)) {
            continue;
        }
        const number = std.mem.trim(u8, value[0 .. value.len - sfx.len], WHITESPACE);
        return .{ .value = try parseNumber(number), .unit = unit };
    }
    return .{ .value = try parseNumber(value), .unit = .none };
}

fn parseNumber(value: []const u8) !f64 {
    const number = std.fmt.parseFloat(f64, value) catch return error.SyntaxError;
    if (!std.math.isFinite(number)) {
        return error.SyntaxError;
    }
    return number;
}

/// CSS pixels per unit for the absolute length units (CSS Values §6.2,
/// 96px per inch). Null for relative and angle units, which need context.
pub fn absoluteLengthFactor(unit: Unit) ?f64 {
    return switch (unit) {
        .none, .px => 1,
        .cm => 96.0 / 2.54,
        .mm => 96.0 / 25.4,
        .in => 96,
        .pt => 96.0 / 72.0,
        .pc => 16,
        else => null,
    };
}

pub fn suffix(unit: Unit) []const u8 {
    return switch (unit) {
        .none => "",
        .percentage => "%",
        else => @tagName(unit),
    };
}

const testing = @import("../../testing.zig");

test "css units: parse" {
    try testing.expectEqual(Parsed{ .value = 12, .unit = .none }, try parse("12"));
    try testing.expectEqual(Parsed{ .value = -3.5, .unit = .px }, try parse("-3.5px"));
    try testing.expectEqual(Parsed{ .value = 50, .unit = .percentage }, try parse("50%"));
    try testing.expectEqual(Parsed{ .value = 2.54, .unit = .cm }, try parse("2.54cm"));
    try testing.expectEqual(Parsed{ .value = 1.5, .unit = .em }, try parse("1.5EM"));
    try testing.expectEqual(Parsed{ .value = 90, .unit = .deg }, try parse("90deg"));
    try testing.expectEqual(Parsed{ .value = 100, .unit = .grad }, try parse("100grad"));
    try testing.expectEqual(Parsed{ .value = 0.5, .unit = .turn }, try parse("0.5turn"));
    try testing.expectEqual(Parsed{ .value = 50, .unit = .vh }, try parse("50vh"));

    // surrounding whitespace, and the historical leniency between number
    // and suffix, are both accepted
    try testing.expectEqual(Parsed{ .value = 10, .unit = .px }, try parse("  10px "));
    try testing.expectEqual(Parsed{ .value = 10, .unit = .px }, try parse("10 px"));

    try testing.expectError(error.SyntaxError, parse(""));
    try testing.expectError(error.SyntaxError, parse("  "));
    try testing.expectError(error.SyntaxError, parse("px"));
    try testing.expectError(error.SyntaxError, parse("abc"));
    try testing.expectError(error.SyntaxError, parse("10furlong"));
    try testing.expectError(error.SyntaxError, parse("inf"));
    try testing.expectError(error.SyntaxError, parse("nan"));
    try testing.expectError(error.SyntaxError, parse("infpx"));
}

test "css units: absoluteLengthFactor" {
    try testing.expectEqual(1, absoluteLengthFactor(.none).?);
    try testing.expectEqual(1, absoluteLengthFactor(.px).?);
    try testing.expectEqual(96, absoluteLengthFactor(.in).?);
    try testing.expectEqual(16, absoluteLengthFactor(.pc).?);
    try testing.expectEqual(null, absoluteLengthFactor(.percentage));
    try testing.expectEqual(null, absoluteLengthFactor(.em));
    try testing.expectEqual(null, absoluteLengthFactor(.vh));
    try testing.expectEqual(null, absoluteLengthFactor(.deg));
}

test "css units: suffix" {
    try testing.expectEqual("", suffix(.none));
    try testing.expectEqual("%", suffix(.percentage));
    try testing.expectEqual("px", suffix(.px));
    try testing.expectEqual("turn", suffix(.turn));
}

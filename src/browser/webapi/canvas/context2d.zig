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

//! State and behaviour shared by the on-screen and offscreen 2D contexts.

const std = @import("std");

const js = @import("../../js/js.zig");
const text_measure = @import("../../text_measure.zig");
const TextMetrics = @import("TextMetrics.zig");

const Execution = js.Execution;

pub const default_font = "10px sans-serif";

pub const State = struct {
    font: []const u8 = default_font,
    font_size: f64 = 10,
    line_dash: []const f64 = &.{},

    /// Invalid font strings are ignored, per the spec.
    pub fn setFont(self: *State, value: []const u8, exec: *const Execution) !void {
        if (std.mem.eql(u8, value, self.font)) return;
        const size = parseFontSize(value) orelse return;
        self.font = try exec.arena.dupe(u8, value);
        self.font_size = size;
    }

    pub fn measureText(self: *const State, text: []const u8, exec: *const Execution) !*TextMetrics {
        return TextMetrics.init(text_measure.width(text, self.font_size), self.font_size, exec);
    }

    /// Negative or non-finite segments leave the list unchanged; an odd count
    /// is repeated, per the spec.
    pub fn setLineDash(self: *State, segments: []const f64, exec: *const Execution) !void {
        for (segments) |s| {
            if (!(s >= 0) or std.math.isInf(s)) return;
        }
        if (std.mem.eql(f64, segments, self.line_dash)) return;
        if (segments.len % 2 == 0) {
            self.line_dash = try exec.arena.dupe(f64, segments);
            return;
        }
        const doubled = try exec.arena.alloc(f64, segments.len * 2);
        @memcpy(doubled[0..segments.len], segments);
        @memcpy(doubled[segments.len..], segments);
        self.line_dash = doubled;
    }
};

/// The size in px out of a CSS font shorthand, or null when there is none.
fn parseFontSize(font: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, font, " \t\n\r");
    while (it.next()) |raw| {
        // "16px/1.5" carries a line-height.
        const token = raw[0 .. std.mem.indexOfScalar(u8, raw, '/') orelse raw.len];
        const units = [_]struct { suffix: []const u8, px: f64 }{
            .{ .suffix = "px", .px = 1 },
            .{ .suffix = "pt", .px = 4.0 / 3.0 },
            .{ .suffix = "rem", .px = 16 },
            .{ .suffix = "em", .px = 16 },
            .{ .suffix = "%", .px = 0.16 },
        };
        for (units) |unit| {
            if (!std.ascii.endsWithIgnoreCase(token, unit.suffix)) continue;
            const number = std.fmt.parseFloat(f64, token[0 .. token.len - unit.suffix.len]) catch continue;
            if (number < 0 or std.math.isInf(number) or std.math.isNan(number)) return null;
            return number * unit.px;
        }
    }
    return null;
}

const testing = std.testing;
test "context2d: parseFontSize" {
    try testing.expectEqual(10, parseFontSize("10px sans-serif").?);
    try testing.expectEqual(20, parseFontSize("italic bold 20px/1.5 Arial, sans-serif").?);
    try testing.expectEqual(16, parseFontSize("12pt serif").?);
    try testing.expectEqual(24, parseFontSize("1.5em serif").?);
    try testing.expectEqual(null, parseFontSize("bold serif"));
    try testing.expectEqual(null, parseFontSize(""));
}

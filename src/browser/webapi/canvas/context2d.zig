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

//! State and behaviour shared by the on-screen and offscreen 2D contexts.

const std = @import("std");

const js = @import("../../js/js.zig");
const color = @import("../../color.zig");
const text_measure = @import("../../text_measure.zig");
const TextMetrics = @import("TextMetrics.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const CanvasPattern = @import("CanvasPattern.zig");

const Execution = js.Execution;

pub const default_font = "10px sans-serif";

// Chart libraries flip font and dash per label per animation frame, so these
// are stored inline: a page-arena copy per change never comes back. Only a
// value that doesn't fit falls back to the arena. 256 covers the long
// framework font stacks (Bootstrap's is ~200 bytes); 8 covers any real dash
// pattern after the odd-count doubling.
const font_capacity = 256;
const dash_capacity = 8;

/// What fillStyle/strokeStyle hold. Gradients and patterns are never painted,
/// but they round-trip so a script that assigns one reads it back.
pub const Style = union(enum) {
    color: color.RGBA,
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
};

/// Pointer fields first: the bridge probes them for an exact match before
/// falling back to string coercion.
pub const StyleInput = union(enum) {
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
    color: []const u8,
};

pub const StyleOutput = union(enum) {
    color: []const u8,
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
};

pub const State = struct {
    fill_style: Style = .{ .color = color.RGBA.Named.black },
    stroke_style: Style = .{ .color = color.RGBA.Named.black },

    font_size: f64 = 10,
    font_buf: [font_capacity]u8 = default_font.* ++ [_]u8{0} ** (font_capacity - default_font.len),
    font_len: u16 = default_font.len,
    font_overflow: ?[]const u8 = null,

    dash_buf: [dash_capacity]f64 = undefined,
    dash_len: u8 = 0,
    dash_overflow: ?[]const f64 = null,

    pub fn font(self: *const State) []const u8 {
        return self.font_overflow orelse self.font_buf[0..self.font_len];
    }

    /// Invalid font strings are ignored, per the spec.
    pub fn setFont(self: *State, value: []const u8, exec: *const Execution) !void {
        if (std.mem.eql(u8, value, self.font())) return;
        const size = parseFontSize(value) orelse return;
        if (value.len <= font_capacity) {
            @memcpy(self.font_buf[0..value.len], value);
            self.font_len = @intCast(value.len);
            self.font_overflow = null;
        } else {
            self.font_overflow = try exec.arena.dupe(u8, value);
        }
        self.font_size = size;
    }

    pub fn measureText(self: *const State, text: []const u8, exec: *const Execution) !*TextMetrics {
        return TextMetrics.init(text_measure.width(text, self.font_size), self.font_size, exec);
    }

    pub fn lineDash(self: *const State) []const f64 {
        return self.dash_overflow orelse self.dash_buf[0..self.dash_len];
    }

    /// Negative or non-finite segments leave the list unchanged; an odd count
    /// is repeated, per the spec.
    pub fn setLineDash(self: *State, segments: []const f64, exec: *const Execution) !void {
        for (segments) |s| {
            if (!(s >= 0) or std.math.isInf(s)) return;
        }
        if (std.mem.eql(f64, segments, self.lineDash())) return;
        const repeat: usize = if (segments.len % 2 == 0) 1 else 2;
        const len = segments.len * repeat;
        if (len <= dash_capacity) {
            for (0..repeat) |i| @memcpy(self.dash_buf[i * segments.len ..][0..segments.len], segments);
            self.dash_len = @intCast(len);
            self.dash_overflow = null;
            return;
        }
        const dash = try exec.arena.alloc(f64, len);
        for (0..repeat) |i| @memcpy(dash[i * segments.len ..][0..segments.len], segments);
        self.dash_overflow = dash;
    }

    pub fn setStyle(self: *State, comptime field: enum { fill, stroke }, value: StyleInput) void {
        const style: *Style = if (field == .fill) &self.fill_style else &self.stroke_style;
        switch (value) {
            .gradient => |g| style.* = .{ .gradient = g },
            .pattern => |p| style.* = .{ .pattern = p },
            .color => |c| {
                // An unparseable color keeps the current style, per the spec.
                // Parsed into a local on purpose: assigning the literal
                // straight through `style` writes the tag before the payload,
                // so an early return from inside it leaves a `.color` with
                // no colour.
                const parsed = color.RGBA.parse(c) catch return;
                style.* = .{ .color = parsed };
            },
        }
    }

    pub fn getStyle(self: *const State, comptime field: enum { fill, stroke }, exec: *const Execution) !StyleOutput {
        const style = if (field == .fill) self.fill_style else self.stroke_style;
        switch (style) {
            .gradient => |g| return .{ .gradient = g },
            .pattern => |p| return .{ .pattern = p },
            .color => |c| {
                var w = std.Io.Writer.Allocating.init(exec.local_arena);
                try c.format(&w.writer);
                return .{ .color = w.written() };
            },
        }
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

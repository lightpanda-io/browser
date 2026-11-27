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

//! `position-area`: validation and serialization only, layout doesn't read
//! it. https://drafts.csswg.org/css-anchor-position/#position-area

const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");

const Io = std.Io;

const PositionArea = struct {
    first: Keyword,
    second: ?Keyword = null,

    fn writeSpecified(self: PositionArea, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(@tagName(self.first));
        if (self.second) |second| {
            try writer.writeByte(' ');
            try writer.writeAll(@tagName(second));
        }
    }

    // The specified form is already canonical; only the logical keywords
    // change: a pair or one beside center takes its short form (block-start
    // → start), an ambiguous one beside span-all names its axis.
    fn writeComputed(self: PositionArea, writer: *Io.Writer) Io.Writer.Error!void {
        const second = self.second orelse return writer.writeAll(@tagName(self.first));
        const a = self.first.axis();
        const b = second.axis();

        if (b == .span_all and a.isAmbiguous()) {
            return writeLong(writer, self.first, "block-");
        }
        if (a == .span_all and b.isAmbiguous()) {
            return writeLong(writer, second, "inline-");
        }
        if ((a == .block and b == .inline_) or (a == .self_block and b == .self_inline)) {
            const short_first = shortName(self.first);
            const short_second = shortName(second);
            try writer.writeAll(short_first);
            if (std.mem.eql(u8, short_first, short_second) == false) {
                try writer.writeByte(' ');
                try writer.writeAll(short_second);
            }
            return;
        }
        if ((a == .block or a == .self_block) and b == .center) {
            return writer.print("{s} center", .{shortName(self.first)});
        }
        if (a == .center and (b == .inline_ or b == .self_inline)) {
            return writer.print("center {s}", .{shortName(second)});
        }
        return self.writeSpecified(writer);
    }
};

const Axis = enum {
    x,
    y,
    block,
    inline_,
    self_block,
    self_inline,
    // start/end: the block axis when first, the inline one when second
    ambiguous,
    self_ambiguous,
    center,
    span_all,

    fn isAmbiguous(self: Axis) bool {
        return self == .ambiguous or self == .self_ambiguous;
    }

    // The one written first in a canonical pair
    fn isFirst(self: Axis) bool {
        return self == .x or self == .block or self == .self_block;
    }
};

const Keyword = enum {
    left,
    right,
    @"span-left",
    @"span-right",
    @"x-start",
    @"x-end",
    @"span-x-start",
    @"span-x-end",
    @"self-x-start",
    @"self-x-end",
    @"span-self-x-start",
    @"span-self-x-end",
    top,
    bottom,
    @"span-top",
    @"span-bottom",
    @"y-start",
    @"y-end",
    @"span-y-start",
    @"span-y-end",
    @"self-y-start",
    @"self-y-end",
    @"span-self-y-start",
    @"span-self-y-end",
    @"block-start",
    @"block-end",
    @"span-block-start",
    @"span-block-end",
    @"inline-start",
    @"inline-end",
    @"span-inline-start",
    @"span-inline-end",
    @"self-block-start",
    @"self-block-end",
    @"span-self-block-start",
    @"span-self-block-end",
    @"self-inline-start",
    @"self-inline-end",
    @"span-self-inline-start",
    @"span-self-inline-end",
    start,
    end,
    @"span-start",
    @"span-end",
    @"self-start",
    @"self-end",
    @"span-self-start",
    @"span-self-end",
    center,
    @"span-all",

    const map = std.StaticStringMapWithEql(Keyword, std.static_string_map.eqlAsciiIgnoreCase).initComptime(blk: {
        const keywords = std.enums.values(Keyword);
        var entries: [keywords.len]struct { []const u8, Keyword } = undefined;
        for (keywords, 0..) |keyword, i| {
            entries[i] = .{ @tagName(keyword), keyword };
        }
        break :blk entries;
    });

    fn axis(self: Keyword) Axis {
        return switch (self) {
            .left, .right, .@"span-left", .@"span-right", .@"x-start", .@"x-end", .@"span-x-start", .@"span-x-end", .@"self-x-start", .@"self-x-end", .@"span-self-x-start", .@"span-self-x-end" => .x,
            .top, .bottom, .@"span-top", .@"span-bottom", .@"y-start", .@"y-end", .@"span-y-start", .@"span-y-end", .@"self-y-start", .@"self-y-end", .@"span-self-y-start", .@"span-self-y-end" => .y,
            .@"block-start", .@"block-end", .@"span-block-start", .@"span-block-end" => .block,
            .@"inline-start", .@"inline-end", .@"span-inline-start", .@"span-inline-end" => .inline_,
            .@"self-block-start", .@"self-block-end", .@"span-self-block-start", .@"span-self-block-end" => .self_block,
            .@"self-inline-start", .@"self-inline-end", .@"span-self-inline-start", .@"span-self-inline-end" => .self_inline,
            .start, .end, .@"span-start", .@"span-end" => .ambiguous,
            .@"self-start", .@"self-end", .@"span-self-start", .@"span-self-end" => .self_ambiguous,
            .center => .center,
            .@"span-all" => .span_all,
        };
    }
};

// block-start → start, span-self-inline-end → span-self-end
fn shortName(keyword: Keyword) []const u8 {
    const short = comptime blk: {
        @setEvalBranchQuota(10_000);
        const keywords = std.enums.values(Keyword);
        var names: [keywords.len][]const u8 = undefined;
        for (keywords, 0..) |keyword_, i| {
            const n = @tagName(keyword_);
            names[i] = for ([_][]const u8{ "block-", "inline-" }) |axis_name| {
                if (std.mem.find(u8, n, axis_name)) |at| {
                    break n[0..at] ++ n[at + axis_name.len ..];
                }
            } else n;
        }
        break :blk names;
    };
    return short[@backingInt(keyword)];
}

// span-self-start → span-self-block-start
fn writeLong(writer: *Io.Writer, keyword: Keyword, axis_name: []const u8) Io.Writer.Error!void {
    const name = @tagName(keyword);
    const dash = if (std.mem.findScalarLast(u8, name, '-')) |i| i + 1 else 0;
    try writer.print("{s}{s}{s}", .{ name[0..dash], axis_name, name[dash..] });
}

fn parse(input: []const u8) ?PositionArea {
    var keywords: [2]Keyword = undefined;
    var count: usize = 0;
    var tokenizer: Tokenizer = .{ .input = input };
    while (tokenizer.next()) |token| {
        switch (token) {
            .white_space, .comment => continue,
            .ident => |name| {
                if (count == keywords.len) {
                    return null;
                }
                keywords[count] = Keyword.map.get(name) orelse return null;
                count += 1;
            },
            else => return null,
        }
    }
    return switch (count) {
        1 => .{ .first = keywords[0] },
        2 => pair(keywords[0], keywords[1]),
        else => null,
    };
}

fn pair(a: Keyword, b: Keyword) ?PositionArea {
    const axis_a = a.axis();
    const axis_b = b.axis();

    if (a == b) {
        return switch (axis_a) {
            .ambiguous, .self_ambiguous, .center, .span_all => .{ .first = a },
            else => null,
        };
    }

    const neutral_a = axis_a == .center or axis_a == .span_all;
    const neutral_b = axis_b == .center or axis_b == .span_all;
    if (neutral_a and neutral_b) {
        return .{ .first = a, .second = b };
    }
    if (neutral_a or neutral_b) {
        const keyword, const axis, const neutral = if (neutral_a) .{ b, axis_b, a } else .{ a, axis_a, b };
        if (axis.isAmbiguous()) {
            return .{ .first = a, .second = b };
        }
        if (neutral == .@"span-all") {
            return .{ .first = keyword };
        }
        return if (axis.isFirst()) .{ .first = keyword, .second = .center } else .{ .first = .center, .second = keyword };
    }

    if (axis_a.isAmbiguous() or axis_b.isAmbiguous()) {
        return if (axis_a == axis_b) .{ .first = a, .second = b } else null;
    }

    const first, const second = if (axis_a.isFirst()) .{ a, b } else .{ b, a };
    const valid = switch (first.axis()) {
        .x => second.axis() == .y,
        .block => second.axis() == .inline_,
        .self_block => second.axis() == .self_inline,
        else => false,
    };
    return if (valid) .{ .first = first, .second = second } else null;
}

/// The specified form of a valid value, written to `writer`, or false when
/// it isn't one. `none` stands alone.
pub fn writeSpecified(input: []const u8, writer: *Io.Writer) Io.Writer.Error!bool {
    if (isNone(input)) {
        try writer.writeAll("none");
        return true;
    }
    const value = parse(input) orelse return false;
    try value.writeSpecified(writer);
    return true;
}

/// The computed form of a specified value; one that doesn't parse is
/// written as it is.
pub fn writeComputed(specified: []const u8, writer: *Io.Writer) Io.Writer.Error!void {
    const value = parse(specified) orelse return writer.writeAll(specified);
    return value.writeComputed(writer);
}

fn isNone(input: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, input, &std.ascii.whitespace), "none");
}

const testing = @import("../../testing.zig");
test "position_area: valid" {
    try expectSerialized("none", null, null);
    try expectSerialized("center center", "center", null);
    try expectSerialized("span-all span-all", "span-all", null);
    try expectSerialized("span-all center", null, null);
    try expectSerialized("LEFT  /**/ Top", "left top", null);
    try expectSerialized("top left", "left top", null);
    try expectSerialized("span-right span-all", "span-right", null);
    try expectSerialized("center left", "left center", null);
    try expectSerialized("top center", "center top", null);
    try expectSerialized("inline-start block-end", "block-end inline-start", "end start");
    try expectSerialized("block-start inline-start", null, "start");
    try expectSerialized("span-self-inline-end span-self-block-start", "span-self-block-start span-self-inline-end", "span-self-start span-self-end");
    try expectSerialized("span-all block-start", "block-start", null);
    try expectSerialized("center block-end", "block-end center", "end center");
    try expectSerialized("span-inline-end center", "center span-inline-end", "center span-end");
    try expectSerialized("start start", "start", null);
    try expectSerialized("end span-start", null, null);
    try expectSerialized("self-start span-self-end", null, null);
    try expectSerialized("start span-all", null, "block-start");
    try expectSerialized("span-all span-self-end", null, "span-self-inline-end");
    try expectSerialized("center start", null, null);
    try expectSerialized("self-end center", null, null);
}

test "position_area: invalid" {
    const invalid = [_][]const u8{
        "",                      "none none",            "start none",       "none start",
        "top left top",          "left left",            "left right",       "left inline-start",
        "top start",             "block-start self-end", "start self-start", "inline-start self-block-end",
        "block-start block-end", "foobar",               "start foobar",     "hidden inline-end",
        "left, top",             "left 1px",
    };
    for (invalid) |input| {
        var buf: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        std.testing.expect(try writeSpecified(input, &writer) == false) catch |err| {
            std.debug.print("expected invalid: {s}\n", .{input});
            return err;
        };
    }
}

fn expectSerialized(input: []const u8, specified: ?[]const u8, computed: ?[]const u8) !void {
    var buf: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    if (try writeSpecified(input, &writer) == false) {
        std.debug.print("expected valid: {s}\n", .{input});
        return error.TestUnexpectedResult;
    }
    const expected_specified = specified orelse input;
    try testing.expectEqual(expected_specified, writer.buffered());

    var computed_buf: [64]u8 = undefined;
    var computed_writer: Io.Writer = .fixed(&computed_buf);
    try writeComputed(expected_specified, &computed_writer);
    try testing.expectEqual(computed orelse expected_specified, computed_writer.buffered());
}

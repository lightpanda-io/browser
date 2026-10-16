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

// The WebVTT parser algorithm: https://w3c.github.io/webvtt/#file-parsing
// Turns a decoded .vtt file into VTTCues (and the VTTRegions they reference).

const std = @import("std");

const Frame = @import("../../Frame.zig");
const VTTCue = @import("VTTCue.zig");
const VTTRegion = @import("VTTRegion.zig");
const cue_text = @import("cue_text.zig");

const Allocator = std.mem.Allocator;

// space, tab, LF, FF, CR
const whitespace = " \t\n\x0C\r";

// Returns null when the file isn't WebVTT (no signature): the track fails to
// load. A valid file can have no cues.
pub fn parse(arena: Allocator, raw: []const u8, frame: *Frame) !?[]*VTTCue {
    const input = try preprocess(arena, raw);

    if (std.mem.startsWith(u8, input, "WEBVTT") == false) {
        return null;
    }
    if (input.len > 6) {
        switch (input[6]) {
            ' ', '\t', '\n' => {},
            else => return null,
        }
    }

    var parser: Parser = .{ .input = input, .arena = arena, .frame = frame };

    // the rest of the signature line
    _ = parser.collectLine();
    if (parser.atEnd()) {
        return parser.cues.items;
    }
    parser.pos += 1;
    if (parser.atEnd()) {
        return parser.cues.items;
    }

    // the header: anything up to the first blank line
    if (input[parser.pos] != '\n') {
        _ = try parser.collectBlock(true);
    } else {
        parser.pos += 1;
    }
    parser.skipNewlines();

    while (parser.atEnd() == false) {
        switch (try parser.collectBlock(false)) {
            .none => {},
            .cue => |cue| try parser.cues.append(arena, cue),
            .region => |region| {
                // a later definition replaces an earlier one with the same id
                var i: usize = 0;
                while (i < parser.regions.items.len) {
                    if (std.mem.eql(u8, parser.regions.items[i]._id, region._id)) {
                        _ = parser.regions.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
                try parser.regions.append(arena, region);
            },
        }
        parser.skipNewlines();
    }

    return parser.cues.items;
}

// UTF-8 decode (BOM stripped, invalid sequences replaced) and then the
// WebVTT preprocessing: NUL becomes U+FFFD, CRLF and CR become LF.
fn preprocess(arena: Allocator, raw: []const u8) ![]const u8 {
    const replacement = "\u{FFFD}";

    var input = raw;
    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
        input = input[3..];
    }

    var out: std.ArrayList(u8) = try .initCapacity(arena, input.len);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        switch (c) {
            0 => {
                try out.appendSlice(arena, replacement);
                i += 1;
            },
            '\r' => {
                try out.append(arena, '\n');
                i += 1;
                if (i < input.len and input[i] == '\n') {
                    i += 1;
                }
            },
            0x01...0x0C, 0x0E...0x7F => {
                try out.append(arena, c);
                i += 1;
            },
            else => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
                if (len == 0 or i + len > input.len or std.unicode.utf8ValidateSlice(input[i .. i + len]) == false) {
                    try out.appendSlice(arena, replacement);
                    i += 1;
                } else {
                    try out.appendSlice(arena, input[i .. i + len]);
                    i += len;
                }
            },
        }
    }
    return out.items;
}

const Block = union(enum) {
    none,
    cue: *VTTCue,
    region: *VTTRegion,
};

const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    arena: Allocator,
    frame: *Frame,
    seen_cue: bool = false,
    cues: std.ArrayList(*VTTCue) = .empty,
    regions: std.ArrayList(*VTTRegion) = .empty,

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.input.len;
    }

    fn collectLine(self: *Parser) []const u8 {
        const start = self.pos;
        const end = std.mem.findScalarPos(u8, self.input, start, '\n') orelse self.input.len;
        self.pos = end;
        return self.input[start..end];
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        }
    }

    fn collectBlock(self: *Parser, in_header: bool) !Block {
        const arena = self.arena;
        const frame = self.frame;

        var line_count: usize = 0;
        var previous_position = self.pos;
        var buffer: std.ArrayList(u8) = .empty;
        var seen_arrow = false;
        var cue: ?*VTTCue = null;
        var is_stylesheet = false;
        var is_region = false;

        while (true) {
            const line = self.collectLine();
            line_count += 1;

            const seen_eof = self.atEnd();
            if (seen_eof == false) {
                self.pos += 1;
            }

            if (std.mem.find(u8, line, "-->") != null) {
                if (in_header == false and (line_count == 1 or (line_count == 2 and seen_arrow == false))) {
                    seen_arrow = true;
                    previous_position = self.pos;
                    cue = try self.parseCueTimingsAndSettings(line, buffer.items);
                    if (cue != null) {
                        buffer.clearRetainingCapacity();
                        self.seen_cue = true;
                    }
                } else {
                    self.pos = previous_position;
                    break;
                }
            } else if (line.len == 0) {
                break;
            } else {
                if (in_header == false and line_count == 2 and self.seen_cue == false) {
                    if (isBlockHeader(buffer.items, "STYLE")) {
                        is_stylesheet = true;
                        buffer.clearRetainingCapacity();
                    } else if (isBlockHeader(buffer.items, "REGION")) {
                        is_region = true;
                        buffer.clearRetainingCapacity();
                    }
                }
                if (buffer.items.len > 0) {
                    try buffer.append(arena, '\n');
                }
                try buffer.appendSlice(arena, line);
                previous_position = self.pos;
            }

            if (seen_eof) {
                break;
            }
        }

        if (cue) |c| {
            c._text = try frame.dupeString(buffer.items);
            return .{ .cue = c };
        }
        if (is_stylesheet) {
            // nothing renders cues, so their stylesheets have no use
            return .none;
        }
        if (is_region) {
            return .{ .region = try parseRegion(buffer.items, frame) };
        }
        return .none;
    }

    // "collect WebVTT cue timings and settings"
    fn parseCueTimingsAndSettings(self: *Parser, line: []const u8, id: []const u8) !?*VTTCue {
        var pos: usize = 0;
        skipWhitespace(line, &pos);
        const start = cue_text.collectTimestamp(line, &pos) orelse return null;

        skipWhitespace(line, &pos);
        if (std.mem.startsWith(u8, line[pos..], "-->") == false) {
            return null;
        }
        pos += 3;

        skipWhitespace(line, &pos);
        const end = cue_text.collectTimestamp(line, &pos) orelse return null;

        const frame = self.frame;
        const cue = try VTTCue.init(toSeconds(start), toSeconds(end), "", frame);
        cue.asCue()._id = try frame.dupeString(id);
        self.parseCueSettings(cue, line[pos..]);
        return cue;
    }

    fn parseCueSettings(self: *const Parser, cue: *VTTCue, settings: []const u8) void {
        var it = std.mem.tokenizeAny(u8, settings, whitespace);
        while (it.next()) |setting| {
            const colon = std.mem.findScalar(u8, setting, ':') orelse continue;
            if (colon == 0 or colon == setting.len - 1) {
                continue;
            }
            const name = setting[0..colon];
            const value = setting[colon + 1 ..];

            if (std.mem.eql(u8, name, "region")) {
                cue._region = null;
                var i = self.regions.items.len;
                while (i > 0) {
                    i -= 1;
                    const region = self.regions.items[i];
                    if (std.mem.eql(u8, region._id, value)) {
                        cue._region = region;
                        break;
                    }
                }
            } else if (std.mem.eql(u8, name, "vertical")) {
                if (std.mem.eql(u8, value, "rl")) {
                    cue._vertical = .rl;
                } else if (std.mem.eql(u8, value, "lr")) {
                    cue._vertical = .lr;
                }
            } else if (std.mem.eql(u8, name, "line")) {
                parseLineSetting(cue, value);
            } else if (std.mem.eql(u8, name, "position")) {
                parsePositionSetting(cue, value);
            } else if (std.mem.eql(u8, name, "size")) {
                if (parsePercentage(value)) |size| {
                    cue._size = size;
                }
            } else if (std.mem.eql(u8, name, "align")) {
                if (std.meta.stringToEnum(VTTCue.Align, value)) |a| {
                    cue._align = a;
                }
            }
        }
    }
};

fn toSeconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000;
}

fn skipWhitespace(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and std.mem.findScalar(u8, whitespace, input[pos.*]) != null) {
        pos.* += 1;
    }
}

// /^STYLE[ \t]*$/ and /^REGION[ \t]*$/
fn isBlockHeader(buffer: []const u8, comptime keyword: []const u8) bool {
    if (std.mem.startsWith(u8, buffer, keyword) == false) {
        return false;
    }
    for (buffer[keyword.len..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn parseLineSetting(cue: *VTTCue, value: []const u8) void {
    var linepos = value;
    var linealign: ?[]const u8 = null;
    if (std.mem.findScalar(u8, value, ',')) |comma| {
        linepos = value[0..comma];
        linealign = value[comma + 1 ..];
    }

    if (std.mem.indexOfAny(u8, linepos, "0123456789") == null) {
        return;
    }

    const is_percentage = linepos[linepos.len - 1] == '%';
    const number = if (is_percentage)
        parsePercentage(linepos) orelse return
    else
        parseLineNumber(linepos) orelse return;

    var line_align: VTTCue.LineAlign = .start;
    if (linealign) |a| {
        line_align = std.meta.stringToEnum(VTTCue.LineAlign, a) orelse return;
    }

    cue._line_align = line_align;
    cue._line = number;
    cue._snap_to_lines = is_percentage == false;
}

// A line number: an optional leading '-', digits, at most one '.' with a
// digit on each side.
fn parseLineNumber(linepos: []const u8) ?f64 {
    var dots: usize = 0;
    for (linepos, 0..) |c, i| {
        switch (c) {
            '0'...'9' => {},
            '-' => if (i != 0) return null,
            '.' => {
                dots += 1;
                if (dots > 1) return null;
                if (i == 0 or i == linepos.len - 1) return null;
                if (std.ascii.isDigit(linepos[i - 1]) == false or std.ascii.isDigit(linepos[i + 1]) == false) return null;
            },
            else => return null,
        }
    }
    const number = std.fmt.parseFloat(f64, linepos) catch return null;
    // the HTML rules for parsing floating-point numbers fail on what doesn't
    // fit in a double, and never yield -0
    if (std.math.isFinite(number) == false) {
        return null;
    }
    return number + 0;
}

fn parsePositionSetting(cue: *VTTCue, value: []const u8) void {
    var colpos = value;
    var colalign: ?[]const u8 = null;
    if (std.mem.findScalar(u8, value, ',')) |comma| {
        colpos = value[0..comma];
        colalign = value[comma + 1 ..];
    }

    const number = parsePercentage(colpos) orelse return;

    var position_align: VTTCue.PositionAlign = .auto;
    if (colalign) |a| {
        position_align = std.meta.stringToEnum(VTTCue.PositionAlign, a) orelse return;
        // "auto" isn't a valid value in the setting
        if (position_align == .auto) return;
    }

    cue._position_align = position_align;
    cue._position = number;
}

// "parse a percentage string": /^\d+(\.\d+)?%$/, within [0, 100]
fn parsePercentage(input: []const u8) ?f64 {
    if (input.len < 2 or input[input.len - 1] != '%') {
        return null;
    }
    const number = input[0 .. input.len - 1];

    var i: usize = 0;
    while (i < number.len and std.ascii.isDigit(number[i])) i += 1;
    if (i == 0) return null;
    if (i < number.len) {
        if (number[i] != '.') return null;
        i += 1;
        const fraction_start = i;
        while (i < number.len and std.ascii.isDigit(number[i])) i += 1;
        if (i == fraction_start or i != number.len) return null;
    }

    const value = std.fmt.parseFloat(f64, number) catch return null;
    if (value < 0 or value > 100) {
        return null;
    }
    return value;
}

// "parse the WebVTT region settings"
fn parseRegion(settings: []const u8, frame: *Frame) !*VTTRegion {
    const region = try VTTRegion.init(frame);

    var it = std.mem.tokenizeAny(u8, settings, whitespace);
    while (it.next()) |setting| {
        const colon = std.mem.findScalar(u8, setting, ':') orelse continue;
        if (colon == 0 or colon == setting.len - 1) {
            continue;
        }
        const name = setting[0..colon];
        const value = setting[colon + 1 ..];

        if (std.mem.eql(u8, name, "id")) {
            region._id = try frame.dupeString(value);
        } else if (std.mem.eql(u8, name, "width")) {
            if (parsePercentage(value)) |width| {
                region._width = width;
            }
        } else if (std.mem.eql(u8, name, "lines")) {
            for (value) |c| {
                if (std.ascii.isDigit(c) == false) break;
            } else {
                region._lines = std.fmt.parseInt(u32, value, 10) catch continue;
            }
        } else if (std.mem.eql(u8, name, "regionanchor")) {
            const x, const y = parseAnchor(value) orelse continue;
            region._region_anchor_x = x;
            region._region_anchor_y = y;
        } else if (std.mem.eql(u8, name, "viewportanchor")) {
            const x, const y = parseAnchor(value) orelse continue;
            region._viewport_anchor_x = x;
            region._viewport_anchor_y = y;
        } else if (std.mem.eql(u8, name, "scroll")) {
            if (std.mem.eql(u8, value, "up")) {
                region._scroll = .up;
            }
        }
    }
    return region;
}

fn parseAnchor(value: []const u8) ?struct { f64, f64 } {
    const comma = std.mem.findScalar(u8, value, ',') orelse return null;
    const x = parsePercentage(value[0..comma]) orelse return null;
    const y = parsePercentage(value[comma + 1 ..]) orelse return null;
    return .{ x, y };
}

const testing = std.testing;
test "webvtt: parsePercentage" {
    try testing.expectEqual(@as(?f64, 50), parsePercentage("50%"));
    try testing.expectEqual(@as(?f64, 12.5), parsePercentage("12.5%"));
    try testing.expectEqual(@as(?f64, null), parsePercentage("101%"));
    try testing.expectEqual(@as(?f64, null), parsePercentage("5.%"));
    try testing.expectEqual(@as(?f64, null), parsePercentage(".5%"));
    try testing.expectEqual(@as(?f64, null), parsePercentage("-5%"));
    try testing.expectEqual(@as(?f64, null), parsePercentage("50"));
}

test "webvtt: parseLineNumber" {
    try testing.expectEqual(@as(?f64, -5), parseLineNumber("-5"));
    try testing.expect(std.math.signbit(parseLineNumber("-0").?) == false);
    try testing.expectEqual(@as(?f64, 1.5), parseLineNumber("1.5"));
    try testing.expectEqual(@as(?f64, null), parseLineNumber("1-5"));
    try testing.expectEqual(@as(?f64, null), parseLineNumber("1..5"));
    try testing.expectEqual(@as(?f64, null), parseLineNumber("-.5"));
}

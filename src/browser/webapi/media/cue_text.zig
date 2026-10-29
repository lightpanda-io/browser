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

// WebVTT cue text parsing rules and the DOM construction rules behind
// VTTCue.getCueAsHTML(): https://w3c.github.io/webvtt/#cue-text-parsing-rules

const std = @import("std");

const Frame = @import("../../Frame.zig");
const html5ever = @import("../../parser/html5ever.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const DocumentFragment = @import("../DocumentFragment.zig");

const Allocator = std.mem.Allocator;

pub fn toFragment(text: []const u8, frame: *Frame) !*DocumentFragment {
    const document = frame.document;
    const fragment = try DocumentFragment.init(document, frame);

    const Kind = enum { root, c, i, b, u, ruby, rt, v, lang };
    const Open = struct { node: *Node, kind: Kind };

    const arena = frame.call_arena;
    var stack: std.ArrayList(Open) = .empty;
    try stack.append(arena, .{ .node = fragment.asNode(), .kind = .root });

    var tokenizer: Tokenizer = .{ .input = text, .arena = arena };
    while (try tokenizer.next()) |token| {
        const current = stack.items[stack.items.len - 1];
        switch (token) {
            .string => |value| {
                const node = try Frame.node_factory.createTextNode(document, value);
                try frame.appendNode(current.node, node, .{});
            },
            .start_tag => |tag| {
                const kind = std.meta.stringToEnum(Kind, tag.name) orelse continue;
                const local_name, const annotation_attribute: ?[]const u8 = switch (kind) {
                    .root => continue,
                    .c => .{ "span", null },
                    .v => .{ "span", "title" },
                    .lang => .{ "span", "lang" },
                    .rt => blk: {
                        // only valid directly inside a <ruby>
                        if (current.kind != .ruby) continue;
                        break :blk .{ "rt", null };
                    },
                    .i, .b, .u, .ruby => .{ @tagName(kind), null },
                };

                const node = try Frame.node_factory.createElementNS(document, .html, local_name, null);
                const element = node.as(Element);
                if (tag.classes.len > 0) {
                    try element.setAttributeSafe(comptime .wrap("class"), .wrap(tag.classes), frame);
                }
                if (annotation_attribute) |name| {
                    try element.setAttributeSafe(.wrap(name), .wrap(tag.annotation), frame);
                }
                try frame.appendNode(current.node, node, .{});
                try stack.append(arena, .{ .node = node, .kind = kind });
            },
            .end_tag => |name| {
                if (current.kind != .root and std.mem.eql(u8, name, @tagName(current.kind))) {
                    stack.items.len -= 1;
                } else if (current.kind == .rt and std.mem.eql(u8, name, "ruby")) {
                    // an rt's parent is always a ruby, so this never pops the root
                    stack.items.len -= 2;
                }
            },
            .timestamp => |value| {
                const seconds = parseTimestamp(value) orelse continue;
                var buf: [64]u8 = undefined;
                const data = try formatTimestamp(&buf, seconds);
                const node = try Frame.node_factory.createProcessingInstruction(document, "timestamp", data);
                try frame.appendNode(current.node, node, .{});
            },
        }
    }

    return fragment;
}

const Token = union(enum) {
    string: []const u8,
    start_tag: struct {
        name: []const u8,
        // already joined with spaces
        classes: []const u8,
        annotation: []const u8,
    },
    end_tag: []const u8,
    timestamp: []const u8,
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    arena: Allocator,

    const State = enum { data, tag, start_tag, start_tag_class, start_tag_annotation, end_tag, timestamp_tag };

    fn next(self: *Tokenizer) !?Token {
        const input = self.input;
        if (self.pos >= input.len) {
            return null;
        }

        var state: State = .data;
        var result: std.ArrayList(u8) = .empty;
        var buffer: std.ArrayList(u8) = .empty;
        var classes: std.ArrayList(u8) = .empty;

        const arena = self.arena;
        while (true) : (self.pos += 1) {
            const c: ?u8 = if (self.pos < input.len) input[self.pos] else null;
            switch (state) {
                .data => {
                    const char = c orelse return .{ .string = result.items };
                    switch (char) {
                        '&' => {
                            if (try consumeCharacterReference(arena, &result, input, self.pos + 1, null)) |end| {
                                // the loop's increment moves past the reference
                                self.pos = end - 1;
                            } else {
                                try result.append(arena, '&');
                            }
                        },
                        '<' => {
                            if (result.items.len == 0) {
                                state = .tag;
                            } else {
                                return .{ .string = result.items };
                            }
                        },
                        else => try result.append(arena, char),
                    }
                },
                .tag => {
                    const char = c orelse return startTag(&result, &classes, "");
                    switch (char) {
                        '\t', '\n', 0x0C, ' ' => state = .start_tag_annotation,
                        '.' => state = .start_tag_class,
                        '/' => state = .end_tag,
                        '0'...'9' => {
                            try result.append(arena, char);
                            state = .timestamp_tag;
                        },
                        '>' => {
                            self.pos += 1;
                            return startTag(&result, &classes, "");
                        },
                        else => {
                            try result.append(arena, char);
                            state = .start_tag;
                        },
                    }
                },
                .start_tag => {
                    const char = c orelse return startTag(&result, &classes, "");
                    switch (char) {
                        '\t', 0x0C, ' ' => state = .start_tag_annotation,
                        '\n' => {
                            try buffer.append(arena, char);
                            state = .start_tag_annotation;
                        },
                        '.' => state = .start_tag_class,
                        '>' => {
                            self.pos += 1;
                            return startTag(&result, &classes, "");
                        },
                        else => try result.append(arena, char),
                    }
                },
                .start_tag_class => {
                    const char = c orelse {
                        try appendClass(arena, &classes, &buffer);
                        return startTag(&result, &classes, "");
                    };
                    switch (char) {
                        '\t', 0x0C, ' ' => {
                            try appendClass(arena, &classes, &buffer);
                            state = .start_tag_annotation;
                        },
                        '\n' => {
                            try appendClass(arena, &classes, &buffer);
                            try buffer.append(arena, char);
                            state = .start_tag_annotation;
                        },
                        '.' => try appendClass(arena, &classes, &buffer),
                        '>' => {
                            self.pos += 1;
                            try appendClass(arena, &classes, &buffer);
                            return startTag(&result, &classes, "");
                        },
                        else => try buffer.append(arena, char),
                    }
                },
                .start_tag_annotation => {
                    const char = c orelse return startTag(&result, &classes, try collapseWhitespace(arena, buffer.items));
                    switch (char) {
                        '&' => {
                            if (try consumeCharacterReference(arena, &buffer, input, self.pos + 1, '>')) |end| {
                                self.pos = end - 1;
                            } else {
                                try buffer.append(arena, '&');
                            }
                        },
                        '>' => {
                            self.pos += 1;
                            return startTag(&result, &classes, try collapseWhitespace(arena, buffer.items));
                        },
                        else => try buffer.append(arena, char),
                    }
                },
                .end_tag => {
                    const char = c orelse return .{ .end_tag = result.items };
                    if (char == '>') {
                        self.pos += 1;
                        return .{ .end_tag = result.items };
                    }
                    try result.append(arena, char);
                },
                .timestamp_tag => {
                    const char = c orelse return .{ .timestamp = result.items };
                    if (char == '>') {
                        self.pos += 1;
                        return .{ .timestamp = result.items };
                    }
                    try result.append(arena, char);
                },
            }
        }
    }

    fn startTag(result: *const std.ArrayList(u8), classes: *const std.ArrayList(u8), annotation: []const u8) Token {
        return .{ .start_tag = .{
            .name = result.items,
            .classes = classes.items,
            .annotation = annotation,
        } };
    }

    // The empty class from "<c..a>" still counts: spec appends `buffer` to the
    // class list unconditionally. We keep the joined form, which is all the
    // DOM construction needs, so an empty class only adds a separator.
    fn appendClass(arena: Allocator, classes: *std.ArrayList(u8), buffer: *std.ArrayList(u8)) !void {
        if (classes.items.len > 0) {
            try classes.append(arena, ' ');
        }
        try classes.appendSlice(arena, buffer.items);
        buffer.clearRetainingCapacity();
    }
};

fn collapseWhitespace(arena: Allocator, value: []const u8) ![]const u8 {
    const whitespace = "\t\n\x0C\r ";
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, value, whitespace);
    while (it.next()) |word| {
        if (out.items.len > 0) {
            try out.append(arena, ' ');
        }
        try out.appendSlice(arena, word);
    }
    return out.items;
}

// HTML "consume a character reference" (the version with an additional
// allowed character that WebVTT references). `start` is the index right after
// the '&'. Returns the index after the reference, having appended its value to
// `out`, or null if there's no reference there (nothing appended).
fn consumeCharacterReference(arena: Allocator, out: *std.ArrayList(u8), input: []const u8, start: usize, additional_allowed: ?u8) !?usize {
    if (start >= input.len) {
        return null;
    }
    const first = input[start];
    switch (first) {
        '\t', '\n', 0x0C, ' ', '<', '&' => return null,
        '#' => return consumeNumericReference(arena, out, input, start + 1),
        else => {
            if (additional_allowed) |c| {
                if (first == c) return null;
            }
        },
    }

    // Longest match: html5ever's table also holds every prefix of every name,
    // so we can stop as soon as nothing starts with what we've read.
    var matched_end: ?usize = null;
    var codepoints: [2]u32 = undefined;
    var end = start + 1;
    while (end <= input.len) : (end += 1) {
        const name = input[start..end];
        var found: [2]u32 = undefined;
        switch (html5ever.html5ever_named_character_reference(name.ptr, name.len, &found)) {
            0 => break,
            1 => {},
            else => {
                matched_end = end;
                codepoints = found;
            },
        }
    }

    const match = matched_end orelse return null;
    try appendCodepoint(arena, out, codepoints[0]);
    if (codepoints[1] != 0) {
        try appendCodepoint(arena, out, codepoints[1]);
    }
    return match;
}

fn consumeNumericReference(arena: Allocator, out: *std.ArrayList(u8), input: []const u8, start: usize) !?usize {
    var pos = start;
    var base: u8 = 10;
    if (pos < input.len and (input[pos] == 'x' or input[pos] == 'X')) {
        base = 16;
        pos += 1;
    }

    const digits_start = pos;
    var value: u32 = 0;
    while (pos < input.len) : (pos += 1) {
        const digit = std.fmt.charToDigit(input[pos], base) catch break;
        // anything past the Unicode range is replaced anyway; just don't overflow
        value = @min(value *| base +| digit, 0x110000);
    }
    if (pos == digits_start) {
        // "&#" or "&#x" without digits: no characters are consumed
        return null;
    }
    if (pos < input.len and input[pos] == ';') {
        pos += 1;
    }

    const codepoint: u32 = switch (value) {
        0, 0xD800...0xDFFF, 0x110000...std.math.maxInt(u32) => 0xFFFD,
        0x80...0x9F => c1_replacements[value - 0x80] orelse value,
        else => value,
    };
    try appendCodepoint(arena, out, codepoint);
    return pos;
}

// Windows-1252 interpretation of the C1 range, per the HTML tokenizer.
const c1_replacements = [32]?u32{
    0x20AC, null,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, null,   0x017D, null,
    null,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, null,   0x017E, 0x0178,
};

fn appendCodepoint(arena: Allocator, out: *std.ArrayList(u8), codepoint: u32) !void {
    var buf: [4]u8 = undefined;
    const cp: u21 = std.math.cast(u21, codepoint) orelse 0xFFFD;
    const len = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(arena, buf[0..len]);
}

// "collect a WebVTT timestamp", requiring the whole input to be consumed.
// Returns the time in milliseconds.
pub fn parseTimestamp(input: []const u8) ?u64 {
    var pos: usize = 0;
    const value = collectTimestamp(input, &pos) orelse return null;
    if (pos != input.len) {
        return null;
    }
    return value;
}

// "collect a WebVTT timestamp" starting at `pos.*`, which is advanced past
// what was consumed. Returns null on failure, otherwise milliseconds.
pub fn collectTimestamp(input: []const u8, pos: *usize) ?u64 {
    var hours_units = false;

    const v1 = collectDigits(input, pos) orelse return null;
    var value1 = v1.value;
    if (v1.len != 2 or value1 > 59) {
        hours_units = true;
    }

    if (pos.* >= input.len or input[pos.*] != ':') return null;
    pos.* += 1;

    const v2 = collectDigits(input, pos) orelse return null;
    if (v2.len != 2) return null;
    var value2 = v2.value;

    var value3: u64 = undefined;
    if (hours_units or (pos.* < input.len and input[pos.*] == ':')) {
        if (pos.* >= input.len or input[pos.*] != ':') return null;
        pos.* += 1;
        const v3 = collectDigits(input, pos) orelse return null;
        if (v3.len != 2) return null;
        value3 = v3.value;
    } else {
        value3 = value2;
        value2 = value1;
        value1 = 0;
    }

    if (pos.* >= input.len or input[pos.*] != '.') return null;
    pos.* += 1;

    const v4 = collectDigits(input, pos) orelse return null;
    if (v4.len != 3) return null;

    if (value2 > 59 or value3 > 59) return null;

    return ((value1 *| 60 +| value2) *| 60 +| value3) *| 1000 +| v4.value;
}

const Digits = struct { value: u64, len: usize };

// Collects a sequence of ASCII digits; null if there are none.
fn collectDigits(input: []const u8, pos: *usize) ?Digits {
    const start = pos.*;
    var value: u64 = 0;
    while (pos.* < input.len and std.ascii.isDigit(input[pos.*])) : (pos.* += 1) {
        value = value *| 10 +| (input[pos.*] - '0');
    }
    const len = pos.* - start;
    if (len == 0) return null;
    return .{ .value = value, .len = len };
}

// Hours are at least two digits; "100:00:00.000" is valid.
pub fn formatTimestamp(buf: []u8, ms: u64) ![]const u8 {
    const hours = ms / 3_600_000;
    const minutes = (ms / 60_000) % 60;
    const seconds = (ms / 1000) % 60;
    const millis = ms % 1000;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, minutes, seconds, millis });
}

const testing = std.testing;
test "cue_text: timestamps" {
    try testing.expectEqual(@as(?u64, 500), parseTimestamp("00:00.500"));
    try testing.expectEqual(@as(?u64, 3_600_500), parseTimestamp("1:00:00.500"));
    try testing.expectEqual(@as(?u64, 360_000_000), parseTimestamp("100:00:00.000"));
    try testing.expectEqual(@as(?u64, null), parseTimestamp("0"));
    try testing.expectEqual(@as(?u64, null), parseTimestamp("0.500"));
    try testing.expectEqual(@as(?u64, null), parseTimestamp("0:00.500"));
    try testing.expectEqual(@as(?u64, null), parseTimestamp("00:60.000"));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("01:00:00.500", try formatTimestamp(&buf, 3_600_500));
    try testing.expectEqualStrings("100:00:00.000", try formatTimestamp(&buf, 360_000_000));
}

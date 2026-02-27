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
const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
pub const Text = @import("cdata/Text.zig");
pub const Comment = @import("cdata/Comment.zig");
pub const CDATASection = @import("cdata/CDATASection.zig");
pub const ProcessingInstruction = @import("cdata/ProcessingInstruction.zig");

const CData = @This();

_type: Type,
_proto: *Node,
_data: String = .empty,

/// Count UTF-16 code units in a UTF-8 string.
/// 4-byte UTF-8 sequences (codepoints >= U+10000) produce 2 UTF-16 code units (surrogate pair),
/// everything else produces 1.
fn utf16Len(data: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid UTF-8 byte — count as 1 code unit, advance 1 byte
            i += 1;
            count += 1;
            continue;
        };
        if (i + seq_len > data.len) {
            // Truncated sequence
            count += 1;
            i += 1;
            continue;
        }
        if (seq_len == 4) {
            count += 2; // surrogate pair
        } else {
            count += 1;
        }
        i += seq_len;
    }
    return count;
}

/// Convert a UTF-16 code unit offset to a UTF-8 byte offset.
/// Returns IndexSizeError if utf16_offset > utf16 length of data.
pub fn utf16OffsetToUtf8(data: []const u8, utf16_offset: usize) error{IndexSizeError}!usize {
    var utf16_pos: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (utf16_pos == utf16_offset) return i;
        const byte = data[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            utf16_pos += 1;
            continue;
        };
        if (i + seq_len > data.len) {
            utf16_pos += 1;
            i += 1;
            continue;
        }
        if (seq_len == 4) {
            utf16_pos += 2;
        } else {
            utf16_pos += 1;
        }
        i += seq_len;
    }
    // At end of string — valid only if offset equals total length
    if (utf16_pos == utf16_offset) return i;
    return error.IndexSizeError;
}

/// Convert a UTF-16 code unit range to UTF-8 byte offsets in a single pass.
/// Returns IndexSizeError if utf16_start > utf16 length of data.
/// Clamps utf16_end to the actual string length if it exceeds it.
fn utf16RangeToUtf8(data: []const u8, utf16_start: usize, utf16_end: usize) !struct { start: usize, end: usize } {
    var i: usize = 0;
    var utf16_pos: usize = 0;
    var byte_start: ?usize = null;

    while (i < data.len) {
        // Record start offset when we reach it
        if (utf16_pos == utf16_start) {
            byte_start = i;
        }
        // If we've found start and reached end, return both
        if (utf16_pos == utf16_end and byte_start != null) {
            return .{ .start = byte_start.?, .end = i };
        }

        const byte = data[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            utf16_pos += 1;
            continue;
        };
        if (i + seq_len > data.len) {
            utf16_pos += 1;
            i += 1;
            continue;
        }
        utf16_pos += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }

    // At end of string
    if (utf16_pos == utf16_start) {
        byte_start = i;
    }
    const start = byte_start orelse return error.IndexSizeError;
    // End is either exactly at utf16_end or clamped to string end
    return .{ .start = start, .end = i };
}

pub const Type = union(enum) {
    text: Text,
    comment: Comment,
    // This should be under Text, but that would require storing a _type union
    // in text, which would add 8 bytes to every text node.
    cdata_section: CDATASection,
    processing_instruction: *ProcessingInstruction,
};

pub fn asNode(self: *CData) *Node {
    return self._proto;
}

pub fn is(self: *CData, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (f.type == T and @field(Type, f.name) == self._type) {
            return &@field(self._type, f.name);
        }
    }
    return null;
}

pub fn getData(self: *const CData) String {
    return self._data;
}

pub const RenderOpts = struct {
    trim_left: bool = true,
    trim_right: bool = true,
};
// Replace successives whitespaces with one withespace.
// Trims left and right according to the options.
// Returns true if the string ends with a trimmed whitespace.
pub fn render(self: *const CData, writer: *std.io.Writer, opts: RenderOpts) !bool {
    var start: usize = 0;
    var prev_w: ?bool = null;
    var is_w: bool = undefined;
    const s = self._data.str();

    for (s, 0..) |c, i| {
        is_w = std.ascii.isWhitespace(c);

        // Detect the first char type.
        if (prev_w == null) {
            prev_w = is_w;
        }
        // The current char is the same kind of char, the chunk continues.
        if (prev_w.? == is_w) {
            continue;
        }

        // Starting here, the chunk changed.
        if (is_w) {
            // We have a chunk of non-whitespaces, we write it as it.
            try writer.writeAll(s[start..i]);
        } else {
            // We have a chunk of whitespaces, replace with one space,
            // depending the position.
            if (start > 0 or !opts.trim_left) {
                try writer.writeByte(' ');
            }
        }
        // Start the new chunk.
        prev_w = is_w;
        start = i;
    }
    // Write the reminder chunk.
    if (is_w) {
        // Last chunk is whitespaces.
        // If the string contains only whitespaces, don't write it.
        if (start > 0 and opts.trim_right == false) {
            try writer.writeByte(' ');
        } else {
            return true;
        }
    } else {
        // last chunk is non whitespaces.
        try writer.writeAll(s[start..]);
    }

    return false;
}

pub fn setData(self: *CData, value: ?[]const u8, page: *Page) !void {
    const old_value = self._data;

    if (value) |v| {
        self._data = try page.dupeSSO(v);
    } else {
        self._data = .empty;
    }

    page.characterDataChange(self.asNode(), old_value);
}

/// JS bridge wrapper for `data` setter.
/// Handles [LegacyNullToEmptyString]: null → setData(null) → "".
/// Passes everything else (including undefined) through V8 toString,
/// so `undefined` becomes the string "undefined" per spec.
pub fn _setData(self: *CData, value: js.Value, page: *Page) !void {
    if (value.isNull()) {
        return self.setData(null, page);
    }
    return self.setData(try value.toZig([]const u8), page);
}

pub fn format(self: *const CData, writer: *std.io.Writer) !void {
    return switch (self._type) {
        .text => writer.print("<text>{f}</text>", .{self._data}),
        .comment => writer.print("<!-- {f} -->", .{self._data}),
        .cdata_section => writer.print("<![CDATA[{f}]]>", .{self._data}),
        .processing_instruction => |pi| writer.print("<?{s} {f}?>", .{ pi._target, self._data }),
    };
}

pub fn getLength(self: *const CData) usize {
    return utf16Len(self._data.str());
}

pub fn isEqualNode(self: *const CData, other: *const CData) bool {
    if (std.meta.activeTag(self._type) != std.meta.activeTag(other._type)) {
        return false;
    }

    if (self._type == .processing_instruction) {
        @branchHint(.unlikely);
        if (std.mem.eql(u8, self._type.processing_instruction._target, other._type.processing_instruction._target) == false) {
            return false;
        }
        // if the _targets are equal, we still want to compare the data
    }

    return self._data.eql(other._data);
}

pub fn appendData(self: *CData, data: []const u8, page: *Page) !void {
    const old_value = self._data;
    self._data = try String.concat(page.arena, &.{ self._data.str(), data });
    page.characterDataChange(self.asNode(), old_value);
}

pub fn deleteData(self: *CData, offset: usize, count: usize, page: *Page) !void {
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const range = try utf16RangeToUtf8(self._data.str(), offset, end_utf16);

    const old_data = self._data;
    const old_value = old_data.str();
    if (range.start == 0) {
        self._data = try page.dupeSSO(old_value[range.end..]);
    } else if (range.end >= old_value.len) {
        self._data = try page.dupeSSO(old_value[0..range.start]);
    } else {
        // Deleting from middle - concat prefix and suffix
        self._data = try String.concat(page.arena, &.{
            old_value[0..range.start],
            old_value[range.end..],
        });
    }
    page.characterDataChange(self.asNode(), old_data);
}

pub fn insertData(self: *CData, offset: usize, data: []const u8, page: *Page) !void {
    const byte_offset = try utf16OffsetToUtf8(self._data.str(), offset);
    const old_value = self._data;
    const existing = old_value.str();
    self._data = try String.concat(page.arena, &.{
        existing[0..byte_offset],
        data,
        existing[byte_offset..],
    });
    page.characterDataChange(self.asNode(), old_value);
}

pub fn replaceData(self: *CData, offset: usize, count: usize, data: []const u8, page: *Page) !void {
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const range = try utf16RangeToUtf8(self._data.str(), offset, end_utf16);
    const old_value = self._data;
    const existing = old_value.str();
    self._data = try String.concat(page.arena, &.{
        existing[0..range.start],
        data,
        existing[range.end..],
    });
    page.characterDataChange(self.asNode(), old_value);
}

pub fn substringData(self: *const CData, offset: usize, count: usize) ![]const u8 {
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const range = try utf16RangeToUtf8(self._data.str(), offset, end_utf16);
    return self._data.str()[range.start..range.end];
}

pub fn remove(self: *CData, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, page);
}

pub fn before(self: *CData, nodes: []const Node.NodeOrText, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, node, page);
    }
}

pub fn after(self: *CData, nodes: []const Node.NodeOrText, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, viable_next, page);
    }
}

pub fn replaceWith(self: *CData, nodes: []const Node.NodeOrText, page: *Page) !void {
    const ref_node = self.asNode();
    const parent = ref_node.parentNode() orelse return;

    var rm_ref_node = true;
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }
        _ = try parent.insertBefore(child, ref_node, page);
    }

    if (rm_ref_node) {
        _ = try parent.removeChild(ref_node, page);
    }
}

pub fn nextElementSibling(self: *CData) ?*Node.Element {
    var maybe_sibling = self.asNode().nextSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Node.Element)) |el| return el;
        maybe_sibling = sibling.nextSibling();
    }
    return null;
}

pub fn previousElementSibling(self: *CData) ?*Node.Element {
    var maybe_sibling = self.asNode().previousSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Node.Element)) |el| return el;
        maybe_sibling = sibling.previousSibling();
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CData);

    pub const Meta = struct {
        pub const name = "CharacterData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const data = bridge.accessor(CData.getData, CData._setData, .{});
    pub const length = bridge.accessor(CData.getLength, null, .{});

    pub const appendData = bridge.function(CData.appendData, .{});
    pub const deleteData = bridge.function(CData.deleteData, .{ .dom_exception = true });
    pub const insertData = bridge.function(CData.insertData, .{ .dom_exception = true });
    pub const replaceData = bridge.function(CData.replaceData, .{ .dom_exception = true });
    pub const substringData = bridge.function(CData.substringData, .{ .dom_exception = true });

    pub const remove = bridge.function(CData.remove, .{});
    pub const before = bridge.function(CData.before, .{});
    pub const after = bridge.function(CData.after, .{});
    pub const replaceWith = bridge.function(CData.replaceWith, .{});

    pub const nextElementSibling = bridge.accessor(CData.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(CData.previousElementSibling, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: CData" {
    try testing.htmlRunner("cdata", .{});
}

test "WebApi: CData.render" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        value: []const u8,
        expected: []const u8,
        result: bool = false,
        opts: RenderOpts = .{},
    };

    const test_cases = [_]TestCase{
        .{ .value = "   ", .expected = "", .result = true },
        .{ .value = "   ", .expected = "", .opts = .{ .trim_left = false, .trim_right = false }, .result = true },
        .{ .value = "foo bar", .expected = "foo bar" },
        .{ .value = "foo  bar", .expected = "foo bar" },
        .{ .value = "  foo bar", .expected = "foo bar" },
        .{ .value = "foo bar  ", .expected = "foo bar", .result = true },
        .{ .value = "  foo  bar  ", .expected = "foo bar", .result = true },
        .{ .value = "foo\n\tbar", .expected = "foo bar" },
        .{ .value = "\tfoo bar   baz   \t\n yeah\r\n", .expected = "foo bar baz yeah", .result = true },
        .{ .value = "  foo bar", .expected = " foo bar", .opts = .{ .trim_left = false } },
        .{ .value = "foo bar  ", .expected = "foo bar ", .opts = .{ .trim_right = false } },
        .{ .value = "  foo bar  ", .expected = " foo bar ", .opts = .{ .trim_left = false, .trim_right = false } },
    };

    var buffer = std.io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();

        const cdata = CData{
            ._type = .{ .text = undefined },
            ._proto = undefined,
            ._data = .wrap(test_case.value),
        };

        const result = try cdata.render(&buffer.writer, test_case.opts);

        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
        try std.testing.expect(result == test_case.result);
    }
}

test "utf16Len" {
    // ASCII: 1 byte = 1 code unit each
    try std.testing.expectEqual(@as(usize, 0), utf16Len(""));
    try std.testing.expectEqual(@as(usize, 5), utf16Len("hello"));
    // CJK: 3 bytes UTF-8 = 1 UTF-16 code unit each
    try std.testing.expectEqual(@as(usize, 2), utf16Len("資料")); // 6 bytes, 2 code units
    // Emoji U+1F320: 4 bytes UTF-8 = 2 UTF-16 code units (surrogate pair)
    try std.testing.expectEqual(@as(usize, 2), utf16Len("🌠")); // 4 bytes, 2 code units
    // Mixed: 🌠(2) + " test "(6) + 🌠(2) + " TEST"(5) = 15
    try std.testing.expectEqual(@as(usize, 15), utf16Len("🌠 test 🌠 TEST"));
    // 2-byte UTF-8 (e.g. é U+00E9): 1 UTF-16 code unit
    try std.testing.expectEqual(@as(usize, 4), utf16Len("café")); // c(1) + a(1) + f(1) + é(1)
}

test "utf16OffsetToUtf8" {
    // ASCII: offsets map 1:1
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("hello", 0));
    try std.testing.expectEqual(@as(usize, 3), try utf16OffsetToUtf8("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), try utf16OffsetToUtf8("hello", 5)); // end
    try std.testing.expectError(error.IndexSizeError, utf16OffsetToUtf8("hello", 6)); // past end

    // CJK "資料" (6 bytes, 2 UTF-16 code units)
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("資料", 0)); // before 資
    try std.testing.expectEqual(@as(usize, 3), try utf16OffsetToUtf8("資料", 1)); // before 料
    try std.testing.expectEqual(@as(usize, 6), try utf16OffsetToUtf8("資料", 2)); // end
    try std.testing.expectError(error.IndexSizeError, utf16OffsetToUtf8("資料", 3));

    // Emoji "🌠AB" (4+1+1 = 6 bytes; 2+1+1 = 4 UTF-16 code units)
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("🌠AB", 0)); // before 🌠
    // offset 1 lands inside the surrogate pair — still valid UTF-16 offset
    try std.testing.expectEqual(@as(usize, 4), try utf16OffsetToUtf8("🌠AB", 2)); // before A
    try std.testing.expectEqual(@as(usize, 5), try utf16OffsetToUtf8("🌠AB", 3)); // before B
    try std.testing.expectEqual(@as(usize, 6), try utf16OffsetToUtf8("🌠AB", 4)); // end

    // Empty string: only offset 0 is valid
    try std.testing.expectEqual(@as(usize, 0), try utf16OffsetToUtf8("", 0));
    try std.testing.expectError(error.IndexSizeError, utf16OffsetToUtf8("", 1));
}

test "utf16RangeToUtf8" {
    // ASCII: basic range
    {
        const result = try utf16RangeToUtf8("hello", 1, 4);
        try std.testing.expectEqual(@as(usize, 1), result.start);
        try std.testing.expectEqual(@as(usize, 4), result.end);
    }

    // ASCII: range to end
    {
        const result = try utf16RangeToUtf8("hello", 2, 5);
        try std.testing.expectEqual(@as(usize, 2), result.start);
        try std.testing.expectEqual(@as(usize, 5), result.end);
    }

    // ASCII: range past end (should clamp)
    {
        const result = try utf16RangeToUtf8("hello", 2, 100);
        try std.testing.expectEqual(@as(usize, 2), result.start);
        try std.testing.expectEqual(@as(usize, 5), result.end); // clamped
    }

    // ASCII: full range
    {
        const result = try utf16RangeToUtf8("hello", 0, 5);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 5), result.end);
    }

    // ASCII: start past end
    try std.testing.expectError(error.IndexSizeError, utf16RangeToUtf8("hello", 6, 10));

    // CJK "資料" (6 bytes, 2 UTF-16 code units)
    {
        const result = try utf16RangeToUtf8("資料", 0, 1);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 3), result.end); // after 資
    }

    {
        const result = try utf16RangeToUtf8("資料", 1, 2);
        try std.testing.expectEqual(@as(usize, 3), result.start); // before 料
        try std.testing.expectEqual(@as(usize, 6), result.end); // end
    }

    {
        const result = try utf16RangeToUtf8("資料", 0, 2);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 6), result.end);
    }

    // Emoji "🌠AB" (4+1+1 = 6 bytes; 2+1+1 = 4 UTF-16 code units)
    {
        const result = try utf16RangeToUtf8("🌠AB", 0, 2);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 4), result.end); // after 🌠
    }

    {
        const result = try utf16RangeToUtf8("🌠AB", 2, 3);
        try std.testing.expectEqual(@as(usize, 4), result.start); // before A
        try std.testing.expectEqual(@as(usize, 5), result.end); // before B
    }

    {
        const result = try utf16RangeToUtf8("🌠AB", 0, 4);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 6), result.end);
    }

    // Empty string
    {
        const result = try utf16RangeToUtf8("", 0, 0);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 0), result.end);
    }

    {
        const result = try utf16RangeToUtf8("", 0, 100);
        try std.testing.expectEqual(@as(usize, 0), result.start);
        try std.testing.expectEqual(@as(usize, 0), result.end); // clamped
    }

    // Mixed "🌠 test 🌠" (4+1+4+1+4 = 14 bytes; 2+1+4+1+2 = 10 UTF-16 code units)
    {
        const result = try utf16RangeToUtf8("🌠 test 🌠", 3, 7);
        try std.testing.expectEqual(@as(usize, 5), result.start); // before 'test'
        try std.testing.expectEqual(@as(usize, 9), result.end); // after 'test', before second space
    }
}

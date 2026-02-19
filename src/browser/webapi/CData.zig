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
_data: []const u8 = "",

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

pub fn getData(self: *const CData) []const u8 {
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
    const s = self._data;

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
        self._data = try page.dupeString(v);
    } else {
        self._data = "";
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
        .text => writer.print("<text>{s}</text>", .{self._data}),
        .comment => writer.print("<!-- {s} -->", .{self._data}),
        .cdata_section => writer.print("<![CDATA[{s}]]>", .{self._data}),
        .processing_instruction => |pi| writer.print("<?{s} {s}?>", .{ pi._target, self._data }),
    };
}

pub fn getLength(self: *const CData) usize {
    return utf16Len(self._data);
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

    return std.mem.eql(u8, self.getData(), other.getData());
}

pub fn appendData(self: *CData, data: []const u8, page: *Page) !void {
    const new_data = try std.mem.concat(page.arena, u8, &.{ self._data, data });
    try self.setData(new_data, page);
}

pub fn deleteData(self: *CData, offset: usize, count: usize, page: *Page) !void {
    const byte_offset = try utf16OffsetToUtf8(self._data, offset);
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const byte_end = utf16OffsetToUtf8(self._data, end_utf16) catch self._data.len;

    // Just slice - original data stays in arena
    const old_value = self._data;
    if (byte_offset == 0) {
        self._data = self._data[byte_end..];
    } else if (byte_end >= self._data.len) {
        self._data = self._data[0..byte_offset];
    } else {
        self._data = try std.mem.concat(page.arena, u8, &.{
            self._data[0..byte_offset],
            self._data[byte_end..],
        });
    }
    page.characterDataChange(self.asNode(), old_value);
}

pub fn insertData(self: *CData, offset: usize, data: []const u8, page: *Page) !void {
    const byte_offset = try utf16OffsetToUtf8(self._data, offset);
    const new_data = try std.mem.concat(page.arena, u8, &.{
        self._data[0..byte_offset],
        data,
        self._data[byte_offset..],
    });
    try self.setData(new_data, page);
}

pub fn replaceData(self: *CData, offset: usize, count: usize, data: []const u8, page: *Page) !void {
    const byte_offset = try utf16OffsetToUtf8(self._data, offset);
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const byte_end = utf16OffsetToUtf8(self._data, end_utf16) catch self._data.len;
    const new_data = try std.mem.concat(page.arena, u8, &.{
        self._data[0..byte_offset],
        data,
        self._data[byte_end..],
    });
    try self.setData(new_data, page);
}

pub fn substringData(self: *const CData, offset: usize, count: usize) ![]const u8 {
    const byte_offset = try utf16OffsetToUtf8(self._data, offset);
    const end_utf16 = std.math.add(usize, offset, count) catch std.math.maxInt(usize);
    const byte_end = utf16OffsetToUtf8(self._data, end_utf16) catch self._data.len;
    return self._data[byte_offset..byte_end];
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
    const next = node.nextSibling();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, next, page);
    }
}

pub fn replaceWith(self: *CData, nodes: []const Node.NodeOrText, page: *Page) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const next = node.nextSibling();

    _ = try parent.removeChild(node, page);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.insertBefore(child, next, page);
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
            ._data = test_case.value,
        };

        const result = try cdata.render(&buffer.writer, test_case.opts);

        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
        try std.testing.expect(result == test_case.result);
    }
}

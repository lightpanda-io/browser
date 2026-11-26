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

const std = @import("std");

const JsonEscapingWriter = @This();

inner: *std.Io.Writer,
writer: std.Io.Writer,

pub fn init(inner: *std.Io.Writer, buffer: []u8) JsonEscapingWriter {
    return .{
        .inner = inner,
        .writer = .{
            .vtable = &vtable,
            .buffer = buffer,
        },
    };
}

const vtable = std.Io.Writer.VTable{ .drain = drain };

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *JsonEscapingWriter = @alignCast(@fieldParentPtr("writer", w));
    try self.escape(w.buffered());
    w.end = 0;

    var total: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        try self.escape(slice);
        total += slice.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        try self.escape(pattern);
        total += pattern.len;
    }
    return total;
}

fn escape(self: *JsonEscapingWriter, bytes: []const u8) std.Io.Writer.Error!void {
    return std.json.Stringify.encodeJsonStringChars(bytes, .{}, self.inner);
}

const testing = @import("testing.zig");

test "JsonEscapingWriter" {
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();

    var escaping_writer = JsonEscapingWriter.init(&aw.writer, &.{});

    // test newlines and quotes
    try escaping_writer.writer.writeAll("hello\n\"world\"");

    // the writer outputs escaped string chars without surrounding quotes
    try testing.expectEqual("hello\\n\\\"world\\\"", aw.written());
}

test "JsonEscapingWriter: buffered" {
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer aw.deinit();

    var buf: [4]u8 = undefined;
    var escaping_writer = JsonEscapingWriter.init(&aw.writer, &buf);
    const w = &escaping_writer.writer;

    try w.writeAll("a\"");
    try w.writeByte('\\');
    try w.writeAll("longer than the buffer\n");
    try w.splatByteAll('"', 3);
    try w.writeByte('z');
    try w.flush();

    try testing.expectEqual("a\\\"\\\\longer than the buffer\\n\\\"\\\"\\\"z", aw.written());
}

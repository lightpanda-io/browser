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

//   var b64 = Base64Writer.init(&out.writer, .standard);
//   try producer.write(&b64.writer);
//   try b64.finish();

const std = @import("std");
const Writer = std.Io.Writer;

const Base64Writer = @This();

inner: *Writer,
writer: Writer,
pending_len: u2 = 0,
pending: [3]u8 = undefined,
codec: *const std.base64.Base64Encoder,

pub const Codec = enum {
    standard,
    standard_no_pad,
    url_safe,
    url_safe_no_pad,

    fn encoder(self: Codec) *const std.base64.Base64Encoder {
        return switch (self) {
            .standard => &std.base64.standard.Encoder,
            .standard_no_pad => &std.base64.standard_no_pad.Encoder,
            .url_safe => &std.base64.url_safe.Encoder,
            .url_safe_no_pad => &std.base64.url_safe_no_pad.Encoder,
        };
    }
};

pub fn init(inner: *Writer, codec: Codec) Base64Writer {
    return .{
        .inner = inner,
        .codec = codec.encoder(),
        .writer = .{
            .vtable = &vtable,
            .buffer = &.{},
        },
    };
}

const vtable = Writer.VTable{ .drain = drain };

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *Base64Writer = @alignCast(@fieldParentPtr("writer", w));
    var total: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        try self.feed(slice);
        total += slice.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        try self.feed(pattern);
        total += pattern.len;
    }
    return total;
}

fn feed(self: *Base64Writer, bytes: []const u8) Writer.Error!void {
    var src = bytes;

    if (self.pending_len > 0) {
        while (self.pending_len < 3 and src.len > 0) {
            self.pending[self.pending_len] = src[0];
            self.pending_len += 1;
            src = src[1..];
        }
        if (self.pending_len < 3) return;
        var group: [4]u8 = undefined;
        try self.inner.writeAll(self.codec.encode(&group, &self.pending));
        self.pending_len = 0;
    }

    // Encode whole groups in bulk through a stack buffer, then keep the
    // remainder for the next write.
    const full = src.len - src.len % 3;
    var out: [4096]u8 = undefined;
    const in_step = out.len / 4 * 3;
    var i: usize = 0;
    while (i < full) {
        const n = @min(in_step, full - i);
        try self.inner.writeAll(self.codec.encode(&out, src[i .. i + n]));
        i += n;
    }

    const rem = src[full..];
    @memcpy(self.pending[0..rem.len], rem);
    self.pending_len = @intCast(rem.len);
}

// Encodes the trailing partial group (with padding, per codec). Call once,
// after the last write.
pub fn finish(self: *Base64Writer) Writer.Error!void {
    if (self.pending_len == 0) return;
    var group: [4]u8 = undefined;
    try self.inner.writeAll(self.codec.encode(&group, self.pending[0..self.pending_len]));
    self.pending_len = 0;
}

const testing = @import("testing.zig");
test "Base64Writer: matches std for every chunking" {
    var input: [1000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    inline for (.{ Codec.standard, Codec.standard_no_pad, Codec.url_safe, Codec.url_safe_no_pad }) |codec| {
        const enc = codec.encoder();
        for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 100, 999, 1000 }) |len| {
            const expected = try testing.allocator.alloc(u8, enc.calcSize(len));
            defer testing.allocator.free(expected);
            _ = enc.encode(expected, input[0..len]);

            for ([_]usize{ 1, 2, 3, 4, 5, 7, 64, 3071, 3072, 3073, 4096 }) |chunk| {
                const got = try testEncode(codec, input[0..len], chunk);
                defer testing.allocator.free(got);
                try testing.expectEqual(expected, got);
            }
        }
    }
}

test "Base64Writer: writer helpers" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var b64 = Base64Writer.init(&aw.writer, .standard);
    try b64.writer.print("{s}-{d}", .{ "hello", 42 });
    try b64.writer.splatByteAll('!', 5);
    try b64.finish();
    try testing.expectEqual("aGVsbG8tNDIhISEhIQ==", aw.written());
}

fn testEncode(codec: Codec, input: []const u8, chunk: usize) ![]const u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();

    var b64 = Base64Writer.init(&aw.writer, codec);
    var i: usize = 0;
    while (i < input.len) : (i += chunk) {
        try b64.writer.writeAll(input[i..@min(input.len, i + chunk)]);
    }
    try b64.finish();
    return aw.toOwnedSlice();
}

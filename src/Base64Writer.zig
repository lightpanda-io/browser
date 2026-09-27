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
const Writer = std.Io.Writer;

const Base64 = @import("sys/simdutf.zig").Base64;

/// Usage:
/// ```zig
/// var b64 = Base64Writer.init(&out.writer, .standard);
/// try producer.write(&b64.writer);
/// try b64.finish();
/// ```
const Base64Writer = @This();

inner: *Writer,
writer: Writer,
pending_len: u2 = 0,
pending: [3]u8 = undefined,
codec: Base64.Type,

pub fn init(inner: *Writer, codec: Base64.Type) Base64Writer {
    return .{
        .inner = inner,
        .codec = codec,
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
        try self.inner.writeAll(Base64.Encoder.encode(self.codec, &group, &self.pending));
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
        try self.inner.writeAll(Base64.Encoder.encode(self.codec, &out, src[i .. i + n]));
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
    try self.inner.writeAll(Base64.Encoder.encode(self.codec, &group, self.pending[0..self.pending_len]));
    self.pending_len = 0;
}

const testing = @import("testing.zig");
const test_codecs = [_]Base64.Type{ .default, .default_no_padding, .url, .url_with_padding };

test "Base64Writer: RFC 4648 vectors" {
    // One column per test_codecs entry. The last row is where the alphabets
    // differ ('+/' vs '-_').
    const cases = [_]struct { []const u8, [test_codecs.len][]const u8 }{
        .{ "", .{ "", "", "", "" } },
        .{ "f", .{ "Zg==", "Zg", "Zg", "Zg==" } },
        .{ "fo", .{ "Zm8=", "Zm8", "Zm8", "Zm8=" } },
        .{ "foo", .{ "Zm9v", "Zm9v", "Zm9v", "Zm9v" } },
        .{ "foob", .{ "Zm9vYg==", "Zm9vYg", "Zm9vYg", "Zm9vYg==" } },
        .{ "fooba", .{ "Zm9vYmE=", "Zm9vYmE", "Zm9vYmE", "Zm9vYmE=" } },
        .{ "foobar", .{ "Zm9vYmFy", "Zm9vYmFy", "Zm9vYmFy", "Zm9vYmFy" } },
        .{ "\xfb\xff", .{ "+/8=", "+/8", "-_8", "-_8=" } },
    };
    for (cases) |case| {
        const input, const expected = case;
        for (test_codecs, expected) |codec, want| {
            for ([_]usize{ 1, 64 }) |chunk| {
                const got = try testEncode(codec, input, chunk);
                defer testing.allocator.free(got);
                try testing.expectEqual(want, got);
            }
        }
    }
}

test "Base64Writer: chunked writes match a one-shot encode" {
    // Long enough for one write to span two 3072-byte bulk steps plus a tail.
    var input: [6145]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    for (test_codecs) |codec| {
        for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 100, 3071, 3072, 3073, 6145 }) |len| {
            const buf = try testing.allocator.alloc(u8, Base64.Encoder.calcSize(codec, len));
            defer testing.allocator.free(buf);
            const expected = Base64.Encoder.encode(codec, buf, input[0..len]);

            for ([_]usize{ 1, 2, 3, 4, 5, 7, 64, 3071, 3072, 3073, 4096, 7000 }) |chunk| {
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

    var b64 = Base64Writer.init(&aw.writer, .default);
    try b64.writer.print("{s}-{d}", .{ "hello", 42 });
    try b64.writer.splatByteAll('!', 5);
    try b64.finish();
    try testing.expectEqual("aGVsbG8tNDIhISEhIQ==", aw.written());
}

fn testEncode(codec: Base64.Type, input: []const u8, chunk: usize) ![]const u8 {
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

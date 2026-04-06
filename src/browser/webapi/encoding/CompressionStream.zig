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
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const CompressionStream = @This();

_transform: *TransformStream,
_state: *State,

const Format = enum {
    deflate,
    @"deflate-raw",
    gzip,
};

const State = struct {
    allocator: std.mem.Allocator,
    format: Format,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
};

pub fn init(format_name: []const u8, page: *Page) !CompressionStream {
    const format = std.meta.stringToEnum(Format, format_name) orelse return error.RangeError;

    const state = try page._factory.create(State{
        .allocator = page.arena,
        .format = format,
    });

    const transform = try TransformStream.initWithZigContext(state, writeCompressedChunk, flushCompressedBytes, page);
    return .{
        ._transform = transform,
        ._state = state,
    };
}

fn writeCompressedChunk(raw_ctx: *anyopaque, _: *TransformStream.DefaultController, chunk: js.Value) !void {
    const state: *State = @ptrCast(@alignCast(raw_ctx));

    if (chunk.isUint8Array()) {
        const typed_array = try chunk.toZig(js.TypedArray(u8));
        try state.buffer.appendSlice(state.allocator, typed_array.values);
        return;
    }

    if (chunk.isArrayBuffer()) {
        const array_buffer = try chunk.toZig(js.ArrayBuffer);
        try state.buffer.appendSlice(state.allocator, array_buffer.values);
        return;
    }

    return error.TypeError;
}

fn flushCompressedBytes(raw_ctx: *anyopaque, controller: *TransformStream.DefaultController) !void {
    const state: *State = @ptrCast(@alignCast(raw_ctx));
    const compressed = try compressBytes(state.allocator, state.format, state.buffer.items);
    try controller.enqueue(.{ .uint8array = .{ .values = compressed } });
    state.buffer.clearRetainingCapacity();
}

fn compressBytes(allocator: std.mem.Allocator, format: Format, input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    switch (format) {
        .deflate => {
            try output.writer.writeAll(&.{ 0x78, 0x9c });
            try writeStoredBlocks(&output.writer, input);

            var footer: [4]u8 = undefined;
            std.mem.writeInt(u32, &footer, std.hash.Adler32.hash(input), .big);
            try output.writer.writeAll(&footer);
        },
        .@"deflate-raw" => {
            try writeStoredBlocks(&output.writer, input);
        },
        .gzip => {
            try output.writer.writeAll(&.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });
            try writeStoredBlocks(&output.writer, input);

            var footer: [8]u8 = undefined;
            std.mem.writeInt(u32, footer[0..4], std.hash.Crc32.hash(input), .little);
            std.mem.writeInt(u32, footer[4..8], @truncate(input.len), .little);
            try output.writer.writeAll(&footer);
        },
    }

    return output.toOwnedSlice();
}

fn writeStoredBlocks(writer: *std.Io.Writer, input: []const u8) !void {
    if (input.len == 0) {
        try writeStoredBlock(writer, true, "");
        return;
    }

    var offset: usize = 0;
    while (offset < input.len) {
        const remaining = input.len - offset;
        const block_len: usize = @min(remaining, 0xffff);
        const final = offset + block_len == input.len;
        try writeStoredBlock(writer, final, input[offset..][0..block_len]);
        offset += block_len;
    }
}

fn writeStoredBlock(writer: *std.Io.Writer, final: bool, input: []const u8) !void {
    try writer.writeByte(if (final) 0x01 else 0x00);

    var header: [4]u8 = undefined;
    const len: u16 = @intCast(input.len);
    std.mem.writeInt(u16, header[0..2], len, .little);
    std.mem.writeInt(u16, header[2..4], ~len, .little);
    try writer.writeAll(&header);
    try writer.writeAll(input);
}

fn flateContainer(format: Format) std.compress.flate.Container {
    return switch (format) {
        .deflate => .zlib,
        .@"deflate-raw" => .raw,
        .gzip => .gzip,
    };
}

fn decompressBytes(allocator: std.mem.Allocator, format: Format, compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, flateContainer(format), &window);
    _ = try decompressor.reader.streamRemaining(&output.writer);

    return output.toOwnedSlice();
}

pub fn getReadable(self: *const CompressionStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const CompressionStream) *WritableStream {
    return self._transform.getWritable();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CompressionStream);

    pub const Meta = struct {
        pub const name = "CompressionStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CompressionStream.init, .{});
    pub const readable = bridge.accessor(CompressionStream.getReadable, null, .{});
    pub const writable = bridge.accessor(CompressionStream.getWritable, null, .{});
};

const testing = @import("../../../testing.zig");

test "WebApi: CompressionStream" {
    try testing.htmlRunner("streams/compression_stream.html", .{});
}

test "CompressionStream round trips deflate containers" {
    const allocator = std.testing.allocator;
    const input = "brass otter lantern";

    inline for ([_]Format{ .deflate, .@"deflate-raw", .gzip }) |format| {
        const compressed = try compressBytes(allocator, format, input);
        defer allocator.free(compressed);

        const restored = try decompressBytes(allocator, format, compressed);
        defer allocator.free(restored);

        try std.testing.expectEqualSlices(u8, input, restored);
    }
}

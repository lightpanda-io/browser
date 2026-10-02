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

const zlib = @import("../../../sys/zlib.zig");

const js = @import("../../js/js.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

pub const Format = enum {
    deflate,
    @"deflate-raw",
    gzip,

    pub const js_enum_from_string = true;
};

const State = enum {
    /// Stream is dormant. Nothing is allocated at this state.
    idle,
    active,
    /// The internal stream is released; compression finished, decompression
    /// reached the end of the compressed data, or the stream errored.
    ended,
};

/// The zlib transformer behind CompressionStream and DecompressionStream.
/// https://compression.spec.whatwg.org/
pub fn Stream(comptime mode: enum(u1) { compress, decompress }) type {
    return struct {
        exec: *const Execution,
        state: State = .idle,
        format: Format,
        /// Internal zlib stream; lazily initialized. Valid if `state` is `active`.
        stream: zlib.z_stream = undefined,

        pub fn init(exec: *const Execution, format: Format) Stream(mode) {
            return .{ .format = format, .exec = exec };
        }

        pub fn transformer(self: *Stream(mode)) TransformStream.ZigTransformer {
            return .{ .ctx = self, .transform = transform, .flush = flush };
        }

        /// Initializes internal `stream`.
        fn initStream(self: *Stream(mode)) !void {
            // This must be done before the first use of deflate(). The zalloc,
            // zfree, and opaque fields in the strm structure must be initialized
            // before calling deflateInit().
            // https://zlib.net/zlib_how.html
            self.stream = .{ .zalloc = zlib_alloc, .zfree = zlib_free, .@"opaque" = @constCast(self.exec) };
            // TODO: Match Chrome.
            const window_bits: c_int = switch (self.format) {
                .deflate => zlib.MAX_WBITS,
                .@"deflate-raw" => -zlib.MAX_WBITS,
                .gzip => zlib.MAX_WBITS + 16,
            };
            // Default compression level Chrome picks.
            // https://github.com/chromium/chromium/blob/1750d75d37b768db7fc6970edb2c4cd3eea0e1a3/third_party/blink/renderer/modules/compression/compression_stream.cc#L53-L55
            const default_level: c_int = 6;

            const rc = switch (comptime mode) {
                .compress => zlib.deflateInit2_(&self.stream, default_level, zlib.Z_DEFLATED, window_bits, 8, zlib.Z_DEFAULT_STRATEGY, zlib.ZLIB_VERSION, @sizeOf(zlib.z_stream)),
                .decompress => zlib.inflateInit2_(&self.stream, window_bits, zlib.ZLIB_VERSION, @sizeOf(zlib.z_stream)),
            };
            return switch (rc) {
                zlib.Z_OK => {},
                zlib.Z_STREAM_ERROR => error.InvalidArguments,
                zlib.Z_MEM_ERROR => error.OutOfMemory,
                zlib.Z_VERSION_ERROR => error.IncompatibleVersionOrStructSize,
                else => unreachable,
            };
        }

        fn end(self: *Stream(mode)) void {
            switch (self.state) {
                .idle, .ended => {},
                .active => {
                    _ = switch (comptime mode) {
                        .compress => zlib.deflateEnd(&self.stream),
                        .decompress => zlib.inflateEnd(&self.stream),
                    };
                    self.state = .ended;
                },
            }
        }

        // Errors the stream, releasing internal stream.
        fn fail(self: *Stream(mode), controller: *TransformStream.DefaultController, message: []const u8) !void {
            self.end();
            try controller.typeError(message);
            return self.exec.js.typeError(message);
        }

        const FeedError = error{
            StreamNotReadable,
            OutOfMemory,
            HasJunkData,
            InvalidData,
        };

        fn feed(
            self: *Stream(mode),
            controller: *TransformStream.DefaultController,
            input: []const u8,
            comptime output_buffer_size: u32,
            finish: bool,
        ) FeedError!void {
            const stream = &self.stream;
            // Can feed and collect up to largest `zlib.uInt` at a time.
            const max_len = std.math.maxInt(zlib.uInt);

            // Reused for each.
            var output: [output_buffer_size]u8 = undefined;
            var remaining = input;
            while (true) {
                // If the last iteration consumed everything and we still have
                // bytes, let internal stream know this.
                if (stream.avail_in == 0 and remaining.len > 0) {
                    const len = @min(remaining.len, max_len);
                    stream.next_in = @constCast(remaining.ptr);
                    stream.avail_in = @intCast(len);
                    // Shrink.
                    remaining = remaining[len..];
                }

                // Collect.
                stream.next_out = &output;
                stream.avail_out = output.len;

                const flush_mode = if (finish and remaining.len == 0) zlib.Z_FINISH else zlib.Z_NO_FLUSH;
                const rc = switch (comptime mode) {
                    .compress => zlib.deflate(stream, flush_mode),
                    .decompress => zlib.inflate(stream, flush_mode),
                };

                // Queued before `rc` is checked, the call that returns
                // `Z_STREAM_END` also produces the last of the output.
                const collected = output[0 .. output.len - stream.avail_out];
                if (collected.len > 0) {
                    const array = js.TypedArray(u8){ .values = collected };
                    try controller.enqueueNoSideEffects(.{ .uint8array = array });
                }

                switch (rc) {
                    // `Z_BUF_ERROR` only means no progress was possible, stream
                    // wants more input.
                    zlib.Z_OK, zlib.Z_BUF_ERROR => {},
                    zlib.Z_STREAM_END => {
                        const unconsumed = stream.avail_in > 0 or remaining.len > 0;
                        self.end();
                        controller.fulfillPendingReads();
                        // If there are unconsumed bytes, that's a failure.
                        if (unconsumed) {
                            return error.HasJunkData;
                        }
                        return;
                    },
                    zlib.Z_MEM_ERROR => return error.OutOfMemory,
                    // the `FDICT` flag isn't supported.
                    zlib.Z_DATA_ERROR, zlib.Z_NEED_DICT => return error.InvalidData,
                    else => unreachable,
                }

                // Output space left over means zlib consumed all the input it had.
                if (stream.avail_out != 0 and stream.avail_in == 0 and remaining.len == 0) {
                    controller.fulfillPendingReads();
                    return;
                }
            }
        }

        fn process(
            self: *Stream(mode),
            controller: *TransformStream.DefaultController,
            input: []const u8,
            finish: bool,
        ) !void {
            state_machine: switch (self.state) {
                .idle => {
                    // The internal stream is initialized here first.
                    self.initStream() catch |err| switch (err) {
                        error.InvalidArguments => unreachable,
                        error.IncompatibleVersionOrStructSize => unreachable,
                        else => return err,
                    };
                    // Jump to `active`.
                    self.state = .active;
                    continue :state_machine self.state;
                },
                .active => {
                    const buffer_size = 16 * 1024;
                    self.feed(controller, input, buffer_size, finish) catch |err| switch (err) {
                        error.StreamNotReadable => return self.fail(controller, "The readable side is closed"),
                        error.HasJunkData => return self.fail(controller, "Junk found after end of data"),
                        error.InvalidData => return self.fail(controller, "The data was not valid"),
                        else => return err,
                    };
                },
                .ended => {}, // Can be reached but no-op.
            }
        }

        fn transform(ctx: ?*anyopaque, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
            const self: *Stream(mode) = @ptrCast(@alignCast(ctx.?));
            const input = chunk.toZig(js.BufferSource) catch {
                return self.fail(controller, "Chunk is not an ArrayBuffer or ArrayBufferView");
            };

            if (self.state == .ended) {
                // Only decompression gets here, the compressed data already ended.
                // (Every other way to end errors or closes the writable side.)
                if (input.bytes.len > 0) {
                    return self.fail(controller, "Junk found after end of compressed data");
                }
                return;
            }

            if (input.bytes.len == 0) {
                return;
            }
            return self.process(controller, input.bytes, false);
        }

        fn flush(ctx: ?*anyopaque, controller: *TransformStream.DefaultController) !void {
            const self: *Stream(mode) = @ptrCast(@alignCast(ctx.?));
            switch (comptime mode) {
                .compress => return self.process(controller, "", true),
                // Each chunk is fully inflated as it's written, so by now the
                // compressed data must have ended.
                .decompress => if (self.state != .ended) {
                    return self.fail(controller, "Compressed input was truncated");
                },
            }
        }
    };
}

// zlib frees without a size, so every block carries its own in a header that
// keeps the payload at malloc's alignment.
// Similar to what's done for @Regex.zig; see `cMalloc` function there.
const HEADER = 16;
const alignment: std.mem.Alignment = .fromByteUnits(HEADER);

fn zlib_alloc(userdata: ?*anyopaque, items: zlib.uInt, size: zlib.uInt) callconv(.c) ?*anyopaque {
    const exec: *const Execution = @ptrCast(@alignCast(userdata.?));
    const allocator = exec._factory.storageAllocator();

    const len = std.math.mul(usize, items, size) catch return null;
    const total = std.math.add(usize, len, HEADER) catch return null;
    const block = allocator.alignedAlloc(u8, alignment, total) catch return null;
    // Write header.
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], total, .native);
    // Conceal header part.
    return block.ptr + HEADER;
}

fn zlib_free(userdata: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const payload = ptr orelse return;
    const exec: *const Execution = @ptrCast(@alignCast(userdata.?));
    const allocator = exec._factory.storageAllocator();

    const base: [*]align(HEADER) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(payload)) - HEADER));
    const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .native);
    allocator.free(base[0..total]);
}

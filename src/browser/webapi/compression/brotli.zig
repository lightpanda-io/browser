// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const brotli = @import("../../../sys/brotli.zig");

const js = @import("../../js/js.zig");
const Execution = js.Execution;

const TransformStream = @import("../streams/TransformStream.zig");

const State = enum {
    /// Stream is dormant. Nothing is allocated at this state.
    idle,
    active,
    ended,
};

/// Does brotli encoding in streaming fashion.
pub const EncodingStream = struct {
    exec: *const Execution,
    state: State = .idle,
    /// Lazily initialized, valid if `state` is `active`.
    stream: *brotli.BrotliEncoderState = undefined,

    // Public API.

    pub fn init(exec: *const Execution) EncodingStream {
        return .{ .exec = exec };
    }

    // Transformer API.

    pub fn transform(self: *EncodingStream, controller: *TransformStream.TransformStreamDefaultController, chunk: js.Value) !void {
        const input = chunk.toZig(js.BufferSource) catch {
            return self.fail(controller, "Chunk is not an ArrayBuffer or ArrayBufferView");
        };

        if (input.bytes.len == 0) return;
        return self.process(controller, input.bytes, false);
    }

    pub fn flush(self: *EncodingStream, controller: *TransformStream.TransformStreamDefaultController) !void {
        return self.process(controller, "", true);
    }

    // Implementation.

    fn end(self: *EncodingStream) void {
        switch (self.state) {
            .idle, .ended => {},
            .active => {
                brotli.BrotliEncoderDestroyInstance(self.stream);
                self.state = .ended;
            },
        }
    }

    // Errors the stream, releasing internal stream.
    fn fail(
        self: *EncodingStream,
        controller: *TransformStream.TransformStreamDefaultController,
        message: []const u8,
    ) !void {
        self.end();
        try controller.typeError(message);
        return self.exec.js.typeError(message);
    }

    /// Feed the stream and collect encoded bytes.
    fn feed(
        self: *EncodingStream,
        controller: *TransformStream.TransformStreamDefaultController,
        input: []const u8,
        finish: bool,
    ) !void {
        const stream = self.stream;
        var avail_in: usize = input.len;
        var next_in: [*c]const u8 = input.ptr;

        if (finish) {
            // Operation finalizes the stream.
            while (brotli.BrotliEncoderIsFinished(stream) == brotli.BROTLI_FALSE) {
                // When *available_out is 0, next_out is allowed to be NULL.
                var avail_out: usize = 0;
                const rc = brotli.BrotliEncoderCompressStream(stream, .finish, &avail_in, &next_in, &avail_out, null, null);
                if (rc == brotli.BROTLI_FALSE) {
                    return error.EncodingFailed;
                }
                // Pull everything from encoder.
                while (brotli.BrotliEncoderHasMoreOutput(stream) == brotli.BROTLI_TRUE) {
                    var size: usize = 0;
                    const out = brotli.BrotliEncoderTakeOutput(stream, &size);
                    // Only valid until the next encoder call; enqueue copies it.
                    try controller.enqueueNoSideEffects(.{ .uint8array = .{ .values = out[0..size] } });
                }
            }
            // encoding ended.
            self.end();
        } else {
            // Operation processes more bytes, but does not finalize the stream.
            while (true) {
                var avail_out: usize = 0;
                const rc = brotli.BrotliEncoderCompressStream(stream, .process, &avail_in, &next_in, &avail_out, null, null);
                if (rc == brotli.BROTLI_FALSE) {
                    return error.EncodingFailed;
                }

                while (brotli.BrotliEncoderHasMoreOutput(stream) == brotli.BROTLI_TRUE) {
                    var size: usize = 0;
                    const out = brotli.BrotliEncoderTakeOutput(stream, &size);
                    try controller.enqueueNoSideEffects(.{ .uint8array = .{ .values = out[0..size] } });
                }
                // Done processing if no more input.
                if (avail_in == 0) break;
            }
        }

        // Wake readers.
        return controller.fulfillPendingReads();
    }

    fn process(
        self: *EncodingStream,
        controller: *TransformStream.DefaultController,
        input: []const u8,
        finish: bool,
    ) !void {
        state_machine: switch (self.state) {
            .idle => {
                const stream = brotli.BrotliEncoderCreateInstance(alloc, free, @constCast(self.exec)) orelse {
                    return error.OutOfMemory;
                };
                // brotli defaults to its maximum quality (11), which is ~60x
                // slower than deflate at level 6. Quality 5 is faster than
                // deflate at level 6 and still compresses better. Same
                // default as Apache's mod_brotli.
                // https://httpd.apache.org/docs/2.4/mod/mod_brotli.html#brotlicompressionquality
                const default_quality: u32 = 5;
                _ = brotli.BrotliEncoderSetParameter(stream, .quality, default_quality);
                self.stream = stream;
                self.state = .active;
                continue :state_machine self.state;
            },
            .active => {
                self.feed(controller, input, finish) catch |err| switch (err) {
                    error.StreamNotReadable => return self.fail(controller, "The readable side is closed"),
                    error.EncodingFailed => return self.fail(controller, "Encoding failed"),
                    else => return err,
                };
            },
            .ended => {},
        }
    }
};

/// Does brotli decoding in streaming fashion.
pub const DecodingStream = struct {
    exec: *const Execution,
    state: State = .idle,
    /// Lazily initialized, valid if `state` is `active`.
    stream: *brotli.BrotliDecoderState = undefined,

    // Public API.

    pub fn init(exec: *const Execution) DecodingStream {
        return .{ .exec = exec };
    }

    // Transformer API.

    pub fn transform(self: *DecodingStream, controller: *TransformStream.TransformStreamDefaultController, chunk: js.Value) !void {
        const input = chunk.toZig(js.BufferSource) catch {
            return self.fail(controller, "Chunk is not an ArrayBuffer or ArrayBufferView");
        };

        if (self.state == .ended) {
            // The compressed data already ended. (Every other way to end
            // errors the writable side.)
            if (input.bytes.len > 0) {
                return self.fail(controller, "Junk found after end of compressed data");
            }
            return;
        }

        if (input.bytes.len == 0) return;
        return self.process(controller, input.bytes);
    }

    pub fn flush(self: *DecodingStream, controller: *TransformStream.TransformStreamDefaultController) !void {
        // Each chunk is fully decoded as it's written, so by now the
        // compressed data must have ended.
        if (self.state != .ended) {
            return self.fail(controller, "Compressed input was truncated");
        }
    }

    // Implementation.

    fn end(self: *DecodingStream) void {
        switch (self.state) {
            .idle, .ended => {},
            .active => {
                brotli.BrotliDecoderDestroyInstance(self.stream);
                self.state = .ended;
            },
        }
    }

    // Errors the stream, releasing internal stream.
    fn fail(
        self: *DecodingStream,
        controller: *TransformStream.TransformStreamDefaultController,
        message: []const u8,
    ) !void {
        self.end();
        try controller.typeError(message);
        return self.exec.js.typeError(message);
    }

    /// Feed the stream and collect decoded bytes.
    fn feed(
        self: *DecodingStream,
        controller: *TransformStream.TransformStreamDefaultController,
        input: []const u8,
    ) !void {
        const stream = self.stream;
        var avail_in: usize = input.len;
        var next_in: [*c]const u8 = input.ptr;

        while (true) {
            // When *available_out is 0, next_out is allowed to be NULL.
            var avail_out: usize = 0;
            const result = brotli.BrotliDecoderDecompressStream(stream, &avail_in, &next_in, &avail_out, null, null);

            // Pull everything from decoder. Its output isn't contiguous, so
            // where the ring buffer wraps it takes more than one call.
            while (brotli.BrotliDecoderHasMoreOutput(stream) == brotli.BROTLI_TRUE) {
                var size: usize = 0;
                const out = brotli.BrotliDecoderTakeOutput(stream, &size);
                // Only valid until the next decoder call; enqueue copies it.
                try controller.enqueueNoSideEffects(.{ .uint8array = .{ .values = out[0..size] } });
            }

            switch (result) {
                .needs_more_output => {},
                // All input is consumed; the compressed data continues in a
                // later chunk.
                .needs_more_input => break,
                .success => {
                    // Input is never consumed past the end of the compressed
                    // data, so whatever is left is junk.
                    const has_junk = avail_in > 0;
                    self.end();
                    controller.fulfillPendingReads();
                    if (has_junk) {
                        return error.HasJunkData;
                    }
                    return;
                },
                .@"error" => return error.InvalidData,
            }
        }

        // Wake readers.
        return controller.fulfillPendingReads();
    }

    fn process(
        self: *DecodingStream,
        controller: *TransformStream.DefaultController,
        input: []const u8,
    ) !void {
        state_machine: switch (self.state) {
            .idle => {
                const stream = brotli.BrotliDecoderCreateInstance(alloc, free, @constCast(self.exec)) orelse {
                    return error.OutOfMemory;
                };
                self.stream = stream;
                self.state = .active;
                continue :state_machine self.state;
            },
            .active => {
                self.feed(controller, input) catch |err| switch (err) {
                    error.StreamNotReadable => return self.fail(controller, "The readable side is closed"),
                    error.HasJunkData => return self.fail(controller, "Junk found after end of data"),
                    error.InvalidData => return self.fail(controller, "The data was not valid"),
                    else => return err,
                };
            },
            .ended => {},
        }
    }
};

const HEADER = 16;
const alignment: std.mem.Alignment = .fromByteUnits(HEADER);

fn alloc(raw_exec: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const exec: *const Execution = @ptrCast(@alignCast(raw_exec));
    const allocator = exec._factory.storageAllocator();

    const total = std.math.add(usize, size, HEADER) catch return null;
    const block = allocator.alignedAlloc(u8, alignment, total) catch return null;
    // Write total size of allocation.
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], total, .native);
    // Conceal header part.
    return block.ptr + HEADER;
}

fn free(raw_exec: ?*anyopaque, maybe_address: ?*anyopaque) callconv(.c) void {
    const address = maybe_address orelse return;

    const exec: *const Execution = @ptrCast(@alignCast(raw_exec));
    const allocator = exec._factory.storageAllocator();

    const block: [*]align(HEADER) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(address)) - HEADER));
    const total = std.mem.readInt(usize, block[0..@sizeOf(usize)], .native);
    allocator.free(block[0..total]);
}

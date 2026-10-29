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

const html5ever = @import("../../parser/html5ever.zig");

const TextDecoder = @import("TextDecoder.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

// https://encoding.spec.whatwg.org/#interface-textdecoderstream
const TextDecoderStream = @This();

_transform: *TransformStream,
_decoder: *Decoder,
_encoding: []const u8,

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

pub fn init(label: ?[]const u8, opts_: ?InitOpts, exec: *const Execution) !TextDecoderStream {
    const info = try TextDecoder.encodingForLabel(label);
    const opts = opts_ orelse InitOpts{};

    const decoder = try Decoder.init(info, opts.fatal, opts.ignoreBOM, exec);
    const transform = try TransformStream.initWithZigTransformer(.{ .text_decoder = decoder }, exec);

    return .{
        ._transform = transform,
        ._decoder = decoder,
        ._encoding = try std.ascii.allocLowerString(exec.page_arena, info.name()),
    };
}

/// The stream's decoder, in the frame's memory like the TransformStream that
/// uses it: encoding_rs's state is built in place and holds no heap memory,
/// so a stream that's never closed leaks nothing.
pub const Decoder = struct {
    exec: *const Execution,
    encoding_name: []const u8,
    fatal: bool,
    ignore_bom: bool,
    bom_seen: bool = false,
    state: *anyopaque,

    fn init(info: html5ever.EncodingInfo, fatal: bool, ignore_bom: bool, exec: *const Execution) !*Decoder {
        const size = html5ever.encoding_decoder_size();
        const alignment = html5ever.encoding_decoder_align();
        std.debug.assert(alignment <= 16);
        const state = try exec.page_arena.alignedAlloc(u8, .@"16", size);
        // Only fails for a null pointer.
        const ok = html5ever.encoding_decoder_init(info.handle.?, state.ptr);
        std.debug.assert(ok == 1);
        return exec._factory.create(Decoder{
            .exec = exec,
            .encoding_name = info.name(),
            .fatal = fatal,
            .ignore_bom = ignore_bom,
            .state = state.ptr,
        });
    }

    /// Each chunk must be a BufferSource, shared or not; its bytes decode with what the last
    /// chunk left of a split sequence.
    pub fn transform(self: *Decoder, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
        const input = chunk.toZig(js.AllowSharedBufferSource) catch {
            return fail(controller, "The chunk is not an ArrayBuffer or ArrayBufferView");
        };
        return self.decode(controller, input.bytes, false);
    }

    /// What a split sequence left at the end decodes now: U+FFFD, or a
    /// TypeError in fatal mode.
    pub fn flush(self: *Decoder, controller: *TransformStream.DefaultController) !void {
        return self.decode(controller, "", true);
    }

    // The output only lives for the call: enqueue copies it into a JS string.
    fn decode(self: *Decoder, controller: *TransformStream.DefaultController, input: []const u8, is_last: bool) !void {
        const decoded = TextDecoder.decodeChunk(self.exec.call_arena, .{
            .encoding_name = self.encoding_name,
            .fatal = self.fatal,
            .ignore_bom = self.ignore_bom,
            .bom_seen = &self.bom_seen,
        }, self.state, input, is_last) catch |err| switch (err) {
            error.TypeError => return fail(controller, "The encoded data is not valid"),
            else => return err,
        };
        // Per spec, a chunk that decodes to nothing produces no output.
        if (decoded.len > 0) {
            try controller.enqueue(.{ .string = decoded });
        }
    }

    fn fail(controller: *TransformStream.DefaultController, message: []const u8) !void {
        try controller.typeError(message);
        return error.StreamError;
    }
};

pub fn getReadable(self: *const TextDecoderStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const TextDecoderStream) *WritableStream {
    return self._transform.getWritable();
}

fn getEncoding(self: *const TextDecoderStream) []const u8 {
    return self._encoding;
}

fn getFatal(self: *const TextDecoderStream) bool {
    return self._decoder.fatal;
}

fn getIgnoreBOM(self: *const TextDecoderStream) bool {
    return self._decoder.ignore_bom;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoderStream);

    pub const Meta = struct {
        pub const name = "TextDecoderStream";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextDecoderStream.init, .{});
    pub const encoding = bridge.accessor(TextDecoderStream.getEncoding, null, .{});
    pub const readable = bridge.accessor(TextDecoderStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TextDecoderStream.getWritable, null, .{});
    pub const fatal = bridge.accessor(TextDecoderStream.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoderStream.getIgnoreBOM, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoderStream" {
    try testing.htmlRunner("streams/text_decoder_stream.html", .{});
}

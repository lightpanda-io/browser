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

const js = @import("../../js/js.zig");
const Execution = js.Execution;

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const compress = @import("compress.zig");

const CompressionStream = @This();

_transform: *TransformStream,
_compressor: compress.Compressor,

pub fn init(format: compress.Format, exec: *const Execution) !*CompressionStream {
    const self = try exec._factory.create(CompressionStream{
        ._transform = undefined,
        ._compressor = .init(exec, format),
    });
    self._transform = try TransformStream.initWithZigTransformer(self._compressor.transformer(), exec);
    return self;
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
    // brotli_output_before_close compresses 1.3 MiB at quality 11; that's
    // slow under TSAN.
    try testing.htmlRunner("compression/compression_stream.html", .{ .timeout_ms = 8000 });
}

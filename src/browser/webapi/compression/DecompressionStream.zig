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

const js = @import("../../js/js.zig");

const brotli = @import("brotli.zig");
const zlib = @import("zlib.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

const compress = @import("compress.zig");

const DecompressionStream = @This();

_transform: *TransformStream,
_decompressor: compress.Decompressor,

pub fn init(format: compress.Format, exec: *const Execution) !*DecompressionStream {
    const self = try exec._factory.create(DecompressionStream{
        ._transform = undefined,
        ._decompressor = .init(exec, format),
    });
    self._transform = try TransformStream.initWithZigTransformer(.{ .decompressor = &self._decompressor }, exec);
    return self;
}

pub fn getReadable(self: *const DecompressionStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const DecompressionStream) *WritableStream {
    return self._transform.getWritable();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DecompressionStream);

    pub const Meta = struct {
        pub const name = "DecompressionStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DecompressionStream.init, .{});
    pub const readable = bridge.accessor(DecompressionStream.getReadable, null, .{});
    pub const writable = bridge.accessor(DecompressionStream.getWritable, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: DecompressionStream" {
    try testing.htmlRunner("compression/decompression_stream.html", .{});
}

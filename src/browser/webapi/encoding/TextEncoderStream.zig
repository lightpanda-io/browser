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

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

const TextEncoderStream = @This();

_transform: *TransformStream,

pub fn init(exec: *const Execution) !TextEncoderStream {
    const transform = try TransformStream.initWithZigTransform(&encodeTransform, exec);
    return .{
        ._transform = transform,
    };
}

fn encodeTransform(controller: *TransformStream.DefaultController, chunk: js.Value) !void {
    // chunk should be a JS string; encode it as UTF-8 bytes (Uint8Array)
    const str = chunk.isString() orelse return error.InvalidChunk;
    const slice = try str.toSlice();
    try controller.enqueue(.{ .uint8array = .{ .values = slice } });
}

pub fn getReadable(self: *const TextEncoderStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const TextEncoderStream) *WritableStream {
    return self._transform.getWritable();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoderStream);

    pub const Meta = struct {
        pub const name = "TextEncoderStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextEncoderStream.init, .{});
    pub const encoding = bridge.property("utf-8", .{ .template = false });
    pub const readable = bridge.accessor(TextEncoderStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TextEncoderStream.getWritable, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoderStream" {
    try testing.htmlRunner("streams/transform_stream.html", .{});
}

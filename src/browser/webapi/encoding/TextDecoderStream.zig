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

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

const TextDecoderStream = @This();

_transform: *TransformStream,
_fatal: bool,
_ignore_bom: bool,

const Label = enum {
    utf8,
    @"utf-8",
    @"unicode-1-1-utf-8",
};

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

pub fn init(label_: ?[]const u8, opts_: ?InitOpts, exec: *const Execution) !TextDecoderStream {
    if (label_) |label| {
        _ = std.meta.stringToEnum(Label, label) orelse return error.RangeError;
    }

    const opts = opts_ orelse InitOpts{};
    const decodeFn: TransformStream.ZigTransformFn = blk: {
        if (opts.ignoreBOM) {
            break :blk struct {
                fn decode(controller: *TransformStream.DefaultController, chunk: js.Value) !void {
                    return decodeTransform(controller, chunk, true);
                }
            }.decode;
        } else {
            break :blk struct {
                fn decode(controller: *TransformStream.DefaultController, chunk: js.Value) !void {
                    return decodeTransform(controller, chunk, false);
                }
            }.decode;
        }
    };

    const transform = try TransformStream.initWithZigTransform(decodeFn, exec);

    return .{
        ._transform = transform,
        ._fatal = opts.fatal,
        ._ignore_bom = opts.ignoreBOM,
    };
}

fn decodeTransform(controller: *TransformStream.DefaultController, chunk: js.Value, ignoreBOM: bool) !void {
    // chunk should be a Uint8Array; decode it as UTF-8 string
    const typed_array = try chunk.toZig(js.TypedArray(u8));
    var input = typed_array.values;

    // Strip UTF-8 BOM if present
    if (ignoreBOM == false and std.mem.startsWith(u8, input, &.{ 0xEF, 0xBB, 0xBF })) {
        input = input[3..];
    }

    // Per spec, empty chunks produce no output
    if (input.len == 0) return;

    try controller.enqueue(.{ .string = input });
}

pub fn getReadable(self: *const TextDecoderStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const TextDecoderStream) *WritableStream {
    return self._transform.getWritable();
}

pub fn getFatal(self: *const TextDecoderStream) bool {
    return self._fatal;
}

pub fn getIgnoreBOM(self: *const TextDecoderStream) bool {
    return self._ignore_bom;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoderStream);

    pub const Meta = struct {
        pub const name = "TextDecoderStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextDecoderStream.init, .{});
    pub const encoding = bridge.property("utf-8", .{ .template = false });
    pub const readable = bridge.accessor(TextDecoderStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TextDecoderStream.getWritable, null, .{});
    pub const fatal = bridge.accessor(TextDecoderStream.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoderStream.getIgnoreBOM, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoderStream" {
    try testing.htmlRunner("streams/text_decoder_stream.html", .{});
}

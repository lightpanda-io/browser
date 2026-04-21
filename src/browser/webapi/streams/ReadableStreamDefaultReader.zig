// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const ReadableStream = @import("ReadableStream.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");

const Execution = js.Execution;

const ReadableStreamDefaultReader = @This();

_stream: ?*ReadableStream,
_execution: *const Execution,

pub fn init(stream: *ReadableStream, exec: *const Execution) !*ReadableStreamDefaultReader {
    return exec._factory.create(ReadableStreamDefaultReader{
        ._stream = stream,
        ._execution = exec,
    });
}

pub const ReadResult = struct {
    done: bool,
    value: Chunk,

    // Done like this so that we can properly return undefined in some cases
    const Chunk = union(enum) {
        empty,
        string: []const u8,
        uint8array: js.TypedArray(u8),
        js_value: js.Value.Global,

        pub fn fromChunk(chunk: ReadableStreamDefaultController.Chunk) Chunk {
            return switch (chunk) {
                .string => |s| .{ .string = s },
                .uint8array => |arr| .{ .uint8array = arr },
                .js_value => |val| .{ .js_value = val },
            };
        }
    };
};

pub fn read(self: *ReadableStreamDefaultReader, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Reader has been released" });
    };

    if (stream._state == .errored) {
        //const err = stream._stored_error orelse "Stream errored";
        return local.rejectPromise(.{ .type_error = "Stream errored" });
    }

    if (stream._controller.dequeue()) |chunk| {
        const result = ReadResult{
            .done = false,
            .value = .fromChunk(chunk),
        };
        return local.resolvePromise(result);
    }

    if (stream._state == .closed) {
        const result = ReadResult{
            .done = true,
            .value = .empty,
        };
        return local.resolvePromise(result);
    }

    // No data, but not closed. We need to queue the read for any future data
    return stream._controller.addPendingRead();
}

pub fn releaseLock(self: *ReadableStreamDefaultReader) void {
    if (self._stream) |stream| {
        stream.releaseReader();
        self._stream = null;
    }
}

pub fn cancel(self: *ReadableStreamDefaultReader, reason_: ?[]const u8, exec: *const Execution) !js.Promise {
    const stream = self._stream orelse {
        return exec.context.local.?.rejectPromise(.{ .type_error = "Reader has been released" });
    };

    self.releaseLock();

    return stream.cancel(reason_, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ReadableStreamDefaultReader);

    pub const Meta = struct {
        pub const name = "ReadableStreamDefaultReader";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const read = bridge.function(ReadableStreamDefaultReader.read, .{});
    pub const cancel = bridge.function(ReadableStreamDefaultReader.cancel, .{});
    pub const releaseLock = bridge.function(ReadableStreamDefaultReader.releaseLock, .{});
};

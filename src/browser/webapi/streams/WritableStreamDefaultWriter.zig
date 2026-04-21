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
const WritableStream = @import("WritableStream.zig");

const Execution = js.Execution;

const WritableStreamDefaultWriter = @This();

_stream: ?*WritableStream,

pub fn init(stream: *WritableStream, exec: *const Execution) !*WritableStreamDefaultWriter {
    return exec._factory.create(WritableStreamDefaultWriter{
        ._stream = stream,
    });
}

pub fn write(self: *WritableStreamDefaultWriter, chunk: js.Value, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return local.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.writeChunk(chunk, exec);

    return local.resolvePromise(.{});
}

pub fn close(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return local.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.closeStream(exec);

    return local.resolvePromise(.{});
}

pub fn releaseLock(self: *WritableStreamDefaultWriter) void {
    if (self._stream) |stream| {
        stream._writer = null;
        self._stream = null;
    }
}

pub fn getClosed(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state == .closed) {
        return local.resolvePromise(.{});
    }

    return local.resolvePromise(.{});
}

pub fn getDesiredSize(self: *const WritableStreamDefaultWriter) ?i32 {
    const stream = self._stream orelse return null;
    return switch (stream._state) {
        .writable => 1,
        .closed => 0,
        .errored => null,
    };
}

pub fn getReady(self: *WritableStreamDefaultWriter, exec: *const Execution) !js.Promise {
    _ = self;
    return exec.context.local.?.resolvePromise(.{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WritableStreamDefaultWriter);

    pub const Meta = struct {
        pub const name = "WritableStreamDefaultWriter";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const write = bridge.function(WritableStreamDefaultWriter.write, .{});
    pub const close = bridge.function(WritableStreamDefaultWriter.close, .{});
    pub const releaseLock = bridge.function(WritableStreamDefaultWriter.releaseLock, .{});
    pub const closed = bridge.accessor(WritableStreamDefaultWriter.getClosed, null, .{});
    pub const ready = bridge.accessor(WritableStreamDefaultWriter.getReady, null, .{});
    pub const desiredSize = bridge.accessor(WritableStreamDefaultWriter.getDesiredSize, null, .{});
};

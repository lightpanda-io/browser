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
const Page = @import("../../Page.zig");
const WritableStream = @import("WritableStream.zig");

const WritableStreamDefaultWriter = @This();

_stream: ?*WritableStream,

pub fn init(stream: *WritableStream, page: *Page) !*WritableStreamDefaultWriter {
    return page._factory.create(WritableStreamDefaultWriter{
        ._stream = stream,
    });
}

pub fn write(self: *WritableStreamDefaultWriter, chunk: js.Value, page: *Page) !js.Promise {
    const stream = self._stream orelse {
        return page.js.local.?.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return page.js.local.?.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.writeChunk(chunk, page);

    return page.js.local.?.resolvePromise(.{});
}

pub fn close(self: *WritableStreamDefaultWriter, page: *Page) !js.Promise {
    const stream = self._stream orelse {
        return page.js.local.?.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state != .writable) {
        return page.js.local.?.rejectPromise(.{ .type_error = "Stream is not writable" });
    }

    try stream.closeStream(page);

    return page.js.local.?.resolvePromise(.{});
}

pub fn releaseLock(self: *WritableStreamDefaultWriter) void {
    if (self._stream) |stream| {
        stream._writer = null;
        self._stream = null;
    }
}

pub fn getClosed(self: *WritableStreamDefaultWriter, page: *Page) !js.Promise {
    const stream = self._stream orelse {
        return page.js.local.?.rejectPromise(.{ .type_error = "Writer has been released" });
    };

    if (stream._state == .closed) {
        return page.js.local.?.resolvePromise(.{});
    }

    return page.js.local.?.resolvePromise(.{});
}

pub fn getDesiredSize(self: *const WritableStreamDefaultWriter) ?i32 {
    const stream = self._stream orelse return null;
    return switch (stream._state) {
        .writable => 1,
        .closed => 0,
        .errored => null,
    };
}

pub fn getReady(self: *WritableStreamDefaultWriter, page: *Page) !js.Promise {
    _ = self;
    return page.js.local.?.resolvePromise(.{});
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

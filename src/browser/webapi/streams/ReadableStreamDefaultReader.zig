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

const Page = @import("../../Page.zig");
const ReadableStream = @import("ReadableStream.zig");

const ReadableStreamDefaultReader = @This();

_page: *Page,
_stream: ?*ReadableStream,

pub fn init(stream: *ReadableStream, page: *Page) !*ReadableStreamDefaultReader {
    return page._factory.create(ReadableStreamDefaultReader{
        ._stream = stream,
        ._page = page,
    });
}

pub const ReadResult = struct {
    done: bool,
    value: ?js.TypedArray(u8),
};

pub fn read(self: *ReadableStreamDefaultReader, page: *Page) !js.Promise {
    const stream = self._stream orelse {
        return page.js.rejectPromise("Reader has been released");
    };

    if (stream._state == .errored) {
        const err = stream._stored_error orelse "Stream errored";
        return page.js.rejectPromise(err);
    }

    if (stream._controller.dequeue()) |chunk| {
        const result = ReadResult{
            .done = false,
            .value = js.TypedArray(u8){ .values = chunk },
        };
        return page.js.resolvePromise(result);
    }

    if (stream._state == .closed) {
        const result = ReadResult{
            .done = true,
            .value = null,
        };
        return page.js.resolvePromise(result);
    }

    // No data, but not closed. We need to queue the read for any future data
    return stream._controller.addPendingRead(page);
}

pub fn releaseLock(self: *ReadableStreamDefaultReader) void {
    if (self._stream) |stream| {
        stream.releaseReader();
        self._stream = null;
    }
}

pub fn cancel(self: *ReadableStreamDefaultReader, reason_: ?[]const u8, page: *Page) !js.Promise {
    const stream = self._stream orelse {
        return page.js.rejectPromise("Reader has been released");
    };

    const reason = reason_ orelse "canceled";

    try stream._controller.doError(reason);
    self.releaseLock();

    return page.js.resolvePromise(.{});
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

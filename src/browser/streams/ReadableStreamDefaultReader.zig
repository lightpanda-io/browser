// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const Page = @import("../page.zig").Page;
const ReadableStream = @import("./ReadableStream.zig");
const ReadableStreamReadResult = @import("./ReadableStream.zig").ReadableStreamReadResult;

const ReadableStreamDefaultReader = @This();

stream: *ReadableStream,

pub fn constructor(stream: *ReadableStream) ReadableStreamDefaultReader {
    return .{ .stream = stream };
}

pub fn get_closed(self: *const ReadableStreamDefaultReader) js.Promise {
    return self.stream.closed_resolver.promise();
}

pub fn _cancel(self: *ReadableStreamDefaultReader, reason: ?[]const u8, page: *Page) !js.Promise {
    return try self.stream._cancel(reason, page);
}

pub fn _read(self: *const ReadableStreamDefaultReader, page: *Page) !js.Promise {
    const stream = self.stream;

    switch (stream.state) {
        .readable => {
            if (stream.queue.items.len > 0) {
                const data = self.stream.queue.orderedRemove(0);
                const promise = page.js.resolvePromise(ReadableStreamReadResult.init(data, false));
                try self.stream.pullIf();
                return promise;
            }
            if (self.stream.reader_resolver) |rr| {
                return rr.promise();
            }
            const persistent_resolver = try page.js.createPromiseResolver(.page);
            self.stream.reader_resolver = persistent_resolver;
            return persistent_resolver.promise();
        },
        .closed => |_| {
            if (stream.queue.items.len > 0) {
                const data = self.stream.queue.orderedRemove(0);
                return page.js.resolvePromise(ReadableStreamReadResult.init(data, false));
            }
            return page.js.resolvePromise(ReadableStreamReadResult{ .done = true });
        },
        .cancelled => |_| return page.js.resolvePromise(ReadableStreamReadResult{ .value = .empty, .done = true }),
        .errored => |err| return page.js.rejectPromise(err),
    }
}

pub fn _releaseLock(self: *const ReadableStreamDefaultReader) !void {
    self.stream.locked = false;

    if (self.stream.reader_resolver) |rr| {
        try rr.reject("TypeError");
    }
}

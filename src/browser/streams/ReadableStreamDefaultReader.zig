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
                const resolver = page.main_context.createPromiseResolver();

                try resolver.resolve(ReadableStreamReadResult.init(data, false));
                try self.stream.pullIf();
                return resolver.promise();
            } else {
                if (self.stream.reader_resolver) |rr| {
                    return rr.promise();
                } else {
                    const persistent_resolver = try page.main_context.createPersistentPromiseResolver(.page);
                    self.stream.reader_resolver = persistent_resolver;
                    return persistent_resolver.promise();
                }
            }
        },
        .closed => |_| {
            const resolver = page.main_context.createPromiseResolver();

            if (stream.queue.items.len > 0) {
                const data = self.stream.queue.orderedRemove(0);
                try resolver.resolve(ReadableStreamReadResult.init(data, false));
            } else {
                try resolver.resolve(ReadableStreamReadResult{ .done = true });
            }

            return resolver.promise();
        },
        .cancelled => |_| {
            const resolver = page.main_context.createPromiseResolver();
            try resolver.resolve(ReadableStreamReadResult{ .value = .empty, .done = true });
            return resolver.promise();
        },
        .errored => |err| {
            const resolver = page.main_context.createPromiseResolver();
            try resolver.reject(err);
            return resolver.promise();
        },
    }
}

pub fn _releaseLock(self: *const ReadableStreamDefaultReader) !void {
    self.stream.locked = false;

    if (self.stream.reader_resolver) |rr| {
        try rr.reject("TypeError");
    }
}

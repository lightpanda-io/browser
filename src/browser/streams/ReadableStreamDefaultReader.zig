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

const v8 = @import("v8");

const log = @import("../../log.zig");
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;
const ReadableStream = @import("./ReadableStream.zig");
const ReadableStreamReadResult = @import("./ReadableStream.zig").ReadableStreamReadResult;

const ReadableStreamDefaultReader = @This();

stream: *ReadableStream,

pub fn constructor(stream: *ReadableStream) ReadableStreamDefaultReader {
    return .{ .stream = stream };
}

pub fn get_closed(self: *const ReadableStreamDefaultReader, page: *Page) Env.Promise {
    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = self.stream.closed_resolver.castToPromiseResolver(),
    };

    return resolver.promise();
}

pub fn _cancel(self: *ReadableStreamDefaultReader, reason: ?[]const u8, page: *Page) !Env.Promise {
    return try self.stream._cancel(reason, page);
}

pub fn _read(self: *const ReadableStreamDefaultReader, page: *Page) !Env.Promise {
    const stream = self.stream;

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    switch (stream.state) {
        .readable => {
            if (stream.queue.items.len > 0) {
                const data = self.stream.queue.orderedRemove(0);
                try resolver.resolve(ReadableStreamReadResult{ .value = .{ .data = data }, .done = false });
            } else {
                if (self.stream.reader_resolver) |rr| {
                    const r_resolver = Env.PromiseResolver{
                        .js_context = page.main_context,
                        .resolver = rr.castToPromiseResolver(),
                    };

                    return r_resolver.promise();
                } else {
                    const p_resolver = v8.Persistent(v8.PromiseResolver).init(page.main_context.isolate, resolver.resolver);
                    self.stream.reader_resolver = p_resolver;
                    return resolver.promise();
                }

                try self.stream.pullIf();
            }
        },
        .closed => |_| {
            if (stream.queue.items.len > 0) {
                const data = self.stream.queue.orderedRemove(0);
                try resolver.resolve(ReadableStreamReadResult{ .value = .{ .data = data }, .done = false });
            } else {
                try resolver.resolve(ReadableStreamReadResult{ .value = .empty, .done = true });
            }
        },
        .cancelled => |_| {
            try resolver.resolve(ReadableStreamReadResult{ .value = .empty, .done = true });
        },
        .errored => |err| {
            try resolver.reject(err);
        },
    }

    return resolver.promise();
}

pub fn _releaseLock(self: *const ReadableStreamDefaultReader, page: *Page) !void {
    self.stream.locked = false;

    if (self.stream.reader_resolver) |rr| {
        const resolver = Env.PromiseResolver{
            .js_context = page.main_context,
            .resolver = rr.castToPromiseResolver(),
        };

        try resolver.reject("TypeError");
    }
}

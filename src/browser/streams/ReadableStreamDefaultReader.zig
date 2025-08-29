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

const ReadableStreamDefaultReader = @This();

stream: *ReadableStream,
// This promise resolves when the stream is closed.
closed_resolver: Env.PromiseResolver,

pub fn constructor(stream: *ReadableStream, page: *Page) ReadableStreamDefaultReader {
    const closed_resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    return .{
        .stream = stream,
        .closed_resolver = closed_resolver,
    };
}

pub fn get_closed(self: *const ReadableStreamDefaultReader) Env.Promise {
    return self.closed_resolver.promise();
}

pub fn _cancel(self: *ReadableStreamDefaultReader) Env.Promise {
    return self.stream._cancel();
}

pub const ReadableStreamReadResult = struct {
    value: ?[]const u8,
    done: bool,

    pub fn get_value(self: *const ReadableStreamReadResult, page: *Page) !?[]const u8 {
        return if (self.value) |value| try page.arena.dupe(u8, value) else null;
    }

    pub fn get_done(self: *const ReadableStreamReadResult) bool {
        return self.done;
    }
};

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
                try resolver.resolve(ReadableStreamReadResult{ .value = data, .done = false });
            } else {
                // TODO: need to wait until we have more data
                try resolver.reject("TODO!");
                return error.Todo;
            }
        },
        .closed => |_| {
            if (stream.queue.items.len > 0) {
                const data = try page.arena.dupe(u8, self.stream.queue.orderedRemove(0));
                try resolver.resolve(ReadableStreamReadResult{ .value = data, .done = false });
            } else {
                try resolver.resolve(ReadableStreamReadResult{ .value = null, .done = true });
            }
        },
        .errored => |err| {
            try resolver.reject(err);
        },
    }

    return resolver.promise();
}

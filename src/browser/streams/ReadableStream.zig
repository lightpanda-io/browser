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
const log = @import("../../log.zig");

const v8 = @import("v8");
const Page = @import("../page.zig").Page;
const Env = @import("../env.zig").Env;

const ReadableStream = @This();
const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");

const State = union(enum) {
    readable,
    closed: ?[]const u8,
    errored: Env.JsObject,
};

// This promise resolves when a stream is canceled.
cancel_resolver: Env.PromiseResolver,
locked: bool = false,
state: State = .readable,

// A queue would be ideal here but I don't want to pay the cost of the priority operation.
queue: std.ArrayListUnmanaged([]const u8) = .empty,

const UnderlyingSource = struct {
    start: ?Env.Function = null,
    pull: ?Env.Function = null,
    cancel: ?Env.Function = null,
    type: ?[]const u8 = null,
};

const QueueingStrategy = struct {
    size: ?Env.Function = null,
    high_water_mark: f64 = 1.0,
};

pub fn constructor(underlying: ?UnderlyingSource, strategy: ?QueueingStrategy, page: *Page) !*ReadableStream {
    _ = strategy;

    const cancel_resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    const stream = try page.arena.create(ReadableStream);
    stream.* = ReadableStream{ .cancel_resolver = cancel_resolver };

    const controller = ReadableStreamDefaultController{ .stream = stream };

    // call start
    if (underlying) |src| {
        if (src.start) |start| {
            try start.call(void, .{controller});
        }
    }

    return stream;
}

pub fn _cancel(self: *const ReadableStream) Env.Promise {
    return self.cancel_resolver.promise();
}

pub fn get_locked(self: *const ReadableStream) bool {
    return self.locked;
}

const GetReaderOptions = struct {
    mode: ?[]const u8 = null,
};

pub fn _getReader(self: *ReadableStream, _options: ?GetReaderOptions, page: *Page) ReadableStreamDefaultReader {
    const options = _options orelse GetReaderOptions{};
    _ = options;

    return ReadableStreamDefaultReader.constructor(self, page);
}

const testing = @import("../../testing.zig");
test "streams: ReadableStream" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "var readResult;", "undefined" },
        .{
            \\  const stream = new ReadableStream({
            \\    start(controller) {
            \\      controller.enqueue("hello");
            \\      controller.enqueue("world");
            \\      controller.close();
            \\    }
            \\  });
            ,
            undefined,
        },
        .{
            \\ const reader = stream.getReader();
            \\ (async function () { readResult = await reader.read() }());
            \\ false;
            ,
            "false",
        },
        .{ "reader", "[object ReadableStreamDefaultReader]" },
        .{ "readResult.value", "hello" },
        .{ "readResult.done", "false" },
    }, .{});
}

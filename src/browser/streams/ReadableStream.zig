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
    cancelled: ?[]const u8,
    errored: Env.JsObject,
};

// This promise resolves when a stream is canceled.
cancel_resolver: v8.Persistent(v8.PromiseResolver),
closed_resolver: v8.Persistent(v8.PromiseResolver),
reader_resolver: ?v8.Persistent(v8.PromiseResolver) = null,

locked: bool = false,
state: State = .readable,

cancel_fn: ?Env.Function = null,
pull_fn: ?Env.Function = null,

strategy: QueueingStrategy,
queue: std.ArrayListUnmanaged([]const u8) = .empty,

pub const ReadableStreamReadResult = struct {
    const ValueUnion =
        union(enum) { data: []const u8, empty: void };

    value: ValueUnion,
    done: bool,

    pub fn get_value(self: *const ReadableStreamReadResult) ValueUnion {
        return self.value;
    }

    pub fn get_done(self: *const ReadableStreamReadResult) bool {
        return self.done;
    }
};

const UnderlyingSource = struct {
    start: ?Env.Function = null,
    pull: ?Env.Function = null,
    cancel: ?Env.Function = null,
    type: ?[]const u8 = null,
};

const QueueingStrategy = struct {
    size: ?Env.Function = null,
    high_water_mark: u32 = 1,
};

pub fn constructor(underlying: ?UnderlyingSource, _strategy: ?QueueingStrategy, page: *Page) !*ReadableStream {
    const strategy: QueueingStrategy = _strategy orelse .{};

    const cancel_resolver = v8.Persistent(v8.PromiseResolver).init(
        page.main_context.isolate,
        v8.PromiseResolver.init(page.main_context.v8_context),
    );

    const closed_resolver = v8.Persistent(v8.PromiseResolver).init(
        page.main_context.isolate,
        v8.PromiseResolver.init(page.main_context.v8_context),
    );

    const stream = try page.arena.create(ReadableStream);
    stream.* = ReadableStream{ .cancel_resolver = cancel_resolver, .closed_resolver = closed_resolver, .strategy = strategy };

    const controller = ReadableStreamDefaultController{ .stream = stream };

    // call start
    if (underlying) |src| {
        if (src.start) |start| {
            try start.call(void, .{controller});
        }

        if (src.cancel) |cancel| {
            stream.cancel_fn = cancel;
        }

        if (src.pull) |pull| {
            stream.pull_fn = pull;
            try stream.pullIf();
        }
    }

    return stream;
}

pub fn destructor(self: *ReadableStream) void {
    self.cancel_resolver.deinit();
    self.closed_resolver.deinit();

    if (self.reader_resolver) |*rr| {
        rr.deinit();
    }
}

pub fn get_locked(self: *const ReadableStream) bool {
    return self.locked;
}

pub fn _cancel(self: *ReadableStream, reason: ?[]const u8, page: *Page) !Env.Promise {
    if (self.locked) {
        return error.TypeError;
    }

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = self.cancel_resolver.castToPromiseResolver(),
    };

    self.state = .{ .cancelled = if (reason) |r| try page.arena.dupe(u8, r) else null };

    // Call cancel callback.
    if (self.cancel_fn) |cancel| {
        if (reason) |r| {
            try cancel.call(void, .{r});
        } else {
            try cancel.call(void, .{});
        }
    }

    try resolver.resolve({});
    return resolver.promise();
}

pub fn pullIf(self: *ReadableStream) !void {
    if (self.pull_fn) |pull_fn| {
        // Must be under the high water mark AND readable.
        if ((self.queue.items.len < self.strategy.high_water_mark) and self.state == .readable) {
            const controller = ReadableStreamDefaultController{ .stream = self };
            try pull_fn.call(void, .{controller});
        }
    }
}

const GetReaderOptions = struct {
    // Mode must equal 'byob' or be undefined. RangeError otherwise.
    mode: ?[]const u8 = null,
};

pub fn _getReader(self: *ReadableStream, _options: ?GetReaderOptions) !ReadableStreamDefaultReader {
    if (self.locked) {
        return error.TypeError;
    }

    // TODO: Determine if we need the ReadableStreamBYOBReader
    const options = _options orelse GetReaderOptions{};
    _ = options;

    return ReadableStreamDefaultReader.constructor(self);
}

// TODO: pipeThrough (requires TransformStream)

// TODO: pipeTo (requires WritableStream)

// TODO: tee

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

test "streams: ReadableStream cancel and close" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();
    try runner.testCases(&.{
        .{ "var readResult; var cancelResult; var closeResult;", "undefined" },

        // Test 1: Stream with controller.close()
        .{
            \\  const stream1 = new ReadableStream({
            \\    start(controller) {
            \\      controller.enqueue("first");
            \\      controller.enqueue("second");
            \\      controller.close();
            \\    }
            \\  });
            ,
            undefined,
        },
        .{ "const reader1 = stream1.getReader();", undefined },
        .{
            \\ (async function () { 
            \\   readResult = await reader1.read();
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "readResult.value", "first" },
        .{ "readResult.done", "false" },

        // Read second chunk
        .{
            \\ (async function () { 
            \\   readResult = await reader1.read();
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "readResult.value", "second" },
        .{ "readResult.done", "false" },

        // Read after close - should get done: true
        .{
            \\ (async function () { 
            \\   readResult = await reader1.read();
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "readResult.value", "undefined" },
        .{ "readResult.done", "true" },

        // Test 2: Stream with reader.cancel()
        .{
            \\  const stream2 = new ReadableStream({
            \\    start(controller) {
            \\      controller.enqueue("data1");
            \\      controller.enqueue("data2");
            \\      controller.enqueue("data3");
            \\    },
            \\    cancel(reason) {
            \\      closeResult = `Stream cancelled: ${reason}`;
            \\    }
            \\  });
            ,
            undefined,
        },
        .{ "const reader2 = stream2.getReader();", undefined },

        // Read one chunk before canceling
        .{
            \\ (async function () { 
            \\   readResult = await reader2.read();
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "readResult.value", "data1" },
        .{ "readResult.done", "false" },

        // Cancel the stream
        .{
            \\ (async function () { 
            \\   cancelResult = await reader2.cancel("user requested");
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "cancelResult", "undefined" },
        .{ "closeResult", "Stream cancelled: user requested" },

        // Try to read after cancel - should throw or return done
        .{
            \\ try {
            \\   (async function () { 
            \\     readResult = await reader2.read();
            \\   }());
            \\ } catch(e) {
            \\   readResult = { error: e.name };
            \\ }
            \\ false;
            ,
            "false",
        },

        // Test 3: Cancel without reason
        .{
            \\  const stream3 = new ReadableStream({
            \\    start(controller) {
            \\      controller.enqueue("test");
            \\    },
            \\    cancel(reason) {
            \\      closeResult = reason === undefined ? "no reason" : reason;
            \\    }
            \\  });
            ,
            undefined,
        },
        .{ "const reader3 = stream3.getReader();", undefined },
        .{
            \\ (async function () { 
            \\   await reader3.cancel();
            \\ }());
            \\ false;
            ,
            "false",
        },
        .{ "closeResult", "no reason" },
    }, .{});
}

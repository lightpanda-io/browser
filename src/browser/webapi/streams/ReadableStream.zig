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
const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");

pub fn registerTypes() []const type {
    return &.{
        ReadableStream,
        AsyncIterator,
    };
}

const ReadableStream = @This();

pub const State = enum {
    readable,
    closed,
    errored,
};

_page: *Page,
_state: State,
_reader: ?*ReadableStreamDefaultReader,
_controller: *ReadableStreamDefaultController,
_stored_error: ?[]const u8,
_pull_fn: ?js.Function.Global = null,
_pulling: bool = false,
_pull_again: bool = false,
_cancel: ?Cancel = null,

const UnderlyingSource = struct {
    start: ?js.Function = null,
    pull: ?js.Function.Global = null,
    cancel: ?js.Function.Global = null,
    type: ?[]const u8 = null,
};

const QueueingStrategy = struct {
    size: ?js.Function = null,
    highWaterMark: u32 = 1,
};

pub fn init(src_: ?UnderlyingSource, strategy_: ?QueueingStrategy, page: *Page) !*ReadableStream {
    const strategy: QueueingStrategy = strategy_ orelse .{};

    const self = try page._factory.create(ReadableStream{
        ._page = page,
        ._state = .readable,
        ._reader = null,
        ._controller = undefined,
        ._stored_error = null,
    });

    self._controller = try ReadableStreamDefaultController.init(self, strategy.highWaterMark, page);

    if (src_) |src| {
        if (src.start) |start| {
            try start.call(void, .{self._controller});
        }

        if (src.cancel) |callback| {
            self._cancel = .{
                .callback = callback,
            };
        }

        if (src.pull) |pull| {
            self._pull_fn = pull;
            try self.callPullIfNeeded();
        }
    }

    return self;
}

pub fn initWithData(data: []const u8, page: *Page) !*ReadableStream {
    const stream = try init(null, null, page);

    // For Phase 1: immediately enqueue all data and close
    try stream._controller.enqueue(.{ .uint8array = .{ .values = data } });
    try stream._controller.close();

    return stream;
}

pub fn getReader(self: *ReadableStream, page: *Page) !*ReadableStreamDefaultReader {
    if (self.getLocked()) {
        return error.ReaderLocked;
    }

    const reader = try ReadableStreamDefaultReader.init(self, page);
    self._reader = reader;
    return reader;
}

pub fn releaseReader(self: *ReadableStream) void {
    self._reader = null;
}

pub fn getAsyncIterator(self: *ReadableStream, page: *Page) !*AsyncIterator {
    return AsyncIterator.init(self, page);
}

pub fn getLocked(self: *const ReadableStream) bool {
    return self._reader != null;
}

pub fn callPullIfNeeded(self: *ReadableStream) !void {
    if (!self.shouldCallPull()) {
        return;
    }

    if (self._pulling) {
        self._pull_again = true;
        return;
    }

    self._pulling = true;

    const pull_fn = &(self._pull_fn orelse return);

    // Call the pull function
    // Note: In a complete implementation, we'd handle the promise returned by pull
    // and set _pulling = false when it resolves
    try pull_fn.local().call(void, .{self._controller});

    self._pulling = false;

    // If pull was requested again while we were pulling, pull again
    if (self._pull_again) {
        self._pull_again = false;
        try self.callPullIfNeeded();
    }
}

fn shouldCallPull(self: *const ReadableStream) bool {
    if (self._state != .readable) {
        return false;
    }

    if (self._pull_fn == null) {
        return false;
    }

    const desired_size = self._controller.getDesiredSize() orelse return false;
    return desired_size > 0;
}

pub fn cancel(self: *ReadableStream, reason: ?[]const u8, page: *Page) !js.Promise {
    if (self._state != .readable) {
        if (self._cancel) |c| {
            if (c.resolver) |r| {
                return r.promise();
            }
        }
        return page.js.resolvePromise(.{});
    }

    if (self._cancel == null) {
        self._cancel = Cancel{};
    }

    var c = &self._cancel.?;
    if (c.resolver == null) {
        c.resolver = try page.js.createPromiseResolver().persist();
    }

    // Execute the cancel callback if provided
    if (c.callback) |*cb| {
        if (reason) |r| {
            try cb.local().call(void, .{r});
        } else {
            try cb.local().call(void, .{});
        }
    }

    self._state = .closed;
    self._controller._queue.clearRetainingCapacity();

    const result = ReadableStreamDefaultReader.ReadResult{
        .done = true,
        .value = .empty,
    };
    for (self._controller._pending_reads.items) |resolver| {
        resolver.resolve("stream cancelled", result);
    }
    self._controller._pending_reads.clearRetainingCapacity();

    c.resolver.?.resolve("ReadableStream.cancel", {});
    return c.resolver.?.promise();
}

const Cancel = struct {
    callback: ?js.Function.Global = null,
    reason: ?[]const u8 = null,
    resolver: ?js.PromiseResolver = null,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ReadableStream);

    pub const Meta = struct {
        pub const name = "ReadableStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ReadableStream.init, .{});
    pub const cancel = bridge.function(ReadableStream.cancel, .{});
    pub const getReader = bridge.function(ReadableStream.getReader, .{});
    pub const locked = bridge.accessor(ReadableStream.getLocked, null, .{});
    pub const symbol_async_iterator = bridge.iterator(ReadableStream.getAsyncIterator, .{ .async = true });
};

pub const AsyncIterator = struct {
    _stream: *ReadableStream,
    _reader: *ReadableStreamDefaultReader,

    pub fn init(stream: *ReadableStream, page: *Page) !*AsyncIterator {
        const reader = try stream.getReader(page);
        return page._factory.create(AsyncIterator{
            ._reader = reader,
            ._stream = stream,
        });
    }

    pub fn next(self: *AsyncIterator, page: *Page) !js.Promise {
        return self._reader.read(page);
    }

    pub fn @"return"(self: *AsyncIterator, page: *Page) !js.Promise {
        self._reader.releaseLock();
        return page.js.resolvePromise(.{ .done = true, .value = null });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ReadableStream.AsyncIterator);

        pub const Meta = struct {
            pub const name = "ReadableStreamAsyncIterator";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const next = bridge.function(ReadableStream.AsyncIterator.next, .{});
        pub const @"return" = bridge.function(ReadableStream.AsyncIterator.@"return", .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: ReadableStream" {
    try testing.htmlRunner("streams/readable_stream.html", .{});
}

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
cancel_resolver: Env.PersistentPromiseResolver,
closed_resolver: Env.PersistentPromiseResolver,
reader_resolver: ?Env.PersistentPromiseResolver = null,

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

    const cancel_resolver = page.main_context.createPersistentPromiseResolver();
    const closed_resolver = page.main_context.createPersistentPromiseResolver();

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

    self.state = .{ .cancelled = if (reason) |r| try page.arena.dupe(u8, r) else null };

    // Call cancel callback.
    if (self.cancel_fn) |cancel| {
        if (reason) |r| {
            try cancel.call(void, .{r});
        } else {
            try cancel.call(void, .{});
        }
    }

    try self.cancel_resolver.resolve({});
    return self.cancel_resolver.promise();
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
    try testing.htmlRunner("streams/readable_stream.html");
}

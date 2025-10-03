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

const Allocator = std.mem.Allocator;
const Page = @import("../page.zig").Page;

const ReadableStream = @This();
const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");

const State = union(enum) {
    readable,
    closed: ?[]const u8,
    cancelled: ?[]const u8,
    errored: js.Object,
};

// This promise resolves when a stream is canceled.
cancel_resolver: js.PersistentPromiseResolver,
closed_resolver: js.PersistentPromiseResolver,
reader_resolver: ?js.PersistentPromiseResolver = null,

locked: bool = false,
state: State = .readable,

cancel_fn: ?js.Function = null,
pull_fn: ?js.Function = null,

strategy: QueueingStrategy,
queue: std.ArrayListUnmanaged(Chunk) = .empty,

pub const Chunk = union(enum) {
    // the order matters, sorry.
    uint8array: js.TypedArray(u8),
    string: []const u8,

    pub fn dupe(self: Chunk, allocator: Allocator) !Chunk {
        return switch (self) {
            .string => |str| .{ .string = try allocator.dupe(u8, str) },
            .uint8array => |arr| .{ .uint8array = try arr.dupe(allocator) },
        };
    }
};

pub const ReadableStreamReadResult = struct {
    done: bool,
    value: Value = .empty,

    const Value = union(enum) {
        empty,
        data: Chunk,
    };

    pub fn init(chunk: Chunk, done: bool) ReadableStreamReadResult {
        if (done) {
            return .{ .done = true, .value = .empty };
        }

        return .{
            .done = false,
            .value = .{ .data = chunk },
        };
    }

    pub fn get_value(self: *const ReadableStreamReadResult) Value {
        return self.value;
    }

    pub fn get_done(self: *const ReadableStreamReadResult) bool {
        return self.done;
    }
};

const UnderlyingSource = struct {
    start: ?js.Function = null,
    pull: ?js.Function = null,
    cancel: ?js.Function = null,
    type: ?[]const u8 = null,
};

const QueueingStrategy = struct {
    size: ?js.Function = null,
    high_water_mark: u32 = 1,
};

pub fn constructor(underlying: ?UnderlyingSource, _strategy: ?QueueingStrategy, page: *Page) !*ReadableStream {
    const strategy: QueueingStrategy = _strategy orelse .{};

    const cancel_resolver = try page.js.createPromiseResolver(.self);
    const closed_resolver = try page.js.createPromiseResolver(.self);

    const stream = try page.arena.create(ReadableStream);
    stream.* = ReadableStream{
        .cancel_resolver = cancel_resolver,
        .closed_resolver = closed_resolver,
        .strategy = strategy,
    };

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
    // reader resolver is scoped to the page lifetime and is cleaned up by it.
}

pub fn get_locked(self: *const ReadableStream) bool {
    return self.locked;
}

pub fn _cancel(self: *ReadableStream, reason: ?[]const u8, page: *Page) !js.Promise {
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

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
const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");

const ReadableStreamDefaultController = @This();

pub const Chunk = union(enum) {
    // the order matters, sorry.
    uint8array: js.TypedArray(u8),
    string: []const u8,

    pub fn dupe(self: Chunk, allocator: std.mem.Allocator) !Chunk {
        return switch (self) {
            .string => |str| .{ .string = try allocator.dupe(u8, str) },
            .uint8array => |arr| .{ .uint8array = try arr.dupe(allocator) },
        };
    }
};

_page: *Page,
_stream: *ReadableStream,
_arena: std.mem.Allocator,
_queue: std.ArrayList(Chunk),
_pending_reads: std.ArrayList(js.PromiseResolver.Global),
_high_water_mark: u32,

pub fn init(stream: *ReadableStream, high_water_mark: u32, page: *Page) !*ReadableStreamDefaultController {
    return page._factory.create(ReadableStreamDefaultController{
        ._page = page,
        ._queue = .empty,
        ._stream = stream,
        ._arena = page.arena,
        ._pending_reads = .empty,
        ._high_water_mark = high_water_mark,
    });
}

pub fn addPendingRead(self: *ReadableStreamDefaultController, page: *Page) !js.Promise {
    const resolver = try page.js.createPromiseResolver().persist();
    try self._pending_reads.append(self._arena, resolver);
    return resolver.local().promise();
}

pub fn enqueue(self: *ReadableStreamDefaultController, chunk: Chunk) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    if (self._pending_reads.items.len == 0) {
        const chunk_copy = try chunk.dupe(self._page.arena);
        return self._queue.append(self._arena, chunk_copy);
    }

    // I know, this is ouch! But we expect to have very few (if any)
    // pending reads.
    const resolver = self._pending_reads.orderedRemove(0);
    const result = ReadableStreamDefaultReader.ReadResult{
        .done = false,
        .value = .fromChunk(chunk),
    };
    resolver.local().resolve("stream enqueue", result);
}

pub fn close(self: *ReadableStreamDefaultController) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    self._stream._state = .closed;

    // Resolve all pending reads with done=true
    const result = ReadableStreamDefaultReader.ReadResult{
        .done = true,
        .value = .empty,
    };
    for (self._pending_reads.items) |*resolver| {
        resolver.local().resolve("stream close", result);
    }
    self._pending_reads.clearRetainingCapacity();
}

pub fn doError(self: *ReadableStreamDefaultController, err: []const u8) !void {
    if (self._stream._state != .readable) {
        return;
    }

    self._stream._state = .errored;
    self._stream._stored_error = try self._page.arena.dupe(u8, err);

    // Reject all pending reads
    for (self._pending_reads.items) |*resolver| {
        resolver.local().reject("stream errror", err);
    }
    self._pending_reads.clearRetainingCapacity();
}

pub fn dequeue(self: *ReadableStreamDefaultController) ?Chunk {
    if (self._queue.items.len == 0) {
        return null;
    }
    const chunk = self._queue.orderedRemove(0);

    // After dequeueing, we may need to pull more data
    self._stream.callPullIfNeeded() catch {};

    return chunk;
}

pub fn getDesiredSize(self: *const ReadableStreamDefaultController) ?i32 {
    switch (self._stream._state) {
        .errored => return null,
        .closed => return 0,
        .readable => {
            const queue_size: i32 = @intCast(self._queue.items.len);
            const hwm: i32 = @intCast(self._high_water_mark);
            return hwm - queue_size;
        },
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ReadableStreamDefaultController);

    pub const Meta = struct {
        pub const name = "ReadableStreamDefaultController";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const enqueue = bridge.function(ReadableStreamDefaultController.enqueue, .{});
    pub const close = bridge.function(ReadableStreamDefaultController.close, .{});
    pub const @"error" = bridge.function(ReadableStreamDefaultController.doError, .{});
    pub const desiredSize = bridge.accessor(ReadableStreamDefaultController.getDesiredSize, null, .{});
};

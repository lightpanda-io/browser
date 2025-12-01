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

const ReadableStreamDefaultController = @This();

_page: *Page,
_stream: *ReadableStream,
_arena: std.mem.Allocator,
_queue: std.ArrayList([]const u8),

pub fn init(stream: *ReadableStream, page: *Page) !*ReadableStreamDefaultController {
    return page._factory.create(ReadableStreamDefaultController{
        ._page = page,
        ._stream = stream,
        ._arena = page.arena,
        ._queue = std.ArrayList([]const u8){},
    });
}

pub fn enqueue(self: *ReadableStreamDefaultController, chunk: []const u8) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    // Store a copy of the chunk in the page arena
    const chunk_copy = try self._page.arena.dupe(u8, chunk);
    try self._queue.append(self._arena, chunk_copy);
}

pub fn close(self: *ReadableStreamDefaultController) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    self._stream._state = .closed;
}

pub fn doError(self: *ReadableStreamDefaultController, err: []const u8) !void {
    if (self._stream._state != .readable) {
        return;
    }

    self._stream._state = .errored;
    self._stream._stored_error = try self._page.arena.dupe(u8, err);
}

pub fn dequeue(self: *ReadableStreamDefaultController) ?[]const u8 {
    if (self._queue.items.len == 0) {
        return null;
    }
    return self._queue.orderedRemove(0);
}

pub fn getDesiredSize(self: *const ReadableStreamDefaultController) ?i32 {
    switch (self._stream._state) {
        .errored => return null,
        .closed => return 0,
        .readable => {
            // For now, just report based on queue size
            // In a real implementation, this would use highWaterMark
            return @as(i32, 1) - @as(i32, @intCast(self._queue.items.len));
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

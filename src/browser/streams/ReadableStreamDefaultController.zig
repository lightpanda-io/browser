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

const ReadableStreamDefaultController = @This();

stream: *ReadableStream,

pub fn get_desiredSize(self: *const ReadableStreamDefaultController) i32 {
    // TODO: This may need tuning at some point if it becomes a performance issue.
    return @intCast(self.stream.queue.capacity - self.stream.queue.items.len);
}

pub fn _close(self: *ReadableStreamDefaultController, _reason: ?[]const u8, page: *Page) !void {
    const reason = if (_reason) |reason| try page.arena.dupe(u8, reason) else null;
    self.stream.state = .{ .closed = reason };

    // Resolve the Reader Promise
    if (self.stream.reader_resolver) |*rr| {
        try rr.resolve(ReadableStreamReadResult{ .value = .empty, .done = true });
        self.stream.reader_resolver = null;
    }

    // Resolve the Closed promise.
    try self.stream.closed_resolver.resolve({});

    // close just sets as closed meaning it wont READ any more but anything in the queue is fine to read.
    // to discard, must use cancel.
}

pub fn _enqueue(self: *ReadableStreamDefaultController, chunk: ReadableStream.Chunk, page: *Page) !void {
    const stream = self.stream;

    if (stream.state != .readable) {
        return error.TypeError;
    }

    const duped_chunk = try chunk.dupe(page.arena);

    if (self.stream.reader_resolver) |*rr| {
        try rr.resolve(ReadableStreamReadResult.init(duped_chunk, false));
        self.stream.reader_resolver = null;
    }

    try self.stream.queue.append(page.arena, duped_chunk);
    try self.stream.pullIf();
}

pub fn _error(self: *ReadableStreamDefaultController, err: js.Object) !void {
    self.stream.state = .{ .errored = err };

    if (self.stream.reader_resolver) |*rr| {
        try rr.reject(err);
        self.stream.reader_resolver = null;
    }
}

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
const v8 = @import("v8");

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

    if (self.stream.reader_resolver) |rr| {
        const resolver = Env.PromiseResolver{
            .js_context = page.main_context,
            .resolver = rr.castToPromiseResolver(),
        };

        try resolver.resolve(ReadableStreamReadResult{ .value = .empty, .done = true });
        self.stream.reader_resolver = null;
    }

    // close just sets as closed meaning it wont READ any more but anything in the queue is fine to read.
    // to discard, must use cancel.
}

pub fn _enqueue(self: *ReadableStreamDefaultController, chunk: []const u8, page: *Page) !void {
    const stream = self.stream;

    if (stream.state != .readable) {
        return error.TypeError;
    }

    if (self.stream.reader_resolver) |rr| {
        const resolver = Env.PromiseResolver{
            .js_context = page.main_context,
            .resolver = rr.castToPromiseResolver(),
        };

        try resolver.resolve(ReadableStreamReadResult{ .value = .{ .data = chunk }, .done = false });
        self.stream.reader_resolver = null;

        // rr.setWeakFinalizer(@ptrCast(self.stream), struct {
        //     fn callback(info: ?*v8.c.WeakCallbackInfo) void {
        //         const inner_stream: *ReadableStream = @ptrCast(@alignCast(v8.c.v8__WeakCallbackInfo__GetParameter(info).?));
        //         inner_stream.reader_resolver = null;
        //     }
        // }.callback, .kParameter);
    }

    try self.stream.queue.append(page.arena, chunk);
    try self.stream.pullIf();
}

pub fn _error(self: *ReadableStreamDefaultController, err: Env.JsObject, page: *Page) !void {
    self.stream.state = .{ .errored = err };

    if (self.stream.reader_resolver) |rr| {
        const resolver = Env.PromiseResolver{
            .js_context = page.main_context,
            .resolver = rr.castToPromiseResolver(),
        };

        try resolver.reject(err);
        self.stream.reader_resolver = null;
    }
}

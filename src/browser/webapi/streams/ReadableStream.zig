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
const log = @import("../../../log.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");
const WritableStream = @import("WritableStream.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

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

    if (comptime IS_DEBUG) {
        if (self._page.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "ReadableStream.callPullIfNeeded", .url = self._page.url });
            std.debug.assert(self._page.js.local != null);
        }
    }

    {
        const func = self._pull_fn orelse return;

        var ls: js.Local.Scope = undefined;
        self._page.js.localScope(&ls);
        defer ls.deinit();

        // Call the pull function
        // Note: In a complete implementation, we'd handle the promise returned by pull
        // and set _pulling = false when it resolves
        try ls.toLocal(func).call(void, .{self._controller});
    }

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
    const local = page.js.local.?;

    if (self._state != .readable) {
        if (self._cancel) |c| {
            if (c.resolver) |r| {
                return local.toLocal(r).promise();
            }
        }
        return local.resolvePromise(.{});
    }

    if (self._cancel == null) {
        self._cancel = Cancel{};
    }

    var c = &self._cancel.?;
    var resolver = blk: {
        if (c.resolver) |r| {
            break :blk local.toLocal(r);
        }
        var temp = local.createPromiseResolver();
        c.resolver = try temp.persist();
        break :blk temp;
    };

    // Execute the cancel callback if provided
    if (c.callback) |cb| {
        if (reason) |r| {
            try local.toLocal(cb).call(void, .{r});
        } else {
            try local.toLocal(cb).call(void, .{});
        }
    }

    self._state = .closed;
    self._controller._queue.clearRetainingCapacity();

    const result = ReadableStreamDefaultReader.ReadResult{
        .done = true,
        .value = .empty,
    };
    for (self._controller._pending_reads.items) |r| {
        local.toLocal(r).resolve("stream cancelled", result);
    }
    self._controller._pending_reads.clearRetainingCapacity();
    resolver.resolve("ReadableStream.cancel", {});
    return resolver.promise();
}

/// pipeThrough(transform) — pipes this readable stream through a transform stream,
/// returning the readable side. `transform` is a JS object with `readable` and `writable` properties.
pub fn pipeThrough(self: *ReadableStream, transform: js.Value, page: *Page) !*ReadableStream {
    if (self.getLocked()) {
        return error.ReaderLocked;
    }

    if (!transform.isObject()) {
        return error.InvalidArgument;
    }

    const obj = transform.toObject();
    const writable_val = try obj.get("writable");
    const readable_val = try obj.get("readable");

    const writable = try writable_val.toZig(*WritableStream);
    const output_readable = try readable_val.toZig(*ReadableStream);

    // Start async piping from this stream to the writable side
    try PipeState.startPipe(self, writable, null, page);

    return output_readable;
}

/// pipeTo(writable) — pipes this readable stream to a writable stream.
/// Returns a promise that resolves when piping is complete.
pub fn pipeTo(self: *ReadableStream, destination: *WritableStream, page: *Page) !js.Promise {
    if (self.getLocked()) {
        return page.js.local.?.rejectPromise("ReadableStream is locked");
    }

    const local = page.js.local.?;
    var pipe_resolver = local.createPromiseResolver();
    const promise = pipe_resolver.promise();
    const persisted_resolver = try pipe_resolver.persist();

    try PipeState.startPipe(self, destination, persisted_resolver, page);

    return promise;
}

/// State for an async pipe operation.
const PipeState = struct {
    reader: *ReadableStreamDefaultReader,
    writable: *WritableStream,
    page: *Page,
    context_id: usize,
    resolver: ?js.PromiseResolver.Global,

    fn startPipe(
        stream: *ReadableStream,
        writable: *WritableStream,
        resolver: ?js.PromiseResolver.Global,
        page: *Page,
    ) !void {
        const reader = try stream.getReader(page);
        const state = try page.arena.create(PipeState);
        state.* = .{
            .reader = reader,
            .writable = writable,
            .page = page,
            .context_id = page.js.id,
            .resolver = resolver,
        };

        try state.pumpRead();
    }

    fn pumpRead(state: *PipeState) !void {
        const local = state.page.js.local.?;

        // Call reader.read() which returns a Promise
        const read_promise = try state.reader.read(state.page);

        // Create JS callback functions for .then() and .catch()
        const then_fn = local.newFunctionWithData(&onReadFulfilled, state);
        const catch_fn = local.newFunctionWithData(&onReadRejected, state);

        _ = read_promise.thenAndCatch(then_fn, catch_fn) catch {
            state.finish(local);
        };
    }

    fn onReadFulfilled(callback_handle: ?*const js.v8.FunctionCallbackInfo) callconv(.c) void {
        var c: js.Caller = undefined;
        c.initFromHandle(callback_handle);
        defer c.deinit();

        const info = js.Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
        const state: *PipeState = @ptrCast(@alignCast(info.getData() orelse return));

        if (state.context_id != c.local.ctx.id) return;

        const l = &c.local;
        defer l.runMicrotasks();

        // Get the read result argument {done, value}
        const result_val = info.getArg(0, l);

        if (!result_val.isObject()) {
            state.finish(l);
            return;
        }

        const result_obj = result_val.toObject();
        const done_val = result_obj.get("done") catch {
            state.finish(l);
            return;
        };
        const done = done_val.toBool();

        if (done) {
            // Stream is finished, close the writable side
            state.writable.closeStream(state.page) catch {};
            state.finishResolve(l);
            return;
        }

        // Get the chunk value and write it to the writable side
        const chunk_val = result_obj.get("value") catch {
            state.finish(l);
            return;
        };

        state.writable.writeChunk(chunk_val, state.page) catch {
            state.finish(l);
            return;
        };

        // Continue reading the next chunk
        state.pumpRead() catch {
            state.finish(l);
        };
    }

    fn onReadRejected(callback_handle: ?*const js.v8.FunctionCallbackInfo) callconv(.c) void {
        var c: js.Caller = undefined;
        c.initFromHandle(callback_handle);
        defer c.deinit();

        const info = js.Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
        const state: *PipeState = @ptrCast(@alignCast(info.getData() orelse return));

        if (state.context_id != c.local.ctx.id) return;

        const l = &c.local;
        defer l.runMicrotasks();

        state.finish(l);
    }

    fn finishResolve(state: *PipeState, local: *const js.Local) void {
        state.reader.releaseLock();
        if (state.resolver) |r| {
            local.toLocal(r).resolve("pipeTo complete", {});
        }
    }

    fn finish(state: *PipeState, local: *const js.Local) void {
        state.reader.releaseLock();
        if (state.resolver) |r| {
            local.toLocal(r).resolve("pipe finished", {});
        }
    }
};

const Cancel = struct {
    callback: ?js.Function.Global = null,
    reason: ?[]const u8 = null,
    resolver: ?js.PromiseResolver.Global = null,
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
    pub const pipeThrough = bridge.function(ReadableStream.pipeThrough, .{});
    pub const pipeTo = bridge.function(ReadableStream.pipeTo, .{});
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
        return page.js.local.?.resolvePromise(.{ .done = true, .value = null });
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

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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");
const WritableStream = @import("WritableStream.zig");

const log = lp.log;
const Execution = js.Execution;

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

_state: State,
_execution: *const Execution,
_reader: ?*ReadableStreamDefaultReader,
_controller: *ReadableStreamDefaultController,
_stored_error: ?[]const u8,
_pull_fn: ?js.Function.Global = null,
_pulling: bool = false,
_pull_again: bool = false,
_cancel: ?Cancel = null,
_collected: bool = false,
_disturbed: bool = false, // once cancelled, cannot be consumed again

const UnderlyingSource = struct {
    cancel: ?js.Function.Global = null,
    pull: ?js.Function.Global = null,
    start: ?js.Function = null,
    type: ?[]const u8 = null,
};

const QueueingStrategy = struct {
    highWaterMark: u32 = 1,
    size: ?js.Function = null,
};

pub fn init(src_: ?UnderlyingSource, strategy_: ?QueueingStrategy, exec: *const Execution) !*ReadableStream {
    const strategy: QueueingStrategy = strategy_ orelse .{};

    const self = try exec._factory.create(ReadableStream{
        ._execution = exec,
        ._state = .readable,
        ._reader = null,
        ._controller = undefined,
        ._stored_error = null,
    });

    self._controller = try ReadableStreamDefaultController.init(self, strategy.highWaterMark, exec);

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

pub fn initWithData(data: []const u8, exec: *const Execution) !*ReadableStream {
    const stream = try init(null, null, exec);

    // For Phase 1: immediately enqueue all data and close
    try stream._controller.enqueue(.{ .uint8array = .{ .values = data } });
    try stream._controller.close();

    return stream;
}

pub fn initWithText(text: []const u8, exec: *const Execution) !*ReadableStream {
    const stream = try init(null, null, exec);

    if (text.len > 0) {
        try stream._controller.enqueue(.{ .string = text });
    }
    try stream._controller.close();

    return stream;
}

pub fn getReader(self: *ReadableStream, exec: *const Execution) !*ReadableStreamDefaultReader {
    if (self.getLocked()) {
        return exec.js.typeError("ReadableStream is locked");
    }

    const reader = try ReadableStreamDefaultReader.init(self, exec);
    self._reader = reader;
    return reader;
}

pub fn releaseReader(self: *ReadableStream) void {
    self._reader = null;
}

pub fn getAsyncIterator(self: *ReadableStream, exec: *const Execution) !*AsyncIterator {
    return AsyncIterator.init(self, exec);
}

pub fn getLocked(self: *const ReadableStream) bool {
    return self._reader != null;
}

/// Drain a closed stream's internal queue into bytes for outbound HTTP
/// request bodies. A stream that is locked, already used as a body, still
/// readable, or errored - or that holds a chunk which isn't string or binary
/// data - is `error.TypeError`. The queue is only consumed once every chunk
/// has converted, so a rejected body leaves the stream as it was.
pub fn collectBodyBytes(self: *ReadableStream, arena: std.mem.Allocator) ![]const u8 {
    if (self._collected or self.getLocked()) {
        return error.TypeError;
    }
    switch (self._state) {
        .errored, .readable => return error.TypeError,
        .closed => {},
    }

    var ls: js.Local.Scope = undefined;
    self._execution.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    var buf = std.Io.Writer.Allocating.init(arena);
    const queue = &self._controller._queue;
    for (queue.items) |chunk| {
        const bytes: []const u8 = switch (chunk) {
            .string => |s| s,
            .uint8array => |arr| arr.values,
            .js_value => |global| blk: {
                const value = local.toLocal(global);
                // toStringSmart falls back to toString(), which would turn a
                // stray number or object into "42" / "[object Object]" bytes.
                if (value.isString() == null and !value.isTypedArray() and
                    !value.isArrayBufferView() and !value.isArrayBuffer())
                {
                    return error.TypeError;
                }
                break :blk try value.toStringSmart();
            },
        };
        try buf.writer.writeAll(bytes);
    }

    self._collected = true;
    queue.clearRetainingCapacity();
    return buf.written();
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

    const exec = self._execution;
    if (comptime lp.IS_DEBUG) {
        if (exec.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "ReadableStream.callPullIfNeeded", .url = exec.url.* });
            std.debug.assert(exec.js.local != null);
        }
    }

    {
        const func = self._pull_fn orelse return;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
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

pub fn cancel(self: *ReadableStream, reason: ?[]const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    self._disturbed = true;

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
const PipeTransform = struct {
    readable: *ReadableStream,
    writable: *WritableStream,
};

pub fn pipeThrough(self: *ReadableStream, transform: PipeTransform, exec: *const Execution) !*ReadableStream {
    if (self.getLocked()) {
        return exec.js.typeError("ReadableStream is locked");
    }

    // Start async piping from this stream to the writable side
    try PipeState.startPipe(self, transform.writable, null, exec);
    return transform.readable;
}

/// pipeTo(writable) — pipes this readable stream to a writable stream.
/// Returns a promise that resolves when piping is complete.
pub fn pipeTo(self: *ReadableStream, destination: *WritableStream, exec: *const Execution) !js.Promise {
    if (self.getLocked()) {
        return exec.js.local.?.rejectPromise(.{ .type_error = "ReadableStream is locked" });
    }

    const local = exec.js.local.?;
    var pipe_resolver = local.createPromiseResolver();
    const promise = pipe_resolver.promise();
    const persisted_resolver = try pipe_resolver.persist();

    try PipeState.startPipe(self, destination, persisted_resolver, exec);
    return promise;
}

/// State for an async pipe operation.
const PipeState = struct {
    execution: *const Execution,
    reader: *ReadableStreamDefaultReader,
    writable: *WritableStream,
    resolver: ?js.PromiseResolver.Global,

    fn startPipe(
        stream: *ReadableStream,
        writable: *WritableStream,
        resolver: ?js.PromiseResolver.Global,
        exec: *const Execution,
    ) !void {
        const reader = try stream.getReader(exec);
        const state = try exec.arena.create(PipeState);
        state.* = .{
            .execution = exec,
            .reader = reader,
            .writable = writable,
            .resolver = resolver,
        };
        try state.pumpRead();
    }

    fn pumpRead(state: *PipeState) !void {
        const exec = state.execution;
        const local = exec.js.local.?;

        // Call reader.read() which returns a Promise
        const read_promise = try state.reader.read(exec);

        // Create JS callback functions for .then() and .catch()
        const then_fn = local.newCallback(onReadFulfilled, state);
        const catch_fn = local.newCallback(onReadRejected, state);

        _ = read_promise.thenAndCatch(then_fn, catch_fn) catch {
            state.finish(local);
        };
    }

    const ReadData = struct {
        done: bool,
        value: js.Value,
    };
    fn onReadFulfilled(self: *PipeState, data_: ?ReadData) void {
        const exec = self.execution;
        const local = exec.js.local.?;
        const data = data_ orelse {
            return self.finish(local);
        };

        if (data.done) {
            // Stream is finished, close the writable side
            self.writable.closeStream(exec) catch {};
            self.reader.releaseLock();
            if (self.resolver) |r| {
                local.toLocal(r).resolve("pipeTo complete", {});
            }
            return;
        }

        const value = data.value;
        if (value.isUndefined()) {
            return self.finish(local);
        }

        self.writable.writeChunk(value, exec) catch {
            return self.finish(local);
        };

        // Continue reading the next chunk
        self.pumpRead() catch {
            self.finish(local);
        };
    }

    fn onReadRejected(self: *PipeState) void {
        self.finish(self.execution.js.local.?);
    }

    fn finish(self: *PipeState, local: *const js.Local) void {
        self.reader.releaseLock();
        if (self.resolver) |r| {
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

    pub fn init(stream: *ReadableStream, exec: *const Execution) !*AsyncIterator {
        const reader = try stream.getReader(exec);
        return exec._factory.create(AsyncIterator{
            ._reader = reader,
            ._stream = stream,
        });
    }

    pub fn next(self: *AsyncIterator, exec: *const Execution) !js.Promise {
        return self._reader.read(exec);
    }

    pub fn @"return"(self: *AsyncIterator, exec: *const Execution) !js.Promise {
        self._reader.releaseLock();
        return exec.js.local.?.resolvePromise(.{ .done = true, .value = null });
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

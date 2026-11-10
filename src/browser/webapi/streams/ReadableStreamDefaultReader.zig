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

const js = @import("../../js/js.zig");

const ReadableStream = @import("ReadableStream.zig");

const Execution = js.Execution;

const ReadableStreamDefaultReader = @This();

_stream: ?*ReadableStream,
_execution: js.ExecutionHandle,
/// Backs `closed`. Created on first access, since readers used internally
/// (pipeTo, tee, async iteration) never look at it.
_closed: ?js.PromiseResolver.Global = null,

pub fn init(stream: *ReadableStream, exec: *const Execution) !*ReadableStreamDefaultReader {
    return exec._factory.create(ReadableStreamDefaultReader{
        ._stream = stream,
        ._execution = exec.handle(),
    });
}

pub const ReadResult = struct {
    done: bool,
    value: Chunk,

    // Done like this so that we can properly return undefined in some cases
    const Chunk = union(enum) {
        empty,
        value: js.Value,
    };
};

pub fn read(self: *ReadableStreamDefaultReader, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const stream = self._stream orelse {
        return local.rejectPromise(.{ .type_error = "Reader has been released" });
    };
    stream._disturbed = true;

    if (stream._state == .errored) {
        const resolver = local.createPromiseResolver();
        resolver.reject("ReadableStreamDefaultReader.read", stream._stored_error.?);
        return resolver.promise();
    }

    if (stream._controller.dequeue()) |chunk| {
        defer chunk.release();
        const result = ReadResult{
            .done = false,
            .value = .{ .value = local.toLocal(chunk) },
        };
        return local.resolvePromise(result);
    }

    if (stream._state == .closed) {
        const result = ReadResult{
            .done = true,
            .value = .empty,
        };
        return local.resolvePromise(result);
    }

    // No data, but not closed: queue the read and ask the source for a chunk.
    const promise = try stream._controller.addPendingRead(local);
    try stream.callPullIfNeeded();
    return promise;
}

pub fn releaseLock(self: *ReadableStreamDefaultReader) void {
    const stream = self._stream orelse return;
    stream.releaseReader();
    self._stream = null;

    // As in the spec, a pending `closed` rejects. A settled one is dropped,
    // so the next access gets a rejected one.
    const closed = self._closed orelse return;
    const context = self._execution.js() orelse return;
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();
    const resolver = ls.toLocal(closed);
    if (resolver.promise().state() == .pending) {
        rejectReleased(&ls.local, resolver);
    } else {
        closed.release();
        self._closed = null;
    }
}

/// Like the spec, the reader keeps its lock: `closed` resolves and later
/// reads are done.
pub fn cancel(self: *ReadableStreamDefaultReader, reason_: ?js.Value, exec: *const Execution) !js.Promise {
    const stream = self._stream orelse {
        return exec.js.typeError("Reader has been released");
    };
    return stream.cancel(reason_, exec);
}

pub fn getClosed(self: *ReadableStreamDefaultReader, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    if (self._closed) |closed| {
        return local.toLocal(closed).promise();
    }

    const resolver = local.createPromiseResolver();
    self._closed = try resolver.persist();
    if (self._stream) |stream| {
        switch (stream._state) {
            .readable => {},
            .closed => if (stream._controller._queue.items.len == 0) {
                resolver.resolve("ReadableStreamDefaultReader.closed", {});
            },
            .errored => rejectClosed(resolver, local.toLocal(stream._stored_error.?)),
        }
    } else {
        rejectReleased(local, resolver);
    }
    return resolver.promise();
}

/// The stream closed and its queue is drained.
pub fn streamClosed(self: *ReadableStreamDefaultReader) void {
    const closed = self._closed orelse return;
    const context = self._execution.js() orelse return;
    var ls: js.Local.Scope = undefined;
    context.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(closed).resolve("ReadableStreamDefaultReader.closed", {});
}

pub fn streamErrored(self: *ReadableStreamDefaultReader, reason: js.Value) void {
    const closed = self._closed orelse return;
    rejectClosed(reason.local.toLocal(closed), reason);
}

/// Like the spec, `closed` rejecting is never reported as unhandled.
fn rejectClosed(resolver: js.PromiseResolver, reason: js.Value) void {
    resolver.promise().markAsHandled();
    resolver.reject("ReadableStreamDefaultReader.closed", reason);
}

fn rejectReleased(local: *const js.Local, resolver: js.PromiseResolver) void {
    const err = local.isolate.createTypeError("Reader has been released");
    rejectClosed(resolver, .{ .local = local, .handle = err });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ReadableStreamDefaultReader);

    pub const Meta = struct {
        pub const name = "ReadableStreamDefaultReader";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const read = bridge.function(ReadableStreamDefaultReader.read, .{});
    pub const cancel = bridge.function(ReadableStreamDefaultReader.cancel, .{});
    pub const releaseLock = bridge.fastFunction(ReadableStreamDefaultReader.releaseLock, .{});
    pub const closed = bridge.accessor(ReadableStreamDefaultReader.getClosed, null, .{});
};

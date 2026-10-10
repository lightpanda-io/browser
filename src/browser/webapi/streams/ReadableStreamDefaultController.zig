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

const ReadableStream = @import("ReadableStream.zig");
const ReadableStreamDefaultReader = @import("ReadableStreamDefaultReader.zig");

const log = lp.log;
const Execution = js.Execution;

const ReadableStreamDefaultController = @This();

pub const Chunk = union(enum) {
    uint8array: js.TypedArray(u8),
    string: []const u8,
};

_stream: *ReadableStream,
_execution: *const Execution,
_arena: std.mem.Allocator,
_queue: std.ArrayList(js.Value.Global),
_pending_reads: std.ArrayList(js.PromiseResolver.Global),
_high_water_mark: u32,

pub fn init(stream: *ReadableStream, high_water_mark: u32, exec: *const Execution) !*ReadableStreamDefaultController {
    return exec._factory.create(ReadableStreamDefaultController{
        ._queue = .empty,
        ._stream = stream,
        ._execution = exec,
        ._arena = exec.page_arena,
        ._pending_reads = .empty,
        ._high_water_mark = high_water_mark,
    });
}

pub fn addPendingRead(self: *ReadableStreamDefaultController, local: *const js.Local) !js.Promise {
    const resolver = local.createPromiseResolver();
    try self._pending_reads.append(self._arena, try resolver.persist());
    return resolver.promise();
}

/// Enqueues `chunk` to internal queue but doesn't resolve pending reads.
/// This function solely exists to give no window for page JS to run when
/// running it may introduce data races. Can still fail if stream is not readable.
///
/// TODO: Come up with a better name.
pub fn enqueueNoSideEffects(self: *ReadableStreamDefaultController, chunk: Chunk) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    var ls: js.Local.Scope = undefined;
    self._execution.js.localScope(&ls);
    defer ls.deinit();
    try self.queueValue(try chunkToJs(&ls.local, chunk));
}

/// Resolves pending reads with queued chunks. Pairs with `enqueueNoSideEffects`.
/// Call it once the producer no longer holds state that page JS could invalidate.
pub fn fulfillPendingReads(self: *ReadableStreamDefaultController) void {
    const exec = self._execution;
    if (comptime lp.IS_DEBUG) {
        if (exec.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "ReadableStreamDefaultController.fulfillPendingReads", .url = exec.url.* });
            std.debug.assert(exec.js.local != null);
        }
    }

    // Each resolve runs microtasks, so page JS can read, cancel or error the
    // stream (or re-enter the producer) between iterations; both lists are
    // re-checked every time.
    while (self._pending_reads.items.len > 0 and self._queue.items.len > 0) {
        const resolver = self._pending_reads.orderedRemove(0);
        const chunk = self._queue.orderedRemove(0);

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        const value = ls.toLocal(chunk);
        chunk.release();
        resolveRead(&ls.local, resolver, value, "stream fulfill pending read");
    }
}

pub fn enqueue(self: *ReadableStreamDefaultController, chunk: Chunk) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    var ls: js.Local.Scope = undefined;
    self._execution.js.localScope(&ls);
    defer ls.deinit();
    return self.enqueueLocal(&ls.local, try chunkToJs(&ls.local, chunk), "stream enqueue");
}

/// Enqueue a raw JS value, preserving its type (number, bool, object, etc.).
/// Used by the JS-facing API; internal Zig callers should use enqueue(Chunk).
pub fn enqueueValue(self: *ReadableStreamDefaultController, value: js.Value) !void {
    if (self._stream._state != .readable) {
        return error.StreamNotReadable;
    }

    var ls: js.Local.Scope = undefined;
    self._execution.js.localScope(&ls);
    defer ls.deinit();
    return self.enqueueLocal(&ls.local, value, "stream enqueue value");
}

fn enqueueLocal(self: *ReadableStreamDefaultController, local: *const js.Local, value: js.Value, comptime source: []const u8) !void {
    if (self._pending_reads.items.len == 0) {
        return self.queueValue(value);
    }

    if (comptime lp.IS_DEBUG) {
        const exec = self._execution;
        if (exec.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "ReadableStreamDefaultController." ++ source, .url = exec.url.* });
            std.debug.assert(exec.js.local != null);
        }
    }

    // I know, this is ouch! But we expect to have very few (if any)
    // pending reads.
    const resolver = self._pending_reads.orderedRemove(0);
    resolveRead(local, resolver, value, source);
}

fn queueValue(self: *ReadableStreamDefaultController, value: js.Value) !void {
    const persisted = try value.persist();
    errdefer persisted.release();
    try self._queue.append(self._arena, persisted);
}

fn chunkToJs(local: *const js.Local, chunk: Chunk) !js.Value {
    return switch (chunk) {
        inline else => |c| local.zigValueToJs(c, .{}),
    };
}

fn resolveRead(local: *const js.Local, resolver: js.PromiseResolver.Global, value: js.Value, comptime source: []const u8) void {
    defer resolver.release();
    const result = ReadableStreamDefaultReader.ReadResult{
        .done = false,
        .value = .{ .value = value },
    };
    local.toLocal(resolver).resolve(source, result);
}

pub fn clearQueue(self: *ReadableStreamDefaultController) void {
    for (self._queue.items) |chunk| {
        chunk.release();
    }
    self._queue.clearRetainingCapacity();
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

    const exec = self._execution;
    if (comptime lp.IS_DEBUG) {
        if (exec.js.local == null) {
            log.fatal(.bug, "null context scope", .{ .src = "ReadableStreamDefaultController.close", .url = exec.url.* });
            std.debug.assert(exec.js.local != null);
        }
    }

    for (self._pending_reads.items) |resolver| {
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        ls.toLocal(resolver).resolve("stream close", result);
        resolver.release();
    }

    self._pending_reads.clearRetainingCapacity();
}

pub fn doError(self: *ReadableStreamDefaultController, err: []const u8) !void {
    return self.fail(err, false);
}

/// Like doError, but pending reads reject with a TypeError instead of the
/// bare message, which is what native transforms (e.g. CompressionStream) throw.
pub fn typeError(self: *ReadableStreamDefaultController, message: []const u8) !void {
    return self.fail(message, true);
}

fn fail(self: *ReadableStreamDefaultController, err: []const u8, type_error: bool) !void {
    if (self._stream._state != .readable) {
        return;
    }

    self._stream._state = .errored;
    self._stream._stored_error = try self._arena.dupe(u8, err);
    self.clearQueue();

    // Reject all pending reads
    for (self._pending_reads.items) |resolver| {
        const local_resolver = self._execution.js.toLocal(resolver);
        if (type_error) {
            local_resolver.rejectError("stream error", .{ .type_error = err });
        } else {
            local_resolver.reject("stream error", err);
        }
        resolver.release();
    }
    self._pending_reads.clearRetainingCapacity();
}

/// The caller owns the returned global and must release it.
pub fn dequeue(self: *ReadableStreamDefaultController) ?js.Value.Global {
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

    pub const enqueue = bridge.function(ReadableStreamDefaultController.enqueueValue, .{});
    pub const close = bridge.function(ReadableStreamDefaultController.close, .{});
    pub const @"error" = bridge.function(ReadableStreamDefaultController.doError, .{});
    pub const desiredSize = bridge.accessor(ReadableStreamDefaultController.getDesiredSize, null, .{});
};

const testing = @import("../../../testing.zig");
test "ReadableStreamDefaultController: chunks and pending reads release their globals" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const tracker = &frame.js.page.globals;
    const base = tracker.list.items.len;

    _ = try ls.local.exec(
        \\{
        \\  let c;
        \\  const r = new ReadableStream({ start(ctrl) { c = ctrl; } }).getReader();
        \\  // queued, then read
        \\  for (let i = 0; i < 50; i++) c.enqueue(new Uint8Array(1024));
        \\  for (let i = 0; i < 50; i++) r.read();
        \\  // pending, then enqueued
        \\  for (let i = 0; i < 50; i++) r.read();
        \\  for (let i = 0; i < 50; i++) c.enqueue('x');
        \\  // pending, then closed
        \\  r.read();
        \\  c.close();
        \\}
        \\{
        \\  let c;
        \\  const s = new ReadableStream({ start(ctrl) { c = ctrl; } });
        \\  for (let i = 0; i < 50; i++) c.enqueue(i);
        \\  s.cancel();
        \\}
        \\{
        \\  let c;
        \\  new ReadableStream({ start(ctrl) { c = ctrl; } }).getReader().read();
        \\  c.error('boom');
        \\}
        \\{
        \\  let c;
        \\  new ReadableStream({ start(ctrl) { c = ctrl; } });
        \\  for (let i = 0; i < 50; i++) c.enqueue(i);
        \\  c.error('boom');
        \\}
        \\new Response('native chunk').body.getReader().read();
    , null);

    // cancel() keeps its own resolver so a repeated cancel returns the same promise.
    try testing.expectEqual(base + 1, tracker.list.items.len);
}

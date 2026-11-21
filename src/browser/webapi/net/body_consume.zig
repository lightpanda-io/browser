// Copyright (C) 2026  Lightpanda (Selecy SAS)
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

// Consuming a Request or Response body: text(), json(), arrayBuffer(),
// bytes(), blob() and formData() (Fetch §6.4, https://fetch.spec.whatwg.org/#body-mixin).

const std = @import("std");

const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const ReadableStreamDefaultReader = @import("../streams/ReadableStreamDefaultReader.zig");

const body_init = @import("body_init.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub const Package = enum { array_buffer, bytes, text, json, blob, form_data };

// settles `resolver` with `body` as `kind`.
pub fn package(kind: Package, body: []const u8, content_type: ?[]const u8, resolver: js.PromiseResolver, exec: *const Execution) !void {
    switch (kind) {
        .array_buffer => resolver.resolve("arrayBuffer", js.ArrayBuffer{ .values = body }),
        .bytes => resolver.resolve("bytes", js.TypedArray(u8){ .values = body }),
        .text => resolver.resolve("text", body_init.stripUtf8Bom(body)),
        .json => {
            const local = exec.js.local.?;
            const value = local.parseJSON(body_init.stripUtf8Bom(body)) catch {
                return resolver.rejectError("json", .{ .syntax_error = "failed to parse" });
            };
            resolver.resolve("json", value);
        },
        .blob => resolver.resolve("blob", try Blob.initFromContentType(body, content_type orelse "", exec)),
        .form_data => {
            const form_data = body_init.parseFormData(body, content_type, exec) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.TypeError => return resolver.rejectError("formData", .{ .type_error = "Failed to parse body as FormData" }),
            };
            resolver.resolve("formData", form_data);
        },
    }
}

// Drains a stream body chunk by chunk, then packages the concatenation.
pub const StreamConsumer = struct {
    execution: js.ExecutionHandle,
    kind: Package,
    content_type: ?[]const u8,
    total_len: usize,
    arena: Allocator,
    reader: *ReadableStreamDefaultReader,
    chunks: std.ArrayList([]const u8),
    resolver: js.PromiseResolver.Global,

    pub fn start(stream: *ReadableStream, kind: Package, content_type: ?[]const u8, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        var resolver = local.createPromiseResolver();
        const promise = resolver.promise();

        const reader = try stream.getReader(exec);

        const state = try exec.page_arena.create(StreamConsumer);
        state.* = .{
            .execution = exec.handle(),
            .kind = kind,
            .content_type = if (content_type) |ct| try exec.page_arena.dupe(u8, ct) else null,
            .reader = reader,
            .chunks = .empty,
            .total_len = 0,
            .arena = exec.page_arena,
            .resolver = try resolver.persist(),
        };

        try state.pumpRead(exec);
        return promise;
    }

    fn pumpRead(self: *StreamConsumer, exec: *const Execution) !void {
        const local = exec.js.local.?;
        const read_promise = try self.reader.read(exec);

        const then_fn = local.newCallback(onReadFulfilled, self);
        const catch_fn = local.newCallback(onReadRejected, self);

        _ = read_promise.thenAndCatch(then_fn, catch_fn) catch {
            self.finish(local, null);
        };
    }

    fn onReadFulfilled(self: *StreamConsumer, result: js.Value) void {
        const exec = self.execution.get() orelse return;
        self._onReadFulfilled(result, exec) catch {
            self.finish(exec.js.local.?, null);
        };
    }

    fn _onReadFulfilled(self: *StreamConsumer, result: js.Value, exec: *const Execution) !void {
        const local = exec.js.local.?;

        if (result.isObject() == false) {
            return self.finish(local, "Read result is not an object");
        }
        const obj = result.toObject();

        if ((try obj.get("done")).toBool()) {
            const body = try self.concatenateChunks(exec.call_arena);
            return package(self.kind, body, self.content_type, local.toLocal(self.resolver), exec);
        }

        const value = try obj.get("value");
        if (value.isUint8Array() == false) {
            // A chunk that is not a Uint8Array is a TypeError.
            return self.finish(local, "Response body chunk is not a Uint8Array");
        }
        const chunk_copy = try self.arena.dupe(u8, (try local.jsValueToZig(js.AllowSharedBufferSource, value)).bytes());
        try self.chunks.append(self.arena, chunk_copy);
        self.total_len += chunk_copy.len;
        try self.pumpRead(exec);
    }

    fn onReadRejected(self: *StreamConsumer, reason: js.Value) void {
        const context = self.execution.js() orelse return;
        self.finishWithReason(context.local.?, reason);
    }

    fn concatenateChunks(self: *StreamConsumer, allocator: Allocator) ![]const u8 {
        if (self.chunks.items.len == 0) {
            return "";
        }
        if (self.chunks.items.len == 1) {
            return self.chunks.items[0];
        }
        return std.mem.join(allocator, "", self.chunks.items);
    }

    fn finish(self: *StreamConsumer, local: *const js.Local, err: ?[]const u8) void {
        self.reader.releaseLock();
        local.toLocal(self.resolver).rejectError("stream body", .{ .type_error = err orelse "Failed to read stream" });
    }

    fn finishWithReason(self: *StreamConsumer, local: *const js.Local, reason: js.Value) void {
        self.reader.releaseLock();
        local.toLocal(self.resolver).reject("stream body", reason);
    }
};

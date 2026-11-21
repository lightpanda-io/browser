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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Blob = @import("../Blob.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const ReadableStreamDefaultReader = @import("../streams/ReadableStreamDefaultReader.zig");

const body_init = @import("body_init.zig");

const Execution = js.Execution;

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

// Reads a stream body to the end, then packages it.
pub const StreamConsumer = struct {
    execution: js.ExecutionHandle,
    kind: Package,
    content_type: ?[]const u8,
    // Holds this state and the body. Released once the body settles, or with
    // the page if it never does.
    arena: *lp.Arena,
    body: std.ArrayList(u8),
    reader: *ReadableStreamDefaultReader,
    resolver: js.PromiseResolver.Global,
    node: std.DoublyLinkedList.Node = .{},

    pub fn start(stream: *ReadableStream, kind: Package, content_type: ?[]const u8, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const arena = try exec.getArena(.small, "body stream");
        errdefer arena.release();
        const allocator = arena.allocator();

        const reader = try stream.getReader(exec);
        errdefer reader.releaseLock();

        var resolver = local.createPromiseResolver();
        const self = try allocator.create(StreamConsumer);
        self.* = .{
            .execution = exec.handle(),
            .kind = kind,
            .content_type = if (content_type) |ct| try allocator.dupe(u8, ct) else null,
            .arena = arena,
            .body = .empty,
            .reader = reader,
            .resolver = try resolver.persist(),
        };
        exec.page._body_reads.append(&self.node);

        self.pump(exec);
        return resolver.promise();
    }

    // Releases the reads still pending when their page goes away. Their JS is
    // gone by then, so only the memory is left to free.
    pub fn releasePending(page: *Page) void {
        while (page._body_reads.popFirst()) |node| {
            const self: *StreamConsumer = @fieldParentPtr("node", node);
            self.arena.release();
        }
    }

    // A failure rejects the body and releases this state. The reader keeps its
    // lock, as in the spec, so the body can't be read or cloned again.
    fn pump(self: *StreamConsumer, exec: *const Execution) void {
        self.pumpChunks(exec) catch |err| self.fail(exec, err);
    }

    // Takes the chunks already queued as they are. A read promise is only
    // needed for one still to come, or to see the end.
    fn pumpChunks(self: *StreamConsumer, exec: *const Execution) !void {
        while (true) {
            // one scope per chunk, so a long queue doesn't pile up handles
            var ls: js.Local.Scope = undefined;
            exec.js.localScope(&ls);
            defer ls.deinit();

            const chunk = self.reader.takeQueued(&ls.local) orelse break;
            try self.append(chunk);
        }

        const local = exec.js.local.?;
        const read = try self.reader.read(exec);
        const then_fn = local.newCallback(onRead, self);
        const catch_fn = local.newCallback(onReadRejected, self);
        _ = try read.thenAndCatch(then_fn, catch_fn);
    }

    // The realm that read the body can go away first, with its frame. The read
    // then stays pending, and its memory goes with the page.
    fn onRead(self: *StreamConsumer, result: js.Value) void {
        const exec = self.execution.get() orelse return;
        const done = self.readResult(result, exec) catch |err| return self.fail(exec, err);
        if (done) {
            self.complete(exec);
        }
    }

    fn readResult(self: *StreamConsumer, result: js.Value, exec: *const Execution) !bool {
        const obj = result.toObject();
        if ((try obj.get("done")).toBool()) {
            return true;
        }
        try self.append(try obj.get("value"));
        try self.pumpChunks(exec);
        return false;
    }

    fn append(self: *StreamConsumer, chunk: js.Value) !void {
        // A chunk that is not a Uint8Array is a TypeError.
        if (chunk.isUint8Array() == false) {
            return error.NotUint8Array;
        }
        const bytes = (try chunk.local.jsValueToZig(js.AllowSharedBufferSource, chunk)).bytes();
        try self.body.appendSlice(self.arena.allocator(), bytes);
    }

    fn complete(self: *StreamConsumer, exec: *const Execution) void {
        const resolver = exec.js.local.?.toLocal(self.resolver);
        package(self.kind, self.body.items, self.content_type, resolver, exec) catch |err| {
            return self.fail(exec, err);
        };
        self.release();
    }

    fn onReadRejected(self: *StreamConsumer, reason: js.Value) void {
        if (self.execution.js() == null) return;
        reason.local.toLocal(self.resolver).reject("stream body", reason);
        self.release();
    }

    fn fail(self: *StreamConsumer, exec: *const Execution, err: anyerror) void {
        const message = switch (err) {
            error.NotUint8Array => "Body chunk is not a Uint8Array",
            else => "Failed to read stream",
        };
        exec.js.local.?.toLocal(self.resolver).rejectError("stream body", .{ .type_error = message });
        self.release();
    }

    fn release(self: *StreamConsumer) void {
        self.resolver.release();
        self.execution.page()._body_reads.remove(&self.node);
        self.arena.release();
    }
};

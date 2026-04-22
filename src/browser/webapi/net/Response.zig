// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Page = @import("../../Page.zig");
const HttpClient = @import("../../HttpClient.zig");

const Blob = @import("../Blob.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Headers = @import("Headers.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Response = @This();

pub const Type = enum {
    basic,
    cors,
    @"error",
    @"opaque",
    opaqueredirect,
};

_rc: lp.RC(u8) = .{},
_status: u16,
_arena: Allocator,
_headers: *Headers,
_body: Body = .empty,
_type: Type,
_status_text: []const u8,
_url: [:0]const u8,
_is_redirected: bool,
_http_response: ?HttpClient.Response = null,

const Body = union(enum) {
    empty,
    bytes: []const u8,
    stream: *ReadableStream,
};

const InitOpts = struct {
    status: u16 = 200,
    headers: ?Headers.InitOpts = null,
    statusText: ?[]const u8 = null,
};

/// Body can be: null, string ([]const u8), ReadableStream, Blob, ArrayBuffer
pub const BodyInit = union(enum) {
    stream: *ReadableStream,
    bytes: []const u8,
    js_val: js.Value,
};

pub fn init(body_: ?BodyInit, opts_: ?InitOpts, exec: *const Execution) !*Response {
    const session = exec.context.page.session;
    const arena = try session.getArena(.large, "Response");
    errdefer session.releaseArena(arena);

    const opts = opts_ orelse InitOpts{};
    const status_text = if (opts.statusText) |st| try arena.dupe(u8, st) else "";

    // Parse body from the union
    const body: Body = blk: {
        const b = body_ orelse break :blk .empty;
        switch (b) {
            .bytes => |body_bytes| break :blk .{ .bytes = try arena.dupe(u8, body_bytes) },
            .stream => |stream| break :blk .{ .stream = stream },
            .js_val => |js_val| {
                if (js_val.isNullOrUndefined()) {
                    break :blk .empty;
                }
                break :blk .{ .bytes = try arena.dupe(u8, try js_val.toStringSmart()) };
            },
        }
        break :blk .empty;
    };

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = opts.status,
        ._status_text = status_text,
        ._url = "",
        ._body = body,
        ._type = .basic,
        ._is_redirected = false,
        ._headers = try Headers.init(opts.headers, exec),
    };
    return self;
}

pub fn deinit(self: *Response, page: *Page) void {
    if (self._http_response) |resp| {
        resp.abort(error.Abort);
        self._http_response = null;
    }
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *Response, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Response) void {
    self._rc.acquire();
}

pub fn getStatus(self: *const Response) u16 {
    return self._status;
}

pub fn getStatusText(self: *const Response) []const u8 {
    return self._status_text;
}

pub fn getURL(self: *const Response) []const u8 {
    return self._url;
}

pub fn isRedirected(self: *const Response) bool {
    return self._is_redirected;
}

pub fn getHeaders(self: *const Response) *Headers {
    return self._headers;
}

pub fn getType(self: *const Response) []const u8 {
    return @tagName(self._type);
}

pub fn getBody(self: *Response, exec: *const Execution) !?*ReadableStream {
    return switch (self._body) {
        .empty => null,
        .stream => |stream| stream,
        .bytes => |body| {
            if (body.len == 0) {
                const stream = try ReadableStream.init(null, null, exec);
                try stream._controller.close();
                return stream;
            }
            return ReadableStream.initWithData(body, exec);
        },
    };
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

pub fn getText(self: *const Response, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const body = switch (self._body) {
        .bytes => |b| b,
        .empty => "",
        .stream => return local.rejectPromise(.{ .type_error = "Cannot read text from stream body" }),
    };
    return local.resolvePromise(body);
}

pub fn getJson(self: *Response, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const body = switch (self._body) {
        .bytes => |b| b,
        .empty => "",
        .stream => return local.rejectPromise(.{ .type_error = "Cannot read JSON from stream body" }),
    };
    const value = local.parseJSON(body) catch {
        return local.rejectPromise(.{ .syntax_error = "failed to parse" });
    };
    return local.resolvePromise(try value.persist());
}

pub fn arrayBuffer(self: *Response, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    return switch (self._body) {
        .bytes => |body| local.resolvePromise(js.ArrayBuffer{ .values = body }),
        .empty => local.resolvePromise(js.ArrayBuffer{ .values = "" }),
        .stream => |stream| StreamConsumer.start(stream, exec),
    };
}

/// Async consumer for reading all data from a ReadableStream
const StreamConsumer = struct {
    const ReadableStreamDefaultReader = @import("../streams/ReadableStreamDefaultReader.zig");

    execution: *const Execution,
    total_len: usize,
    arena: Allocator,
    reader: *ReadableStreamDefaultReader,
    chunks: std.ArrayList([]const u8),
    resolver: js.PromiseResolver.Global,

    fn start(stream: *ReadableStream, exec: *const Execution) !js.Promise {
        const local = exec.context.local.?;
        var resolver = local.createPromiseResolver();
        const promise = resolver.promise();

        const reader = try stream.getReader(exec);

        const state = try exec.arena.create(StreamConsumer);
        state.* = .{
            .execution = exec,
            .reader = reader,
            .chunks = .empty,
            .total_len = 0,
            .arena = exec.arena,
            .resolver = try resolver.persist(),
        };

        try state.pumpRead();
        return promise;
    }

    fn pumpRead(self: *StreamConsumer) !void {
        const local = self.execution.context.local.?;
        const read_promise = try self.reader.read(self.execution);

        const then_fn = local.newCallback(onReadFulfilled, self);
        const catch_fn = local.newCallback(onReadRejected, self);

        _ = read_promise.thenAndCatch(then_fn, catch_fn) catch {
            self.finish(local, null);
        };
    }

    const ReadData = struct {
        done: bool,
        value: js.Value,
    };

    fn onReadFulfilled(self: *StreamConsumer, data_: ?ReadData) void {
        const local = self.execution.context.local.?;

        const data = data_ orelse {
            return self.finish(local, null);
        };

        self._onReadFulfilled(data) catch {
            self.finish(local, null);
        };
    }

    fn _onReadFulfilled(self: *StreamConsumer, data: ReadData) !void {
        const exec = self.execution;
        const local = exec.context.local.?;

        if (data.done) {
            // Stream is finished, concatenate all chunks and resolve
            self.reader.releaseLock();
            const result = try self.concatenateChunks(exec.call_arena);
            local.toLocal(self.resolver).resolve("arrayBuffer complete", js.ArrayBuffer{ .values = result });
            return;
        }

        // Collect the chunk data
        const value = data.value;
        if (!value.isUndefined()) {
            // Try to get bytes from the value (could be Uint8Array or string)
            if (value.isTypedArray() or value.isArrayBufferView() or value.isArrayBuffer()) {
                if (local.jsValueToZig([]u8, value)) |typed_data| {
                    const chunk_copy = try self.arena.dupe(u8, typed_data);
                    try self.chunks.append(self.arena, chunk_copy);
                    self.total_len += chunk_copy.len;
                } else |_| {}
            } else if (value.isString()) |str| {
                const slice = try str.toSlice();
                const chunk_copy = try self.arena.dupe(u8, slice);
                try self.chunks.append(self.arena, chunk_copy);
                self.total_len += chunk_copy.len;
            }
        }
        try self.pumpRead();
    }

    fn onReadRejected(self: *StreamConsumer) void {
        self.finish(self.execution.context.local.?, null);
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
        local.toLocal(self.resolver).rejectError("arrayBuffer error", .{ .type_error = err orelse "Failed to read stream" });
    }
};

pub fn blob(self: *const Response, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const body = switch (self._body) {
        .bytes => |b| b,
        .empty => "",
        .stream => return local.rejectPromise(.{ .type_error = "Cannot read blob from stream body" }),
    };
    const content_type = try self._headers.get("content-type", exec) orelse "";
    const b = try Blob.initFromBytes(body, content_type, true, exec.context.page);
    return local.resolvePromise(b);
}

pub fn bytes(self: *const Response, exec: *const Execution) !js.Promise {
    const local = exec.context.local.?;
    const body = switch (self._body) {
        .bytes => |b| b,
        .empty => "",
        .stream => return local.rejectPromise(.{ .type_error = "Cannot read bytes from stream body" }),
    };
    return local.resolvePromise(js.TypedArray(u8){ .values = body });
}

pub fn clone(self: *const Response, exec: *const Execution) !*Response {
    const session = exec.context.page.session;
    const body_len = switch (self._body) {
        .bytes => |b| b.len,
        .empty => 0,
        .stream => 0,
    };
    const arena = try session.getArena(body_len + self._url.len + 256, "Response.clone");
    errdefer session.releaseArena(arena);

    const body: Body = switch (self._body) {
        .bytes => |b| .{ .bytes = try arena.dupe(u8, b) },
        .empty => .empty,
        .stream => .empty, // TODO: implement stream tee for proper cloning
    };
    const status_text = try arena.dupe(u8, self._status_text);
    const url = try arena.dupeZ(u8, self._url);

    const cloned = try arena.create(Response);
    cloned.* = .{
        ._arena = arena,
        ._status = self._status,
        ._status_text = status_text,
        ._url = url,
        ._body = body,
        ._type = self._type,
        ._is_redirected = self._is_redirected,
        ._headers = try Headers.init(.{ .obj = self._headers }, exec),
        ._http_response = null,
    };
    return cloned;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Response);

    pub const Meta = struct {
        pub const name = "Response";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Response.init, .{});
    pub const ok = bridge.accessor(Response.isOK, null, .{});
    pub const status = bridge.accessor(Response.getStatus, null, .{});
    pub const statusText = bridge.accessor(Response.getStatusText, null, .{});
    pub const @"type" = bridge.accessor(Response.getType, null, .{});
    pub const text = bridge.function(Response.getText, .{});
    pub const json = bridge.function(Response.getJson, .{});
    pub const headers = bridge.accessor(Response.getHeaders, null, .{});
    pub const body = bridge.accessor(Response.getBody, null, .{});
    pub const url = bridge.accessor(Response.getURL, null, .{});
    pub const redirected = bridge.accessor(Response.isRedirected, null, .{});
    pub const arrayBuffer = bridge.function(Response.arrayBuffer, .{});
    pub const blob = bridge.function(Response.blob, .{});
    pub const bytes = bridge.function(Response.bytes, .{});
    pub const clone = bridge.function(Response.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Response" {
    try testing.htmlRunner("net/response.html", .{});
}

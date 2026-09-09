// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const URL = @import("../../URL.zig");
const Page = @import("../../Page.zig");
const Transfer = @import("../../../network/HttpClient.zig").Transfer;

const Blob = @import("../Blob.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");
const FormData = @import("FormData.zig");

const Headers = @import("Headers.zig");
const body_init = @import("body_init.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Response = @This();

pub const Type = enum {
    basic,
    cors,
    default,
    @"error",
    @"opaque",
    opaqueredirect,
};

_rc: lp.RC = .{},
_status: u16,
_arena: *lp.Arena,
_headers: *Headers,
_body: Body = .empty,
_type: Type,
_status_text: []const u8,
_url: [:0]const u8,
_is_redirected: bool,
_http_transfer: ?*Transfer = null,
_body_used: bool = false,
_body_stream: ?*ReadableStream = null,

const Body = union(enum) {
    empty,
    bytes: []const u8,
    stream: *ReadableStream,
};

const InitOpts = struct {
    headers: ?Headers.InitOpts = null,
    status: u16 = 200,
    statusText: ?[]const u8 = null,
};

pub const BodyInit = body_init.BodyInit;

pub fn init(body_: ?BodyInit, opts_: ?InitOpts, exec: *const Execution) !*Response {
    const session = exec.session;

    const bucket: lp.ArenaPool.BucketSize = blk: {
        const body = body_ orelse break :blk .small;
        if (body == .stream) {
            // A stream body is referenced below, never copied into the arena.
            break :blk .small;
        }
        const hint = body.sizeHint() orelse break :blk .large;
        break :blk session.arena_pool.bucketFor(hint + 512);
    };

    const arena = try session.getPinnedArena(bucket, "Response");
    errdefer arena.release();
    return initWithArena(arena, body_, opts_, exec);
}

// fetch()'s response shell.
pub fn initPending(exec: *const Execution) !*Response {
    const arena = try exec.session.getPinnedArena(.large, "Response.pending");
    errdefer arena.release();
    return initWithArena(arena, null, .{ .status = 0 }, exec);
}

fn initWithArena(arena: *lp.Arena, body_: ?BodyInit, opts_: ?InitOpts, exec: *const Execution) !*Response {
    const opts = opts_ orelse InitOpts{};
    const status_text = if (opts.statusText) |st| try arena.dupe(u8, st) else "";

    var content_type: ?[]const u8 = null;
    const body: Body = blk: {
        const b = body_ orelse break :blk .empty;
        switch (b) {
            .stream => |stream| break :blk .{ .stream = stream },
            else => {
                const extracted = try b.extract(arena.allocator());
                content_type = extracted.content_type;
                break :blk .{ .bytes = extracted.bytes };
            },
        }
    };

    const headers = try Headers.initGuarded(opts.headers, .response, exec);
    if (content_type) |ct| {
        if (try headers.has("content-type", exec) == false) {
            try headers.append("content-type", ct, exec);
        }
    }

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = opts.status,
        ._status_text = status_text,
        ._url = "",
        ._body = body,
        ._type = .default,
        ._is_redirected = false,
        ._headers = headers,
    };
    arena.report();
    return self;
}

pub fn createError(exec: *const Execution) !*Response {
    const session = exec.session;
    const arena = try session.getPinnedArena(.tiny, "Response.error");
    errdefer arena.release();

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = 0,
        ._status_text = "",
        ._url = "",
        ._body = .empty,
        ._type = .@"error",
        ._is_redirected = false,
        ._headers = try .initGuarded(null, .immutable, exec),
    };
    arena.report();
    return self;
}

pub fn createRedirect(url_: []const u8, status_: ?u16, exec: *const Execution) !*Response {
    const status = status_ orelse 302;
    switch (status) {
        301, 302, 303, 307, 308 => {},
        else => return error.RangeError,
    }

    const session = exec.session;
    const arena = try session.getPinnedArena(.small, "Response.redirect");
    errdefer arena.release();

    const location = try URL.resolve(arena.allocator(), exec.base(), url_, .{ .encoding = exec.charset.* });

    const headers = try Headers.init(null, exec);
    // append location directly, then lock the headers
    try headers.set("location", location, exec);
    headers._guard = .immutable;

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = status,
        ._status_text = "",
        ._url = "",
        ._body = .empty,
        ._type = .default,
        ._is_redirected = false,
        ._headers = headers,
    };
    arena.report();
    return self;
}

pub fn createJson(data: js.Value, opts_: ?InitOpts, exec: *const Execution) !*Response {
    const session = exec.session;
    const arena = try session.getPinnedArena(.medium, "Response.json");
    errdefer arena.release();

    const json = data.toJson(arena.allocator()) catch |err| switch (err) {
        error.JsException => return error.TryCatchRethrow,
        else => return err,
    };
    if (std.mem.eql(u8, json, "undefined")) {
        return error.TypeError;
    }

    const opts = opts_ orelse InitOpts{};
    const status_text = if (opts.statusText) |st| try arena.dupe(u8, st) else "";

    const headers = try Headers.initGuarded(opts.headers, .response, exec);
    if (try headers.has("content-type", exec) == false) {
        try headers.append("content-type", "application/json", exec);
    }

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = opts.status,
        ._status_text = status_text,
        ._url = "",
        ._body = .{ .bytes = json },
        ._type = .default,
        ._is_redirected = false,
        ._headers = headers,
    };
    arena.report();
    return self;
}

pub fn deinit(self: *Response, _: *Page) void {
    if (self._http_transfer) |resp| {
        resp.cancel();
        self._http_transfer = null;
    }
    self._arena.release();
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
            if (self._body_stream) |stream| {
                return stream;
            }
            const stream = blk: {
                if (body.len == 0) {
                    const stream = try ReadableStream.init(null, null, exec);
                    try stream._controller.close();
                    break :blk stream;
                }
                break :blk try ReadableStream.initWithData(body, exec);
            };
            self._body_stream = stream;
            if (self._body_used) {
                try lockStream(stream, exec);
            }
            return stream;
        },
    };
}

// A consumed body's stream stays locked and disturbed (Fetch §6.4 never
// releases the reader it read with).
fn lockStream(stream: *ReadableStream, exec: *const Execution) !void {
    _ = try stream.getReader(exec);
    stream._disturbed = true;
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

pub fn getBodyUsed(self: *const Response) bool {
    return switch (self._body) {
        .empty => false,
        .stream => |stream| stream._disturbed,
        .bytes => self._body_used,
    };
}

// A TypeError if the body is disturbed or its stream is locked (Fetch §6.4).
fn checkUnusable(self: *const Response, local: *const js.Local) !void {
    const stream = switch (self._body) {
        .empty => return,
        .stream => |stream| stream,
        .bytes => self._body_stream orelse {
            if (self._body_used) {
                return local.typeError("Body has already been read");
            }
            return;
        },
    };
    if (stream._disturbed or stream.getLocked()) {
        return local.typeError("Body is disturbed or locked");
    }
}

// Marks a present body consumed.
fn consume(self: *Response, exec: *const Execution) !void {
    const local = exec.js.local.?;
    try self.checkUnusable(local);
    self._body_used = true;
    if (self._body == .bytes) {
        if (self._body_stream) |stream| {
            try lockStream(stream, exec);
        }
    }
}

pub fn getText(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.text, exec);
}

pub fn getJson(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.json, exec);
}

pub fn arrayBuffer(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.array_buffer, exec);
}

pub fn blob(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.blob, exec);
}

pub fn bytes(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.bytes, exec);
}

pub fn formData(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.form_data, exec);
}

const Package = enum { array_buffer, bytes, text, json, blob, form_data };

// a byte body is packaged right away, a stream body once it has been drained.
fn consumeAs(self: *Response, kind: Package, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    try self.consume(exec);

    const content_type = try self._headers.get("content-type", exec);
    switch (self._body) {
        .stream => |stream| return StreamConsumer.start(stream, kind, content_type, exec),
        .bytes, .empty => {},
    }

    var resolver = local.createPromiseResolver();
    const body = switch (self._body) {
        .bytes => |b| b,
        else => "",
    };
    try package(kind, body, content_type, resolver, exec);
    return resolver.promise();
}

// settles `resolver` with `body` as `kind`.
fn package(kind: Package, body: []const u8, content_type: ?[]const u8, resolver: js.PromiseResolver, exec: *const Execution) !void {
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
        .blob => resolver.resolve("blob", try Blob.initFromBytes(body, content_type orelse "", exec)),
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
const StreamConsumer = struct {
    const ReadableStreamDefaultReader = @import("../streams/ReadableStreamDefaultReader.zig");

    execution: *const Execution,
    kind: Package,
    content_type: ?[]const u8,
    total_len: usize,
    arena: Allocator,
    reader: *ReadableStreamDefaultReader,
    chunks: std.ArrayList([]const u8),
    resolver: js.PromiseResolver.Global,

    fn start(stream: *ReadableStream, kind: Package, content_type: ?[]const u8, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        var resolver = local.createPromiseResolver();
        const promise = resolver.promise();

        const reader = try stream.getReader(exec);

        const state = try exec.arena.create(StreamConsumer);
        state.* = .{
            .execution = exec,
            .kind = kind,
            .content_type = if (content_type) |ct| try exec.arena.dupe(u8, ct) else null,
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
        const local = self.execution.js.local.?;
        const read_promise = try self.reader.read(self.execution);

        const then_fn = local.newCallback(onReadFulfilled, self);
        const catch_fn = local.newCallback(onReadRejected, self);

        _ = read_promise.thenAndCatch(then_fn, catch_fn) catch {
            self.finish(local, null);
        };
    }

    fn onReadFulfilled(self: *StreamConsumer, result: js.Value) void {
        const local = self.execution.js.local.?;
        self._onReadFulfilled(result) catch {
            self.finish(local, null);
        };
    }

    fn _onReadFulfilled(self: *StreamConsumer, result: js.Value) !void {
        const exec = self.execution;
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
        const chunk_copy = try self.arena.dupe(u8, try local.jsValueToZig([]u8, value));
        try self.chunks.append(self.arena, chunk_copy);
        self.total_len += chunk_copy.len;
        try self.pumpRead();
    }

    fn onReadRejected(self: *StreamConsumer) void {
        self.finish(self.execution.js.local.?, null);
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
};

pub fn clone(self: *const Response, exec: *const Execution) !*Response {
    try self.checkUnusable(exec.js.local.?);
    const session = exec.session;
    const body_len = switch (self._body) {
        .bytes => |b| b.len,
        .empty => 0,
        .stream => 0,
    };
    const arena = try session.getPinnedArena(body_len + self._url.len + 256, "Response.clone");
    errdefer arena.release();

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
        ._headers = try .initGuarded(.{ .obj = self._headers }, self._headers._guard, exec),
        ._http_transfer = null,
    };
    arena.report();
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

    pub const @"error" = bridge.function(Response.createError, .{ .static = true });
    pub const redirect = bridge.function(Response.createRedirect, .{ .static = true });
    // Response.json (staticc) conflicts with resposne.json, hence the `js_name` option
    pub const json_static = bridge.function(Response.createJson, .{ .static = true, .js_name = "json" });

    pub const ok = bridge.accessor(Response.isOK, null, .{});
    pub const status = bridge.accessor(Response.getStatus, null, .{});
    pub const statusText = bridge.accessor(Response.getStatusText, null, .{});
    pub const @"type" = bridge.accessor(Response.getType, null, .{});
    pub const text = bridge.function(Response.getText, .{});
    pub const json = bridge.function(Response.getJson, .{});
    pub const headers = bridge.accessor(Response.getHeaders, null, .{});
    pub const body = bridge.accessor(Response.getBody, null, .{});
    pub const bodyUsed = bridge.accessor(Response.getBodyUsed, null, .{});
    pub const url = bridge.accessor(Response.getURL, null, .{});
    pub const redirected = bridge.accessor(Response.isRedirected, null, .{});
    pub const arrayBuffer = bridge.function(Response.arrayBuffer, .{});
    pub const blob = bridge.function(Response.blob, .{});
    pub const bytes = bridge.function(Response.bytes, .{});
    pub const formData = bridge.function(Response.formData, .{});
    pub const clone = bridge.function(Response.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Response" {
    try testing.htmlRunner("net/response.html", .{});
}

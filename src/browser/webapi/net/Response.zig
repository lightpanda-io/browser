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
const HttpClient = @import("../../../network/HttpClient.zig");

const AbortSignal = @import("../AbortSignal.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Headers = @import("Headers.zig");
const body_init = @import("body_init.zig");
const body_consume = @import("body_consume.zig");
const TextDecoderStream = @import("../encoding/TextDecoderStream.zig");

const Execution = js.Execution;
const Transfer = HttpClient.Transfer;

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
// fetch's body, taken from the transfer instead of copied into _arena. When
// set, _body.bytes points into it.
_transfer_body: HttpClient.Body = .empty,
// What V8 has been told about _transfer_body; see report.
_transfer_body_reported: usize = 0,
_type: Type,
_status_text: []const u8,
_url: [:0]const u8,
_is_redirected: bool,
_http_transfer: ?*Transfer = null,
_body_used: bool = false,
_body_stream: ?*ReadableStream = null,
_signal: ?*AbortSignal = null, // fetch's abort, aborts response body read

const Body = union(enum) {
    empty,
    bytes: []const u8,
    stream: *ReadableStream,
    errored,
};

const InitOpts = struct {
    headers: ?Headers.InitOpts = null,
    status: u16 = 200,
    statusText: ?[]const u8 = null,
};

pub const BodyInit = body_init.BodyInit;

pub fn init(body_: ?BodyInit, opts_: ?InitOpts, exec: *const Execution) !*Response {
    try validateInit(opts_ orelse .{}, body_ != null);
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

fn validateInit(opts: InitOpts, has_body: bool) !void {
    if (opts.status < 200 or opts.status > 599) {
        return error.RangeError;
    }

    if (opts.statusText) |status_text| {
        // reason-phrase: HTAB, SP, VCHAR and obs-text, all within a ByteString
        var it = (std.unicode.Utf8View.init(status_text) catch return error.TypeError).iterator();
        while (it.nextCodepoint()) |cp| switch (cp) {
            '\t', ' '...'~', 0x80...0xFF => {},
            else => return error.TypeError,
        };
    }

    if (has_body and isNullBodyStatus(opts.status)) {
        return error.TypeError;
    }
}

// https://fetch.spec.whatwg.org/#null-body-status
pub fn isNullBodyStatus(status: u16) bool {
    return switch (status) {
        101, 103, 204, 205, 304 => true,
        else => false,
    };
}

// fetch()'s response shell.
pub fn initPending(exec: *const Execution) !*Response {
    // The body doesn't go in here; see takeTransferBody.
    const arena = try exec.session.getPinnedArena(.small, "Response.pending");
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

fn createRedirect(url_: []const u8, status_: ?u16, exec: *const Execution) !*Response {
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

fn createJson(data: js.Value, opts_: ?InitOpts, exec: *const Execution) !*Response {
    try validateInit(opts_ orelse .{}, true);
    const session = exec.session;
    const arena = try session.getPinnedArena(.medium, "Response.json");
    errdefer arena.release();

    const json = data.toJson(arena.allocator()) catch |err| switch (err) {
        error.JsException => return error.TryCatchRethrow,
        else => return err,
    } orelse return error.TypeError;

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
    if (self._arena.account) |account| {
        account.pending -= @intCast(self._transfer_body_reported);
    }
    self._transfer_body.deinit();
    self._arena.release();
}

pub fn releaseRef(self: *Response, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Response) void {
    self._rc.acquire();
}

pub fn takeTransferBody(self: *Response, transfer: *Transfer) void {
    self._transfer_body = transfer.takeBody();
    self._body = .{ .bytes = self._transfer_body.items() };
}

pub fn report(self: *Response) void {
    self._arena.report();
    const account = self._arena.account orelse return;
    const cap = self._transfer_body.capacity();
    account.pending += @as(i64, @intCast(cap)) - @as(i64, @intCast(self._transfer_body_reported));
    self._transfer_body_reported = cap;
}

pub fn getStatus(self: *const Response) u16 {
    return self._status;
}

fn getStatusText(self: *const Response) []const u8 {
    return self._status_text;
}

pub fn getURL(self: *const Response) []const u8 {
    return self._url;
}

fn isRedirected(self: *const Response) bool {
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
                if (self.abortReason()) |reason| {
                    // Like text() and json(), reads reject with the signal's reason.
                    const stream = try ReadableStream.init(null, null, exec);
                    try stream._controller.doError(try AbortSignal.reasonJsValue(reason, exec.js.local.?));
                    break :blk stream;
                }
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
        .errored => {
            if (self._body_stream) |stream| {
                return stream;
            }
            const stream = try ReadableStream.init(null, null, exec);
            try stream._controller.typeError("Failed to read response body");
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

// TODO: a body stream obtained before the abort isn't errored.
fn abortReason(self: *const Response) ?AbortSignal.Reason {
    const signal = self._signal orelse return null;
    if (signal._aborted == false or self._body == .empty) {
        return null;
    }
    return signal._reason;
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

fn getBodyUsed(self: *const Response) bool {
    return switch (self._body) {
        .empty => false,
        .stream => |stream| stream._disturbed,
        .bytes, .errored => self._body_used,
    };
}

// A TypeError if the body is disturbed or its stream is locked (Fetch §6.4).
fn checkUnusable(self: *const Response, local: *const js.Local) !void {
    const stream = switch (self._body) {
        .empty => return,
        .stream => |stream| stream,
        .bytes, .errored => self._body_stream orelse {
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
    switch (self._body) {
        .bytes, .errored => if (self._body_stream) |stream| {
            try lockStream(stream, exec);
        },
        .empty, .stream => {},
    }
}

pub fn consumeBytes(self: *Response, exec: *const Execution) ![]const u8 {
    try self.consume(exec);
    if (self.abortReason() != null) {
        return exec.js.local.?.typeError("The operation was aborted.");
    }
    return switch (self._body) {
        .empty => "",
        .bytes => |b| b,
        .stream => exec.js.local.?.typeError("Response with a ReadableStream body is unsupported"),
        .errored => exec.js.local.?.typeError("Failed to read response body"),
    };
}

pub fn getText(self: *Response, exec: *const Execution) !js.Promise {
    return self.consumeAs(.text, exec);
}

fn getJson(self: *Response, exec: *const Execution) !js.Promise {
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

// Returns a ReadableStream<string> that decodes the body as UTF-8, ignoring
// any Content-Type charset (Fetch's non-standard streaming text accessor).
fn textStream(self: *Response, exec: *const Execution) !*ReadableStream {
    const local = exec.js.local.?;
    try self.checkUnusable(local);

    const byte_stream = try self.getBody(exec) orelse {
        const stream = try ReadableStream.init(null, null, exec);
        try stream._controller.close();
        return stream;
    };
    self._body_used = true;

    const decoder = try TextDecoderStream.init(null, null, exec);
    return byte_stream.pipeThrough(.{ .readable = decoder.getReadable(), .writable = decoder.getWritable() }, exec);
}

// a byte body is packaged right away, a stream body once it has been drained.
fn consumeAs(self: *Response, kind: body_consume.Package, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    try self.consume(exec);

    if (self.abortReason()) |reason| {
        var resolver = local.createPromiseResolver();
        resolver.reject("response aborted", try AbortSignal.reasonJsValue(reason, local));
        return resolver.promise();
    }

    const content_type = try self._headers.get("content-type", exec);
    switch (self._body) {
        .stream => |stream| return body_consume.StreamConsumer.start(stream, kind, content_type, exec),
        .errored => {
            var resolver = local.createPromiseResolver();
            resolver.rejectError("response body", .{ .type_error = "Failed to read response body" });
            return resolver.promise();
        },
        .bytes, .empty => {},
    }

    var resolver = local.createPromiseResolver();
    const body = switch (self._body) {
        .bytes => |b| b,
        else => "",
    };
    try body_consume.package(kind, body, content_type, resolver, exec);
    return resolver.promise();
}

pub fn clone(self: *Response, exec: *const Execution) !*Response {
    const local = exec.js.local.?;
    try self.checkUnusable(local);

    switch (self._body) {
        // No stream tee: a stream body is drained so each copy owns its bytes.
        // Same as Request.clone().
        .stream => |stream| {
            const drained = stream.collectBodyBytes(self._arena.allocator(), .lenient) catch |err| switch (err) {
                error.TypeError => return local.typeError("Failed to read ReadableStream body"),
                else => return err,
            };
            try lockStream(stream, exec);
            self._body = .{ .bytes = drained };
        },
        .empty, .bytes, .errored => {},
    }

    const session = exec.session;
    const body_len = switch (self._body) {
        .bytes => |b| b.len,
        .empty, .errored => 0,
        .stream => unreachable,
    };
    const arena = try session.getPinnedArena(body_len + self._url.len + 256, "Response.clone");
    errdefer arena.release();

    const body: Body = switch (self._body) {
        .bytes => |b| .{ .bytes = try arena.dupe(u8, b) },
        .empty => .empty,
        .stream => unreachable,
        .errored => .errored,
    };
    const status_text = try arena.dupe(u8, self._status_text);
    const url = try arena.dupeSentinel(u8, self._url, 0);

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
        ._signal = self._signal,
    };
    arena.report();
    return cloned;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Response);

    pub const Meta = struct {
        pub const name = "Response";
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
    pub const textStream = bridge.function(Response.textStream, .{});
    pub const clone = bridge.function(Response.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Response" {
    try testing.htmlRunner("net/response.html", .{});
}

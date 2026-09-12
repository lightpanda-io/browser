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
const http = @import("../../../network/http.zig");

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Blob = @import("../Blob.zig");
const AbortSignal = @import("../AbortSignal.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Headers = @import("Headers.zig");
const FormData = @import("FormData.zig");
const body_init = @import("body_init.zig");
const BodyInit = body_init.BodyInit;

const Execution = js.Execution;

const Request = @This();

_rc: lp.RC = .{},
_url: [:0]const u8,
_method: http.Method,
_headers: ?*Headers,
_body: ?[]const u8,
_body_stream: ?*ReadableStream = null, // drained into `_body` on first use.
_arena: *lp.Arena,
_cache: Cache,
_credentials: Credentials,
_redirect: Redirect,
_mode: Mode,
_signal: ?*AbortSignal,
_body_used: bool = false,

pub const Input = union(enum) {
    request: *Request,
    url: [:0]const u8,
};

pub const InitOpts = struct {
    body: ?BodyInit = null,
    cache: Cache = .default,
    credentials: Credentials = .@"same-origin",
    headers: ?Headers.InitOpts = null,
    method: ?[]const u8 = null,
    mode: Mode = .cors,
    priority: ?[]const u8 = null,
    redirect: Redirect = .follow,
    signal: ?*AbortSignal = null,
};

const Priority = enum { high, low, auto };

const Redirect = enum {
    follow,
    manual,
    @"error",
    pub const js_enum_from_string = true;
};

const Credentials = enum {
    omit,
    include,
    @"same-origin",
    pub const js_enum_from_string = true;
};

const Cache = enum {
    default,
    @"no-store",
    reload,
    @"no-cache",
    @"force-cache",
    @"only-if-cached",
    pub const js_enum_from_string = true;
};

const Mode = enum {
    cors,
    @"no-cors",
    @"same-origin",
    navigate,
    pub const js_enum_from_string = true;
};

pub fn init(input: Input, opts_: ?InitOpts, exec: *const Execution) !*Request {
    const arena = try exec.getPinnedArena(.medium, "Request");
    errdefer arena.release();

    const url = switch (input) {
        .url => |u| try URL.resolve(arena.allocator(), exec.base(), u, .{ .encoding = exec.charset.* }),
        .request => |r| try arena.dupeZ(u8, r._url),
    };

    const opts = opts_ orelse InitOpts{};
    if (opts.priority) |p| {
        if (std.meta.stringToEnum(Priority, p) == null) {
            return error.InvalidArgument;
        }
    }

    const method = if (opts.method) |m|
        try parseMethod(m, exec)
    else switch (input) {
        .url => .GET,
        .request => |r| r._method,
    };

    const mode = switch (input) {
        .url => opts.mode,
        .request => |r| if (opts_ != null) opts.mode else r._mode,
    };

    const guard = headerGuard(mode);
    var headers = if (opts.headers) |headers_init|
        try Headers.initGuarded(headers_init, guard, exec)
    else switch (input) {
        .url => null,
        .request => |r| if (r._headers) |h| try Headers.initGuarded(.{ .obj = h }, guard, exec) else null,
    };

    var body_stream: ?*ReadableStream = null;
    const body = if (opts.body) |b| blk: {
        if (b == .stream) {
            // Drained on first use, not here: the stream may not be closed yet.
            body_stream = b.stream;
            break :blk null;
        }
        const extracted = try b.extract(arena.allocator());
        // Per Fetch §6.5 step 11, the default Content-Type only applies if
        // the user has not already set one via the headers init dict.
        if (extracted.content_type) |ct| {
            const hs = headers orelse try Headers.initGuarded(null, guard, exec);
            if (try hs.has("content-type", exec) == false) {
                try hs.append("content-type", ct, exec);
            }
            headers = hs;
        }
        break :blk extracted.bytes;
    } else switch (input) {
        .url => null,
        .request => |r| blk: {
            body_stream = r._body_stream;
            // Dupe: the source Request owns its body bytes and may be finalized
            // before this one.
            break :blk if (r._body) |b| try arena.dupe(u8, b) else null;
        },
    };

    const signal = if (opts.signal) |s|
        s
    else switch (input) {
        .url => null,
        .request => |r| r._signal,
    };

    const self = try arena.create(Request);
    self.* = .{
        ._url = url,
        ._arena = arena,
        ._method = method,
        ._headers = headers,
        ._cache = opts.cache,
        ._credentials = opts.credentials,
        ._redirect = opts.redirect,
        ._mode = mode,
        ._body = body,
        ._body_stream = body_stream,
        ._signal = signal,
    };
    arena.report();
    return self;
}

pub fn deinit(self: *Request, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Request, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Request) void {
    self._rc.acquire();
}

fn parseMethod(method: []const u8, exec: *const Execution) !http.Method {
    if (method.len > "propfind".len) {
        return error.InvalidMethod;
    }

    const lower = std.ascii.lowerString(exec.buf, method);

    const method_lookup = std.StaticStringMap(http.Method).initComptime(.{
        .{ "get", .GET },
        .{ "post", .POST },
        .{ "delete", .DELETE },
        .{ "put", .PUT },
        .{ "patch", .PATCH },
        .{ "head", .HEAD },
        .{ "options", .OPTIONS },
        .{ "propfind", .PROPFIND },
    });
    return method_lookup.get(lower) orelse return error.InvalidMethod;
}

pub fn getUrl(self: *const Request) []const u8 {
    return self._url;
}

pub fn getMethod(self: *const Request) []const u8 {
    return @tagName(self._method);
}

fn getCache(self: *const Request) []const u8 {
    return @tagName(self._cache);
}

fn getCredentials(self: *const Request) []const u8 {
    return @tagName(self._credentials);
}

fn getRedirect(self: *const Request) []const u8 {
    return @tagName(self._redirect);
}

pub fn getMode(self: *const Request) []const u8 {
    return @tagName(self._mode);
}

fn getSignal(self: *const Request) ?*AbortSignal {
    return self._signal;
}

fn getHeaders(self: *Request, exec: *const Execution) !*Headers {
    if (self._headers) |headers| {
        return headers;
    }

    const headers = try Headers.initGuarded(null, headerGuard(self._mode), exec);
    self._headers = headers;
    return headers;
}

fn headerGuard(mode: Mode) Headers.Guard {
    return if (mode == .@"no-cors") .request_no_cors else .request;
}

fn getBodyUsed(self: *const Request) bool {
    if (self._body == null and self._body_stream == null) {
        return false;
    }
    return self._body_used;
}

pub fn bodyBytes(self: *Request) !?[]const u8 {
    if (self._body_stream) |stream| {
        // drain the stram on first use, TypeError if it can't.
        self._body = try stream.collectBodyBytes(self._arena.allocator());
        self._body_stream = null;
    }
    return self._body;
}

// Marks a present body consumed and returns it
fn consume(self: *Request, local: *const js.Local) ![]const u8 {
    if (self._body == null and self._body_stream == null) {
        return "";
    }

    if (self._body_used) {
        return local.typeError("Body has already been read");
    }
    const body = self.bodyBytes() catch |err| switch (err) {
        error.TypeError => return local.typeError("Failed to read ReadableStream body"),
        else => return err,
    };
    self._body_used = true;
    return body orelse "";
}

pub fn blob(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const body = try self.consume(local);

    const headers = try self.getHeaders(exec);
    const content_type = try headers.get("content-type", exec) orelse "";

    const b = try Blob.initFromBytes(body, content_type, exec);
    return local.resolvePromise(b);
}

pub fn text(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const body = try self.consume(local);
    return local.resolvePromise(body_init.stripUtf8Bom(body));
}

pub fn json(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const body = try self.consume(local);

    const value = local.parseJSON(body_init.stripUtf8Bom(body)) catch {
        return local.rejectPromise(.{ .syntax_error = "failed to parse" });
    };
    return local.resolvePromise(try value.persist());
}

pub fn arrayBuffer(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const body = try self.consume(local);
    return local.resolvePromise(js.ArrayBuffer{ .values = body });
}

pub fn bytes(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const body = try self.consume(local);
    return local.resolvePromise(js.TypedArray(u8){ .values = body });
}

pub fn formData(self: *Request, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    // Per Fetch, a null body acts as an empty byte sequence.
    const body = try self.consume(local);

    const headers = try self.getHeaders(exec);
    const content_type = try headers.get("content-type", exec);
    const form_data = body_init.parseFormData(body, content_type, exec) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.TypeError => return local.typeError("Failed to parse body as FormData"),
    };
    return local.resolvePromise(form_data);
}

pub fn clone(self: *Request, exec: *const Execution) !*Request {
    // No stream tee: a stream body is drained so each copy owns its bytes.
    const body = self.bodyBytes() catch |err| switch (err) {
        error.TypeError => return exec.js.local.?.typeError("Failed to read ReadableStream body"),
        else => return err,
    };
    const arena = try exec.getPinnedArena(if (body) |b| b.len else 512, "Request.clone");
    errdefer arena.release();

    const request = try arena.create(Request);
    request.* = .{
        ._url = try arena.dupeZ(u8, self._url),
        ._arena = arena,
        ._method = self._method,
        ._headers = self._headers,
        ._cache = self._cache,
        ._credentials = self._credentials,
        ._redirect = self._redirect,
        ._mode = self._mode,
        ._body = if (body) |b| try arena.dupe(u8, b) else null,
        ._signal = self._signal,
    };
    arena.report();
    return request;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Request);

    pub const Meta = struct {
        pub const name = "Request";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Request.init, .{});
    pub const url = bridge.accessor(Request.getUrl, null, .{});
    pub const method = bridge.accessor(Request.getMethod, null, .{});
    pub const headers = bridge.accessor(Request.getHeaders, null, .{});
    pub const cache = bridge.accessor(Request.getCache, null, .{});
    pub const credentials = bridge.accessor(Request.getCredentials, null, .{});
    pub const redirect = bridge.accessor(Request.getRedirect, null, .{});
    pub const mode = bridge.accessor(Request.getMode, null, .{});
    pub const signal = bridge.accessor(Request.getSignal, null, .{});
    pub const bodyUsed = bridge.accessor(Request.getBodyUsed, null, .{});
    pub const blob = bridge.function(Request.blob, .{});
    pub const text = bridge.function(Request.text, .{});
    pub const json = bridge.function(Request.json, .{});
    pub const arrayBuffer = bridge.function(Request.arrayBuffer, .{});
    pub const bytes = bridge.function(Request.bytes, .{});
    pub const formData = bridge.function(Request.formData, .{});
    pub const clone = bridge.function(Request.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Request" {
    try testing.htmlRunner("net/request.html", .{});
}

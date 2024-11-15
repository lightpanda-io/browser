// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const DOMError = @import("netsurf").DOMError;
const DOMException = @import("../dom/exceptions.zig").DOMException;

const ProgressEvent = @import("progress_event.zig").ProgressEvent;
const XMLHttpRequestEventTarget = @import("event_target.zig").XMLHttpRequestEventTarget;

const Mime = @import("../browser/mime.zig");

const Loop = jsruntime.Loop;
const Client = @import("../http/async/main.zig").Client;

const parser = @import("netsurf");

const UserContext = @import("../user_context.zig").UserContext;

const log = std.log.scoped(.xhr);

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = generate.Tuple(.{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
    XMLHttpRequest,
});

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
};

pub const XMLHttpRequestBodyInitTag = enum {
    Blob,
    BufferSource,
    FormData,
    URLSearchParams,
    String,
};

pub const XMLHttpRequestBodyInit = union(XMLHttpRequestBodyInitTag) {
    Blob: []const u8,
    BufferSource: []const u8,
    FormData: []const u8,
    URLSearchParams: []const u8,
    String: []const u8,

    fn contentType(self: XMLHttpRequestBodyInit) ![]const u8 {
        return switch (self) {
            .Blob => error.NotImplemented,
            .BufferSource => error.NotImplemented,
            .FormData => "multipart/form-data; boundary=TODO",
            .URLSearchParams => "application/x-www-form-urlencoded; charset=UTF-8",
            .String => "text/plain; charset=UTF-8",
        };
    }

    // Duplicate the body content.
    // The caller owns the allocated string.
    fn dupe(self: XMLHttpRequestBodyInit, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .Blob => error.NotImplemented,
            .BufferSource => error.NotImplemented,
            .FormData => error.NotImplemented,
            .URLSearchParams => error.NotImplemented,
            .String => |v| try alloc.dupe(u8, v),
        };
    }
};

pub const XMLHttpRequest = struct {
    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
    alloc: std.mem.Allocator,
    cli: *Client,
    loop: Client.Loop,

    priv_state: PrivState = .new,
    req: ?Client.Request = null,
    ctx: ?Client.Ctx = null,

    method: std.http.Method,
    state: u16,
    url: ?[]const u8,
    uri: std.Uri,
    // request headers
    headers: Headers,
    sync: bool = true,
    err: ?anyerror = null,

    // TODO uncomment this field causes casting issue with
    // XMLHttpRequestEventTarget. I think it's dueto an alignement issue, but
    // not sure. see
    // https://lightpanda.slack.com/archives/C05TRU6RBM1/p1707819010681019
    // upload: ?XMLHttpRequestUpload = null,

    // TODO uncomment this field causes casting issue with
    // XMLHttpRequestEventTarget. I think it's dueto an alignement issue, but
    // not sure. see
    // https://lightpanda.slack.com/archives/C05TRU6RBM1/p1707819010681019
    // timeout: u32 = 0,

    withCredentials: bool = false,
    // TODO: response readonly attribute any response;
    response_bytes: ?[]const u8 = null,
    response_type: ResponseType = .Empty,
    response_headers: Headers,

    // used by zig client to parse response headers.
    // use 16KB for headers buffer size.
    response_header_buffer: [1024 * 16]u8 = undefined,

    response_status: u10 = 0,

    // TODO uncomment this field causes casting issue with
    // XMLHttpRequestEventTarget. I think it's dueto an alignement issue, but
    // not sure. see
    // https://lightpanda.slack.com/archives/C05TRU6RBM1/p1707819010681019
    // response_override_mime_type: ?[]const u8 = null,

    response_mime: Mime = undefined,
    response_obj: ?ResponseObj = null,
    send_flag: bool = false,

    payload: ?[]const u8 = null,

    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    pub const UNSENT: u16 = 0;
    pub const OPENED: u16 = 1;
    pub const HEADERS_RECEIVED: u16 = 2;
    pub const LOADING: u16 = 3;
    pub const DONE: u16 = 4;

    // https://xhr.spec.whatwg.org/#response-type
    const ResponseType = enum {
        Empty,
        Text,
        ArrayBuffer,
        Blob,
        Document,
        JSON,
    };

    const JSONValue = std.json.Value;

    const Headers = struct {
        alloc: std.mem.Allocator,
        list: List,

        const List = std.ArrayListUnmanaged(std.http.Header);

        fn init(alloc: std.mem.Allocator) Headers {
            return .{
                .alloc = alloc,
                .list = List{},
            };
        }

        fn deinit(self: *Headers) void {
            self.free();
            self.list.deinit(self.alloc);
        }

        fn append(self: *Headers, k: []const u8, v: []const u8) !void {
            // duplicate strings
            const kk = try self.alloc.dupe(u8, k);
            const vv = try self.alloc.dupe(u8, v);
            try self.list.append(self.alloc, .{ .name = kk, .value = vv });
        }

        // free all strings allocated.
        fn free(self: *Headers) void {
            for (self.list.items) |h| {
                self.alloc.free(h.name);
                self.alloc.free(h.value);
            }
        }

        fn clearAndFree(self: *Headers) void {
            self.free();
            self.list.clearAndFree(self.alloc);
        }

        fn has(self: Headers, k: []const u8) bool {
            for (self.list.items) |h| {
                if (std.ascii.eqlIgnoreCase(k, h.name)) {
                    return true;
                }
            }

            return false;
        }

        fn getFirstValue(self: Headers, k: []const u8) ?[]const u8 {
            for (self.list.items) |h| {
                if (std.ascii.eqlIgnoreCase(k, h.name)) {
                    return h.value;
                }
            }

            return null;
        }

        // replace any existing header with the same key
        fn set(self: *Headers, k: []const u8, v: []const u8) !void {
            for (self.list.items, 0..) |h, i| {
                if (std.ascii.eqlIgnoreCase(k, h.name)) {
                    const hh = self.list.swapRemove(i);
                    self.alloc.free(hh.name);
                    self.alloc.free(hh.value);
                }
            }
            self.append(k, v);
        }

        // TODO
        fn sort(_: *Headers) void {}

        fn all(self: Headers) []std.http.Header {
            return self.list.items;
        }

        fn load(self: *Headers, it: *std.http.HeaderIterator) !void {
            while (true) {
                const h = it.next() orelse break;
                _ = try self.append(h.name, h.value);
            }
        }
    };

    const Response = union(ResponseType) {
        Empty: void,
        Text: []const u8,
        ArrayBuffer: void,
        Blob: void,
        Document: *parser.Document,
        JSON: JSONValue,
    };

    const ResponseObjTag = enum {
        Document,
        Failure,
        JSON,
    };
    const ResponseObj = union(ResponseObjTag) {
        Document: *parser.Document,
        Failure: bool,
        JSON: std.json.Parsed(JSONValue),

        fn deinit(self: ResponseObj) void {
            return switch (self) {
                .Document => |d| {
                    const doc = @as(*parser.DocumentHTML, @ptrCast(d));
                    parser.documentHTMLClose(doc) catch {};
                },
                .JSON => |p| p.deinit(),
                .Failure => {},
            };
        }
    };

    const PrivState = enum { new, open, send, write, finish, wait, done };

    const min_delay: u64 = 50000000; // 50ms

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop, userctx: UserContext) !XMLHttpRequest {
        return .{
            .alloc = alloc,
            .headers = Headers.init(alloc),
            .response_headers = Headers.init(alloc),
            .loop = Client.Loop.init(loop),
            .method = undefined,
            .url = null,
            .uri = undefined,
            .state = UNSENT,
            .cli = userctx.httpClient,
        };
    }

    pub fn reset(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        if (self.url) |v| alloc.free(v);
        self.url = null;

        if (self.payload) |v| alloc.free(v);
        self.payload = null;

        if (self.response_bytes) |v| alloc.free(v);
        if (self.response_obj) |v| v.deinit();

        self.response_obj = null;
        self.response_mime = Mime.Empty;
        self.response_type = .Empty;

        // TODO should we clearRetainingCapacity instead?
        self.headers.clearAndFree();
        self.response_headers.clearAndFree();
        self.response_status = 0;

        self.send_flag = false;

        self.priv_state = .new;

        if (self.ctx) |*c| c.deinit();
        self.ctx = null;

        if (self.req) |*r| r.deinit();
        self.req = null;
    }

    pub fn deinit(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        self.reset();
        self.headers.deinit();
        self.response_headers.deinit();

        self.proto.deinit(alloc);
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.state;
    }

    pub fn get_timeout(_: *XMLHttpRequest) u32 {
        return 0;
    }

    // TODO, the value is ignored for now.
    pub fn set_timeout(_: *XMLHttpRequest, _: u32) !void {
        // TODO If the current global object is a Window object and this’s
        // synchronous flag is set, then throw an "InvalidAccessError"
        // DOMException.
        // https://xhr.spec.whatwg.org/#dom-xmlhttprequest-timeout
    }

    pub fn get_withCredentials(self: *XMLHttpRequest) bool {
        return self.withCredentials;
    }

    pub fn set_withCredentials(self: *XMLHttpRequest, withCredentials: bool) !void {
        if (self.state != OPENED and self.state != UNSENT) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        self.withCredentials = withCredentials;
    }

    pub fn _open(
        self: *XMLHttpRequest,
        alloc: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        asyn: ?bool,
        username: ?[]const u8,
        password: ?[]const u8,
    ) !void {
        _ = username;
        _ = password;

        // TODO If this’s relevant global object is a Window object and its
        // associated Document is not fully active, then throw an
        // "InvalidStateError" DOMException.

        self.method = try validMethod(method);

        self.reset(alloc);

        self.url = try alloc.dupe(u8, url);
        self.uri = std.Uri.parse(self.url.?) catch return DOMError.Syntax;
        self.sync = if (asyn) |b| !b else false;

        self.state = OPENED;
        self.dispatchEvt("readystatechange");
    }

    // dispatch request event.
    // errors are logged only.
    fn dispatchEvt(self: *XMLHttpRequest, typ: []const u8) void {
        const evt = parser.eventCreate() catch |e| {
            return log.err("dispatch event create: {any}", .{e});
        };

        // We can we defer event destroy once the event is dispatched.
        defer parser.eventDestroy(evt);

        parser.eventInit(evt, typ, .{ .bubbles = true, .cancelable = true }) catch |e| {
            return log.err("dispatch event init: {any}", .{e});
        };
        _ = parser.eventTargetDispatchEvent(@as(*parser.EventTarget, @ptrCast(self)), evt) catch |e| {
            return log.err("dispatch event: {any}", .{e});
        };
    }

    fn dispatchProgressEvent(
        self: *XMLHttpRequest,
        typ: []const u8,
        opts: ProgressEvent.EventInit,
    ) void {
        log.debug("dispatch progress event: {s}", .{typ});
        var evt = ProgressEvent.constructor(typ, .{
            // https://xhr.spec.whatwg.org/#firing-events-using-the-progressevent-interface
            .lengthComputable = opts.total > 0,
            .total = opts.total,
            .loaded = opts.loaded,
        }) catch |e| {
            return log.err("construct progress event: {any}", .{e});
        };

        _ = parser.eventTargetDispatchEvent(
            @as(*parser.EventTarget, @ptrCast(self)),
            @as(*parser.Event, @ptrCast(&evt)),
        ) catch |e| {
            return log.err("dispatch progress event: {any}", .{e});
        };
    }

    const methods = [_]struct {
        tag: std.http.Method,
        name: []const u8,
    }{
        .{ .tag = .DELETE, .name = "DELETE" },
        .{ .tag = .GET, .name = "GET" },
        .{ .tag = .HEAD, .name = "HEAD" },
        .{ .tag = .OPTIONS, .name = "OPTIONS" },
        .{ .tag = .POST, .name = "POST" },
        .{ .tag = .PUT, .name = "PUT" },
    };
    const methods_forbidden = [_][]const u8{ "CONNECT", "TRACE", "TRACK" };

    pub fn validMethod(m: []const u8) DOMError!std.http.Method {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(method.name, m)) {
                return method.tag;
            }
        }
        // If method is a forbidden method, then throw a "SecurityError" DOMException.
        for (methods_forbidden) |method| {
            if (std.ascii.eqlIgnoreCase(method, m)) {
                return DOMError.Security;
            }
        }

        // If method is not a method, then throw a "SyntaxError" DOMException.
        return DOMError.Syntax;
    }

    pub fn _setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8) !void {
        if (self.state != OPENED) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;
        return try self.headers.append(name, value);
    }

    // TODO body can be either a XMLHttpRequestBodyInit or a document
    pub fn _send(self: *XMLHttpRequest, alloc: std.mem.Allocator, body: ?[]const u8) !void {
        if (self.state != OPENED) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        //  The body argument provides the request body, if any, and is ignored
        //  if the request method is GET or HEAD.
        //  https://xhr.spec.whatwg.org/#the-send()-method
        // var used_body: ?XMLHttpRequestBodyInit = null;
        if (body != null and self.method != .GET and self.method != .HEAD) {
            // TODO If body is a Document, then set this’s request body to body, serialized, converted, and UTF-8 encoded.

            const body_init = XMLHttpRequestBodyInit{ .String = body.? };

            // keep the user content type from request headers.
            if (self.headers.has("Content-Type")) {
                // https://fetch.spec.whatwg.org/#bodyinit-safely-extract
                try self.headers.append("Content-Type", try body_init.contentType());
            }

            // copy the payload
            if (self.payload) |v| alloc.free(v);
            self.payload = try body_init.dupe(alloc);
        }

        log.debug("{any} {any}", .{ self.method, self.uri });

        self.send_flag = true;

        self.priv_state = .open;

        self.req = try self.cli.create(self.method, self.uri, .{
            .server_header_buffer = &self.response_header_buffer,
            .extra_headers = self.headers.all(),
        });
        errdefer {
            self.req.?.deinit();
            self.req = null;
        }

        self.ctx = try Client.Ctx.init(&self.loop, &self.req.?);
        errdefer {
            self.ctx.?.deinit();
            self.ctx = null;
        }
        self.ctx.?.userData = self;

        try self.cli.async_open(
            self.method,
            self.uri,
            .{ .server_header_buffer = &self.response_header_buffer },
            &self.ctx.?,
            onRequestConnect,
        );
    }

    fn onRequestWait(ctx: *Client.Ctx, res: anyerror!void) !void {
        var self = selfCtx(ctx);
        res catch |err| return self.onErr(err);

        log.info("{any} {any} {d}", .{ self.method, self.uri, self.req.?.response.status });

        self.priv_state = .done;
        var it = self.req.?.response.iterateHeaders();
        self.response_headers.load(&it) catch |e| return self.onErr(e);

        // extract a mime type from headers.
        const ct = self.response_headers.getFirstValue("Content-Type") orelse "text/xml";
        self.response_mime = Mime.parse(ct) catch |e| return self.onErr(e);

        // TODO handle override mime type

        self.state = HEADERS_RECEIVED;
        self.dispatchEvt("readystatechange");

        self.response_status = @intFromEnum(self.req.?.response.status);

        var buf: std.ArrayListUnmanaged(u8) = .{};

        // TODO set correct length
        const total = 0;
        var loaded: u64 = 0;

        // dispatch a progress event loadstart.
        self.dispatchProgressEvent("loadstart", .{ .loaded = loaded, .total = total });

        // TODO read async
        const reader = self.req.?.reader();
        var buffer: [1024]u8 = undefined;
        var ln = buffer.len;
        var prev_dispatch: ?std.time.Instant = null;
        while (ln > 0) {
            ln = reader.read(&buffer) catch |e| {
                buf.deinit(self.alloc);
                return self.onErr(e);
            };
            buf.appendSlice(self.alloc, buffer[0..ln]) catch |e| {
                buf.deinit(self.alloc);
                return self.onErr(e);
            };
            loaded = loaded + ln;

            // Dispatch only if 50ms have passed.
            const now = std.time.Instant.now() catch |e| {
                buf.deinit(self.alloc);
                return self.onErr(e);
            };
            if (prev_dispatch != null and now.since(prev_dispatch.?) < min_delay) continue;
            defer prev_dispatch = now;

            self.state = LOADING;
            self.dispatchEvt("readystatechange");

            // dispatch a progress event progress.
            self.dispatchProgressEvent("progress", .{
                .loaded = loaded,
                .total = total,
            });
        }
        self.response_bytes = buf.items;
        self.send_flag = false;

        self.state = DONE;
        self.dispatchEvt("readystatechange");

        // dispatch a progress event load.
        self.dispatchProgressEvent("load", .{ .loaded = loaded, .total = total });
        // dispatch a progress event loadend.
        self.dispatchProgressEvent("loadend", .{ .loaded = loaded, .total = total });

        if (self.ctx) |*c| c.deinit();
        self.ctx = null;

        if (self.req) |*r| r.deinit();
        self.req = null;
    }

    fn onRequestFinish(ctx: *Client.Ctx, res: anyerror!void) !void {
        var self = selfCtx(ctx);
        res catch |err| return self.onErr(err);

        self.priv_state = .wait;
        return ctx.req.async_wait(ctx, onRequestWait) catch |e| return self.onErr(e);
    }

    fn onRequestSend(ctx: *Client.Ctx, res: anyerror!void) !void {
        var self = selfCtx(ctx);
        res catch |err| return self.onErr(err);

        if (self.payload) |payload| {
            self.priv_state = .write;
            return ctx.req.async_writeAll(payload, ctx, onRequestWrite) catch |e| return self.onErr(e);
        }

        self.priv_state = .finish;
        return ctx.req.async_finish(ctx, onRequestFinish) catch |e| return self.onErr(e);
    }

    fn onRequestWrite(ctx: *Client.Ctx, res: anyerror!void) !void {
        var self = selfCtx(ctx);
        res catch |err| return self.onErr(err);
        self.priv_state = .finish;
        return ctx.req.async_finish(ctx, onRequestFinish) catch |e| return self.onErr(e);
    }

    fn onRequestConnect(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var self = selfCtx(ctx);
        res catch |err| return self.onErr(err);

        // prepare payload transfert.
        if (self.payload) |v| self.req.?.transfer_encoding = .{ .content_length = v.len };

        self.priv_state = .send;
        return ctx.req.async_send(ctx, onRequestSend) catch |err| return self.onErr(err);
    }

    fn selfCtx(ctx: *Client.Ctx) *XMLHttpRequest {
        return @ptrCast(@alignCast(ctx.userData));
    }

    fn onErr(self: *XMLHttpRequest, err: anyerror) void {
        self.priv_state = .done;

        self.err = err;
        self.state = DONE;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");
        self.dispatchProgressEvent("error", .{});
        self.dispatchProgressEvent("loadend", .{});

        log.debug("{any} {any} {any}", .{ self.method, self.uri, self.err });

        if (self.ctx) |*c| c.deinit();
        self.ctx = null;

        if (self.req) |*r| r.deinit();
        self.req = null;
    }

    pub fn _abort(self: *XMLHttpRequest) void {
        self.onErr(DOMError.Abort);
    }

    pub fn get_responseType(self: *XMLHttpRequest) []const u8 {
        return switch (self.response_type) {
            .Empty => "",
            .ArrayBuffer => "arraybuffer",
            .Blob => "blob",
            .Document => "document",
            .JSON => "json",
            .Text => "text",
        };
    }

    pub fn set_responseType(self: *XMLHttpRequest, rtype: []const u8) !void {
        if (self.state == LOADING or self.state == DONE) return DOMError.InvalidState;

        if (std.mem.eql(u8, rtype, "")) {
            self.response_type = .Empty;
            return;
        }
        if (std.mem.eql(u8, rtype, "arraybuffer")) {
            self.response_type = .ArrayBuffer;
            return;
        }
        if (std.mem.eql(u8, rtype, "blob")) {
            self.response_type = .Blob;
            return;
        }
        if (std.mem.eql(u8, rtype, "document")) {
            self.response_type = .Document;
            return;
        }
        if (std.mem.eql(u8, rtype, "json")) {
            self.response_type = .JSON;
            return;
        }
        if (std.mem.eql(u8, rtype, "text")) {
            self.response_type = .Text;
            return;
        }
    }

    // TODO retrieve the redirected url
    pub fn get_responseURL(self: *XMLHttpRequest) ?[]const u8 {
        return self.url;
    }

    pub fn get_responseXML(self: *XMLHttpRequest, alloc: std.mem.Allocator) !?Response {
        if (self.response_type != .Empty and self.response_type != .Document) {
            return DOMError.InvalidState;
        }

        if (self.state != DONE) return null;

        // fastpath if response is previously parsed.
        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => null,
            };
        }

        self.setResponseObjDocument(alloc);

        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => null,
            };
        }
        return null;
    }

    // https://xhr.spec.whatwg.org/#the-response-attribute
    pub fn get_response(self: *XMLHttpRequest, alloc: std.mem.Allocator) !?Response {
        if (self.response_type == .Empty or self.response_type == .Text) {
            if (self.state == LOADING or self.state == DONE) return .{ .Text = "" };
            return .{ .Text = try self.get_responseText() };
        }

        // fastpath if response is previously parsed.
        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => |v| .{ .JSON = v.value },
            };
        }

        if (self.response_type == .ArrayBuffer) {
            // TODO If this’s response type is "arraybuffer", then set this’s
            // response object to a new ArrayBuffer object representing this’s
            // received bytes. If this throws an exception, then set this’s
            // response object to failure and return null.
            return null;
        }

        if (self.response_type == .Blob) {
            // TODO Otherwise, if this’s response type is "blob", set this’s
            // response object to a new Blob object representing this’s
            // received bytes with type set to the result of get a final MIME
            // type for this.
            return null;
        }

        // Otherwise, if this’s response type is "document", set a
        // document response for this.
        if (self.response_type == .Document) {
            self.setResponseObjDocument(alloc);
        }

        if (self.response_type == .JSON) {
            if (self.response_bytes == null) return null;

            // TODO Let jsonObject be the result of running parse JSON from bytes
            // on this’s received bytes. If that threw an exception, then return
            // null.
            self.setResponseObjJSON(alloc);
        }

        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => |v| .{ .JSON = v.value },
            };
        }

        return null;
    }

    // setResponseObjDocument parses the received bytes as HTML document and
    // stores the result into response_obj.
    // If the par sing fails, a Failure is stored in response_obj.
    // TODO parse XML.
    // https://xhr.spec.whatwg.org/#response-object
    fn setResponseObjDocument(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        const isHTML = self.response_mime.eql(Mime.HTML);

        // TODO If finalMIME is not an HTML MIME type or an XML MIME type, then
        // return.
        if (!isHTML) return;

        const ccharset = alloc.dupeZ(u8, self.response_mime.charset orelse "utf-8") catch {
            self.response_obj = .{ .Failure = true };
            return;
        };
        defer alloc.free(ccharset);

        var fbs = std.io.fixedBufferStream(self.response_bytes.?);
        const doc = parser.documentHTMLParse(fbs.reader(), ccharset) catch {
            self.response_obj = .{ .Failure = true };
            return;
        };

        // TODO Set document’s URL to xhr’s response’s URL.
        // TODO Set document’s origin to xhr’s relevant settings object’s origin.

        self.response_obj = .{
            .Document = parser.documentHTMLToDocument(doc),
        };
    }

    // setResponseObjJSON parses the received bytes as a std.json.Value.
    fn setResponseObjJSON(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        // TODO should we use parseFromSliceLeaky if we expect the allocator is
        // already an arena?
        const p = std.json.parseFromSlice(
            JSONValue,
            alloc,
            self.response_bytes.?,
            .{},
        ) catch |e| {
            log.err("parse JSON: {}", .{e});
            self.response_obj = .{ .Failure = true };
            return;
        };

        self.response_obj = .{ .JSON = p };
    }

    pub fn get_responseText(self: *XMLHttpRequest) ![]const u8 {
        if (self.response_type != .Empty and self.response_type != .Text) return DOMError.InvalidState;

        return if (self.response_bytes) |v| v else "";
    }

    pub fn _getResponseHeader(self: *XMLHttpRequest, name: []const u8) ?[]const u8 {
        return self.response_headers.getFirstValue(name);
    }

    // The caller owns the string returned.
    // TODO change the return type to express the string ownership and let
    // jsruntime free the string once copied to v8.
    // see https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn _getAllResponseHeaders(self: *XMLHttpRequest, alloc: std.mem.Allocator) ![]const u8 {
        if (self.response_headers.list.items.len == 0) return "";
        self.response_headers.sort();

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(alloc);

        const w = buf.writer(alloc);

        for (self.response_headers.list.items) |entry| {
            if (entry.value.len == 0) continue;

            try w.writeAll(entry.name);
            try w.writeAll(": ");
            try w.writeAll(entry.value);
            try w.writeAll("\r\n");
        }

        return buf.items;
    }

    pub fn get_status(self: *XMLHttpRequest) u16 {
        return self.response_status;
    }

    pub fn get_statusText(self: *XMLHttpRequest) []const u8 {
        if (self.response_status == 0) return "";

        return std.http.Status.phrase(@enumFromInt(self.response_status)) orelse "";
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var send = [_]Case{
        .{ .src = "var nb = 0; var evt = null; function cbk(event) { nb ++; evt = event; }", .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest()", .ex = "undefined" },

        .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; evt = event; }" },
        // Getter returning a callback crashes.
        // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/200
        // .{ .src = "req.onload", .ex = "function cbk(event) { nb ++; evt = event; }" },
        //.{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; evt = event; }" },

        .{ .src = "req.open('GET', 'https://httpbin.io/html')", .ex = "undefined" },
        .{ .src = "req.setRequestHeader('User-Agent', 'lightpanda/1.0')", .ex = "undefined" },

        // ensure open resets values
        .{ .src = "req.status", .ex = "0" },
        .{ .src = "req.statusText", .ex = "" },
        .{ .src = "req.getAllResponseHeaders()", .ex = "" },
        .{ .src = "req.getResponseHeader('Content-Type')", .ex = "null" },
        .{ .src = "req.responseText", .ex = "" },

        .{ .src = "req.send(); nb", .ex = "0" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt.type", .ex = "load" },
        .{ .src = "evt.loaded > 0", .ex = "true" },
        .{ .src = "evt instanceof ProgressEvent", .ex = "true" },
        .{ .src = "req.status", .ex = "200" },
        .{ .src = "req.statusText", .ex = "OK" },
        .{ .src = "req.getResponseHeader('Content-Type')", .ex = "text/html; charset=utf-8" },
        .{ .src = "req.getAllResponseHeaders().length > 64", .ex = "true" },
        .{ .src = "req.responseText.length > 64", .ex = "true" },
        .{ .src = "req.response", .ex = "" },
        .{ .src = "req.responseXML instanceof Document", .ex = "true" },
    };
    try checkCases(js_env, &send);

    var document = [_]Case{
        .{ .src = "const req2 = new XMLHttpRequest()", .ex = "undefined" },
        .{ .src = "req2.open('GET', 'https://httpbin.io/html')", .ex = "undefined" },
        .{ .src = "req2.responseType = 'document'", .ex = "document" },

        .{ .src = "req2.send()", .ex = "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "req2.status", .ex = "200" },
        .{ .src = "req2.statusText", .ex = "OK" },
        .{ .src = "req2.response instanceof Document", .ex = "true" },
        .{ .src = "req2.responseXML instanceof Document", .ex = "true" },
    };
    try checkCases(js_env, &document);

    var json = [_]Case{
        .{ .src = "const req3 = new XMLHttpRequest()", .ex = "undefined" },
        .{ .src = "req3.open('GET', 'https://httpbin.io/json')", .ex = "undefined" },
        .{ .src = "req3.responseType = 'json'", .ex = "json" },

        .{ .src = "req3.send()", .ex = "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "req3.status", .ex = "200" },
        .{ .src = "req3.statusText", .ex = "OK" },
        .{ .src = "req3.response.slideshow.author", .ex = "Yours Truly" },
    };
    try checkCases(js_env, &json);

    var post = [_]Case{
        .{ .src = "const req4 = new XMLHttpRequest()", .ex = "undefined" },
        .{ .src = "req4.open('POST', 'https://httpbin.io/post')", .ex = "undefined" },
        .{ .src = "req4.send('foo')", .ex = "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "req4.status", .ex = "200" },
        .{ .src = "req4.statusText", .ex = "OK" },
        .{ .src = "req4.responseText.length > 64", .ex = "true" },
    };
    try checkCases(js_env, &post);

    var cbk = [_]Case{
        .{ .src = "const req5 = new XMLHttpRequest()", .ex = "undefined" },
        .{ .src = "req5.open('GET', 'https://httpbin.io/json')", .ex = "undefined" },
        .{ .src = "var status = 0; req5.onload = function () { status = this.status };", .ex = "function () { status = this.status }" },
        .{ .src = "req5.send()", .ex = "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "status", .ex = "200" },
    };
    try checkCases(js_env, &cbk);
}

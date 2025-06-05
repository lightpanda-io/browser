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
const Allocator = std.mem.Allocator;

const DOMError = @import("../netsurf.zig").DOMError;

const ProgressEvent = @import("progress_event.zig").ProgressEvent;
const XMLHttpRequestEventTarget = @import("event_target.zig").XMLHttpRequestEventTarget;

const log = @import("../../log.zig");
const URL = @import("../../url.zig").URL;
const Mime = @import("../mime.zig").Mime;
const parser = @import("../netsurf.zig");
const http = @import("../../http/client.zig");
const Page = @import("../page.zig").Page;
const Loop = @import("../../runtime/loop.zig").Loop;
const CookieJar = @import("../storage/storage.zig").CookieJar;

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = .{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
    XMLHttpRequest,
};

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
};

const XMLHttpRequestBodyInit = union(enum) {
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
    fn dupe(self: XMLHttpRequestBodyInit, alloc: Allocator) ![]const u8 {
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
    loop: *Loop,
    arena: Allocator,
    request: ?*http.Request = null,

    method: http.Request.Method,
    state: State,
    url: ?URL = null,
    origin_url: *const URL,

    // request headers
    headers: Headers,
    sync: bool = true,
    err: ?anyerror = null,
    last_dispatch: i64 = 0,
    request_body: ?[]const u8 = null,

    cookie_jar: *CookieJar,
    // the URI of the page where this request is originating from

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
    response_bytes: std.ArrayListUnmanaged(u8) = .{},
    response_type: ResponseType = .Empty,
    response_headers: Headers,

    response_status: u16 = 0,

    // TODO uncomment this field causes casting issue with
    // XMLHttpRequestEventTarget. I think it's dueto an alignement issue, but
    // not sure. see
    // https://lightpanda.slack.com/archives/C05TRU6RBM1/p1707819010681019
    // response_override_mime_type: ?[]const u8 = null,

    response_mime: ?Mime = null,
    response_obj: ?ResponseObj = null,
    send_flag: bool = false,

    pub const prototype = *XMLHttpRequestEventTarget;

    const State = enum(u16) {
        unsent = 0,
        opened = 1,
        headers_received = 2,
        loading = 3,
        done = 4,
    };

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
        list: List,
        arena: Allocator,

        const List = std.ArrayListUnmanaged(std.http.Header);

        fn init(arena: Allocator) Headers {
            return .{
                .arena = arena,
                .list = .{},
            };
        }

        fn append(self: *Headers, k: []const u8, v: []const u8) !void {
            // duplicate strings
            const kk = try self.arena.dupe(u8, k);
            const vv = try self.arena.dupe(u8, v);
            try self.list.append(self.arena, .{ .name = kk, .value = vv });
        }

        fn reset(self: *Headers) void {
            self.list.clearRetainingCapacity();
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
                    _ = self.list.swapRemove(i);
                }
            }
            self.append(k, v);
        }

        // TODO
        fn sort(_: *Headers) void {}

        fn all(self: Headers) []std.http.Header {
            return self.list.items;
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

    const ResponseObj = union(enum) {
        Document: *parser.Document,
        Failure: void,
        JSON: JSONValue,

        fn deinit(self: ResponseObj) void {
            switch (self) {
                .JSON, .Failure => {},
                .Document => |d| {
                    const doc = @as(*parser.DocumentHTML, @ptrCast(d));
                    parser.documentHTMLClose(doc) catch {};
                },
            }
        }
    };

    const PrivState = enum { new, open, send, write, finish, wait, done };

    const min_delay: u64 = 50000000; // 50ms

    pub fn constructor(page: *Page) !XMLHttpRequest {
        const arena = page.arena;
        return .{
            .url = null,
            .arena = arena,
            .loop = page.loop,
            .headers = Headers.init(arena),
            .response_headers = Headers.init(arena),
            .method = undefined,
            .state = .unsent,
            .origin_url = &page.url,
            .cookie_jar = page.cookie_jar,
        };
    }

    pub fn destructor(self: *XMLHttpRequest) void {
        if (self.request) |req| {
            req.abort();
            self.request = null;
        }
    }

    pub fn reset(self: *XMLHttpRequest) void {
        self.url = null;

        if (self.response_obj) |v| {
            v.deinit();
        }

        self.response_obj = null;
        self.response_type = .Empty;
        self.response_mime = null;

        // TODO should we clearRetainingCapacity instead?
        self.headers.reset();
        self.response_headers.reset();
        self.response_status = 0;

        self.send_flag = false;
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return @intFromEnum(self.state);
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
        if (self.state != .opened and self.state != .unsent) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        self.withCredentials = withCredentials;
    }

    pub fn _open(
        self: *XMLHttpRequest,
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
        self.reset();

        self.method = try validMethod(method);
        const arena = self.arena;

        self.url = try self.origin_url.resolve(arena, url);
        self.sync = if (asyn) |b| !b else false;

        self.state = .opened;
        self.dispatchEvt("readystatechange");
    }

    // dispatch request event.
    // errors are logged only.
    fn dispatchEvt(self: *XMLHttpRequest, typ: []const u8) void {
        log.debug(.script_event, "dispatch event", .{ .type = typ, .source = "xhr" });
        self._dispatchEvt(typ) catch |err| {
            log.err(.app, "dispatch event error", .{ .err = err, .type = typ, .source = "xhr" });
        };
    }

    fn _dispatchEvt(self: *XMLHttpRequest, typ: []const u8) !void {
        const evt = try parser.eventCreate();
        // We can we defer event destroy once the event is dispatched.
        defer parser.eventDestroy(evt);

        try parser.eventInit(evt, typ, .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(@as(*parser.EventTarget, @ptrCast(self)), evt);
    }

    fn dispatchProgressEvent(
        self: *XMLHttpRequest,
        typ: []const u8,
        opts: ProgressEvent.EventInit,
    ) void {
        log.debug(.script_event, "dispatch progress event", .{ .type = typ, .source = "xhr" });
        self._dispatchProgressEvent(typ, opts) catch |err| {
            log.err(.app, "dispatch progress event error", .{ .err = err, .type = typ, .source = "xhr" });
        };
    }

    fn _dispatchProgressEvent(
        self: *XMLHttpRequest,
        typ: []const u8,
        opts: ProgressEvent.EventInit,
    ) !void {
        var evt = try ProgressEvent.constructor(typ, .{
            // https://xhr.spec.whatwg.org/#firing-events-using-the-progressevent-interface
            .lengthComputable = opts.total > 0,
            .total = opts.total,
            .loaded = opts.loaded,
        });

        _ = try parser.eventTargetDispatchEvent(
            @as(*parser.EventTarget, @ptrCast(self)),
            @as(*parser.Event, @ptrCast(&evt)),
        );
    }

    const methods = [_]struct {
        tag: http.Request.Method,
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

    pub fn validMethod(m: []const u8) DOMError!http.Request.Method {
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
        if (self.state != .opened) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;
        return try self.headers.append(name, value);
    }

    // TODO body can be either a XMLHttpRequestBodyInit or a document
    pub fn _send(self: *XMLHttpRequest, body: ?[]const u8, page: *Page) !void {
        if (self.state != .opened) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        log.debug(.http, "request", .{ .method = self.method, .url = self.url, .source = "xhr" });

        self.send_flag = true;
        if (body) |b| {
            self.request_body = try self.arena.dupe(u8, b);
        }

        try page.request_factory.initAsync(
            page.arena,
            self.method,
            &self.url.?.uri,
            self,
            onHttpRequestReady,
            self.loop,
        );
    }

    fn onHttpRequestReady(ctx: *anyopaque, request: *http.Request) !void {
        // on error, our caller will cleanup request
        const self: *XMLHttpRequest = @alignCast(@ptrCast(ctx));

        for (self.headers.list.items) |hdr| {
            try request.addHeader(hdr.name, hdr.value, .{});
        }

        {
            var arr: std.ArrayListUnmanaged(u8) = .{};
            try self.cookie_jar.forRequest(&self.url.?.uri, arr.writer(self.arena), .{
                .navigation = false,
                .origin_uri = &self.origin_url.uri,
            });

            if (arr.items.len > 0) {
                try request.addHeader("Cookie", arr.items, .{});
            }
        }

        //  The body argument provides the request body, if any, and is ignored
        //  if the request method is GET or HEAD.
        //  https://xhr.spec.whatwg.org/#the-send()-method
        // var used_body: ?XMLHttpRequestBodyInit = null;
        if (self.request_body) |b| {
            if (self.method != .GET and self.method != .HEAD) {
                request.body = b;
                try request.addHeader("Content-Type", "text/plain; charset=UTF-8", .{});
            }
        }

        try request.sendAsync(self.loop, self, .{});
        self.request = request;
    }

    pub fn onHttpResponse(self: *XMLHttpRequest, progress_: anyerror!http.Progress) !void {
        const progress = progress_ catch |err| {
            // The request has been closed internally by the client, it isn't safe
            // for us to keep it around.
            self.request = null;
            self.onErr(err);
            return err;
        };

        if (progress.first) {
            const header = progress.header;

            log.debug(.http, "request header", .{
                .source = "xhr",
                .url = self.url,
                .status = header.status,
            });
            for (header.headers.items) |hdr| {
                try self.response_headers.append(hdr.name, hdr.value);
            }

            // extract a mime type from headers.
            if (header.get("content-type")) |ct| {
                self.response_mime = Mime.parse(self.arena, ct) catch |e| {
                    return self.onErr(e);
                };
            }

            // TODO handle override mime type
            self.state = .headers_received;
            self.dispatchEvt("readystatechange");

            self.response_status = header.status;

            // TODO correct total
            self.dispatchProgressEvent("loadstart", .{ .loaded = 0, .total = 0 });

            self.state = .loading;
            self.dispatchEvt("readystatechange");

            try self.cookie_jar.populateFromResponse(self.request.?.request_uri, &header);
        }

        if (progress.data) |data| {
            try self.response_bytes.appendSlice(self.arena, data);
        }

        const loaded = self.response_bytes.items.len;
        const now = std.time.milliTimestamp();
        if (now - self.last_dispatch > 50) {
            // don't send this more than once every 50ms
            self.dispatchProgressEvent("progress", .{
                .total = loaded,
                .loaded = loaded,
            });
            self.last_dispatch = now;
        }

        if (progress.done == false) {
            return;
        }

        log.info(.http, "request complete", .{
            .source = "xhr",
            .url = self.url,
            .status = self.response_status,
        });

        // Not that the request is done, the http/client will free the request
        // object. It isn't safe to keep it around.
        self.request = null;

        self.state = .done;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");

        // dispatch a progress event load.
        self.dispatchProgressEvent("load", .{ .loaded = loaded, .total = loaded });
        // dispatch a progress event loadend.
        self.dispatchProgressEvent("loadend", .{ .loaded = loaded, .total = loaded });
    }

    fn onErr(self: *XMLHttpRequest, err: anyerror) void {
        self.state = .done;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");
        self.dispatchProgressEvent("error", .{});
        self.dispatchProgressEvent("loadend", .{});

        const level: log.Level = if (err == DOMError.Abort) .debug else .err;
        log.log(.http, level, "error", .{
            .url = self.url,
            .err = err,
            .source = "xhr",
        });
    }

    pub fn _abort(self: *XMLHttpRequest) void {
        self.onErr(DOMError.Abort);
        self.destructor();
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
        if (self.state == .loading or self.state == .done) return DOMError.InvalidState;

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
        const url = &(self.url orelse return null);
        return url.raw;
    }

    pub fn get_responseXML(self: *XMLHttpRequest) !?Response {
        if (self.response_type != .Empty and self.response_type != .Document) {
            return DOMError.InvalidState;
        }

        if (self.state != .done) return null;

        // fastpath if response is previously parsed.
        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => null,
            };
        }

        self.setResponseObjDocument();

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
    pub fn get_response(self: *XMLHttpRequest) !?Response {
        if (self.response_type == .Empty or self.response_type == .Text) {
            if (self.state == .loading or self.state == .done) {
                return .{ .Text = try self.get_responseText() };
            }
            return .{ .Text = "" };
        }

        // fastpath if response is previously parsed.
        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => |v| .{ .JSON = v },
            };
        }

        if (self.response_type == .ArrayBuffer) {
            // TODO If this’s response type is "arraybuffer", then set this’s
            // response object to a new ArrayBuffer object representing this’s
            // received bytes. If this throws an exception, then set this’s
            // response object to failure and return null.
            log.err(.web_api, "not implemented", .{ .feature = "XHR ArrayBuffer resposne type" });
            return null;
        }

        if (self.response_type == .Blob) {
            // TODO Otherwise, if this’s response type is "blob", set this’s
            // response object to a new Blob object representing this’s
            // received bytes with type set to the result of get a final MIME
            // type for this.
            log.err(.web_api, "not implemented", .{ .feature = "XHR Blob resposne type" });
            return null;
        }

        // Otherwise, if this’s response type is "document", set a
        // document response for this.
        if (self.response_type == .Document) {
            self.setResponseObjDocument();
        }

        if (self.response_type == .JSON) {
            if (self.response_bytes.items.len == 0) return null;

            // TODO Let jsonObject be the result of running parse JSON from bytes
            // on this’s received bytes. If that threw an exception, then return
            // null.
            self.setResponseObjJSON();
        }

        if (self.response_obj) |obj| {
            return switch (obj) {
                .Failure => null,
                .Document => |v| .{ .Document = v },
                .JSON => |v| .{ .JSON = v },
            };
        }

        return null;
    }

    // setResponseObjDocument parses the received bytes as HTML document and
    // stores the result into response_obj.
    // If the par sing fails, a Failure is stored in response_obj.
    // TODO parse XML.
    // https://xhr.spec.whatwg.org/#response-object
    fn setResponseObjDocument(self: *XMLHttpRequest) void {
        const mime = self.response_mime orelse return;
        if (mime.isHTML() == false) {
            return;
        }

        var ccharset: [:0]const u8 = "utf-8";
        if (mime.charset) |rc| {
            if (std.mem.eql(u8, rc, "utf-8") == false) {
                ccharset = self.arena.dupeZ(u8, rc) catch {
                    self.response_obj = .{ .Failure = {} };
                    return;
                };
            }
        }

        var fbs = std.io.fixedBufferStream(self.response_bytes.items);
        const doc = parser.documentHTMLParse(fbs.reader(), ccharset) catch {
            self.response_obj = .{ .Failure = {} };
            return;
        };

        // TODO Set document’s URL to xhr’s response’s URL.
        // TODO Set document’s origin to xhr’s relevant settings object’s origin.

        self.response_obj = .{
            .Document = parser.documentHTMLToDocument(doc),
        };
    }

    // setResponseObjJSON parses the received bytes as a std.json.Value.
    fn setResponseObjJSON(self: *XMLHttpRequest) void {
        // TODO should we use parseFromSliceLeaky if we expect the allocator is
        // already an arena?
        const p = std.json.parseFromSliceLeaky(
            JSONValue,
            self.arena,
            self.response_bytes.items,
            .{},
        ) catch |e| {
            log.warn(.http, "invalid json", .{ .err = e, .url = self.url, .source = "xhr" });
            self.response_obj = .{ .Failure = {} };
            return;
        };

        self.response_obj = .{ .JSON = p };
    }

    pub fn get_responseText(self: *XMLHttpRequest) ![]const u8 {
        if (self.response_type != .Empty and self.response_type != .Text) return DOMError.InvalidState;
        return self.response_bytes.items;
    }

    pub fn _getResponseHeader(self: *XMLHttpRequest, name: []const u8) ?[]const u8 {
        return self.response_headers.getFirstValue(name);
    }

    // The caller owns the string returned.
    // TODO change the return type to express the string ownership and let
    // jsruntime free the string once copied to v8.
    // see https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn _getAllResponseHeaders(self: *XMLHttpRequest) ![]const u8 {
        if (self.response_headers.list.items.len == 0) return "";
        self.response_headers.sort();

        var buf: std.ArrayListUnmanaged(u8) = .{};
        const w = buf.writer(self.arena);

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

const testing = @import("../../testing.zig");
test "Browser.XHR.XMLHttpRequest" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "var nb = 0; var evt = null; function cbk(event) { nb ++; evt = event; }", "undefined" },
        .{ "const req = new XMLHttpRequest()", "undefined" },

        .{ "req.onload = cbk", "function cbk(event) { nb ++; evt = event; }" },

        .{ "req.onload", "function cbk(event) { nb ++; evt = event; }" },
        .{ "req.onload = cbk", "function cbk(event) { nb ++; evt = event; }" },

        .{ "req.open('GET', 'https://127.0.0.1:9581/xhr')", "undefined" },
        .{ "req.setRequestHeader('User-Agent', 'lightpanda/1.0')", "undefined" },

        // ensure open resets values
        .{ "req.status  ", "0" },
        .{ "req.statusText", "" },
        .{ "req.getAllResponseHeaders()", "" },
        .{ "req.getResponseHeader('Content-Type')", "null" },
        .{ "req.responseText", "" },

        .{ "req.send(); nb", "0" },

        // Each case executed waits for all loop callback calls.
        // So the url has been retrieved.
        .{ "nb", "1" },
        .{ "evt.type", "load" },
        .{ "evt.loaded > 0", "true" },
        .{ "evt instanceof ProgressEvent", "true" },
        .{ "req.status", "200" },
        .{ "req.statusText", "OK" },
        .{ "req.getResponseHeader('Content-Type')", "text/html; charset=utf-8" },
        .{ "req.getAllResponseHeaders().length", "80" },
        .{ "req.responseText.length", "100" },
        .{ "req.response.length == req.responseText.length", "true" },
        .{ "req.responseXML instanceof Document", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "const req2 = new XMLHttpRequest()", "undefined" },
        .{ "req2.open('GET', 'https://127.0.0.1:9581/xhr')", "undefined" },
        .{ "req2.responseType = 'document'", "document" },

        .{ "req2.send()", "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ "req2.status", "200" },
        .{ "req2.statusText", "OK" },
        .{ "req2.response instanceof Document", "true" },
        .{ "req2.responseXML instanceof Document", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "const req3 = new XMLHttpRequest()", "undefined" },
        .{ "req3.open('GET', 'https://127.0.0.1:9581/xhr/json')", "undefined" },
        .{ "req3.responseType = 'json'", "json" },

        .{ "req3.send()", "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ "req3.status", "200" },
        .{ "req3.statusText", "OK" },
        .{ "req3.response.over", "9000!!!" },
    }, .{});

    try runner.testCases(&.{
        .{ "const req4 = new XMLHttpRequest()", "undefined" },
        .{ "req4.open('POST', 'https://127.0.0.1:9581/xhr')", "undefined" },
        .{ "req4.send('foo')", "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ "req4.status", "200" },
        .{ "req4.statusText", "OK" },
        .{ "req4.responseText.length > 64", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "const req5 = new XMLHttpRequest()", "undefined" },
        .{ "req5.open('GET', 'https://127.0.0.1:9581/xhr')", "undefined" },
        .{ "var status = 0; req5.onload = function () { status = this.status };", "function () { status = this.status }" },
        .{ "req5.send()", "undefined" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ "status", "200" },
    }, .{});
}

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
const Page = @import("../page.zig").Page;
const Http = @import("../../http/Http.zig");
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
    arena: Allocator,
    transfer: ?*Http.Transfer = null,
    err: ?anyerror = null,
    last_dispatch: i64 = 0,
    send_flag: bool = false,

    method: Http.Method,
    state: State,
    url: ?[:0]const u8 = null,

    sync: bool = true,
    withCredentials: bool = false,
    headers: std.ArrayListUnmanaged([:0]const u8),
    request_body: ?[]const u8 = null,

    response_status: u16 = 0,
    response_bytes: std.ArrayListUnmanaged(u8) = .{},
    response_type: ResponseType = .Empty,
    response_headers: std.ArrayListUnmanaged([]const u8) = .{},

    response_mime: ?Mime = null,
    response_obj: ?ResponseObj = null,

    pub const prototype = *XMLHttpRequestEventTarget;

    const State = enum(u16) {
        unsent = 0,
        opened = 1,
        headers_received = 2,
        loading = 3,
        done = 4,
    };

    // class attributes
    pub const _UNSENT = @intFromEnum(State.unsent);
    pub const _OPENED = @intFromEnum(State.opened);
    pub const _HEADERS_RECEIVED = @intFromEnum(State.headers_received);
    pub const _LOADING = @intFromEnum(State.loading);
    pub const _DONE = @intFromEnum(State.done);

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
            .headers = .{},
            .method = undefined,
            .state = .unsent,
        };
    }

    pub fn destructor(self: *XMLHttpRequest) void {
        if (self.transfer) |transfer| {
            transfer.abort();
            self.transfer = null;
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

        self.headers.clearRetainingCapacity();
        self.response_headers.clearRetainingCapacity();
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
        page: *Page,
    ) !void {
        _ = username;
        _ = password;

        // TODO If this’s relevant global object is a Window object and its
        // associated Document is not fully active, then throw an
        // "InvalidStateError" DOMException.
        self.reset();

        self.method = try validMethod(method);
        self.url = try URL.stitch(page.arena, url, page.url.raw, .{ .null_terminated = true });
        self.sync = if (asyn) |b| !b else false;

        self.state = .opened;
        self.dispatchEvt("readystatechange");
    }

    // dispatch request event.
    // errors are logged only.
    fn dispatchEvt(self: *XMLHttpRequest, typ: []const u8) void {
        log.debug(.script_event, "dispatch event", .{
            .type = typ,
            .source = "xhr",
            .method = self.method,
            .url = self.url,
        });
        self._dispatchEvt(typ) catch |err| {
            log.err(.app, "dispatch event error", .{
                .err = err,
                .type = typ,
                .source = "xhr",
                .method = self.method,
                .url = self.url,
            });
        };
    }

    fn _dispatchEvt(self: *XMLHttpRequest, typ: []const u8) !void {
        const evt = try parser.eventCreate();
        // We can we defer event destroy once the event is dispatched.
        defer parser.eventDestroy(evt);

        try parser.eventSetInternalType(evt, .xhr_event);

        try parser.eventInit(evt, typ, .{ .bubbles = true, .cancelable = true });
        _ = try parser.eventTargetDispatchEvent(@as(*parser.EventTarget, @ptrCast(self)), evt);
    }

    fn dispatchProgressEvent(
        self: *XMLHttpRequest,
        typ: []const u8,
        opts: ProgressEvent.EventInit,
    ) void {
        log.debug(.script_event, "dispatch progress event", .{
            .type = typ,
            .source = "xhr",
            .method = self.method,
            .url = self.url,
        });
        self._dispatchProgressEvent(typ, opts) catch |err| {
            log.err(.app, "dispatch progress event error", .{
                .err = err,
                .type = typ,
                .source = "xhr",
                .method = self.method,
                .url = self.url,
            });
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
        tag: Http.Method,
        name: []const u8,
    }{
        .{ .tag = .DELETE, .name = "DELETE" },
        .{ .tag = .GET, .name = "GET" },
        .{ .tag = .HEAD, .name = "HEAD" },
        .{ .tag = .OPTIONS, .name = "OPTIONS" },
        .{ .tag = .POST, .name = "POST" },
        .{ .tag = .PUT, .name = "PUT" },
    };
    pub fn validMethod(m: []const u8) DOMError!Http.Method {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(method.name, m)) {
                return method.tag;
            }
        }

        // If method is not a method, then throw a "SyntaxError" DOMException.
        return DOMError.Syntax;
    }

    pub fn _setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8) !void {
        if (self.state != .opened) {
            return DOMError.InvalidState;
        }

        if (self.send_flag) {
            return DOMError.InvalidState;
        }

        return self.headers.append(
            self.arena,
            try std.fmt.allocPrintSentinel(self.arena, "{s}: {s}", .{ name, value }, 0),
        );
    }

    // TODO body can be either a XMLHttpRequestBodyInit or a document
    pub fn _send(self: *XMLHttpRequest, body: ?[]const u8, page: *Page) !void {
        if (self.state != .opened) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        log.debug(.http, "request queued", .{ .method = self.method, .url = self.url, .source = "xhr" });

        self.send_flag = true;
        if (body) |b| {
            if (self.method != .GET and self.method != .HEAD) {
                self.request_body = try self.arena.dupe(u8, b);
            }
        }

        var headers = try Http.Headers.init();
        for (self.headers.items) |hdr| {
            try headers.add(hdr);
        }
        try page.requestCookie(.{}).headersForRequest(self.arena, self.url.?, &headers);

        try page.http_client.request(.{
            .ctx = self,
            .url = self.url.?,
            .method = self.method,
            .headers = headers,
            .body = self.request_body,
            .cookie_jar = page.cookie_jar,
            .resource_type = .xhr,
            .start_callback = httpStartCallback,
            .header_callback = httpHeaderDoneCallback,
            .data_callback = httpDataCallback,
            .done_callback = httpDoneCallback,
            .error_callback = httpErrorCallback,
        });
    }

    fn httpStartCallback(transfer: *Http.Transfer) !void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
        log.debug(.http, "request start", .{ .method = self.method, .url = self.url, .source = "xhr" });
        self.transfer = transfer;
    }

    fn httpHeaderCallback(transfer: *Http.Transfer, header: Http.Header) !void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
        const joined = try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ header.name, header.value });
        try self.response_headers.append(self.arena, joined);
    }

    fn httpHeaderDoneCallback(transfer: *Http.Transfer) !void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));

        const header = &transfer.response_header.?;

        log.debug(.http, "request header", .{
            .source = "xhr",
            .url = self.url,
            .status = header.status,
        });

        if (header.contentType()) |ct| {
            self.response_mime = Mime.parse(ct) catch |e| {
                return self.onErr(e);
            };
        }

        var it = transfer.responseHeaderIterator();
        while (it.next()) |hdr| {
            const joined = try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ hdr.name, hdr.value });
            try self.response_headers.append(self.arena, joined);
        }

        // TODO handle override mime type
        self.state = .headers_received;
        self.dispatchEvt("readystatechange");

        self.response_status = header.status;

        // TODO correct total
        self.dispatchProgressEvent("loadstart", .{ .loaded = 0, .total = 0 });

        self.state = .loading;
        self.dispatchEvt("readystatechange");

        if (transfer.getContentLength()) |cl| {
            try self.response_bytes.ensureTotalCapacity(self.arena, cl);
        }
    }

    fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
        try self.response_bytes.appendSlice(self.arena, data);

        const now = std.time.milliTimestamp();
        if (now - self.last_dispatch < 50) {
            // don't send this more than once every 50ms
            return;
        }

        const loaded = self.response_bytes.items.len;
        self.dispatchProgressEvent("progress", .{
            .total = loaded, // TODO, this is wrong? Need the content-type
            .loaded = loaded,
        });
        self.last_dispatch = now;
    }

    fn httpDoneCallback(ctx: *anyopaque) !void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));

        log.info(.http, "request complete", .{
            .source = "xhr",
            .url = self.url,
            .status = self.response_status,
        });

        // Not that the request is done, the http/client will free the transfer
        // object. It isn't safe to keep it around.
        self.transfer = null;

        self.state = .done;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");

        const loaded = self.response_bytes.items.len;

        // dispatch a progress event load.
        self.dispatchProgressEvent("load", .{ .loaded = loaded, .total = loaded });
        // dispatch a progress event loadend.
        self.dispatchProgressEvent("loadend", .{ .loaded = loaded, .total = loaded });
    }

    fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
        // http client will close it after an error, it isn't safe to keep around
        self.transfer = null;
        self.onErr(err);
    }

    pub fn _abort(self: *XMLHttpRequest) void {
        self.onErr(DOMError.Abort);
        if (self.transfer) |transfer| {
            transfer.abort();
        }
    }

    fn onErr(self: *XMLHttpRequest, err: anyerror) void {
        self.send_flag = false;

        // capture the state before we change it
        const s = self.state;

        const is_abort = err == DOMError.Abort;

        if (is_abort) {
            self.state = .unsent;
        } else {
            self.state = .done;
            self.dispatchEvt("error");
        }

        if (s != .done or s != .unsent) {
            self.dispatchEvt("readystatechange");
            if (is_abort) {
                self.dispatchProgressEvent("abort", .{});
            }
            self.dispatchProgressEvent("loadend", .{});
        }

        const level: log.Level = if (err == DOMError.Abort) .debug else .err;
        log.log(.http, level, "error", .{
            .url = self.url,
            .err = err,
            .source = "xhr.OnErr",
        });
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
    pub fn get_responseURL(self: *XMLHttpRequest) ?[:0]const u8 {
        return self.url;
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

        var fbs = std.io.fixedBufferStream(self.response_bytes.items);
        const doc = parser.documentHTMLParse(fbs.reader(), mime.charset orelse "UTF-8") catch {
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
        for (self.response_headers.items) |entry| {
            if (entry.len <= name.len) {
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, entry[0..name.len]) == false) {
                continue;
            }
            if (entry[name.len] != ':') {
                continue;
            }
            return std.mem.trimLeft(u8, entry[name.len + 1 ..], " ");
        }
        return null;
    }

    pub fn _getAllResponseHeaders(self: *XMLHttpRequest) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        const w = buf.writer(self.arena);

        for (self.response_headers.items) |entry| {
            try w.writeAll(entry);
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
test "Browser: XHR.XMLHttpRequest" {
    try testing.htmlRunner("xhr/xhr.html");
}

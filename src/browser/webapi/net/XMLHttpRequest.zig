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

const HttpClient = @import("../../HttpClient.zig");
const http = @import("../../../network/http.zig");

const URL = @import("../../URL.zig");
const Mime = @import("../../Mime.zig");
const Page = @import("../../Page.zig");

const Node = @import("../Node.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const Headers = @import("Headers.zig");
const Request = @import("Request.zig");
const BodyInit = @import("body_init.zig").BodyInit;
const XMLHttpRequestEventTarget = @import("XMLHttpRequestEventTarget.zig");

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const XMLHttpRequest = @This();
_rc: lp.RC(u8) = .{},
_exec: *const Execution,
_proto: *XMLHttpRequestEventTarget,
_arena: Allocator,
_http_response: ?HttpClient.Response = null,
_active_request: bool = false,

_url: [:0]const u8 = "",
_method: http.Method = .GET,
_request_headers: *Headers,
_request_body: ?[]const u8 = null,

_response: ?Response = null,
_response_data: std.ArrayList(u8) = .empty,
_response_status: u16 = 0,
_response_len: ?usize = 0,
_response_url: [:0]const u8 = "",
_response_mime: ?Mime = null,
_response_headers: std.ArrayList([]const u8) = .empty,
_response_type: ResponseType = .text,

_ready_state: ReadyState = .unsent,
_on_ready_state_change: ?js.Function.Temp = null,
_with_credentials: bool = false,
_timeout: u32 = 0,

const ReadyState = enum(u8) {
    unsent = 0,
    opened = 1,
    headers_received = 2,
    loading = 3,
    done = 4,
};

const Response = union(ResponseType) {
    text: []const u8,
    json: js.Value.Global,
    document: *Node.Document,
    arraybuffer: js.ArrayBuffer,
};

const ResponseType = enum {
    text,
    json,
    document,
    arraybuffer,
    // TODO: other types to support
};

pub fn init(exec: *const Execution) !*XMLHttpRequest {
    const arena = try exec.getArena(.large, "XMLHttpRequest");
    errdefer exec.releaseArena(arena);
    const self = try exec._factory.xhrEventTarget(arena, XMLHttpRequest{
        ._exec = exec,
        ._arena = arena,
        ._proto = undefined,
        ._request_headers = try Headers.init(null, exec),
    });
    return self;
}

pub fn deinit(self: *XMLHttpRequest, page: *Page) void {
    if (self._http_response) |resp| {
        resp.abort(error.Abort);
        self._http_response = null;
    }

    if (self._on_ready_state_change) |func| {
        func.release();
    }

    {
        const proto = self._proto;
        if (proto._on_abort) |func| {
            func.release();
        }
        if (proto._on_error) |func| {
            func.release();
        }
        if (proto._on_load) |func| {
            func.release();
        }
        if (proto._on_load_end) |func| {
            func.release();
        }
        if (proto._on_load_start) |func| {
            func.release();
        }
        if (proto._on_progress) |func| {
            func.release();
        }
        if (proto._on_timeout) |func| {
            func.release();
        }
    }

    page.releaseArena(self._arena);
}

fn releaseSelfRef(self: *XMLHttpRequest) void {
    if (self._active_request == false) {
        return;
    }
    self._active_request = false;
    self.releaseRef(self._exec.context.page);
}

pub fn releaseRef(self: *XMLHttpRequest, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *XMLHttpRequest) void {
    self._rc.acquire();
}

fn asEventTarget(self: *XMLHttpRequest) *EventTarget {
    return self._proto._proto;
}

pub fn getOnReadyStateChange(self: *const XMLHttpRequest) ?js.Function.Temp {
    return self._on_ready_state_change;
}

pub fn setOnReadyStateChange(self: *XMLHttpRequest, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_ready_state_change = try cb.tempWithThis(self);
    } else {
        self._on_ready_state_change = null;
    }
}

pub fn getWithCredentials(self: *const XMLHttpRequest) bool {
    return self._with_credentials;
}

pub fn setWithCredentials(self: *XMLHttpRequest, value: bool) !void {
    if (self._ready_state != .unsent and self._ready_state != .opened) {
        return error.InvalidStateError;
    }
    self._with_credentials = value;
}

pub fn getTimeout(self: *const XMLHttpRequest) u32 {
    return self._timeout;
}

pub fn setTimeout(self: *XMLHttpRequest, value: u32) void {
    self._timeout = value;
}

// TODO: this takes an optional 3 more parameters
// TODO: url should be a union, as it can be multiple things
pub fn open(self: *XMLHttpRequest, method_: []const u8, url: [:0]const u8) !void {
    // Abort any in-progress request
    if (self._http_response) |transfer| {
        transfer.abort(error.Abort);
        self._http_response = null;
    }

    // Reset internal state
    self._response = null;
    self._response_data.clearRetainingCapacity();
    self._response_status = 0;
    self._response_len = 0;
    self._response_url = "";
    self._response_mime = null;
    self._response_headers.clearRetainingCapacity();
    self._request_body = null;

    const exec = self._exec;
    self._method = try parseMethod(method_);
    self._url = try URL.resolve(self._arena, exec.base(), url, .{ .always_dupe = true, .encoding = exec.charset.* });
    try self.stateChanged(.opened, exec);
}

pub fn setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8, exec: *const Execution) !void {
    if (self._ready_state != .opened) {
        return error.InvalidStateError;
    }
    return self._request_headers.append(name, value, exec);
}

pub fn send(self: *XMLHttpRequest, body_: ?BodyInit, exec_: *const Execution) !void {
    if (comptime IS_DEBUG) {
        log.debug(.http, "XMLHttpRequest.send", .{ .url = self._url });
    }
    if (self._ready_state != .opened) {
        return error.InvalidStateError;
    }

    if (body_) |b| {
        if (self._method != .GET and self._method != .HEAD) {
            const extracted = try b.extract(self._arena);
            self._request_body = extracted.bytes;
            // Per XHR §4.7.6 "send()" step 4, the default Content-Type only
            // applies if the author hasn't already set one via
            // setRequestHeader.
            if (extracted.content_type) |ct| {
                if (!self._request_headers.has("content-type", exec_)) {
                    try self._request_headers.append("content-type", ct, exec_);
                }
            }
        }
    }

    const exec = self._exec;

    if (std.mem.startsWith(u8, self._url, "blob:")) {
        return self.handleBlobUrl(exec);
    }

    const session = exec.context.page.session;
    const http_client = &session.browser.http_client;
    var headers = try http_client.newHeaders();

    // Only add cookies for same-origin or when withCredentials is true
    const cookie_support = self._with_credentials or exec.isSameOrigin(self._url);

    try self._request_headers.populateHttpHeader(exec.call_arena, &headers);
    if (cookie_support) {
        try exec.headersForRequest(&headers);
    }

    self.acquireRef();
    self._active_request = true;

    exec.makeRequest(.{
        .ctx = self,
        .params = .{
            .url = self._url,
            .method = self._method,
            .headers = headers,
            .frame_id = exec.frameId(),
            .loader_id = exec.loaderId(),
            .body = self._request_body,
            .cookie_jar = if (cookie_support) &session.cookie_jar else null,
            .cookie_origin = exec.url.*,
            .resource_type = .xhr,
            .timeout_ms = self._timeout,
            .notification = session.notification,
        },
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        self.releaseSelfRef();
        return err;
    };
}

fn handleBlobUrl(self: *XMLHttpRequest, exec: *const Execution) !void {
    const blob = exec.lookupBlobUrl(self._url) orelse {
        self.handleError(error.BlobNotFound);
        return;
    };

    self._response_status = 200;
    self._response_url = self._url;

    try self._response_data.appendSlice(self._arena, blob._slice);
    self._response_len = blob._slice.len;

    try self.stateChanged(.headers_received, exec);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, exec);
    try self.stateChanged(.loading, exec);
    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response_data.items.len,
    }, exec);
    try self.stateChanged(.done, exec);

    const loaded = self._response_data.items.len;
    try self._proto.dispatch(.load, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
    try self._proto.dispatch(.load_end, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
}

pub fn getReadyState(self: *const XMLHttpRequest) u32 {
    return @intFromEnum(self._ready_state);
}

pub fn getResponseHeader(self: *const XMLHttpRequest, name: []const u8) ?[]const u8 {
    for (self._response_headers.items) |entry| {
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

pub fn getAllResponseHeaders(self: *const XMLHttpRequest, exec: *const Execution) ![]const u8 {
    if (self._ready_state != .done) {
        // MDN says this should return null, but it seems to return an empty string
        // in every browser. Specs are too hard for a dumbo like me to understand.
        return "";
    }

    var buf = std.Io.Writer.Allocating.init(exec.call_arena);
    for (self._response_headers.items) |entry| {
        try buf.writer.writeAll(entry);
        try buf.writer.writeAll("\r\n");
    }
    return buf.written();
}

pub fn getResponseType(self: *const XMLHttpRequest) []const u8 {
    if (self._ready_state != .done) {
        return "";
    }
    return @tagName(self._response_type);
}

pub fn setResponseType(self: *XMLHttpRequest, value: []const u8) void {
    if (std.meta.stringToEnum(ResponseType, value)) |rt| {
        self._response_type = rt;
    }
}

pub fn getResponseText(self: *const XMLHttpRequest) []const u8 {
    return self._response_data.items;
}

pub fn getStatus(self: *const XMLHttpRequest) u16 {
    return self._response_status;
}

pub fn getStatusText(self: *const XMLHttpRequest) []const u8 {
    return std.http.Status.phrase(@enumFromInt(self._response_status)) orelse "";
}

pub fn getResponseURL(self: *XMLHttpRequest) []const u8 {
    return self._response_url;
}

pub fn getResponse(self: *XMLHttpRequest, exec: *const Execution) !?Response {
    if (self._ready_state != .done) {
        return null;
    }

    if (self._response) |res| {
        // was already loaded
        return res;
    }

    const data = self._response_data.items;
    const res: Response = switch (self._response_type) {
        .text => .{ .text = data },
        .json => blk: {
            const value = try exec.context.local.?.parseJSON(data);
            break :blk .{ .json = try value.persist() };
        },
        .document => blk: {
            // responseType=document is only meaningful in a Frame; workers
            // have no DOM. Drastically different impls -> switch on global.
            switch (exec.context.global) {
                .frame => |frame| {
                    const document = try exec._factory.node(Node.Document{ ._proto = undefined, ._type = .generic });
                    try frame.parseHtmlAsChildren(document.asNode(), data);
                    break :blk .{ .document = document };
                },
                .worker => return error.NotSupportedInWorker,
            }
        },
        .arraybuffer => .{ .arraybuffer = .{ .values = data } },
    };

    self._response = res;
    return res;
}

pub fn getResponseXML(self: *XMLHttpRequest, exec: *const Execution) !?*Node.Document {
    const res = (try self.getResponse(exec)) orelse return null;
    return switch (res) {
        .document => |doc| doc,
        else => null,
    };
}

fn httpStartCallback(response: HttpClient.Response) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .method = self._method, .url = self._url, .source = "xhr" });
    }
    self._http_response = response;
}

fn httpHeaderCallback(response: HttpClient.Response, header: http.Header) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ header.name, header.value });
    try self._response_headers.append(self._arena, joined);
}

fn httpHeaderDoneCallback(response: HttpClient.Response) !bool {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "xhr",
            .url = self._url,
            .status = response.status(),
        });
    }

    if (response.contentType()) |ct| {
        self._response_mime = Mime.parse(ct) catch |e| {
            log.info(.http, "invalid content type", .{
                .content_Type = ct,
                .err = e,
                .url = self._url,
            });
            return false;
        };
    }

    var it = response.headerIterator();
    while (it.next()) |hdr| {
        const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ hdr.name, hdr.value });
        try self._response_headers.append(self._arena, joined);
    }

    self._response_status = response.status().?;
    if (response.contentLength()) |cl| {
        self._response_len = cl;
        try self._response_data.ensureTotalCapacity(self._arena, cl);
    }
    self._response_url = try self._arena.dupeZ(u8, response.url());

    const exec = self._exec;

    var ls: js.Local.Scope = undefined;
    exec.context.localScope(&ls);
    defer ls.deinit();

    try self.stateChanged(.headers_received, exec);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, exec);
    try self.stateChanged(.loading, exec);

    return true;
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(response.ctx));
    try self._response_data.appendSlice(self._arena, data);

    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response_data.items.len,
    }, self._exec);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));

    log.info(.http, "request complete", .{
        .source = "xhr",
        .url = self._url,
        .status = self._response_status,
        .len = self._response_data.items.len,
    });

    // Not that the request is done, the http/client will free the transfer
    // object. It isn't safe to keep it around.
    self._http_response = null;

    const exec = self._exec;

    try self.stateChanged(.done, exec);

    const loaded = self._response_data.items.len;
    try self._proto.dispatch(.load, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);
    try self._proto.dispatch(.load_end, .{
        .total = loaded,
        .loaded = loaded,
    }, exec);

    self.releaseSelfRef();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
    // http client will close it after an error, it isn't safe to keep around
    self.handleError(err);
    if (self._http_response != null) {
        self._http_response = null;
    }
    self.releaseSelfRef();
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self.releaseSelfRef();
}

pub fn abort(self: *XMLHttpRequest) void {
    self.handleError(error.Abort);
    if (self._http_response) |resp| {
        self._http_response = null;
        resp.abort(error.Abort);
    }
    self.releaseSelfRef();
}

fn handleError(self: *XMLHttpRequest, err: anyerror) void {
    self._handleError(err) catch |inner| {
        log.err(.http, "handle error error", .{
            .original = err,
            .err = inner,
        });
    };
}
fn _handleError(self: *XMLHttpRequest, err: anyerror) !void {
    const is_abort = err == error.Abort;
    const is_timeout = err == error.OperationTimedout;

    const new_state: ReadyState = if (is_abort) .unsent else .done;
    if (new_state != self._ready_state) {
        const exec = self._exec;

        try self.stateChanged(new_state, exec);
        if (is_abort) {
            try self._proto.dispatch(.abort, null, exec);
        } else if (is_timeout) {
            try self._proto.dispatch(.timeout, null, exec);
        }
        if (!is_timeout) {
            try self._proto.dispatch(.err, null, exec);
        }
        try self._proto.dispatch(.load_end, null, exec);
    }

    const level: log.Level = if (err == error.Abort) .debug else .err;
    log.log(.http, level, "error", .{
        .url = self._url,
        .err = err,
        .source = "xhr.handleError",
    });
}

fn stateChanged(self: *XMLHttpRequest, state: ReadyState, exec: *const Execution) !void {
    if (state == self._ready_state) {
        return;
    }

    self._ready_state = state;

    const target = self.asEventTarget();
    if (exec.hasDirectListeners(target, "readystatechange", self._on_ready_state_change)) {
        const event = try Event.initTrusted(.wrap("readystatechange"), .{}, exec.context.page);
        try exec.dispatch(target, event, self._on_ready_state_change, .{ .context = "XHR state change" });
    }
}

fn parseMethod(method: []const u8) !http.Method {
    if (std.ascii.eqlIgnoreCase(method, "get")) {
        return .GET;
    }
    if (std.ascii.eqlIgnoreCase(method, "post")) {
        return .POST;
    }
    if (std.ascii.eqlIgnoreCase(method, "delete")) {
        return .DELETE;
    }
    if (std.ascii.eqlIgnoreCase(method, "put")) {
        return .PUT;
    }
    if (std.ascii.eqlIgnoreCase(method, "propfind")) {
        return .PROPFIND;
    }
    return error.InvalidMethod;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequest);

    pub const Meta = struct {
        pub const name = "XMLHttpRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(XMLHttpRequest.init, .{});
    pub const UNSENT = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.unsent), .{ .template = true });
    pub const OPENED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.opened), .{ .template = true });
    pub const HEADERS_RECEIVED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.headers_received), .{ .template = true });
    pub const LOADING = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.loading), .{ .template = true });
    pub const DONE = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.done), .{ .template = true });

    pub const onreadystatechange = bridge.accessor(XMLHttpRequest.getOnReadyStateChange, XMLHttpRequest.setOnReadyStateChange, .{});
    pub const timeout = bridge.accessor(XMLHttpRequest.getTimeout, XMLHttpRequest.setTimeout, .{});
    pub const withCredentials = bridge.accessor(XMLHttpRequest.getWithCredentials, XMLHttpRequest.setWithCredentials, .{ .dom_exception = true });
    pub const open = bridge.function(XMLHttpRequest.open, .{});
    pub const send = bridge.function(XMLHttpRequest.send, .{ .dom_exception = true });
    pub const responseType = bridge.accessor(XMLHttpRequest.getResponseType, XMLHttpRequest.setResponseType, .{});
    pub const status = bridge.accessor(XMLHttpRequest.getStatus, null, .{});
    pub const statusText = bridge.accessor(XMLHttpRequest.getStatusText, null, .{});
    pub const readyState = bridge.accessor(XMLHttpRequest.getReadyState, null, .{});
    pub const response = bridge.accessor(XMLHttpRequest.getResponse, null, .{});
    pub const responseText = bridge.accessor(XMLHttpRequest.getResponseText, null, .{});
    pub const responseXML = bridge.accessor(XMLHttpRequest.getResponseXML, null, .{});
    pub const responseURL = bridge.accessor(XMLHttpRequest.getResponseURL, null, .{});
    pub const setRequestHeader = bridge.function(XMLHttpRequest.setRequestHeader, .{ .dom_exception = true });
    pub const getResponseHeader = bridge.function(XMLHttpRequest.getResponseHeader, .{});
    pub const getAllResponseHeaders = bridge.function(XMLHttpRequest.getAllResponseHeaders, .{});
    pub const abort = bridge.function(XMLHttpRequest.abort, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: XHR" {
    try testing.htmlRunner("net/xhr.html", .{});
}

test "WebApi: XHR in worker" {
    try testing.htmlRunner("net/xhr_worker.html", .{});
}

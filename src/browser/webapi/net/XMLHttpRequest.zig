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
const js = @import("../../js/js.zig");

const log = @import("../../../log.zig");
const Http = @import("../../../http/Http.zig");

const URL = @import("../../URL.zig");
const Mime = @import("../../Mime.zig");
const Page = @import("../../Page.zig");
const Node = @import("../Node.zig");
const Event = @import("../Event.zig");
const Headers = @import("Headers.zig");
const EventTarget = @import("../EventTarget.zig");
const XMLHttpRequestEventTarget = @import("XMLHttpRequestEventTarget.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const XMLHttpRequest = @This();
_page: *Page,
_proto: *XMLHttpRequestEventTarget,
_arena: Allocator,
_transfer: ?*Http.Transfer = null,

_url: [:0]const u8 = "",
_method: Http.Method = .GET,
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
_on_ready_state_change: ?js.Function.Global = null,

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
};

const ResponseType = enum {
    text,
    json,
    document,
    // TODO: other types to support
};

pub fn init(page: *Page) !*XMLHttpRequest {
    return page._factory.xhrEventTarget(XMLHttpRequest{
        ._page = page,
        ._proto = undefined,
        ._arena = page.arena,
        ._request_headers = try Headers.init(null, page),
    });
}

pub fn deinit(self: *XMLHttpRequest) void {
    if (self.transfer) |transfer| {
        transfer.abort(error.Abort);
        self.transfer = null;
    }
}

fn asEventTarget(self: *XMLHttpRequest) *EventTarget {
    return self._proto._proto;
}

pub fn getOnReadyStateChange(self: *const XMLHttpRequest) ?js.Function.Global {
    return self._on_ready_state_change;
}

pub fn setOnReadyStateChange(self: *XMLHttpRequest, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_ready_state_change = try cb.persistWithThis(self);
    } else {
        self._on_ready_state_change = null;
    }
}

// TODO: this takes an opitonal 3 more parameters
// TODO: url should be a union, as it can be multiple things
pub fn open(self: *XMLHttpRequest, method_: []const u8, url: [:0]const u8) !void {
    // Abort any in-progress request
    if (self._transfer) |transfer| {
        transfer.abort(error.Abort);
        self._transfer = null;
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

    self._method = try parseMethod(method_);
    self._url = try URL.resolve(self._arena, self._page.base(), url, .{ .always_dupe = true });
    try self.stateChanged(.opened, self._page);
}

pub fn setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8, page: *Page) !void {
    if (self._ready_state != .opened) {
        return error.InvalidStateError;
    }
    return self._request_headers.append(name, value, page);
}

pub fn send(self: *XMLHttpRequest, body_: ?[]const u8) !void {
    if (comptime IS_DEBUG) {
        log.debug(.http, "XMLHttpRequest.send", .{ .url = self._url });
    }
    if (self._ready_state != .opened) {
        return error.InvalidStateError;
    }

    if (body_) |b| {
        if (self._method != .GET and self._method != .HEAD) {
            self._request_body = try self._arena.dupe(u8, b);
        }
    }

    const page = self._page;
    const http_client = page._session.browser.http_client;
    var headers = try http_client.newHeaders();
    try self._request_headers.populateHttpHeader(page.call_arena, &headers);
    try page.requestCookie(.{}).headersForRequest(self._arena, self._url, &headers);

    try http_client.request(.{
        .ctx = self,
        .url = self._url,
        .method = self._method,
        .headers = headers,
        .body = self._request_body,
        .cookie_jar = &page._session.cookie_jar,
        .resource_type = .xhr,
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
    });
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

pub fn getAllResponseHeaders(self: *const XMLHttpRequest, page: *Page) ![]const u8 {
    if (self._ready_state != .done) {
        // MDN says this should return null, but it seems to return an empty string
        // in every browser. Specs are too hard for a dumbo like me to understand.
        return "";
    }

    var buf = std.Io.Writer.Allocating.init(page.call_arena);
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

pub fn getResponse(self: *XMLHttpRequest, page: *Page) !?Response {
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
            const value = try page.js.parseJSON(data);
            break :blk .{ .json = try value.persist() };
        },
        .document => blk: {
            const document = try page._factory.node(Node.Document{ ._proto = undefined, ._type = .generic });
            try page.parseHtmlAsChildren(document.asNode(), data);
            break :blk .{ .document = document };
        },
    };

    self._response = res;
    return res;
}

pub fn getResponseXML(self: *XMLHttpRequest, page: *Page) !?*Node.Document {
    const res = (try self.getResponse(page)) orelse return null;
    return switch (res) {
        .document => |doc| doc,
        else => null,
    };
}

fn httpStartCallback(transfer: *Http.Transfer) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .method = self._method, .url = self._url, .source = "xhr" });
    }
    self._transfer = transfer;
}

fn httpHeaderCallback(transfer: *Http.Transfer, header: Http.Header) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
    const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ header.name, header.value });
    try self._response_headers.append(self._arena, joined);
}

fn httpHeaderDoneCallback(transfer: *Http.Transfer) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));

    const header = &transfer.response_header.?;

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "xhr",
            .url = self._url,
            .status = header.status,
        });
    }

    if (header.contentType()) |ct| {
        self._response_mime = Mime.parse(ct) catch |e| {
            return self.handleError(e);
        };
    }

    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        const joined = try std.fmt.allocPrint(self._arena, "{s}: {s}", .{ hdr.name, hdr.value });
        try self._response_headers.append(self._arena, joined);
    }

    self._response_status = header.status;
    if (transfer.getContentLength()) |cl| {
        self._response_len = cl;
        try self._response_data.ensureTotalCapacity(self._arena, cl);
    }
    self._response_url = try self._arena.dupeZ(u8, std.mem.span(header.url));

    try self.stateChanged(.headers_received, self._page);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, self._page);
    try self.stateChanged(.loading, self._page);
}

fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
    try self._response_data.appendSlice(self._arena, data);

    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response_data.items.len,
    }, self._page);
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
    self._transfer = null;
    try self.stateChanged(.done, self._page);

    const loaded = self._response_data.items.len;
    try self._proto.dispatch(.load, .{
        .total = loaded,
        .loaded = loaded,
    }, self._page);
    try self._proto.dispatch(.load_end, .{
        .total = loaded,
        .loaded = loaded,
    }, self._page);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));
    // http client will close it after an error, it isn't safe to keep around
    self._transfer = null;
    self.handleError(err);
}

pub fn abort(self: *XMLHttpRequest) void {
    self.handleError(error.Abort);
    if (self._transfer) |transfer| {
        transfer.abort(error.Abort);
        self._transfer = null;
    }
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

    const new_state: ReadyState = if (is_abort) .unsent else .done;
    if (new_state != self._ready_state) {
        const page = self._page;
        try self.stateChanged(new_state, page);
        if (is_abort) {
            try self._proto.dispatch(.abort, null, page);
        }
        try self._proto.dispatch(.err, null, page);
        try self._proto.dispatch(.load_end, null, page);
    }

    const level: log.Level = if (err == error.Abort) .debug else .err;
    log.log(.http, level, "error", .{
        .url = self._url,
        .err = err,
        .source = "xhr.handleError",
    });
}

fn stateChanged(self: *XMLHttpRequest, state: ReadyState, page: *Page) !void {
    if (state == self._ready_state) {
        return;
    }

    self._ready_state = state;

    const event = try Event.initTrusted("readystatechange", .{}, page);
    const func = if (self._on_ready_state_change) |*g| g.local() else null;
    try page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        func,
        .{ .context = "XHR state change" },
    );
}

fn parseMethod(method: []const u8) !Http.Method {
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
    pub const UNSENT = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.unsent));
    pub const OPENED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.opened));
    pub const HEADERS_RECEIVED = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.headers_received));
    pub const LOADING = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.loading));
    pub const DONE = bridge.property(@intFromEnum(XMLHttpRequest.ReadyState.done));

    pub const onreadystatechange = bridge.accessor(XMLHttpRequest.getOnReadyStateChange, XMLHttpRequest.setOnReadyStateChange, .{});
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

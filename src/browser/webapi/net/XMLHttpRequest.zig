const std = @import("std");
const js = @import("../../js/js.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const log = @import("../../../log.zig");
const Http = @import("../../../http/Http.zig");

const URL = @import("../../URL.zig");
const Mime = @import("../../Mime.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const XMLHttpRequestEventTarget = @import("XMLHttpRequestEventTarget.zig");

const Allocator = std.mem.Allocator;

const XMLHttpRequest = @This();
_page: *Page,
_proto: *XMLHttpRequestEventTarget,
_arena: Allocator,
_transfer: ?*Http.Transfer = null,

_url: [:0]const u8 = "",
_method: Http.Method = .GET,
_request_body: ?[]const u8 = null,

_response: std.ArrayList(u8) = .empty,
_response_status: u16 = 0,
_response_len: ?usize = 0,
_response_mime: ?Mime = null,
_response_headers: std.ArrayList([]const u8) = .empty,
_response_type: ResponseType = .text,

_state: State = .unsent,
_on_ready_state_change: ?js.Function = null,

const State = enum(u8) {
    unsent = 0,
    opened = 1,
    headers_received = 2,
    loading = 3,
    done = 4,
};

const ResponseType = enum {
    text,
    json,
    // TODO: other types to support
};

pub fn init(page: *Page) !*XMLHttpRequest {
    return page._factory.xhrEventTarget(XMLHttpRequest{
        ._page = page,
        ._proto = undefined,
        ._arena = page.arena,
    });
}

fn asEventTarget(self: *XMLHttpRequest) *EventTarget {
    return self._proto._proto;
}

pub fn getOnReadyStateChange(self: *const XMLHttpRequest) ?js.Function {
    return self._on_ready_state_change;
}

pub fn setOnReadyStateChange(self: *XMLHttpRequest, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_ready_state_change = try cb.withThis(self);
    } else {
        self._on_ready_state_change = null;
    }
}

pub fn getResponseType(self: *const XMLHttpRequest) []const u8 {
    return @tagName(self._response_type);
}

pub fn setResponseType(self: *XMLHttpRequest, value: []const u8) void {
    if (std.meta.stringToEnum(ResponseType, value)) |rt| {
        self._response_type = rt;
    }
}

pub fn getStatus(self: *const XMLHttpRequest) u16 {
    return self._response_status;
}

pub fn getResponse(self: *const XMLHttpRequest, page: *Page) !Response {
    switch (self._response_type) {
        .text => return .{ .text = self._response.items },
        .json => {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, page.call_arena, self._response.items, .{});
            return .{ .json = parsed };
        },
    }
}

// TODO: this takes an opitonal 3 more parameters
// TODO: url should be a union, as it can be multiple things
pub fn open(self: *XMLHttpRequest, method_: []const u8, url: [:0]const u8) !void {
    self._method = try parseMethod(method_);
    self._url = try URL.resolve(self._arena, self._page.url, url, .{ .always_dupe = true });
    try self.stateChanged(.opened, self._page);
}

pub fn send(self: *XMLHttpRequest, body_: ?[]const u8) !void {
    if (comptime IS_DEBUG) {
        log.debug(.xhr, "XMLHttpRequest.send", .{ .url = self._url });
    }

    if (body_) |b| {
        if (self._method != .GET and self._method != .HEAD) {
            self._request_body = try self._arena.dupe(u8, b);
        }
    }

    const page = self._page;
    const http_client = page._session.browser.http_client;
    var headers = try http_client.newHeaders();
    // @ZIGDOM
    // for (self._headers.items) |hdr| {
    //     try headers.add(hdr);
    // }
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
        try self._response.ensureTotalCapacity(self._arena, cl);
    }

    try self.stateChanged(.headers_received, self._page);
    try self._proto.dispatch(.load_start, .{ .loaded = 0, .total = self._response_len orelse 0 }, self._page);
    try self.stateChanged(.loading, self._page);
}

fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(transfer.ctx));
    try self._response.appendSlice(self._arena, data);

    try self._proto.dispatch(.progress, .{
        .total = self._response_len orelse 0,
        .loaded = self._response.items.len,
    }, self._page);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *XMLHttpRequest = @ptrCast(@alignCast(ctx));

    log.info(.http, "request complete", .{
        .source = "xhr",
        .url = self._url,
        .status = self._response_status,
        .len = self._response.items.len,
    });

    // Not that the request is done, the http/client will free the transfer
    // object. It isn't safe to keep it around.
    self._transfer = null;
    try self.stateChanged(.done, self._page);

    const loaded = self._response.items.len;
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

pub fn _abort(self: *XMLHttpRequest) void {
    self.handleError(error.Abort);
    if (self._transfer) |transfer| {
        transfer.abort();
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

    const new_state: State = if (is_abort) .unsent else .done;
    if (new_state != self._state) {
        const page = self._page;
        try self.stateChanged(new_state, page);
        if (is_abort) {
            try self._proto.dispatch(.abort, null, page);
        }
        try self._proto.dispatch(.load_end, null, page);
    }

    const level: log.Level = if (err == error.Abort) .debug else .err;
    log.log(.http, level, "error", .{
        .url = self._url,
        .err = err,
        .source = "xhr.handleError",
    });
}

fn stateChanged(self: *XMLHttpRequest, state: State, page: *Page) !void {
    // there are more rules than this, but it's a start
    std.debug.assert(state != self._state);

    const event = try Event.init("readystatechange", .{}, page);
    try page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        self._on_ready_state_change,
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

const Response = union(enum) {
    text: []const u8,
    json: std.json.Value,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequest);

    pub const Meta = struct {
        pub const name = "XMLHttpRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(XMLHttpRequest.init, .{});
    pub const UNSENT = bridge.property(@intFromEnum(XMLHttpRequest.State.unsent));
    pub const OPENED = bridge.property(@intFromEnum(XMLHttpRequest.State.opened));
    pub const HEADERS_RECEIVED = bridge.property(@intFromEnum(XMLHttpRequest.State.headers_received));
    pub const LOADING = bridge.property(@intFromEnum(XMLHttpRequest.State.loading));
    pub const DONE = bridge.property(@intFromEnum(XMLHttpRequest.State.done));

    pub const onreadystatechange = bridge.accessor(XMLHttpRequest.getOnReadyStateChange, XMLHttpRequest.setOnReadyStateChange, .{});
    pub const open = bridge.function(XMLHttpRequest.open, .{});
    pub const send = bridge.function(XMLHttpRequest.send, .{});
    pub const responseType = bridge.accessor(XMLHttpRequest.getResponseType, XMLHttpRequest.setResponseType, .{});
    pub const status = bridge.accessor(XMLHttpRequest.getStatus, null, .{});
    pub const response = bridge.accessor(XMLHttpRequest.getResponse, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: XHR" {
    try testing.htmlRunner("net/xhr.html", .{});
}

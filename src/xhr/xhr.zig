const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const Callback = jsruntime.Callback;
const DOMError = @import("../netsurf.zig").DOMError;

const Loop = jsruntime.Loop;
const YieldImpl = Loop.Yield(XMLHttpRequest);
const Client = @import("../async/Client.zig");

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = generate.Tuple(.{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
    XMLHttpRequest,
});

pub const XMLHttpRequestEventTarget = struct {
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;

    onloadstart_cbk: ?Callback = null,
    onprogress_cbk: ?Callback = null,
    onabort_cbk: ?Callback = null,
    onload_cbk: ?Callback = null,
    ontimeout_cbk: ?Callback = null,
    onloadend_cbk: ?Callback = null,

    pub fn constructor() !XMLHttpRequestEventTarget {
        return .{};
    }

    pub fn set_onloadstart(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onloadstart_cbk = handler;
    }
    pub fn set_onprogress(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onprogress_cbk = handler;
    }
    pub fn set_onabort(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onabort_cbk = handler;
    }
    // TODO remove-me, test func du to an issue w/ the setter.
    // see https://lightpanda.slack.com/archives/C05TRU6RBM1/p1706708213838989
    pub fn _setOnload(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.set_onload(handler);
    }
    pub fn set_onload(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onload_cbk = handler;
    }
    pub fn set_ontimeout(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.ontimeout_cbk = handler;
    }
    pub fn set_onloadend(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onloadend_cbk = handler;
    }

    pub fn deinit(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator) void {
        if (self.onloadstart_cbk) |cbk| cbk.deinit(alloc);
        if (self.onprogress_cbk) |cbk| cbk.deinit(alloc);
        if (self.onabort_cbk) |cbk| cbk.deinit(alloc);
        if (self.onload_cbk) |cbk| cbk.deinit(alloc);
        if (self.ontimeout_cbk) |cbk| cbk.deinit(alloc);
        if (self.onloadend_cbk) |cbk| cbk.deinit(alloc);
    }
};

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    proto: XMLHttpRequestEventTarget,
};

pub const XMLHttpRequest = struct {
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

    proto: XMLHttpRequestEventTarget,
    cli: Client,
    impl: YieldImpl,

    method: std.http.Method,
    state: u16,
    url: ?[]const u8,
    uri: std.Uri,
    headers: std.http.Headers,
    sync: bool = true,
    err: ?anyerror = null,

    upload: ?XMLHttpRequestUpload = null,
    timeout: u32 = 0,
    withCredentials: bool = false,
    // TODO: response readonly attribute any response;
    response_bytes: ?[]const u8 = null,
    response_type: ResponseType = .Empty,
    response_headers: std.http.Headers,
    send_flag: bool = false,

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !XMLHttpRequest {
        return .{
            .proto = try XMLHttpRequestEventTarget.constructor(),
            .headers = .{ .allocator = alloc, .owned = true },
            .response_headers = .{ .allocator = alloc, .owned = true },
            .impl = YieldImpl.init(loop),
            .method = undefined,
            .url = null,
            .uri = undefined,
            .state = UNSENT,
            // TODO retrieve the HTTP client globally to reuse existing connections.
            .cli = .{ .allocator = alloc, .loop = loop },
        };
    }

    pub fn deinit(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        self.proto.deinit(alloc);
        self.headers.deinit();
        self.response_headers.deinit();
        if (self.url) |v| alloc.free(v);
        if (self.response_bytes) |v| alloc.free(v);
        if (self.response_headers) |v| alloc.free(v);
        // TODO the client must be shared between requests.
        self.cli.deinit();
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.state;
    }

    pub fn get_timeout(self: *XMLHttpRequest) u32 {
        return self.timeout;
    }

    pub fn set_timeout(self: *XMLHttpRequest, timeout: u32) !void {
        // TODO If the current global object is a Window object and this’s
        // synchronous flag is set, then throw an "InvalidAccessError"
        // DOMException.
        // https://xhr.spec.whatwg.org/#dom-xmlhttprequest-timeout
        self.timeout = timeout;
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

        self.url = try alloc.dupe(u8, url);
        self.uri = std.Uri.parse(self.url.?) catch return DOMError.Syntax;
        self.sync = if (asyn) |b| !b else false;
        self.send_flag = false;

        // TODO should we clearRetainingCapacity instead?
        self.headers.clearAndFree();
        self.response_headers.clearAndFree();

        self.response_type = .Empty;
        if (self.response_bytes) |v| alloc.free(v);

        self.state = OPENED;
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

    // TODO body can be either a string or a document
    pub fn _send(self: *XMLHttpRequest, body: ?[]const u8) !void {
        if (self.state != OPENED) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        //  The body argument provides the request body, if any, and is ignored
        //  if the request method is GET or HEAD.
        //  https://xhr.spec.whatwg.org/#the-send()-method
        _ = body;
        // TODO set Content-Type header according to the given body.

        self.send_flag = true;
        self.impl.yield(self);
    }

    pub fn onYield(self: *XMLHttpRequest, err: ?anyerror) void {
        if (err) |e| return self.onerr(e);
        var req = self.cli.open(self.method, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
        defer req.deinit();

        req.send(.{}) catch |e| return self.onerr(e);
        req.finish() catch |e| return self.onerr(e);
        req.wait() catch |e| return self.onerr(e);

        self.response_headers = req.response.headers.clone(self.response_headers.allocator) catch |e| return self.onerr(e);

        self.state = HEADERS_RECEIVED;

        self.state = LOADING;

        self.state = DONE;

        // TODO use events instead
        if (self.proto.onload_cbk) |cbk| {
            // TODO pass an EventProgress
            cbk.call(null) catch |e| {
                std.debug.print("--- CALLBACK ERROR: {any}\n", .{e});
            }; // TODO handle error
        }
    }

    fn onerr(self: *XMLHttpRequest, err: anyerror) void {
        self.err = err;
        self.state = DONE;
    }

    pub fn get_responseText(self: *XMLHttpRequest) ![]const u8 {
        if (self.state != LOADING and self.state != DONE) return DOMError.InvalidState;
        if (self.response_type != .Empty and self.response_type != .Text) return DOMError.InvalidState;
        return if (self.response_bytes) |v| v else "";
    }

    // the caller owns the string.
    pub fn _getAllResponseHeaders(self: *XMLHttpRequest, alloc: std.mem.Allocator) ![]const u8 {
        self.response_headers.sort();

        var buf: std.ArrayListUnmanaged(u8) = .{};
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
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var send = [_]Case{
        .{ .src = "var nb = 0; function cbk(event) { nb ++; }", .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest()", .ex = "undefined" },

        // TODO remove-me, test func du to an issue w/ the setter.
        // see https://lightpanda.slack.com/archives/C05TRU6RBM1/p1706708213838989
        .{ .src = "req.setOnload(cbk)", .ex = "undefined" },
        // .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; }" },

        .{ .src = "req.open('GET', 'https://w3.org')", .ex = "undefined" },
        .{ .src = "req.setRequestHeader('User-Agent', 'lightpanda/1.0')", .ex = "undefined" },
        .{ .src = "req.send(); nb", .ex = "0" },
        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "nb", .ex = "1" },
        .{ .src = "req.getAllResponseHeaders()", .ex = "undefined" },
    };
    try checkCases(js_env, &send);
}

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

    proto: XMLHttpRequestEventTarget,
    cli: Client,
    impl: YieldImpl,

    readyState: u16,
    url: ?[]const u8,
    uri: std.Uri,
    headers: std.http.Headers,
    asyn: bool = true,
    err: ?anyerror = null,

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !*XMLHttpRequest {
        var req = try alloc.create(XMLHttpRequest);
        req.* = XMLHttpRequest{
            .proto = try XMLHttpRequestEventTarget.constructor(),
            .headers = .{ .allocator = alloc, .owned = false },
            .impl = undefined,
            .url = null,
            .uri = undefined,
            .readyState = UNSENT,
            // TODO retrieve the HTTP client globally to reuse existing connections.
            .cli = .{
                .allocator = alloc,
                .loop = loop,
            },
        };
        req.impl = YieldImpl.init(loop, req);
        return req;
    }

    pub fn deinit(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        self.proto.deinit(alloc);
        self.headers.deinit();
        if (self.url) |url| alloc.free(url);
        // TODO the client must be shared between requests.
        self.cli.deinit();
        alloc.destroy(self);
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.readyState;
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

        try validMethod(method);

        self.url = try alloc.dupe(u8, url);
        self.uri = try std.Uri.parse(self.url.?);
        self.asyn = if (asyn) |b| b else true;

        self.readyState = OPENED;
    }

    const methods = [_][]const u8{ "DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT" };
    const methods_forbidden = [_][]const u8{ "CONNECT", "TRACE", "TRACK" };

    pub fn validMethod(m: []const u8) DOMError!void {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(method, m)) {
                return;
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

    pub fn _send(self: *XMLHttpRequest) void {
        self.impl.yield();
    }

    fn onerr(self: *XMLHttpRequest, err: anyerror) void {
        self.err = err;
        self.readyState = DONE;
    }

    pub fn onYield(self: *XMLHttpRequest, err: ?anyerror) void {
        if (err) |e| return self.onerr(e);
        var req = self.cli.open(.GET, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
        defer req.deinit();

        req.send(.{}) catch |e| return self.onerr(e);
        req.finish() catch |e| return self.onerr(e);
        req.wait() catch |e| return self.onerr(e);

        self.readyState = HEADERS_RECEIVED;

        // TODO read response body

        self.readyState = LOADING;
        self.readyState = DONE;

        // TODO use events instead
        if (self.proto.onload_cbk) |cbk| {
            // TODO pass an EventProgress
            cbk.call(null) catch |e| {
                std.debug.print("--- CALLBACK ERROR: {any}\n", .{e});
            }; // TODO handle error
        }
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var send = [_]Case{
        .{ .src = "var nb = 0; function cbk(event) { nb ++; }", .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest()", .ex = "undefined" },
        .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; }" },
        .{ .src = "req.open('GET', 'https://w3.org')", .ex = "undefined" },
        .{ .src = "req.send(); nb", .ex = "0" },
        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "nb", .ex = "1" },
    };
    try checkCases(js_env, &send);
}

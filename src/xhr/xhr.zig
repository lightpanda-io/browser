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

    pub fn set_onloadstart(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onloadstart_cbk = handler;
    }
    pub fn set_onprogress(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onprogress_cbk = handler;
    }
    pub fn set_onabort(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onabort = handler;
    }
    pub fn set_onload(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onload = handler;
    }
    pub fn set_ontimeout(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.ontimeout = handler;
    }
    pub fn set_onloadend(self: *XMLHttpRequestEventTarget, handler: Callback) void {
        self.onloadend = handler;
    }
};

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;
};

pub const XMLHttpRequest = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    pub const UNSENT: u16 = 0;
    pub const OPENED: u16 = 1;
    pub const HEADERS_RECEIVED: u16 = 2;
    pub const LOADING: u16 = 3;
    pub const DONE: u16 = 4;

    cli: Client,
    impl: YieldImpl,

    readyState: u16 = UNSENT,
    uri: std.Uri,
    headers: std.http.Headers,
    asyn: bool = true,
    err: ?anyerror = null,

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !*XMLHttpRequest {
        var req = try alloc.create(XMLHttpRequest);
        req.* = XMLHttpRequest{
            .headers = .{ .allocator = alloc, .owned = false },
            .impl = undefined,
            .uri = undefined,
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
        self.headers.deinit();
        // TODO the client must be shared between requests.
        self.cli.deinit();
        alloc.destroy(self);
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.readyState;
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

        try validMethod(method);

        self.uri = try std.Uri.parse(url);
        self.asyn = if (asyn) |b| b else true;
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

        self.readyState = OPENED;

        req.send(.{}) catch |e| return self.onerr(e);
        req.finish() catch |e| return self.onerr(e);
        req.wait() catch |e| return self.onerr(e);
        self.readyState = HEADERS_RECEIVED;
        self.readyState = LOADING;
        self.readyState = DONE;
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var send = [_]Case{
        .{ .src = 
        \\var nb = 0; var evt;
        \\function cbk(event) {
        \\  evt = event;
        \\  nb ++;
        \\}
        , .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest();", .ex = "undefined" },
        .{ .src = "req.onload = cbk; true;", .ex = "true" },
        .{ .src = "req.open('GET', 'https://w3.org');", .ex = "undefined" },
        .{ .src = "req.send();", .ex = "undefined" },
    };
    try checkCases(js_env, &send);
}

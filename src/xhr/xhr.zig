const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const EventTarget = @import("../dom/event_target.zig").EventTarget;
const Event = @import("../events/event.zig").Event;
const Callback = jsruntime.Callback;
const DOMError = @import("../netsurf.zig").DOMError;
const DOMException = @import("../dom/exceptions.zig").DOMException;

const Loop = jsruntime.Loop;
const YieldImpl = Loop.Yield(XMLHttpRequest);
const Client = @import("../async/Client.zig");

const parser = @import("../netsurf.zig");
const c = @cImport({
    @cInclude("events/event_target.h");
});

const log = std.log.scoped(.xhr);

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = generate.Tuple(.{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
    XMLHttpRequest,
    ProgressEvent,
    ProgressEventInit,
});

pub const XMLHttpRequestEventTarget = struct {
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{},

    onloadstart_cbk: ?Callback = null,
    onprogress_cbk: ?Callback = null,
    onabort_cbk: ?Callback = null,
    onload_cbk: ?Callback = null,
    ontimeout_cbk: ?Callback = null,
    onloadend_cbk: ?Callback = null,

    fn register(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, typ: []const u8, cbk: Callback) !void {
        try parser.eventTargetAddEventListener(@as(*parser.EventTarget, @ptrCast(self)), alloc, typ, cbk, false);
    }
    fn unregister(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, typ: []const u8, cbk: Callback) !void {
        const et = @as(*parser.EventTarget, @ptrCast(self));
        // check if event target has already this listener
        const lst = try parser.eventTargetHasListener(et, typ, false, cbk.id());
        if (lst == null) {
            return;
        }

        // remove listener
        try parser.eventTargetRemoveEventListener(et, alloc, typ, lst.?, false);
    }

    pub fn get_onloadstart(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onloadstart_cbk;
    }
    pub fn get_onprogress(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onprogress_cbk;
    }
    pub fn get_onabort(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onabort_cbk;
    }
    pub fn get_onload(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onload_cbk;
    }
    pub fn get_ontimeout(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.ontimeout_cbk;
    }
    pub fn get_onloadend(self: *XMLHttpRequestEventTarget) ?Callback {
        return self.onloadend_cbk;
    }

    pub fn set_onloadstart(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onloadstart_cbk) |cbk| try self.unregister(alloc, "loadstart", cbk);
        try self.register(alloc, "loadstart", handler);
        self.onloadstart_cbk = handler;
    }
    pub fn set_onprogress(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onprogress_cbk) |cbk| try self.unregister(alloc, "progress", cbk);
        try self.register(alloc, "progress", handler);
        self.onprogress_cbk = handler;
    }
    pub fn set_onabort(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onabort_cbk) |cbk| try self.unregister(alloc, "abort", cbk);
        try self.register(alloc, "abort", handler);
        self.onabort_cbk = handler;
    }
    pub fn set_onload(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onload_cbk) |cbk| try self.unregister(alloc, "load", cbk);
        try self.register(alloc, "load", handler);
        self.onload_cbk = handler;
    }
    pub fn set_ontimeout(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.ontimeout_cbk) |cbk| try self.unregister(alloc, "timeout", cbk);
        try self.register(alloc, "timeout", handler);
        self.ontimeout_cbk = handler;
    }
    pub fn set_onloadend(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator, handler: Callback) !void {
        if (self.onloadend_cbk) |cbk| try self.unregister(alloc, "loadend", cbk);
        try self.register(alloc, "loadend", handler);
        self.onloadend_cbk = handler;
    }

    pub fn deinit(self: *XMLHttpRequestEventTarget, alloc: std.mem.Allocator) void {
        parser.eventTargetRemoveAllEventListeners(@as(*parser.EventTarget, @ptrCast(self)), alloc) catch |e| {
            log.err("remove all listeners: {any}", .{e});
        };
    }
};

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
};

pub const ProgressEventInit = struct {
    pub const mem_guarantied = true;

    lengthComputable: bool = false,
    loaded: u64 = 0,
    total: u64 = 0,
};

pub const ProgressEvent = struct {
    pub const prototype = *Event;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    proto: parser.Event,
    lengthComputable: bool,
    loaded: u64 = 0,
    total: u64 = 0,

    pub fn constructor(eventType: []const u8, opts: ProgressEventInit) !ProgressEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, eventType, .{});

        return .{
            .proto = event.*,
            .lengthComputable = opts.lengthComputable,
            .loaded = opts.loaded,
            .total = opts.total,
        };
    }

    pub fn get_lengthComputable(self: ProgressEvent) bool {
        return self.lengthComputable;
    }

    pub fn get_loaded(self: ProgressEvent) u64 {
        return self.loaded;
    }

    pub fn get_total(self: ProgressEvent) u64 {
        return self.total;
    }
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

    const PrivState = enum { new, open, send, finish, wait, done };

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
    alloc: std.mem.Allocator,
    cli: Client,
    impl: YieldImpl,

    priv_state: PrivState = .new,
    req: ?Client.Request = null,

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
    response_status: u10 = 0,
    send_flag: bool = false,

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !XMLHttpRequest {
        return .{
            .alloc = alloc,
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

        if (self.req) |*r| r.deinit();
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
        self.response_status = 0;

        self.response_type = .Empty;
        if (self.response_bytes) |v| alloc.free(v);

        self.state = OPENED;
        self.priv_state = .new;
        if (self.req) |*r| {
            r.deinit();
            self.req = null;
        }

        self.dispatchEvt("readystatechange");
    }

    // dispatch request event.
    // errors are logged only.
    fn dispatchEvt(self: *XMLHttpRequest, typ: []const u8) void {
        const evt = parser.eventCreate() catch |e| {
            return log.err("dispatch event create: {any}", .{e});
        };
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
        opts: ProgressEventInit,
    ) void {
        // TODO destroy struct
        const evt = self.alloc.create(ProgressEvent) catch |e| {
            return log.err("allocate progress event: {any}", .{e});
        };
        evt.* = ProgressEvent.constructor(typ, .{
            // https://xhr.spec.whatwg.org/#firing-events-using-the-progressevent-interface
            .lengthComputable = opts.total > 0,
            .total = opts.total,
            .loaded = opts.loaded,
        }) catch |e| {
            return log.err("construct progress event: {any}", .{e});
        };
        _ = parser.eventTargetDispatchEvent(
            @as(*parser.EventTarget, @ptrCast(self)),
            @as(*parser.Event, @ptrCast(evt)),
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

    // onYield is a callback called between each request's steps.
    // Between each step, the code is blocking.
    // Yielding allows pseudo-async and gives a chance to other async process
    // to be called.
    pub fn onYield(self: *XMLHttpRequest, err: ?anyerror) void {
        if (err) |e| return self.onerr(e);

        switch (self.priv_state) {
            .new => {
                self.priv_state = .open;
                self.req = self.cli.open(self.method, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
            },
            .open => {
                self.priv_state = .send;
                self.req.?.send(.{}) catch |e| return self.onerr(e);
            },
            .send => {
                self.priv_state = .finish;
                self.req.?.finish() catch |e| return self.onerr(e);
            },
            .finish => {
                self.priv_state = .wait;
                self.req.?.wait() catch |e| return self.onerr(e);
            },
            .wait => {
                self.priv_state = .done;
                self.response_headers = self.req.?.response.headers.clone(self.response_headers.allocator) catch |e| return self.onerr(e);

                self.state = HEADERS_RECEIVED;
                self.dispatchEvt("readystatechange");

                self.response_status = @intFromEnum(self.req.?.response.status);

                var buf: std.ArrayListUnmanaged(u8) = .{};

                // TODO set correct length
                const total = 0;
                var loaded: u64 = 0;

                // dispatch a progress event loadstart.
                self.dispatchProgressEvent("loadstart", .{ .loaded = loaded, .total = total });

                const reader = self.req.?.reader();
                var buffer: [1024]u8 = undefined;
                var ln = buffer.len;
                while (ln > 0) {
                    ln = reader.read(&buffer) catch |e| {
                        buf.deinit(self.alloc);
                        return self.onerr(e);
                    };
                    buf.appendSlice(self.alloc, buffer[0..ln]) catch |e| {
                        buf.deinit(self.alloc);
                        return self.onerr(e);
                    };
                    loaded = loaded + ln;

                    // TODO dispatch only if 50ms have passed.

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
                self.dispatchEvt("load");
                self.dispatchProgressEvent("load", .{ .loaded = loaded, .total = total });
                // dispatch a progress event loadend.
                self.dispatchProgressEvent("loadend", .{ .loaded = loaded, .total = total });
            },
            .done => {
                if (self.req) |*r| {
                    r.deinit();
                    self.req = null;
                }

                // finalize fetch process.
                return;
            },
        }

        self.impl.yield(self);
    }

    fn onerr(self: *XMLHttpRequest, err: anyerror) void {
        self.priv_state = .done;
        if (self.req) |*r| {
            r.deinit();
            self.req = null;
        }

        self.err = err;
        self.state = DONE;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");
        self.dispatchProgressEvent("error", .{});
        self.dispatchProgressEvent("loadend", .{});
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
        .{ .src = "var nb = 0; function cbk(event) { nb ++; }", .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest()", .ex = "undefined" },

        .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; }" },
        // .{ .src = "req.onload", .ex = "function cbk(event) { nb ++; }" },
        .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; }" },

        .{ .src = "req.open('GET', 'https://w3.org')", .ex = "undefined" },
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
        .{ .src = "req.status", .ex = "200" },
        .{ .src = "req.statusText", .ex = "OK" },
        .{ .src = "req.getResponseHeader('Content-Type')", .ex = "text/html; charset=UTF-8" },
        .{ .src = "req.getAllResponseHeaders().length > 1024", .ex = "true" },
        .{ .src = "req.responseText.length > 1024", .ex = "true" },
    };
    try checkCases(js_env, &send);
}

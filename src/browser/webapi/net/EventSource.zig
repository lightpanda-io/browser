// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const URL = @import("../../URL.zig");
const Mime = @import("../../Mime.zig");
const Page = @import("../../Page.zig");
const Transfer = @import("../../../network/HttpClient.zig").Transfer;

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const MessageEvent = @import("../event/MessageEvent.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

// https://html.spec.whatwg.org/multipage/server-sent-events.html
const EventSource = @This();

_rc: lp.RC(u16) = .{},
_exec: *const Execution,
_proto: *EventTarget,
_arena: Allocator,

_url: [:0]const u8,
_with_credentials: bool = false,
_ready_state: ReadyState = .connecting,
_transfer: ?*Transfer = null,
_max_response_size: usize,

// Holds a self-reference from creation until close() / a failed connection
// / owner teardown. Guards the double-release in deactivate().
_active: bool = true,

// The committed "last event ID string": stamped on every message event and
// sent as the Last-Event-ID header on reconnects. A reused buffer — ids
// change on most events, one arena dupe per commit would grow forever.
_last_event_id: std.ArrayList(u8) = .empty,

_event_origin: []const u8 = "",

_reconnect_ms: u32 = 3000,

// Per-stream parser state, reset by connect().
_line_buf: std.ArrayList(u8) = .empty,
_data_buf: std.ArrayList(u8) = .empty,
_event_type_buf: std.ArrayList(u8) = .empty,

// The "last event ID buffer": committed to _last_event_id when an event
// block completes (even one that dispatches nothing).
_id_buf: std.ArrayList(u8) = .empty,

// if we ended on a CR, then we should skip a leading LF
_skip_lf: bool = false,

// A single leading BOM is stripped from the stream's first line.
_bom_checked: bool = false,

_on_open: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,

pub const ReadyState = enum(u8) {
    connecting = 0,
    open = 1,
    closed = 2,
};

const Opts = struct {
    withCredentials: bool = false,
};

pub fn init(url: []const u8, opts_: ?Opts, exec: *const Execution) !*EventSource {
    const arena = try exec.getArena(.medium, "EventSource");
    errdefer exec.releaseArena(arena);

    const resolved = URL.resolve(arena, exec.base(), url, .{ .encoding = exec.charset.* }) catch {
        return error.SyntaxError;
    };

    const self = try exec._factory.eventTargetWithAllocator(arena, EventSource{
        ._exec = exec,
        ._arena = arena,
        ._proto = undefined,
        ._url = resolved,
        ._with_credentials = if (opts_) |o| o.withCredentials else false,
        ._max_response_size = exec.session.browser.http_client.max_response_size,
    });

    // deactivate() releases it.
    self.acquireRef();

    if (comptime IS_DEBUG) {
        log.debug(.http, "EventSource connecting", .{ .url = resolved });
    }

    if (std.ascii.startsWithIgnoreCase(url, "http://") == false and std.ascii.startsWithIgnoreCase(url, "https://") == false) {
        try self.scheduleTask(failConnection, 0, "EventSource.fail");
        return self;
    }

    self.connect() catch |err| {
        log.info(.http, "EventSource connect", .{ .err = err });
        try self.scheduleTask(failConnection, 0, "EventSource.fail");
    };
    return self;
}

pub fn deinit(self: *EventSource, page: *Page) void {
    self._ready_state = .closed;
    if (self._transfer) |transfer| {
        self._transfer = null;
        transfer.abort(error.Abort);
    }

    if (self._on_open) |func| {
        func.release();
    }
    if (self._on_message) |func| {
        func.release();
    }
    if (self._on_error) |func| {
        func.release();
    }

    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *EventSource, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *EventSource) void {
    self._rc.acquire();
}

fn asEventTarget(self: *EventSource) *EventTarget {
    return self._proto;
}

fn connect(self: *EventSource) !void {
    const exec = self._exec;
    const session = exec.session;
    const http_client = &session.browser.http_client;

    self._skip_lf = false;
    self._bom_checked = false;
    self._line_buf.clearRetainingCapacity();
    self._data_buf.clearRetainingCapacity();
    self._event_type_buf.clearRetainingCapacity();

    self._id_buf.clearRetainingCapacity();
    try self._id_buf.appendSlice(self._arena, self._last_event_id.items);

    var headers = try http_client.newHeaders();
    try headers.add("Accept: text/event-stream");
    try headers.add("Cache-Control: no-cache");
    if (self._last_event_id.items.len > 0) {
        // headers.add copies the value, so the local arena's lifetime is enough
        const header = try std.fmt.allocPrintSentinel(exec.local_arena, "Last-Event-ID: {s}", .{self._last_event_id.items}, 0);
        try headers.add(header);
    }

    const same_origin = exec.isSameOrigin(self._url);
    if (!same_origin) {
        // EventSource is a CORS request: cross-origin fetches carry the
        // document's origin ("null" for opaque origins, like Chrome).
        const origin = exec.origin() orelse "null";
        const header = try std.fmt.allocPrintSentinel(exec.local_arena, "Origin: {s}", .{origin}, 0);
        try headers.add(header);
    }
    try exec.headersForRequest(&headers);

    const cookie_support = self._with_credentials or same_origin;

    const transfer = try exec.newRequest(.{
        .ctx = self,
        .url = self._url,
        .method = .GET,
        .headers = headers,
        .frame_id = exec.frameId(),
        .loader_id = exec.loaderId(),
        .cookie_jar = if (cookie_support) &session.cookie_jar else null,
        .cookie_origin = exec.url.*,
        .resource_type = .eventsource,
        .streaming = true,
        .notification = session.notification,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    });

    self._transfer = transfer;

    // Failures inside submit are dispatched to httpErrorCallback.
    transfer.submit() catch {};
}

fn reconnectTask(self: *EventSource) void {
    if (self._ready_state != .connecting or self._transfer != null) {
        // closed while the timer was pending
        return;
    }
    self.connect() catch |err| {
        log.warn(.http, "EventSource reconnect", .{ .err = err, .url = self._url });
        self.failConnection();
    };
}

pub fn close(self: *EventSource) void {
    if (self._ready_state == .closed) {
        return;
    }
    self._ready_state = .closed;
    self.deactivate();
}

fn deactivate(self: *EventSource) void {
    if (!self._active) {
        return;
    }
    self._active = false;
    if (self._transfer) |transfer| {
        self._transfer = null;
        transfer.abort(error.Abort);
    }
    self.releaseRef(self._exec.page);
}

fn failConnection(self: *EventSource) void {
    if (self._ready_state == .closed) {
        return;
    }
    self._ready_state = .closed;
    self.dispatchEvent("error", self._on_error) catch |err| {
        log.err(.http, "EventSource error event", .{ .err = err, .url = self._url });
    };
    self.deactivate();
}

fn reestablish(self: *EventSource) void {
    if (self._ready_state == .closed) {
        return;
    }
    self._ready_state = .connecting;
    self.dispatchEvent("error", self._on_error) catch |err| {
        log.err(.http, "EventSource error event", .{ .err = err, .url = self._url });
    };
    // the error handler may have close()d us
    if (self._ready_state == .closed) {
        return;
    }
    self.scheduleTask(reconnectTask, self._reconnect_ms, "EventSource.reconnect") catch {
        self.failConnection();
    };
}

// runs the task while ensuring self is kept alive
fn scheduleTask(self: *EventSource, comptime task: fn (*EventSource) void, ms: u32, name: []const u8) !void {
    const Wrapper = struct {
        fn run(ctx: *anyopaque) anyerror!?u32 {
            const es: *EventSource = @ptrCast(@alignCast(ctx));
            defer es.releaseRef(es._exec.page);
            task(es);
            return null;
        }
        fn finalize(ctx: *anyopaque) void {
            // Scheduler teardown with the task still pending: the context is
            // going away. A source waiting on this task holds no transfer, so
            // no shutdown_callback will ever deactivate it — do it here (must
            // not run JS), then drop the task's own reference.
            const es: *EventSource = @ptrCast(@alignCast(ctx));
            es._ready_state = .closed;
            es.deactivate();
            es.releaseRef(es._exec.page);
        }
    };

    self.acquireRef();
    errdefer self.releaseRef(self._exec.page);
    try self._exec._scheduler.add(self, Wrapper.run, ms, .{
        .name = name,
        .finalizer = Wrapper.finalize,
    });
}

fn httpHeaderDoneCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *EventSource = @ptrCast(@alignCast(transfer.req.ctx));

    const status = transfer.responseStatus().?;
    const mime_ok = blk: {
        const ct = transfer.contentType() orelse break :blk false;
        const mime = Mime.parse(ct) catch break :blk false;
        break :blk mime.content_type == .text_event_stream;
    };

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "eventsource",
            .url = self._url,
            .status = status,
            .mime_ok = mime_ok,
        });
    }

    if (status != 200 or !mime_ok) {
        self.failConnection();
        return .abort;
    }

    if (!self._exec.isSameOrigin(self._url) and !self.corsAllowed(transfer)) {
        self.failConnection();
        return .abort;
    }

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    const final_url = try self._arena.dupeZ(u8, transfer.req.url);
    self._event_origin = (URL.getOrigin(self._arena, final_url) catch null) orelse "";

    // https://html.spec.whatwg.org/multipage/server-sent-events.html#announce-the-connection
    self._ready_state = .open;
    try self.dispatchEvent("open", self._on_open);
    return .proceed;
}

// The general http stack doesn't model CORS (fetch/XHR assume it passed),
// but the EventSource WPTs require enforcement, and it's self-contained
// enough to do here: the response must echo an acceptable
// Access-Control-Allow-Origin (plus Allow-Credentials for credentialed
// requests).
fn corsAllowed(self: *const EventSource, transfer: *Transfer) bool {
    var allow_origin: ?[]const u8 = null;
    var allow_credentials: ?[]const u8 = null;
    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
            allow_origin = hdr.value;
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-credentials")) {
            allow_credentials = hdr.value;
        }
    }

    const allowed = allow_origin orelse return false;
    if (std.mem.eql(u8, allowed, "*")) {
        // the wildcard is not valid for credentialed requests
        return !self._with_credentials;
    }
    const origin = self._exec.origin() orelse "null";
    if (!std.mem.eql(u8, allowed, origin)) {
        return false;
    }
    if (self._with_credentials) {
        const creds = allow_credentials orelse return false;
        return std.mem.eql(u8, creds, "true");
    }
    return true;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *EventSource = @ptrCast(@alignCast(transfer.req.ctx));
    try self.parse(data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *EventSource = @ptrCast(@alignCast(ctx));
    self._transfer = null;
    self.reestablish();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *EventSource = @ptrCast(@alignCast(ctx));
    self._transfer = null;
    if (self._ready_state == .closed) {
        // our own doing: close(), a failed connection's .abort, or teardown
        return;
    }
    log.info(.http, "request error", .{
        .source = "eventsource",
        .url = self._url,
        .err = err,
    });
    if (err == error.ResponseTooLarge) {
        // oversized batch, line or event: reconnecting would just download
        // the same stream again
        return self.failConnection();
    }
    self.reestablish();
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *EventSource = @ptrCast(@alignCast(ctx));
    self._transfer = null;
    self._ready_state = .closed;
    self.deactivate();
}

fn parse(self: *EventSource, chunk: []const u8) !void {
    var rest = chunk;

    // a CR ended the previous chunk; its LF partner may lead this one
    if (self._skip_lf and rest.len > 0) {
        self._skip_lf = false;
        if (rest[0] == '\n') {
            rest = rest[1..];
        }
    }

    while (rest.len > 0) {
        // lines end at CR, LF or CRLF
        const idx = std.mem.indexOfAny(u8, rest, "\r\n") orelse {
            // no terminator; hold the partial line for the next chunk
            return self.bufferLine(rest);
        };
        try self.bufferLine(rest[0..idx]);

        if (rest[idx] == '\r') {
            if (idx + 1 == rest.len) {
                // chunk ends on this CR; its LF partner may lead the next
                self._skip_lf = true;
                rest = rest[idx + 1 ..];
            } else {
                rest = rest[idx + @as(usize, if (rest[idx + 1] == '\n') 2 else 1) ..];
            }
        } else {
            rest = rest[idx + 1 ..];
        }
        try self.processLine();
    }
}

// HttpClient only enforces the max-response per buffered chunk. Now we're
// accumulating these chunks together.
fn bufferLine(self: *EventSource, bytes: []const u8) !void {
    if (self._line_buf.items.len + bytes.len > self._max_response_size) {
        return error.ResponseTooLarge;
    }
    return self._line_buf.appendSlice(self._arena, bytes);
}

fn processLine(self: *EventSource) !void {
    var line: []const u8 = self._line_buf.items;
    defer self._line_buf.clearRetainingCapacity();

    if (!self._bom_checked) {
        self._bom_checked = true;
        if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) {
            line = line[3..];
        }
    }

    if (line.len == 0) {
        return self.dispatchPending();
    }
    if (line[0] == ':') {
        // comment
        return;
    }

    var field = line;
    var value: []const u8 = "";
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        field = line[0..colon];
        value = line[colon + 1 ..];
        if (value.len > 0 and value[0] == ' ') {
            value = value[1..];
        }
    }

    const arena = self._arena;
    if (std.mem.eql(u8, field, "data")) {
        const add_len = value.len + 1;
        if (self._data_buf.items.len + add_len > self._max_response_size) {
            return error.ResponseTooLarge;
        }
        try self._data_buf.ensureUnusedCapacity(arena, add_len);
        self._data_buf.appendSliceAssumeCapacity(value);
        self._data_buf.appendAssumeCapacity('\n');
    }

    if (std.mem.eql(u8, field, "event")) {
        self._event_type_buf.clearRetainingCapacity();
        try self._event_type_buf.appendSlice(arena, value);
    }

    if (std.mem.eql(u8, field, "id")) {
        if (std.mem.indexOfScalar(u8, value, 0) == null) {
            self._id_buf.clearRetainingCapacity();
            try self._id_buf.appendSlice(arena, value);
        }
    }

    if (std.mem.eql(u8, field, "retry")) {
        if (std.fmt.parseInt(u32, value, 10)) |ms| {
            self._reconnect_ms = ms;
        } else |_| {}
    }
    // unknown fields are ignored
}

// An empty line completed an event block.
fn dispatchPending(self: *EventSource) !void {
    self._last_event_id.clearRetainingCapacity();
    try self._last_event_id.appendSlice(self._arena, self._id_buf.items);

    const data = self._data_buf.items;
    if (data.len == 0) {
        self._event_type_buf.clearRetainingCapacity();
        return;
    }

    defer {
        self._data_buf.clearRetainingCapacity();
        self._event_type_buf.clearRetainingCapacity();
    }

    // every data field appended a trailing newline; the last one is dropped
    const body = data[0 .. data.len - 1];
    const type_buf = self._event_type_buf.items;
    const is_message = type_buf.len == 0;

    const exec = self._exec;
    const target = self.asEventTarget();
    const handler: ?js.Function.Global = if (is_message) self._on_message else null;

    if (is_message) {
        if (!exec.hasDirectListeners(target, "message", handler)) {
            return;
        }
    } else if (!exec.hasDirectListeners(target, type_buf, handler)) {
        return;
    }

    const typ: String = if (is_message) comptime .wrap("message") else .wrap(type_buf);

    const event = try MessageEvent.initTrusted(typ, .{
        .data = .{ .string = body },
        .origin = self._event_origin,
        .lastEventId = self._last_event_id.items,
    }, exec.page);
    try exec.dispatch(target, event.asEvent(), handler, .{ .context = "EventSource message" });
}

fn dispatchEvent(self: *EventSource, comptime name: []const u8, handler: ?js.Function.Global) !void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (exec.hasDirectListeners(target, name, handler)) {
        const event = try Event.initTrusted(comptime .wrap(name), .{}, exec.page);
        try exec.dispatch(target, event, handler, .{ .context = "EventSource " ++ name });
    }
}

pub fn getUrl(self: *const EventSource) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *const EventSource) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getWithCredentials(self: *const EventSource) bool {
    return self._with_credentials;
}

pub fn getOnOpen(self: *const EventSource) ?js.Function.Global {
    return self._on_open;
}

pub fn setOnOpen(self: *EventSource, cb_: ?js.Function) !void {
    if (self._on_open) |old| {
        old.release();
    }
    self._on_open = if (cb_) |cb| try cb.persistWithThis(self) else null;
}

pub fn getOnMessage(self: *const EventSource) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *EventSource, cb_: ?js.Function) !void {
    if (self._on_message) |old| {
        old.release();
    }
    self._on_message = if (cb_) |cb| try cb.persistWithThis(self) else null;
}

pub fn getOnError(self: *const EventSource) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *EventSource, cb_: ?js.Function) !void {
    if (self._on_error) |old| {
        old.release();
    }
    self._on_error = if (cb_) |cb| try cb.persistWithThis(self) else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventSource);

    pub const Meta = struct {
        pub const name = "EventSource";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(EventSource.init, .{});

    pub const CONNECTING = bridge.property(@intFromEnum(ReadyState.connecting), .{ .template = true });
    pub const OPEN = bridge.property(@intFromEnum(ReadyState.open), .{ .template = true });
    pub const CLOSED = bridge.property(@intFromEnum(ReadyState.closed), .{ .template = true });

    pub const url = bridge.accessor(EventSource.getUrl, null, .{});
    pub const readyState = bridge.accessor(EventSource.getReadyState, null, .{});
    pub const withCredentials = bridge.accessor(EventSource.getWithCredentials, null, .{});

    pub const onopen = bridge.accessor(EventSource.getOnOpen, EventSource.setOnOpen, .{});
    pub const onmessage = bridge.accessor(EventSource.getOnMessage, EventSource.setOnMessage, .{});
    pub const onerror = bridge.accessor(EventSource.getOnError, EventSource.setOnError, .{});

    pub const close = bridge.function(EventSource.close, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: EventSource" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("net/eventsource.html", .{});
}

test "WebApi: EventSource in worker" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("net/eventsource_worker.html", .{});
}

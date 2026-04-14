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

const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const http = @import("../../network/http.zig");

const URL = @import("../URL.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");
const HttpClient = @import("../HttpClient.zig");

const Blob = @import("Blob.zig");
const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Worker = @This();

// used by HttpClient when generating notification
// Ultimately used by CDP to generate request/loader ids.
id: u32,
_pseudo_frame_id: u32,

_proto: *EventTarget,
_page: *Page,
_arena: Allocator,
_worker_scope: *WorkerGlobalScope,

_url: [:0]const u8,
_script_loaded: bool = false,
_script_buffer: std.ArrayList(u8) = .empty,
_http_response: ?HttpClient.Response = null,

// Event handlers
_on_error: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_messageerror: ?js.Function.Global = null,

pub fn init(url: []const u8, exec: *Execution) !*Worker {
    const page = switch (exec.context.global) {
        .page => |p| p,
        .worker => return error.WorkerCannotCreateWorker,
    };
    const session = page._session;

    const arena = try session.getArena(.large, "Worker");
    errdefer session.releaseArena(arena);

    const resolved_url = try URL.resolve(arena, exec.url.*, url, .{});
    const self = try session.factory.eventTargetWithAllocator(arena, Worker{
        .id = session.nextPageId(),
        ._pseudo_frame_id = session.nextFrameId(),
        ._arena = arena,
        ._proto = undefined,
        ._page = page,
        ._url = resolved_url,
        ._worker_scope = undefined,
    });
    self._worker_scope = try WorkerGlobalScope.init(self, resolved_url);
    errdefer self._worker_scope.deinit();
    try page.trackWorker(self);

    if (std.mem.startsWith(u8, url, "blob:")) {
        errdefer page.removeWorker(self);
        const blob: *Blob = page.lookupBlobUrl(url) orelse {
            log.warn(.js, "invalid blob", .{ .target = "worker" });
            return error.BlobNotFound;
        };
        try self.loadInitialScript(blob._slice);
        return self;
    }

    const http_client = session.browser.http_client;
    http_client.request(.{
        .ctx = self,
        .url = resolved_url,
        .method = .GET,
        .headers = try http_client.newHeaders(),
        .page_id = self.id,
        .frame_id = self._pseudo_frame_id,
        .resource_type = .script,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = resolved_url,
        .notification = session.notification,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
    }) catch |err| {
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        page.removeWorker(self);
        return err;
    };
    return self;
}

// Called from Page.deinit when the page is destroyed, so we don't need to
// remove from the page's worker list.
pub fn deinit(self: *Worker) void {
    if (self._http_response) |res| {
        res.abort(error.Abort);
        self._http_response = null;
    }
    self._worker_scope.deinit();
    self._page._session.releaseArena(self._arena);
}

pub fn asEventTarget(self: *Worker) *EventTarget {
    return self._proto;
}

fn httpHeaderCallback(response: HttpClient.Response) !bool {
    const self: *Worker = @ptrCast(@alignCast(response.ctx));

    const status = response.status() orelse return false;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "Worker status", .{
            .url = self._url,
            .status = status,
        });
        return false;
    }

    self._http_response = response;
    if (response.contentLength()) |cl| {
        try self._script_buffer.ensureTotalCapacity(self._arena, cl);
    }

    return true;
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *Worker = @ptrCast(@alignCast(response.ctx));
    try self._script_buffer.appendSlice(self._arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self._script_loaded = true;

    const url = self._url;
    const script = self._script_buffer.items;

    if (comptime IS_DEBUG) {
        log.info(.browser, "worker fetch done", .{
            .url = url,
            .len = script.len,
        });
    }

    try self.loadInitialScript(script);
}

fn loadInitialScript(self: *Worker, script: []const u8) !void {
    var ls: js.Local.Scope = undefined;
    self._worker_scope.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = ls.local.eval(script, self._url) catch |err| {
        const caught = try_catch.caughtOrError(self._arena, err);
        log.err(.browser, "worker script error", .{ .url = self._url, .caught = caught });
        self.fireErrorEvent(caught.exception orelse @errorName(err), null);
        return;
    };

    ls.local.runMacrotasks();
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_response = null;

    log.err(.browser, "worker fetch error", .{
        .url = self._worker_scope.url,
        .err = err,
    });

    self.fireErrorEvent(@errorName(err), null);
}

// Fire an error event on the Worker object (parent context)
fn fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Temp) void {
    self._fireErrorEvent(message, error_value) catch |err| {
        log.warn(.browser, "worker fire error", .{ .err = err, .message = message });
    };
}

fn _fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Temp) !void {
    const page = self._page;
    const session = page._session;
    const target = self.asEventTarget();
    const on_error = self._on_error;

    // Check if there are any listeners
    if (!page._event_manager.hasDirectListeners(target, "error", on_error)) {
        if (error_value) |ev| ev.release();
        return;
    }

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = error_value,
        .message = message,
        .filename = self._url,
        .bubbles = false,
        .cancelable = true,
    }, session);

    try page._event_manager.dispatchDirect(target, error_event.asEvent(), on_error, .{
        .context = "Worker.onerror",
    });
}

pub fn terminate(self: *Worker) void {
    // Abort any pending script fetch
    if (self._http_response) |resp| {
        resp.abort(error.Abort);
        self._http_response = null;
    }
}

// Posts a message from the page to the worker.
pub fn postMessage(self: *Worker, data: js.Value) !void {
    try self._worker_scope.receiveMessage(data);
}

// Called internally by WorkerGlobalScope when it wants to post a message to us
pub fn receiveMessage(self: *Worker, data: js.Value) !void {
    const page = self._page;
    const cloned_data = blk: {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker context) to our Page's context
        const cloned = data.structuredCloneTo(&ls.local) catch |err| break :blk err;
        break :blk cloned.temp();
    };

    const message_arena = try page.getArena(.tiny, "Worker.receiveMessage");
    errdefer page.releaseArena(message_arena);

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .worker = self,
        .data = cloned_data,
        .arena = message_arena,
    };

    try page.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "Worker.receiveMessage",
        .low_priority = false,
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

pub fn getOnMessage(self: *const Worker) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *Worker, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

pub fn getOnMessageError(self: *const Worker) ?js.Function.Global {
    return self._on_messageerror;
}

pub fn setOnMessageError(self: *Worker, setter: ?FunctionSetter) void {
    self._on_messageerror = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const Worker) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Worker, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

const ReceiveMessageCallback = struct {
    data: anyerror!js.Value.Temp,
    arena: Allocator,
    worker: *Worker,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        } else |_| {}
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.worker._page._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker = self.worker;
        const page = worker._page;
        const target = worker.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        const data = self.data catch |err| {
            const on_messageerror = worker._on_messageerror;
            if (!page._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .data = .{ .string = @errorName(err) },
                .bubbles = false,
                .cancelable = false,
            }, page._session)).asEvent();
            try page._event_manager.dispatchDirect(target, event, on_messageerror, .{ .context = "Worker.messageerror" });
            return null;
        };

        const on_message = worker._on_message;

        // Check if there are any listeners before creating the event
        if (!page._event_manager.hasDirectListeners(target, "message", on_message)) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .bubbles = false,
            .cancelable = false,
        }, page._session)).asEvent();

        try page._event_manager.dispatchDirect(target, event, on_message, .{ .context = "Worker.receiveMessage" });

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Worker);

    pub const Meta = struct {
        pub const name = "Worker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Worker.init, .{});

    pub const terminate = bridge.function(Worker.terminate, .{});
    pub const postMessage = bridge.function(Worker.postMessage, .{});

    pub const onmessage = bridge.accessor(Worker.getOnMessage, Worker.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(Worker.getOnMessageError, Worker.setOnMessageError, .{});
    pub const onerror = bridge.accessor(Worker.getOnError, Worker.setOnError, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Worker" {
    try testing.htmlRunner("worker", .{});
}

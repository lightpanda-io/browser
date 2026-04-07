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

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Worker = @This();

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

    const arena = try session.getArena(.{ .debug = "Worker" });
    errdefer session.releaseArena(arena);

    // Resolve URL relative to current context
    const resolved_url = try URL.resolve(arena, exec.url.*, url, .{});

    const self = try session.factory.eventTargetWithAllocator(arena, Worker{
        ._arena = arena,
        ._proto = undefined,
        ._page = page,
        ._url = resolved_url,
        ._worker_scope = undefined,
    });
    self._worker_scope = try WorkerGlobalScope.init(self, resolved_url);
    errdefer self._worker_scope.deinit();

    try page.trackWorker(self);

    const http_client = session.browser.http_client;
    http_client.request(.{
        .ctx = self,
        .url = resolved_url,
        .method = .GET,
        .headers = try http_client.newHeaders(),
        .frame_id = 0, // Workers don't belong to frames
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

    var ls: js.Local.Scope = undefined;
    self._worker_scope.js.localScope(&ls);
    defer ls.deinit();

    _ = ls.local.eval(script, url) catch |err| {
        log.err(.browser, "worker script error", .{ .url = url, .err = err });
        // TODO: Fire error event on Worker
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

    // TODO: Fire error event on Worker
}

pub fn terminate(self: *Worker) void {
    // Abort any pending script fetch
    if (self._http_response) |resp| {
        resp.abort(error.Abort);
        self._http_response = null;
    }

    self._page.removeWorker(self);
}

// Posts a message from the page to the worker.
pub fn postMessage(self: *Worker, data: js.Value) !void {
    try self._worker_scope.receiveMessage(data);
}

// Called internally by WorkerGlobalScope when it wants to post a message to use
pub fn receiveMessage(self: *Worker, data: js.Value) !void {
    const page = self._page;
    const cloned_data = blk: {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker context) to our Page's context
        const cloned = try data.structuredCloneTo(&ls.local);
        break :blk try cloned.temp();
    };
    errdefer cloned_data.release();

    const message_arena = try page.getArena(.{ .debug = "Worker.receiveMessage" });
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
    data: js.Value.Temp,
    arena: Allocator,
    worker: *Worker,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        self.data.release();
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
        const on_message = worker._on_message;

        // Check if there are any listeners before creating the event
        if (!page._event_manager.hasDirectListeners(target, "message", on_message)) {
            self.data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data },
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

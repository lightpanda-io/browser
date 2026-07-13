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

const js = @import("../js/js.zig");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Transfer = @import("../../network/HttpClient.zig").Transfer;

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Worker = @This();

pub const WorkerType = enum {
    classic,
    module,
    pub const js_enum_from_string = true;
};

// used by HttpClient when generating notification
// Ultimately used by CDP to generate request/loader ids.
_frame_id: u32,
_loader_id: u32,

_proto: *EventTarget,
_frame: *Frame,
_arena: Allocator,
_worker_scope: *DedicatedWorkerGlobalScope,

_url: [:0]const u8,
_type: WorkerType = .classic,
_script_loaded: bool = false,
_script_buffer: std.ArrayList(u8) = .empty,
_http_transfer: ?*Transfer = null,

// Event handlers
_on_error: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_messageerror: ?js.Function.Global = null,

const WorkerOptions = struct {
    type: WorkerType = .classic,
};

pub fn init(url: []const u8, options: ?WorkerOptions, frame: *Frame) !*Worker {
    const session = frame._session;

    const arena = try session.getArena(.large, "Worker");
    errdefer session.releaseArena(arena);

    const resolved_url = try URL.resolve(arena, frame.base(), url, .{ .encoding = frame.charset });
    const self = try frame._page.factory.eventTargetWithAllocator(arena, Worker{
        ._arena = arena,
        ._proto = undefined,
        ._frame = frame,
        ._url = resolved_url,
        ._type = if (options) |o| o.type else .classic,
        ._worker_scope = undefined,
        ._frame_id = session.nextFrameId(),
        ._loader_id = session.nextLoaderId(),
    });
    const dedicated_worker = try DedicatedWorkerGlobalScope.init(self, resolved_url);
    errdefer dedicated_worker.deinit();

    self._worker_scope = dedicated_worker;
    try frame.trackWorker(self);

    // `--disable-workers` (or `LP.configureLoading { worker: false }`):
    // skip the script fetch and eval. The Worker object is still
    // constructed so JS `new Worker(url)` does not throw, but the
    // worker's eval never runs (postMessage from the page is queued
    // indefinitely with no handler to drain it). Mirrors the
    // `subframe_loading_enabled` pattern for iframes.
    if (!session.worker_loading_enabled) {
        log.debug(.browser, "worker disabled", .{ .url = resolved_url });
        return self;
    }

    const transfer = frame.newRequest(.{
        .ctx = self,
        .method = .GET,
        .url = resolved_url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .resource_type = .script,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = resolved_url,
        .notification = session.notification,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        frame.removeWorker(self);
        return err;
    };

    // Held for deinit's abort; the done, error and shutdown callbacks clear
    // it. The shutdown one matters: Frame.deinit's abortOwner kills the
    // transfer before it deinits this worker, and deinit must not abort a
    // freed transfer.
    self._http_transfer = transfer;

    transfer.submit() catch |err| {
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        frame.removeWorker(self);
        return err;
    };
    return self;
}

// Called from Frame.deinit when the frame is destroyed, so we don't need to
// remove from the frame's worker list.
pub fn deinit(self: *Worker) void {
    // No pending frame for workers, so we can abort all frames.
    if (self._http_transfer) |res| {
        res.abort(error.Abort);
        self._http_transfer = null;
    }
    self._worker_scope.deinit();
    self._frame._session.releaseArena(self._arena);
}

pub fn asEventTarget(self: *Worker) *EventTarget {
    return self._proto;
}

fn httpHeaderCallback(transfer: *Transfer) !Transfer.HeaderResult {
    const self: *Worker = @ptrCast(@alignCast(transfer.req.ctx));

    const status = transfer.responseStatus() orelse return .abort;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "Worker status", .{
            .url = self._url,
            .status = status,
        });
        return .abort;
    }

    if (transfer.getContentLength()) |cl| {
        try self._script_buffer.ensureTotalCapacity(self._arena, cl);
    }

    return .proceed;
}

fn httpDataCallback(transfer: *Transfer, data: []const u8) !void {
    const self: *Worker = @ptrCast(@alignCast(transfer.req.ctx));
    try self._script_buffer.appendSlice(self._arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;

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
    const js_context = self._worker_scope._proto.js;

    if (js_context.env.terminatePending()) {
        return;
    }

    // Keep buffering throughout the entire outer eval (including any
    // runMacrotasks pumped by importScripts via the synchronous CDP path,
    // see WorkerGlobalScope.importScripts). The flip-and-drain happens
    // via defer so it runs after eval AND after the trailing
    // runMacrotasks below — by which point the outer script has had its
    // only chance to register onmessage. drainPendingMessages enqueues
    // messages in receive order, so pre-eval and during-eval messages
    // are delivered FIFO on the next runner tick, matching the spec.
    //
    // On eval-throw the defer still fires; the messages get scheduled
    // and then drop at the "no listener" check, mirroring the
    // httpErrorCallback path.
    defer {
        self._script_loaded = true;
        self._worker_scope.drainPendingMessages();
    }

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Classic workers evaluate the entry script as a classic script; module
    // workers (`new Worker(url, { type: "module" })`) instantiate it as a
    // module so top-level `import`/`export` work. Static imports load
    // synchronously through ScriptManagerBase (client.tick sync_wait).
    switch (self._type) {
        .classic => _ = ls.local.eval(script, self._url) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            const caught = try_catch.caughtOrError(self._arena, err);
            log.err(.browser, "worker script error", .{ .url = self._url, .caught = caught });
            self.fireErrorEvent(caught.exception orelse @errorName(err), null);
            return;
        },
        .module => js_context.module(false, &ls.local, script, self._url, true) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            const caught = try_catch.caughtOrError(self._arena, err);
            log.err(.browser, "worker module error", .{ .url = self._url, .caught = caught });
            self.fireErrorEvent(caught.exception orelse @errorName(err), null);
            return;
        },
    }

    ls.local.runMacrotasks();
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_transfer = null;

    log.err(.browser, "worker fetch error", .{
        .url = self._url,
        .err = err,
    });

    // The worker will never load and onmessage will never be registered.
    // Drain any buffered messages so they get dispatched (and silently
    // dropped at the "no listener" check) rather than accumulating until
    // worker teardown. Future postMessages then schedule normally.
    self._script_loaded = true;
    self._worker_scope.drainPendingMessages();

    self.fireErrorEvent(@errorName(err), null);
}

// Fire an error event on the Worker object (parent context)
fn fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Global) void {
    self._fireErrorEvent(message, error_value) catch |err| {
        log.warn(.browser, "worker fire error", .{ .err = err, .message = message });
    };
}

fn _fireErrorEvent(self: *Worker, message: []const u8, error_value: ?js.Value.Global) !void {
    const frame = self._frame;
    const target = self.asEventTarget();
    const on_error = self._on_error;

    // Check if there are any listeners
    if (!frame._event_manager.hasDirectListeners(target, "error", on_error)) {
        if (error_value) |ev| ev.release();
        return;
    }

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = error_value,
        .message = message,
        .filename = self._url,
        .bubbles = false,
        .cancelable = true,
    }, frame._page);

    try frame._event_manager.dispatchDirect(target, error_event.asEvent(), on_error, .{
        .context = "Worker.onerror",
    });
}

pub fn terminate(self: *Worker) void {
    // Abort any pending script fetch
    if (self._http_transfer) |resp| {
        resp.abort(error.Abort);
        self._http_transfer = null;
    }
}

// Posts a message from the frame to the worker.
pub fn postMessage(self: *Worker, data: js.Value) !void {
    try self._worker_scope.receiveMessage(data);
}

// Called internally by DedicatedWorkerGlobalScope when it wants to post a message to us
pub fn receiveMessage(self: *Worker, data: js.Value) !void {
    const frame = self._frame;
    const cloned_data = blk: {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker context) to our Page's context
        const cloned = data.structuredCloneTo(&ls.local) catch |err| break :blk err;
        break :blk cloned.persist();
    };

    const message_arena = try frame.getArena(.tiny, "Worker.receiveMessage");
    errdefer frame.releaseArena(message_arena);

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .worker = self,
        .data = cloned_data,
        .arena = message_arena,
    };

    try frame.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
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
    data: anyerror!js.Value.Global,
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
        self.worker._frame._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker = self.worker;
        const frame = worker._frame;
        const target = worker.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        const data = self.data catch |err| {
            const on_messageerror = worker._on_messageerror;
            if (!frame._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .data = .{ .string = @errorName(err) },
                .bubbles = false,
                .cancelable = false,
            }, frame._page)).asEvent();
            try frame._event_manager.dispatchDirect(target, event, on_messageerror, .{ .context = "Worker.messageerror" });
            return null;
        };

        const on_message = worker._on_message;

        // Check if there are any listeners before creating the event
        if (!frame._event_manager.hasDirectListeners(target, "message", on_message)) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .bubbles = false,
            .cancelable = false,
        }, frame._page)).asEvent();

        try frame._event_manager.dispatchDirect(target, event, on_message, .{ .context = "Worker.receiveMessage" });

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
    // Worker tests chain a worker-script fetch with a dynamic-import fetch
    // and a cross-context postMessage. The default 2 s assertion budget can
    // blow up on TSAN CI; give it more room.
    try testing.htmlRunner("worker", .{ .timeout_ms = 8000 });
}

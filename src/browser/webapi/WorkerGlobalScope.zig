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

// The struct is like a mix of Page and Window, but a very limited Page and
// a very limited Window. This dual-purpose does make it a bit harder to know
// what's what...e.g what is a WebAPI call and what it called internally.

const std = @import("std");
const lp = @import("lightpanda");

const JS = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Factory = @import("../Factory.zig");
const Session = @import("../Session.zig");
const EventManagerBase = @import("../EventManagerBase.zig");
const ScriptManagerBase = @import("../ScriptManagerBase.zig");

const Blob = @import("Blob.zig");
const Worker = @import("Worker.zig");
const Crypto = @import("Crypto.zig");
const Console = @import("Console.zig");
const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");

const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;

const log = lp.log;
const Allocator = std.mem.Allocator;

const WorkerGlobalScope = @This();

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_session: *Session,
_page: *Page,
_factory: *Factory,
_identity: JS.Identity = .{},
arena: Allocator,
call_arena: Allocator,
url: [:0]const u8,
// Same-origin constraint: a worker's origin is inherited from its parent frame.
origin: ?[]const u8 = null,
buf: [1024]u8 = undefined, // same size as frame.buf
// Document charset (matches Page.charset). Workers default to UTF-8.
charset: []const u8 = "UTF-8",
js: *JS.Context,

// Blob URL registry for URL.createObjectURL/revokeObjectURL.
_blob_urls: std.StringHashMapUnmanaged(*Blob) = .{},

// Reference back to the Worker object (for postMessage to frame)
_worker: *Worker,

// Event management for non-DOM targets in worker context
_event_manager: EventManagerBase,

// Handles module imports (static + dynamic). No parser integration since
// workers don't have <script> tags.
_script_manager: ScriptManagerBase,

// These fields represent the "Window"-like component of the WGS
_closed: bool = false,
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_on_message: ?JS.Function.Global = null,
_on_messageerror: ?JS.Function.Global = null,

pub fn init(worker: *Worker, url: [:0]const u8) !*WorkerGlobalScope {
    const arena = worker._arena;
    const parent = worker._frame;
    const session = worker._frame._session;

    const call_arena = try session.getArena(.small, "WorkerGlobalScope.call_arena");
    errdefer session.releaseArena(call_arena);

    const factory = parent._factory;
    const self = try factory.eventTargetWithAllocator(arena, WorkerGlobalScope{
        .url = url,
        .arena = arena,
        .origin = parent.origin,
        .js = undefined,
        .call_arena = call_arena,
        ._session = session,
        ._page = parent._page,
        ._identity = .{},
        ._proto = undefined,
        ._factory = factory,
        ._worker = worker,
        ._event_manager = .init(arena),
        ._script_manager = undefined,
    });
    errdefer factory.destroy(self);

    self._script_manager = ScriptManagerBase.init(
        arena,
        session.browser.http_client,
        .{ .worker = self },
    );

    self.js = try session.browser.env.createWorkerContext(self, .{
        .call_arena = call_arena,
        .identity_arena = arena,
        .identity = &self._identity,
    });

    return self;
}

pub fn deinit(self: *WorkerGlobalScope) void {
    self._identity.deinit();
    self._script_manager.deinit();

    const page = self._page;
    var it = self._blob_urls.valueIterator();
    while (it.next()) |blob| {
        blob.*.releaseRef(page);
    }
    page.session.browser.env.destroyContext(self.js);
    page.releaseArena(self.call_arena);
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

const Event = @import("Event.zig");

// Dispatch an event to listeners on the given target within this worker context.
pub fn dispatch(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    try self._event_manager.dispatchDirect(
        self.call_arena,
        self.js,
        target,
        event,
        handler,
        self._page,
        opts,
    );
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getOnError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn getOnMessage(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

pub fn getOnMessageError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_messageerror;
}

pub fn setOnMessageError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_messageerror = getFunctionFromSetter(setter);
}

// Posts a message from the worker back to the frame.
// The message is cloned via structured clone and dispatched on the Worker object.
pub fn postMessage(self: *WorkerGlobalScope, data: JS.Value) !void {
    try self._worker.receiveMessage(data);
}

// Called internally by Worker when it wants to post a message to us
pub fn receiveMessage(self: *WorkerGlobalScope, data: JS.Value) !void {
    if (self._closed) {
        return;
    }

    const cloned_data: ?JS.Value.Temp = blk: {
        // Enter our context to clone the message
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker's Page context) to our Context
        const cloned = data.structuredCloneTo(&ls.local) catch break :blk null;
        break :blk cloned.temp() catch break :blk null;
    };

    const session = self._session;

    const message_arena = try session.getArena(.tiny, "WorkerGlobalScope.receiveMessage");
    errdefer session.releaseArena(message_arena);

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .worker_scope = self,
        .arena = message_arena,
    };

    try self.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "WorkerGlobalScope.receiveMessage",
        .low_priority = false,
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

pub fn btoa(_: *const WorkerGlobalScope, input: []const u8, exec: *JS.Execution) ![]const u8 {
    const base64 = @import("encoding/base64.zig");
    return base64.encode(exec.call_arena, input);
}

pub fn atob(_: *const WorkerGlobalScope, input: []const u8, exec: *JS.Execution) ![]const u8 {
    const base64 = @import("encoding/base64.zig");
    return base64.decode(exec.call_arena, input);
}

pub fn structuredClone(_: *const WorkerGlobalScope, value: JS.Value) !JS.Value {
    return value.structuredClone();
}

pub fn unhandledPromiseRejection(self: *WorkerGlobalScope, no_handler: bool, rejection: JS.PromiseRejection) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "worker",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (self._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (rejection.reason()) |r| try r.temp() else null,
            .promise = try rejection.promise().temp(),
        }, self._page)).asEvent();
        try self.dispatch(target, event, attribute_callback, .{});
    }
}

pub fn close(self: *WorkerGlobalScope) void {
    // TOOD: we should also stop new tasks from being scheduled
    self.js.scheduler.reset();
    self._closed = true;
}

pub fn reportError(self: *WorkerGlobalScope, err: JS.Value) !void {
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.temp(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, self._page);

    // Invoke onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = local_func.call(JS.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }) catch null;

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try self.dispatch(self.asEventTarget(), event, null, .{});

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "worker.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

// TODO: importScripts - needs script loading infrastructure
// TODO: location - needs WorkerLocation
// TODO: navigator - needs WorkerNavigator
// TODO: Timer functions - need scheduler integration

const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

const ReceiveMessageCallback = struct {
    data: ?JS.Value.Temp,
    arena: Allocator,
    worker_scope: *WorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| d.release();
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.worker_scope._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker_scope = self.worker_scope;
        const target = worker_scope.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        if (self.data == null) {
            const on_messageerror = worker_scope._on_messageerror;
            if (!worker_scope._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .bubbles = false,
                .cancelable = false,
            }, worker_scope._page)).asEvent();
            try worker_scope.dispatch(target, event, on_messageerror, .{});
            return null;
        }

        const on_message = worker_scope._on_message;

        // Check if there are any listeners before creating the event
        if (!worker_scope._event_manager.hasDirectListeners(target, "message", on_message)) {
            self.data.?.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data.? },
            .bubbles = false,
            .cancelable = false,
        }, worker_scope._page)).asEvent();
        try worker_scope.dispatch(target, event, on_message, .{});
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = JS.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, null, .{});
    pub const console = bridge.accessor(WorkerGlobalScope.getConsole, null, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});

    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{});
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{ .dom_exception = true });
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{});
    pub const postMessage = bridge.function(WorkerGlobalScope.postMessage, .{});
    pub const reportError = bridge.function(WorkerGlobalScope.reportError, .{});
    pub const close = bridge.function(WorkerGlobalScope.close, .{});

    pub const onmessage = bridge.accessor(WorkerGlobalScope.getOnMessage, WorkerGlobalScope.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(WorkerGlobalScope.getOnMessageError, WorkerGlobalScope.setOnMessageError, .{});

    // Return false since workers don't have secure-context-only APIs
    pub const isSecureContext = bridge.property(false, .{ .template = false });
};

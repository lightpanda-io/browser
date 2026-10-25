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

// The global object of a dedicated worker. Per the HTML spec this is the most
// derived interface of a dedicated worker's global, inheriting from
// WorkerGlobalScope (-> EventTarget). It is the actual JS global object (`self`);
// the WorkerGlobalScope base holds all of the state and implementation, reached
// here through `_proto`. Sites branch on `self instanceof DedicatedWorkerGlobalScope`
// to tell a worker apart from an iframe (e.g. Shopify's Web Pixel sandbox).

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");
const MessagePort = @import("MessagePort.zig");
const Worker = @import("Worker.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const MessageEvent = @import("event/MessageEvent.zig");

const DedicatedWorkerGlobalScope = @This();

pub const Proto = WorkerGlobalScope;

_proto: *WorkerGlobalScope,
_worker: *Worker,
_closed: bool = false,

// Messages received before the worker script finished evaluating. Per the
// HTML spec, postMessage'd data is buffered while the worker is loading
// and delivered once the worker is ready (i.e. once onmessage can be set).
// Drained by drainPendingMessages, called from Worker.loadInitialScript
// after the initial script has been evaluated.
_pending_messages: std.ArrayList(MessagePort.Message) = .empty,

pub fn init(worker: *Worker, url: [:0]const u8) !*DedicatedWorkerGlobalScope {
    return WorkerGlobalScope.init(
        worker._arena.allocator(),
        url,
        .dedicated,
        DedicatedWorkerGlobalScope{
            ._worker = worker,
            ._proto = undefined,
        },
        worker._type == .module,
        worker._frame_id,
        worker._loader_id,
        worker._frame,
    );
}

pub fn deinit(self: *DedicatedWorkerGlobalScope) void {
    for (self._pending_messages.items) |message| {
        message.release();
    }
    self._proto.deinit();
}

pub fn postMessage(self: *DedicatedWorkerGlobalScope, data: js.Value, transfer: ?js.Value) !void {
    try self._worker.receiveMessage(data, try MessagePort.transferList(transfer));
}

pub fn close(self: *DedicatedWorkerGlobalScope) void {
    // TODO: we should also stop new tasks from being scheduled
    self._proto._session.idb.detachContext(self._proto.js);
    self._proto.js.scheduler.reset();
    self._closed = true;
}

pub fn requestAnimationFrame(self: *DedicatedWorkerGlobalScope, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._proto._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "worker.requestAnimationFrame",
    });
}

pub fn cancelAnimationFrame(self: *DedicatedWorkerGlobalScope, id: u32) void {
    self._proto._timers.clear(id);
}

// Called internally by Worker when it wants to post a message to us
pub fn receiveMessage(self: *DedicatedWorkerGlobalScope, data: js.Value, transfer: []const *MessagePort) !void {
    // clones from where it currently is (the Worker's Page context) to our Context.
    // Done even when closed (per spec), so transferred ports still detach and
    // bad data still throws.
    const cloned_data = try MessagePort.cloneMessage(data, transfer, &self._proto.js.execution);
    if (self._closed) {
        cloned_data.release();
        return;
    }
    errdefer cloned_data.release();

    if (!self._worker._script_loaded) {
        // Buffer until Worker.loadInitialScript calls drainPendingMessages.
        // Without this, postMessage'd data races against the worker's
        // script load: if onmessage hasn't been registered yet (because
        // the worker hasn't been evaluated), the dispatched event finds
        // no listener and the message is silently dropped.
        try self._pending_messages.append(self._proto.arena, cloned_data);
        return;
    }

    try self.scheduleMessage(cloned_data);
}

fn scheduleMessage(self: *DedicatedWorkerGlobalScope, cloned_data: MessagePort.Message) !void {
    const wgs = self._proto;
    const session = wgs._session;

    const message_arena = try session.getArena(.tiny, "DedicatedWorkerGlobalScope.receiveMessage");
    errdefer message_arena.release();

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .worker_scope = self,
        .arena = message_arena,
    };

    try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "WorkerGlobalScope.receiveMessage",
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

// Called by Worker.loadInitialScript once the initial script has been
// evaluated and onmessage has had a chance to be registered. Any messages
// that arrived while the worker was loading are scheduled for delivery in
// the order they were received.
pub fn drainPendingMessages(self: *DedicatedWorkerGlobalScope) void {
    for (self._pending_messages.items) |cloned_data| {
        self.scheduleMessage(cloned_data) catch |err| {
            lp.log.debug(.browser, "worker drain msg failed", .{ .err = err });
            cloned_data.release();
        };
    }
    self._pending_messages.clearRetainingCapacity();
}

const ReceiveMessageCallback = struct {
    data: MessagePort.Message,
    arena: *lp.Arena,
    worker_scope: *DedicatedWorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        self.data.release();
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.arena.release();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        defer self.data.releasePorts();

        const worker_scope = self.worker_scope;
        const wsg = worker_scope._proto;
        const target = wsg.asEventTarget();

        // If data is null, deserialization failed - fire messageerror
        const data = self.data.data orelse {
            if (!wsg._event_manager.hasDirectListeners(target, "messageerror")) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .ports = self.data.ports,
                .bubbles = false,
                .cancelable = false,
            }, wsg.page)).asEvent();
            try wsg.dispatch(target, event, .{});
            return null;
        };

        // Check if there are any listeners before creating the event
        if (!wsg._event_manager.hasDirectListeners(target, "message")) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .ports = self.data.ports,
            .bubbles = false,
            .cancelable = false,
        }, wsg.page)).asEvent();
        try wsg.dispatch(target, event, .{});
        return null;
    }
};

pub fn asEventTarget(self: *DedicatedWorkerGlobalScope) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DedicatedWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "DedicatedWorkerGlobalScope";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postMessage = bridge.function(DedicatedWorkerGlobalScope.postMessage, .{});
    pub const close = bridge.function(DedicatedWorkerGlobalScope.close, .{});
    pub const onmessage = EventTarget.handlerAccessor(DedicatedWorkerGlobalScope, "message");
    pub const onmessageerror = EventTarget.handlerAccessor(DedicatedWorkerGlobalScope, "messageerror");
    pub const requestAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.cancelAnimationFrame, .{});
};

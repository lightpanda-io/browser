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

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;
const Execution = js.Execution;

const MessagePort = @This();

_proto: *EventTarget,

// The context this port lives in. The two ends of an entangled pair can be in
// different contexts. Delivery always goes through the *receiving* port's context.
_exec: *Execution,
_enabled: bool = false,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,
_entangled_port: ?*MessagePort = null,

// queued message received before the port is started.
_pending: std.ArrayList(js.Value.Global) = .empty,

// Link list into the owning Frame or WorkerGlobalScope. When the frame/WGS is
// shutdown, the port will be closed.
_node: std.DoublyLinkedList.Node = .{},

pub fn init(exec: *Execution) !*MessagePort {
    const self = try exec._factory.eventTarget(MessagePort{
        ._proto = undefined,
        ._exec = exec,
    });
    exec.messagePorts().append(&self._node);
    return self;
}

pub fn asEventTarget(self: *MessagePort) *EventTarget {
    return self._proto;
}

pub fn entangle(port1: *MessagePort, port2: *MessagePort) void {
    port1._entangled_port = port2;
    port2._entangled_port = port1;
}

pub fn postMessage(self: *MessagePort, message: js.Value) !void {
    if (self._closed) {
        return;
    }

    const other = self._entangled_port orelse return;
    if (other._closed) {
        return;
    }

    // StructuredSerialize runs synchronously (per spec): clone the message now
    // so the receiver gets an independent copy (a mutation on one side isn't
    // visible to the other) and an unserializable value throws a DataCloneError
    // to the caller. The clone is made directly into the receiving port's
    // context, which may not be the sender's.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        other._exec.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception from a failed serialization so it surfaces as
        // a clean DataCloneError; deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const c = message.structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try c.persist();
    };
    errdefer cloned.release();

    if (!other._enabled) {
        try other._pending.append(other._exec.arena, cloned);
        return;
    }

    try other.scheduleDelivery(cloned);
}

pub fn start(self: *MessagePort) void {
    if (self._closed or self._enabled) {
        return;
    }
    self._enabled = true;

    for (self._pending.items) |message| {
        self.scheduleDelivery(message) catch |err| {
            log.warn(.dom, "MessagePort.start drain", .{ .err = err });
            message.release();
        };
    }
    self._pending.clearRetainingCapacity();
}

pub fn close(self: *MessagePort) void {
    if (self._closed) {
        return;
    }
    self._closed = true;
    self._exec.messagePorts().remove(&self._node);

    for (self._pending.items) |message| {
        message.release();
    }
    self._pending.clearRetainingCapacity();

    // Break entanglement
    if (self._entangled_port) |other| {
        other._entangled_port = null;
    }
    self._entangled_port = null;
}

pub fn getOnMessage(self: *const MessagePort) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *MessagePort, cb: ?js.Function.Global) !void {
    self._on_message = cb;
    if (cb != null) {
        self.start();
    }
}

pub fn getOnMessageError(self: *const MessagePort) ?js.Function.Global {
    return self._on_message_error;
}

pub fn setOnMessageError(self: *MessagePort, cb: ?js.Function.Global) !void {
    self._on_message_error = cb;
}

// Queues delivery of `message` (a clone already living in this port's
// context) on this port's scheduler.
fn scheduleDelivery(self: *MessagePort, message: js.Value.Global) !void {
    const exec = self._exec;
    const callback = try exec._factory.create(DeliverCallback{
        .port = self,
        .message = message,
    });
    errdefer exec._factory.destroy(callback);

    try exec.js.scheduler.add(callback, DeliverCallback.run, 0, .{
        .name = "MessagePort.postMessage",
        .low_priority = false,
        .finalizer = DeliverCallback.cancelled,
    });
}

const DeliverCallback = struct {
    port: *MessagePort,
    message: js.Value.Global,

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *DeliverCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn deinit(self: *DeliverCallback) void {
        self.port._exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeliverCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        const port = self.port;
        const exec = port._exec;

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; on any path where we don't hand it over, release it here so
        // it doesn't leak.
        if (port._closed) {
            self.message.release();
            return null;
        }

        const target = port.asEventTarget();
        if (!exec.hasDirectListeners(target, "message", port._on_message)) {
            self.message.release();
            return null;
        }

        const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = "",
            .source = null,
        }, exec.page) catch |err| {
            self.message.release();
            log.err(.dom, "MessagePort.postMessage", .{ .err = err });
            return null;
        }).asEvent();

        exec.dispatch(target, event, port._on_message, .{ .context = "MessagePort message" }) catch |err| {
            log.err(.dom, "MessagePort.postMessage", .{ .err = err });
        };

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessagePort);

    pub const Meta = struct {
        pub const name = "MessagePort";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const postMessage = bridge.function(MessagePort.postMessage, .{});
    pub const start = bridge.function(MessagePort.start, .{});
    pub const close = bridge.function(MessagePort.close, .{});

    pub const onmessage = bridge.accessor(MessagePort.getOnMessage, MessagePort.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(MessagePort.getOnMessageError, MessagePort.setOnMessageError, .{});
};

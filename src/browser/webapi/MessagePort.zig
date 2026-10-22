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

pub const Proto = EventTarget;

_proto: *EventTarget,

// The context this port lives in. The two ends of an entangled pair can be in
// different contexts. Delivery always goes through the *receiving* port's context.
_exec: *Execution,
_enabled: bool = false,
_closed: bool = false,

// set once transfered to another context
_detached: bool = false,
_entangled_port: ?*MessagePort = null,

// queued message received before the port is started.
_pending: std.ArrayList(Message) = .empty,

// DeliverCallbacks scheduled but not yet run, in order. A transfer takes their
// messages along to the new port.
_in_flight: std.DoublyLinkedList = .{},

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

pub fn postMessage(self: *MessagePort, message: js.Value, transfer: ?js.Value) !void {
    const ports = try transferList(transfer);
    if (std.mem.findScalar(*MessagePort, ports, self) != null) {
        return error.DataClone;
    }

    const other: ?*MessagePort = if (self._closed) null else self._entangled_port;

    // With no live receiver, or when the receiving port is itself being
    // transferred, the message is doomed. It's still serialized (per spec), so
    // the transferred ports detach and bad data throws, but nothing is
    // delivered.
    var doomed = true;
    if (other) |o| {
        doomed = o._closed or std.mem.findScalar(*MessagePort, ports, o) != null;
    }

    // The clone is made directly into the receiving port's context, which may
    // not be the sender's.
    const target_exec = if (other) |o| o._exec else self._exec;
    const cloned = try cloneMessage(message, ports, target_exec);
    if (doomed) {
        cloned.release();
        return;
    }
    errdefer cloned.release();

    const receiver = other.?;
    if (!receiver._enabled) {
        try receiver._pending.append(receiver._exec.page_arena, cloned);
        return;
    }

    try receiver.scheduleDelivery(cloned);
}

// A message cloned into the receiving context. `data` is null when it couldn't
// be deserialized there, which the receiver reports as a messageerror.
pub const Message = struct {
    data: ?js.Value.Global,
    // The transferred ports, already moved into the receiving context.
    ports: []const *MessagePort,
    // Owns `ports`; null when there are none.
    ports_arena: ?*lp.Arena = null,

    // For a message that's dropped.
    pub fn release(self: Message) void {
        if (self.data) |d| {
            d.release();
        }
        self.releasePorts();
    }

    // For a message that's delivered: the event owns `data` and has copied
    // `ports`.
    pub fn releasePorts(self: Message) void {
        if (self.ports_arena) |arena| {
            arena.release();
        }
    }
};

// StructuredSerializeWithTransfer in the sender's realm, then
// StructuredDeserializeWithTransfer in `target`'s, done back to back since
// every realm lives in the same isolate. Serialization runs synchronously (per
// spec) so an unserializable value throws a DataCloneError to the sender, and
// the receiver gets an independent copy. Each port in `transfer` moves to
// `target`; one nested in `message` comes out as its moved counterpart.
pub fn cloneMessage(message: js.Value, transfer: []const *MessagePort, target: *Execution) !Message {
    for (transfer, 0..) |port, i| {
        if (port._detached or std.mem.findScalar(*MessagePort, transfer[0..i], port) != null) {
            return error.DataClone;
        }
    }

    const serialized = blk: {
        // Contain any V8 exception from a failed serialization so it surfaces
        // as a clean DataCloneError; deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(message.local);
        defer try_catch.deinit();
        break :blk message.serializeTransfer(transfer) catch return error.DataClone;
    };
    defer serialized.deinit();

    var ports: []*MessagePort = &.{};
    var ports_arena: ?*lp.Arena = null;
    errdefer if (ports_arena) |arena| arena.release();
    if (transfer.len > 0) {
        const arena = try target.getArena(.tiny, "MessagePort.Message");
        ports_arena = arena;
        ports = try arena.allocator().alloc(*MessagePort, transfer.len);
    }
    for (transfer, ports) |port, *moved| {
        moved.* = try port.transferTo(target);
    }

    var ls: js.Local.Scope = undefined;
    target.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const value = js.Value.deserializeTransfer(&ls.local, serialized.bytes(), ports) catch {
        return .{ .data = null, .ports = ports, .ports_arena = ports_arena };
    };
    return .{ .data = try value.persist(), .ports = ports, .ports_arena = ports_arena };
}

// The `transfer` argument of postMessage: a sequence of transferables, or a
// StructuredSerializeOptions dictionary. Only MessagePorts move; an
// ArrayBuffer is accepted but left attached (the clone copies it).
pub fn transferList(arg: ?js.Value) ![]const *MessagePort {
    const value = arg orelse return &.{};
    if (value.isNullOrUndefined()) {
        return &.{};
    }
    if (value.isObject() == false) {
        return error.TypeError;
    }

    const local = value.local;
    const list = if (value.isArray()) value else blk: {
        const t = try value.toObject().get("transfer");
        if (t.isNullOrUndefined()) {
            return &.{};
        }
        break :blk t;
    };

    const items = try local.jsValueToZig([]const js.Value, list);
    const ports = try local.call_arena.alloc(*MessagePort, items.len);
    var count: usize = 0;
    for (items) |item| {
        if (item.isArrayBuffer()) {
            continue;
        }
        const port = if (item.isObject()) if (item.taggedOpaque()) |tao| tao.as(MessagePort) else null else null;
        ports[count] = port orelse return error.DataClone;
        count += 1;
    }
    return ports[0..count];
}

// Moves this port into `exec`: a fresh port there takes over the entanglement
// and any queued messages, and this one is left detached.
fn transferTo(self: *MessagePort, exec: *Execution) !*MessagePort {
    const port = try MessagePort.init(exec);

    if (self._entangled_port) |other| {
        entangle(port, other);
    }
    self._entangled_port = null;

    // Scheduled deliveries were queued before anything still pending (which
    // only exists if the port was never started), so they go first.
    while (self._in_flight.popFirst()) |node| {
        const callback: *DeliverCallback = @fieldParentPtr("node", node);
        const message = callback.message.?;
        callback.message = null;
        port.adoptPending(message, self._exec);
    }
    for (self._pending.items) |message| {
        port.adoptPending(message, self._exec);
    }
    self._pending.clearRetainingCapacity();

    if (self._closed) {
        port.close();
    }
    self._detached = true;
    self.close();
    return port;
}

// Queues a message the port's previous incarnation (in `from`) hadn't
// delivered yet. The new port isn't started, so it waits in _pending.
fn adoptPending(self: *MessagePort, message: Message, from: *Execution) void {
    const moved = moveMessage(message, from, self._exec) orelse return;
    self._pending.append(self._exec.page_arena, moved) catch |err| {
        log.debug(.dom, "MessagePort transfer", .{ .err = err });
        moved.release();
    };
}

// Re-homes a queued message (and the ports it carries) into another context.
// Takes ownership of `message`; null if it couldn't be moved.
fn moveMessage(message: Message, from: *Execution, to: *Execution) ?Message {
    if (from == to) {
        return message;
    }
    defer message.release();

    const data = message.data orelse return null;

    var ls: js.Local.Scope = undefined;
    from.js.localScope(&ls);
    defer ls.deinit();

    return cloneMessage(data.local(&ls.local), message.ports, to) catch |err| {
        log.debug(.dom, "MessagePort transfer", .{ .err = err });
        return null;
    };
}

pub fn start(self: *MessagePort) void {
    if (self._closed or self._enabled) {
        return;
    }
    self._enabled = true;

    for (self._pending.items) |message| {
        self.scheduleDelivery(message) catch |err| {
            log.debug(.dom, "MessagePort.start drain", .{ .err = err });
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

// Queues delivery of `message` (a clone already living in this port's
// context) on this port's scheduler.
fn scheduleDelivery(self: *MessagePort, message: Message) !void {
    const exec = self._exec;
    const callback = try exec._factory.create(DeliverCallback{
        .port = self,
        .message = message,
    });
    errdefer exec._factory.destroy(callback);

    self._in_flight.append(&callback.node);
    errdefer self._in_flight.remove(&callback.node);

    try exec.js.scheduler.add(callback, DeliverCallback.run, 0, .{
        .name = "MessagePort.postMessage",
        .finalizer = DeliverCallback.cancelled,
    });
}

const DeliverCallback = struct {
    port: *MessagePort,
    // null once a transfer has taken it to the port's new incarnation (and
    // unlinked this callback from _in_flight).
    message: ?Message,
    node: std.DoublyLinkedList.Node = .{},

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *DeliverCallback = @ptrCast(@alignCast(ctx));
        if (self.message) |message| {
            self.port._in_flight.remove(&self.node);
            message.release();
        }
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

        const message = self.message orelse return null;
        port._in_flight.remove(&self.node);
        defer message.releasePorts();

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; on any path where we don't hand it over, release it here so
        // it doesn't leak.
        if (port._closed) {
            if (message.data) |d| {
                d.release();
            }
            return null;
        }

        const target = port.asEventTarget();
        const data = message.data orelse {
            if (exec.hasDirectListeners(target, "messageerror")) {
                const event = (MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                    .origin = "",
                    .ports = message.ports,
                }, exec.page) catch |err| {
                    log.debug(.dom, "MessagePort.postMessage", .{ .err = err });
                    return null;
                }).asEvent();
                exec.dispatch(target, event, .{ .context = "MessagePort messageerror" }) catch |err| {
                    log.debug(.dom, "MessagePort.postMessage", .{ .err = err });
                };
            }
            return null;
        };

        if (!exec.hasDirectListeners(target, "message")) {
            data.release();
            return null;
        }

        const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .origin = "",
            .source = null,
            .ports = message.ports,
        }, exec.page) catch |err| {
            data.release();
            log.debug(.dom, "MessagePort.postMessage", .{ .err = err });
            return null;
        }).asEvent();

        exec.dispatch(target, event, .{ .context = "MessagePort message" }) catch |err| {
            log.debug(.dom, "MessagePort.postMessage", .{ .err = err });
        };

        return null;
    }
};

fn getOnMessage(self: *MessagePort, exec: *js.Execution) ?js.Function.Global {
    return exec.getHandler(self.asEventTarget(), "message");
}

// Setting onmessage implicitly starts the port (unlike addEventListener).
fn setOnMessage(self: *MessagePort, value: ?EventTarget.HandlerValue, exec: *js.Execution) !void {
    const cb = EventTarget.HandlerValue.function(value);
    try exec.setHandler(self.asEventTarget(), "message", cb);
    if (cb != null) {
        self.start();
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessagePort);

    pub const Meta = struct {
        pub const name = "MessagePort";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const postMessage = bridge.function(MessagePort.postMessage, .{});
    pub const start = bridge.function(MessagePort.start, .{});
    pub const close = bridge.function(MessagePort.close, .{});

    pub const onmessage = bridge.accessor(MessagePort.getOnMessage, MessagePort.setOnMessage, .{});
    pub const onmessageerror = EventTarget.handlerAccessor(MessagePort, "messageerror");
};

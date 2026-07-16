// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;
const Execution = js.Execution;

const MessagePort = @This();

_proto: *EventTarget,
_enabled: bool = false,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,
_entangled_port: ?*MessagePort = null,

pub fn init(exec: *Execution) !*MessagePort {
    return exec._factory.eventTarget(MessagePort{
        ._proto = undefined,
    });
}

pub fn asEventTarget(self: *MessagePort) *EventTarget {
    return self._proto;
}

pub fn entangle(port1: *MessagePort, port2: *MessagePort) void {
    port1._entangled_port = port2;
    port2._entangled_port = port1;
}

pub fn postMessage(self: *MessagePort, message: js.Value, exec: *Execution) !void {
    if (self._closed) {
        return;
    }

    const other = self._entangled_port orelse return;
    if (other._closed) {
        return;
    }

    // StructuredSerialize runs synchronously (per spec): clone the message into a
    // fresh, self-owned temp now so the receiver gets an independent copy (a
    // mutation on one side isn't visible to the other) and an unserializable
    // value throws a DataCloneError to the caller. Mirrors Worker.postMessage.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
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

    // Create callback to deliver message
    const callback = try exec._factory.create(PostMessageCallback{
        .exec = exec,
        .port = other,
        .message = cloned,
    });

    try exec.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "MessagePort.postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

pub fn start(self: *MessagePort) void {
    if (self._closed) {
        return;
    }
    self._enabled = true;
}

pub fn close(self: *MessagePort) void {
    self._closed = true;

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
}

pub fn getOnMessageError(self: *const MessagePort) ?js.Function.Global {
    return self._on_message_error;
}

pub fn setOnMessageError(self: *MessagePort, cb: ?js.Function.Global) !void {
    self._on_message_error = cb;
}

const PostMessageCallback = struct {
    port: *MessagePort,
    message: js.Value.Global,
    exec: *Execution,

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn deinit(self: *PostMessageCallback) void {
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        const exec = self.exec;

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; on any path where we don't hand it over, release it here so
        // it doesn't leak.
        if (self.port._closed) {
            self.message.release();
            return null;
        }

        const target = self.port.asEventTarget();
        if (!exec.hasDirectListeners(target, "message", self.port._on_message)) {
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

        exec.dispatch(target, event, self.port._on_message, .{ .context = "MessagePort message" }) catch |err| {
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

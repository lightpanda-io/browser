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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;

const MessagePort = @This();

_proto: *EventTarget,
_enabled: bool = false,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,
_entangled_port: ?*MessagePort = null,

pub fn init(frame: *Frame) !*MessagePort {
    return frame._factory.eventTarget(MessagePort{
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

pub fn postMessage(self: *MessagePort, message: js.Value.Temp, frame: *Frame) !void {
    if (self._closed) {
        return;
    }

    const other = self._entangled_port orelse return;
    if (other._closed) {
        return;
    }

    // Create callback to deliver message
    const callback = try frame._factory.create(PostMessageCallback{
        .frame = frame,
        .port = other,
        .message = message,
    });

    try frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "MessagePort.postMessage",
        .low_priority = false,
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
    message: js.Value.Temp,
    frame: *Frame,

    fn deinit(self: *PostMessageCallback) void {
        self.frame._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        const frame = self.frame;

        if (self.port._closed) {
            return null;
        }

        const target = self.port.asEventTarget();
        if (frame._event_manager.hasDirectListeners(target, "message", self.port._on_message)) {
            const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
                .data = .{ .value = self.message },
                .origin = "",
                .source = null,
            }, frame._page) catch |err| {
                log.err(.dom, "MessagePort.postMessage", .{ .err = err });
                return null;
            }).asEvent();

            frame._event_manager.dispatchDirect(target, event, self.port._on_message, .{ .context = "MessagePort message" }) catch |err| {
                log.err(.dom, "MessagePort.postMessage", .{ .err = err });
            };
        }

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

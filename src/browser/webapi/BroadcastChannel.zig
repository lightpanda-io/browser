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
const Frame = @import("../Frame.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;

const BroadcastChannel = @This();

_proto: *EventTarget,
_frame: *Frame,
_name: []const u8,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,

// Intrusive node, registered in `frame._broadcast_channels` for the lifetime
// of the channel (until close()). The registry is how a postMessage on one
// channel finds the other same-named channels to deliver to.
_node: std.DoublyLinkedList.Node = .{},

pub fn init(name: []const u8, frame: *Frame) !*BroadcastChannel {
    const self = try frame._factory.eventTarget(BroadcastChannel{
        ._proto = undefined,
        ._frame = frame,
        ._name = try frame.arena.dupe(u8, name),
    });
    frame._broadcast_channels.append(&self._node);
    return self;
}

pub fn asEventTarget(self: *BroadcastChannel) *EventTarget {
    return self._proto;
}

fn fromNode(node: *std.DoublyLinkedList.Node) *BroadcastChannel {
    return @fieldParentPtr("_node", node);
}

pub fn getName(self: *const BroadcastChannel) []const u8 {
    return self._name;
}

// https://html.spec.whatwg.org/multipage/web-messaging.html#dom-broadcastchannel-postmessage
// The message is delivered asynchronously to every other BroadcastChannel
// object with the same name in the same agent cluster, never to the sender.
pub fn postMessage(self: *BroadcastChannel, message: js.Value.Temp, frame: *Frame) !void {
    if (self._closed) {
        return error.InvalidStateError;
    }

    // StructuredSerialize runs synchronously (per spec): clone the message once
    // now so an unserializable value throws a DataCloneError to the caller, and
    // so the async delivery has a self-owned snapshot to copy from. Each receiver
    // gets its own re-clone of this snapshot in `run()` — that gives every
    // MessageEvent an independently owned handle (a shared temp would be freed by
    // the first receiver's event teardown, leaving the rest reading a dead slot)
    // and honours the spec requirement that receivers don't share one object.
    const snapshot = blk: {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception raised by a failed serialization so we can
        // re-raise it as a clean DataCloneError (per spec) instead of leaking a
        // stale pending exception into the caller. deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const cloned = message.local(&ls.local).structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try cloned.temp();
    };
    errdefer snapshot.release();

    const callback = try frame._factory.create(PostMessageCallback{
        .frame = frame,
        .sender = self,
        .message = snapshot,
    });

    try frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "BroadcastChannel.postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

pub fn close(self: *BroadcastChannel) void {
    if (self._closed) {
        return;
    }
    self._closed = true;
    self._frame._broadcast_channels.remove(&self._node);
}

pub fn getOnMessage(self: *const BroadcastChannel) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *BroadcastChannel, cb: ?js.Function.Global) !void {
    self._on_message = cb;
}

pub fn getOnMessageError(self: *const BroadcastChannel) ?js.Function.Global {
    return self._on_message_error;
}

pub fn setOnMessageError(self: *BroadcastChannel, cb: ?js.Function.Global) !void {
    self._on_message_error = cb;
}

const PostMessageCallback = struct {
    sender: *BroadcastChannel,
    // A self-owned structured-clone snapshot of the posted message. Re-cloned
    // (never shared) into each receiver's MessageEvent, then released.
    message: js.Value.Temp,
    frame: *Frame,

    // Called by the scheduler if the task is dropped before it runs (e.g. page
    // teardown). `run` and `cancelled` are mutually exclusive, so the snapshot
    // is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn deinit(self: *PostMessageCallback) void {
        self.frame._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        // LIFO: deinit() frees `self`, so it must run last; the snapshot is
        // released after delivery (no MessageEvent owns it) but before deinit.
        defer self.deinit();
        defer self.message.release();

        const frame = self.frame;
        const sender = self.sender;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        const snapshot = self.message.local(&ls.local);

        var it = frame._broadcast_channels.first;
        while (it) |node| : (it = node.next) {
            const channel = BroadcastChannel.fromNode(node);

            // Never deliver to the sender, to closed channels, or across names.
            if (channel == sender or channel._closed) {
                continue;
            }
            if (!std.mem.eql(u8, channel._name, sender._name)) {
                continue;
            }

            const target = channel.asEventTarget();
            if (!frame._event_manager.hasDirectListeners(target, "message", channel._on_message)) {
                continue;
            }

            // Independent clone per receiver. The snapshot is already plain,
            // serializable data, so this cannot raise a DataCloneError. The
            // resulting temp is owned by the MessageEvent, which releases it on
            // teardown — so each receiver frees only its own handle.
            const cloned = snapshot.structuredCloneTo(&ls.local) catch |err| {
                log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                continue;
            };
            const cloned_temp = cloned.temp() catch |err| {
                log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                continue;
            };

            const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
                .data = .{ .value = cloned_temp },
                .origin = "",
                .source = null,
            }, frame._page) catch |err| {
                cloned_temp.release();
                log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                continue;
            }).asEvent();

            frame._event_manager.dispatchDirect(target, event, channel._on_message, .{ .context = "BroadcastChannel message" }) catch |err| {
                log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
            };
        }

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(BroadcastChannel);

    pub const Meta = struct {
        pub const name = "BroadcastChannel";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const constructor = bridge.constructor(BroadcastChannel.init, .{});

    pub const name = bridge.accessor(BroadcastChannel.getName, null, .{});
    pub const postMessage = bridge.function(BroadcastChannel.postMessage, .{ .dom_exception = true });
    pub const close = bridge.function(BroadcastChannel.close, .{});

    pub const onmessage = bridge.accessor(BroadcastChannel.getOnMessage, BroadcastChannel.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(BroadcastChannel.getOnMessageError, BroadcastChannel.setOnMessageError, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: BroadcastChannel" {
    try testing.htmlRunner("broadcast_channel.html", .{});
}

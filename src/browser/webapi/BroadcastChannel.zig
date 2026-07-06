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

const BroadcastChannel = @This();

_proto: *EventTarget,
_exec: *Execution,
_name: lp.String,
_sequence: u64,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,

// Intrusive node, registered in `frame._broadcast_channels` (or WGS)
// for the lifetime of the channel (until close()). The registry is how a
// postMessage on one channel finds the other same-named channels to deliver to.
_node: std.DoublyLinkedList.Node = .{},

pub fn init(name: lp.String.Global, exec: *Execution) !*BroadcastChannel {
    const page = exec.page;
    const self = try exec._factory.eventTarget(BroadcastChannel{
        ._proto = undefined,
        ._exec = exec,
        ._name = name.str,
        ._sequence = page.broadcast_sequence,
    });
    page.broadcast_sequence += 1;
    exec.getBroadcastChannels().append(&self._node);
    return self;
}

pub fn asEventTarget(self: *BroadcastChannel) *EventTarget {
    return self._proto;
}

pub fn getName(self: *const BroadcastChannel) lp.String {
    return self._name;
}

// https://html.spec.whatwg.org/multipage/web-messaging.html#dom-broadcastchannel-postmessage
// The message is delivered asynchronously to every other BroadcastChannel
// object with the same name in the same agent cluster, never to the sender.
pub fn postMessage(self: *BroadcastChannel, message: js.Value, exec: *Execution) !void {
    if (self._closed) {
        return error.InvalidStateError;
    }

    // StructuredSerialize runs synchronously (per spec): clone the message once
    // now so an unserializable value throws a DataCloneError to the caller.
    const snapshot = blk: {
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception raised by a failed serialization so we can
        // re-raise it as a clean DataCloneError (per spec) instead of leaking a
        // stale pending exception into the caller. deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const cloned = message.structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try cloned.temp();
    };
    errdefer snapshot.release();

    const callback = try exec._factory.create(PostMessageCallback{
        .exec = exec,
        .sender = self,
        .message = snapshot,
        .post_sequence = exec.page.broadcast_sequence,
    });

    try exec.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
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
    self._exec.getBroadcastChannels().remove(&self._node);
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
    exec: *Execution,
    post_sequence: u64,

    // Called by the scheduler if the task is dropped before it runs (e.g. page
    // teardown). `run` and `cancelled` are mutually exclusive, so the snapshot
    // is released exactly once.
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
        // LIFO: deinit() frees `self`, so it must run last; the snapshot is
        // released after delivery (no MessageEvent owns it) but before deinit.
        defer self.deinit();
        defer self.message.release();

        const sender = self.sender;
        const page = self.exec.page;
        const origin = self.exec.origin();

        // MessageEvent.origin is the serialization of the sender's origin (same
        // for every receiver); an opaque origin serializes to "null".
        const sender_origin = origin orelse "null";

        // Snapshot every same-origin global up front. Dispatch (below) runs user
        // JS that can create or tear down frames/workers, so we must not hold a
        // live frame-tree walk across it. Per-global channel lists are intrusive
        // (never realloc) and teardown is deferred to the next tick, so walking
        // each channel list live during dispatch is safe.
        const arena = try page.getArena(.tiny, "BroadcastChannel.postMessage");
        defer page.releaseArena(arena);

        // Opaque origins have no string form and are unique per execution, so
        // the sender is the only same-origin context
        const executions = if (origin) |o|
            try page.executionsForOrigin(arena, o)
        else
            (&self.exec)[0..1];

        for (executions) |exec| {
            // The MessageEvent and its cloned `data` must live in the receiver's
            // realm, and its listeners are in the receiver's event manager.
            // localScope enters the receiver's v8 context, so both happen there.
            var ls: js.Local.Scope = undefined;
            exec.js.localScope(&ls);
            defer ls.deinit();
            const snapshot = self.message.local(&ls.local);

            var it = exec.getBroadcastChannels().*.first;
            while (it) |node| : (it = node.next) {
                const channel: *BroadcastChannel = @alignCast(@fieldParentPtr("_node", node));

                // Never deliver to the sender, to closed channels, to channels
                // created after this message was posted, or across names.
                if (channel == sender or channel._closed) {
                    continue;
                }
                if (channel._sequence >= self.post_sequence) {
                    continue;
                }
                if (sender._name.eql(channel._name) == false) {
                    continue;
                }

                const target = channel.asEventTarget();
                if (!exec.hasDirectListeners(target, "message", channel._on_message)) {
                    continue;
                }

                // Independent clone per receiver, in the receiver's realm. The
                // snapshot is already plain, serializable data, so this cannot
                // raise a DataCloneError. The resulting temp is owned by the
                // MessageEvent, which releases it on teardown — so each receiver
                // frees only its own handle.
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
                    .origin = sender_origin,
                    .source = null,
                }, exec.page) catch |err| {
                    cloned_temp.release();
                    log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                    continue;
                }).asEvent();

                exec.dispatch(target, event, channel._on_message, .{ .context = "BroadcastChannel message" }) catch |err| {
                    log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                };
            }
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
    pub const postMessage = bridge.function(BroadcastChannel.postMessage, .{});
    pub const close = bridge.function(BroadcastChannel.close, .{});

    pub const onmessage = bridge.accessor(BroadcastChannel.getOnMessage, BroadcastChannel.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(BroadcastChannel.getOnMessageError, BroadcastChannel.setOnMessageError, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: BroadcastChannel" {
    try testing.htmlRunner("broadcast_channel.html", .{});
}

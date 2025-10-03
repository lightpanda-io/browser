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
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventHandler = @import("../events/event.zig").EventHandler;

const Allocator = std.mem.Allocator;

const MAX_QUEUE_SIZE = 10;

pub const Interfaces = .{ MessageChannel, MessagePort };

const MessageChannel = @This();

port1: *MessagePort,
port2: *MessagePort,

pub fn constructor(page: *Page) !MessageChannel {
    // Why do we allocate this rather than storing directly in the struct?
    // https://github.com/lightpanda-io/project/discussions/165
    const port1 = try page.arena.create(MessagePort);
    const port2 = try page.arena.create(MessagePort);
    port1.* = .{
        .pair = port2,
    };
    port2.* = .{
        .pair = port1,
    };

    return .{
        .port1 = port1,
        .port2 = port2,
    };
}

pub fn get_port1(self: *const MessageChannel) *MessagePort {
    return self.port1;
}

pub fn get_port2(self: *const MessageChannel) *MessagePort {
    return self.port2;
}

pub const MessagePort = struct {
    pub const prototype = *EventTarget;

    proto: parser.EventTargetTBase = .{ .internal_target_type = .message_port },

    pair: *MessagePort,
    closed: bool = false,
    started: bool = false,
    onmessage_cbk: ?js.Function = null,
    onmessageerror_cbk: ?js.Function = null,
    // This is the queue of messages to dispatch to THIS MessagePort when the
    // MessagePort is started.
    queue: std.ArrayListUnmanaged(js.Object) = .empty,

    pub const PostMessageOption = union(enum) {
        transfer: js.Object,
        options: Opts,

        pub const Opts = struct {
            transfer: js.Object,
        };
    };

    pub fn _postMessage(self: *MessagePort, obj: js.Object, opts_: ?PostMessageOption, page: *Page) !void {
        if (self.closed) {
            return;
        }

        if (opts_ != null) {
            log.warn(.web_api, "not implemented", .{ .feature = "MessagePort postMessage options" });
        }

        try self.pair.dispatchOrQueue(obj, page.arena);
    }

    // Start impacts the ability to receive a message.
    // Given pair1 (started) and pair2 (not started), then:
    //    pair2.postMessage('x'); //will be dispatched to pair1.onmessage
    //    pair1.postMessage('x'); // will be queued until pair2 is started
    pub fn _start(self: *MessagePort) !void {
        if (self.started) {
            return;
        }
        self.started = true;
        for (self.queue.items) |data| {
            try self.dispatch(data);
        }
        // we'll never use this queue again, but it's allocated with an arena
        // we don't even need to clear it, but it seems a bit safer to do at
        // least that
        self.queue.clearRetainingCapacity();
    }

    // Closing seems to stop both the publishing and receiving of messages,
    // effectively rendering the channel useless. It cannot be reversed.
    pub fn _close(self: *MessagePort) void {
        self.closed = true;
        self.pair.closed = true;
    }

    pub fn get_onmessage(self: *MessagePort) ?js.Function {
        return self.onmessage_cbk;
    }
    pub fn get_onmessageerror(self: *MessagePort) ?js.Function {
        return self.onmessageerror_cbk;
    }

    pub fn set_onmessage(self: *MessagePort, listener: EventHandler.Listener, page: *Page) !void {
        if (self.onmessage_cbk) |cbk| {
            try self.unregister("message", cbk.id);
        }
        self.onmessage_cbk = try self.register(page.arena, "message", listener);

        // When onmessage is set directly, then it's like start() was called.
        // If addEventListener('message') is used, the app has to call start()
        // explicitly.
        try self._start();
    }

    pub fn set_onmessageerror(self: *MessagePort, listener: EventHandler.Listener, page: *Page) !void {
        if (self.onmessageerror_cbk) |cbk| {
            try self.unregister("messageerror", cbk.id);
        }
        self.onmessageerror_cbk = try self.register(page.arena, "messageerror", listener);
    }

    // called from our pair. If port1.postMessage("x") is called, then this
    // will be called on port2.
    fn dispatchOrQueue(self: *MessagePort, obj: js.Object, arena: Allocator) !void {
        // our pair should have checked this already
        std.debug.assert(self.closed == false);

        if (self.started) {
            return self.dispatch(try obj.persist());
        }

        if (self.queue.items.len > MAX_QUEUE_SIZE) {
            // This isn't part of the spec, but not putting a limit is reckless
            return error.MessageQueueLimit;
        }
        return self.queue.append(arena, try obj.persist());
    }

    fn dispatch(self: *MessagePort, obj: js.Object) !void {
        // obj is already persisted, don't use `MessageEvent.constructor`, but
        // go directly to `init`, which assumes persisted objects.
        var evt = try MessageEvent.init(.{ .data = obj });
        _ = try parser.eventTargetDispatchEvent(
            parser.toEventTarget(MessagePort, self),
            @as(*parser.Event, @ptrCast(&evt)),
        );
    }

    fn register(
        self: *MessagePort,
        alloc: Allocator,
        typ: []const u8,
        listener: EventHandler.Listener,
    ) !?js.Function {
        const target = @as(*parser.EventTarget, @ptrCast(self));
        const eh = (try EventHandler.register(alloc, target, typ, listener, null)) orelse unreachable;
        return eh.callback;
    }

    fn unregister(self: *MessagePort, typ: []const u8, cbk_id: usize) !void {
        const et = @as(*parser.EventTarget, @ptrCast(self));
        const lst = try parser.eventTargetHasListener(et, typ, false, cbk_id);
        if (lst == null) {
            return;
        }
        try parser.eventTargetRemoveEventListener(et, typ, lst.?, false);
    }
};

pub const MessageEvent = struct {
    const Event = @import("../events/event.zig").Event;
    const DOMException = @import("exceptions.zig").DOMException;

    pub const prototype = *Event;
    pub const Exception = DOMException;
    pub const union_make_copy = true;

    proto: parser.Event,
    data: ?js.Object,

    // You would think if port1 sends to port2, the source would be port2
    // (which is how I read the documentation), but it appears to always be
    // null. It can always be set explicitly via the constructor;
    source: ?js.Object,

    origin: []const u8,

    // This is used for Server-Sent events. Appears to always be an empty
    // string for MessagePort messages.
    last_event_id: []const u8,

    // This might be related to the "transfer" option of postMessage which
    // we don't yet support. For "normal" message, it's always an empty array.
    // Though it could be set explicitly via the constructor
    ports: []*MessagePort,

    const Options = struct {
        data: ?js.Object = null,
        source: ?js.Object = null,
        origin: []const u8 = "",
        lastEventId: []const u8 = "",
        ports: []*MessagePort = &.{},
    };

    pub fn constructor(opts: Options) !MessageEvent {
        return init(.{
            .data = if (opts.data) |obj| try obj.persist() else null,
            .source = if (opts.source) |obj| try obj.persist() else null,
            .ports = opts.ports,
            .origin = opts.origin,
            .lastEventId = opts.lastEventId,
        });
    }

    // This is like "constructor", but it assumes js.Objects have already been
    // persisted. Necessary because this `new MessageEvent()` can be called
    // directly from JS OR from a port.postMessage. In the latter case, data
    // may have already been persisted (as it might need to be queued);
    fn init(opts: Options) !MessageEvent {
        const event = try parser.eventCreate();
        defer parser.eventDestroy(event);
        try parser.eventInit(event, "message", .{});
        parser.eventSetInternalType(event, .message_event);

        return .{
            .proto = event.*,
            .data = opts.data,
            .source = opts.source,
            .ports = opts.ports,
            .origin = opts.origin,
            .last_event_id = opts.lastEventId,
        };
    }

    pub fn get_data(self: *const MessageEvent) !?js.Object {
        return self.data;
    }

    pub fn get_origin(self: *const MessageEvent) []const u8 {
        return self.origin;
    }

    pub fn get_source(self: *const MessageEvent) ?js.Object {
        return self.source;
    }

    pub fn get_ports(self: *const MessageEvent) []*MessagePort {
        return self.ports;
    }

    pub fn get_lastEventId(self: *const MessageEvent) []const u8 {
        return self.last_event_id;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.MessageChannel" {
    try testing.htmlRunner("dom/message_channel.html");
}

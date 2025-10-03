// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const generate = @import("../js/generate.zig");

const Page = @import("../page.zig").Page;
const Node = @import("../dom/node.zig").Node;
const DOMException = @import("../dom/exceptions.zig").DOMException;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const EventTargetUnion = @import("../dom/event_target.zig").Union;
const AbortSignal = @import("../html/AbortController.zig").AbortSignal;

const CustomEvent = @import("custom_event.zig").CustomEvent;
const ProgressEvent = @import("../xhr/progress_event.zig").ProgressEvent;
const MouseEvent = @import("mouse_event.zig").MouseEvent;
const KeyboardEvent = @import("keyboard_event.zig").KeyboardEvent;
const ErrorEvent = @import("../html/error_event.zig").ErrorEvent;
const MessageEvent = @import("../dom/MessageChannel.zig").MessageEvent;
const PopStateEvent = @import("../html/History.zig").PopStateEvent;

// Event interfaces
pub const Interfaces = .{
    Event,
    CustomEvent,
    ProgressEvent,
    MouseEvent,
    KeyboardEvent,
    ErrorEvent,
    MessageEvent,
    PopStateEvent,
};

pub const Union = generate.Union(Interfaces);

// https://dom.spec.whatwg.org/#event
pub const Event = struct {
    pub const Self = parser.Event;
    pub const Exception = DOMException;

    pub const EventInit = parser.EventInit;

    // JS
    // --

    pub const _CAPTURING_PHASE = 1;
    pub const _AT_TARGET = 2;
    pub const _BUBBLING_PHASE = 3;

    pub fn toInterface(evt: *parser.Event) Union {
        return switch (parser.eventGetInternalType(evt)) {
            .event, .abort_signal, .xhr_event => .{ .Event = evt },
            .custom_event => .{ .CustomEvent = @as(*CustomEvent, @ptrCast(evt)).* },
            .progress_event => .{ .ProgressEvent = @as(*ProgressEvent, @ptrCast(evt)).* },
            .mouse_event => .{ .MouseEvent = @as(*parser.MouseEvent, @ptrCast(evt)) },
            .error_event => .{ .ErrorEvent = @as(*ErrorEvent, @ptrCast(evt)).* },
            .message_event => .{ .MessageEvent = @as(*MessageEvent, @ptrCast(evt)).* },
            .keyboard_event => .{ .KeyboardEvent = @as(*parser.KeyboardEvent, @ptrCast(evt)) },
            .pop_state => .{ .PopStateEvent = @as(*PopStateEvent, @ptrCast(evt)).* },
        };
    }

    pub fn constructor(event_type: []const u8, opts: ?EventInit) !*parser.Event {
        const event = try parser.eventCreate();
        try parser.eventInit(event, event_type, opts orelse EventInit{});
        return event;
    }

    // Getters

    pub fn get_type(self: *parser.Event) []const u8 {
        return parser.eventType(self);
    }

    pub fn get_target(self: *parser.Event, page: *Page) !?EventTargetUnion {
        const et = parser.eventTarget(self);
        if (et == null) return null;
        return try EventTarget.toInterface(et.?, page);
    }

    pub fn get_currentTarget(self: *parser.Event, page: *Page) !?EventTargetUnion {
        const et = parser.eventCurrentTarget(self);
        if (et == null) return null;
        return try EventTarget.toInterface(et.?, page);
    }

    pub fn get_eventPhase(self: *parser.Event) u8 {
        return parser.eventPhase(self);
    }

    pub fn get_bubbles(self: *parser.Event) bool {
        return parser.eventBubbles(self);
    }

    pub fn get_cancelable(self: *parser.Event) bool {
        return parser.eventCancelable(self);
    }

    pub fn get_defaultPrevented(self: *parser.Event) bool {
        return parser.eventDefaultPrevented(self);
    }

    pub fn get_isTrusted(self: *parser.Event) bool {
        return parser.eventIsTrusted(self);
    }

    // Even though this is supposed to to provide microsecond resolution, browser
    // return coarser values to protect against fingerprinting. libdom returns
    // seconds, which is good enough.
    pub fn get_timeStamp(self: *parser.Event) u64 {
        return parser.eventTimestamp(self);
    }

    // Methods

    pub fn _initEvent(
        self: *parser.Event,
        eventType: []const u8,
        bubbles: ?bool,
        cancelable: ?bool,
    ) !void {
        const opts = EventInit{
            .bubbles = bubbles orelse false,
            .cancelable = cancelable orelse false,
        };
        return try parser.eventInit(self, eventType, opts);
    }

    pub fn _stopPropagation(self: *parser.Event) !void {
        return parser.eventStopPropagation(self);
    }

    pub fn _stopImmediatePropagation(self: *parser.Event) !void {
        return parser.eventStopImmediatePropagation(self);
    }

    pub fn _preventDefault(self: *parser.Event) !void {
        return parser.eventPreventDefault(self);
    }

    pub fn _composedPath(self: *parser.Event, page: *Page) ![]const EventTargetUnion {
        const et_ = parser.eventTarget(self);
        const et = et_ orelse return &.{};

        var node: ?*parser.Node = switch (parser.eventTargetInternalType(et)) {
            .libdom_node => @as(*parser.Node, @ptrCast(et)),
            .plain => parser.eventTargetToNode(et),
            else => {
                // Window, XHR, MessagePort, etc...no path beyond the event itself
                return &.{try EventTarget.toInterface(et, page)};
            },
        };

        const arena = page.call_arena;
        var path: std.ArrayListUnmanaged(EventTargetUnion) = .empty;
        while (node) |n| {
            try path.append(arena, .{
                .node = try Node.toInterface(n),
            });

            node = parser.nodeParentNode(n);
            if (node == null and parser.nodeType(n) == .document_fragment) {
                // we have a non-continuous hook from a shadowroot to its host (
                // it's parent element). libdom doesn't really support ShdowRoots
                // and, for the most part, that works out well since it naturally
                // provides isolation. But events don't follow the same
                // shadowroot isolation as most other things, so, if this is
                // a parent-less document fragment, we need to check if it has
                // a host.
                if (parser.documentFragmentGetHost(@ptrCast(n))) |host| {
                    node = host;

                    // If a document fragment has a host, then that host
                    // _has_ to have a state and that state _has_ to have
                    // a shadow_root field. All of this is set in Element._attachShadow
                    if (page.getNodeState(host).?.shadow_root.?.mode == .closed) {
                        // if the shadow root is closed, then the composedPath
                        // starts at the host element.
                        path.clearRetainingCapacity();
                    }
                } else {
                    // Our document fragement has no parent and no host, we
                    // can break out of the loop.
                    break;
                }
            }
        }

        if (path.getLastOrNull()) |last| {
            // the Window isn't part of the DOM hierarchy, but for events, it
            // is, so we need to glue it on.
            if (last.node == .HTMLDocument and last.node.HTMLDocument == page.window.document) {
                try path.append(arena, .{ .node = .{ .Window = &page.window } });
            }
        }
        return path.items;
    }
};

pub const EventHandler = struct {
    once: bool,
    capture: bool,
    callback: js.Function,
    node: parser.EventNode,
    listener: *parser.EventListener,

    const js = @import("../js/js.zig");

    pub const Listener = union(enum) {
        function: js.Function,
        object: js.Object,

        pub fn callback(self: Listener, target: *parser.EventTarget) !?js.Function {
            return switch (self) {
                .function => |func| try func.withThis(target),
                .object => |obj| blk: {
                    const func = (try obj.getFunction("handleEvent")) orelse return null;
                    break :blk try func.withThis(try obj.persist());
                },
            };
        }
    };

    pub const Opts = union(enum) {
        flags: Flags,
        capture: bool,

        const Flags = struct {
            once: ?bool,
            capture: ?bool,
            // We ignore this property. It seems to be largely used to help the
            // browser make certain performance tweaks (i.e. the browser knows
            // that the listener won't call preventDefault() and thus can safely
            // run the default as needed).
            passive: ?bool,
            signal: ?*AbortSignal, // currently does nothing
        };
    };

    pub fn register(
        allocator: Allocator,
        target: *parser.EventTarget,
        typ: []const u8,
        listener: Listener,
        opts_: ?Opts,
    ) !?*EventHandler {
        var once = false;
        var capture = false;
        var signal: ?*AbortSignal = null;

        if (opts_) |opts| {
            switch (opts) {
                .capture => |c| capture = c,
                .flags => |f| {
                    once = f.once orelse false;
                    signal = f.signal orelse null;
                    capture = f.capture orelse false;
                },
            }
        }
        const callback = (try listener.callback(target)) orelse return null;

        if (signal) |s| {
            const signal_target = parser.toEventTarget(AbortSignal, s);

            const scb = try allocator.create(SignalCallback);
            scb.* = .{
                .target = target,
                .capture = capture,
                .callback_id = callback.id,
                .typ = try allocator.dupe(u8, typ),
                .signal_target = signal_target,
                .signal_listener = undefined,
                .node = .{ .func = SignalCallback.handle },
            };

            scb.signal_listener = try parser.eventTargetAddEventListener(
                signal_target,
                "abort",
                &scb.node,
                false,
            );
        }

        // check if event target has already this listener
        if (try parser.eventTargetHasListener(target, typ, capture, callback.id) != null) {
            return null;
        }

        const eh = try allocator.create(EventHandler);
        eh.* = .{
            .once = once,
            .capture = capture,
            .callback = callback,
            .node = .{
                .id = callback.id,
                .func = handle,
            },
            .listener = undefined,
        };

        eh.listener = try parser.eventTargetAddEventListener(
            target,
            typ,
            &eh.node,
            capture,
        );
        return eh;
    }

    fn handle(node: *parser.EventNode, event: *parser.Event) void {
        const ievent = Event.toInterface(event);
        const self: *EventHandler = @fieldParentPtr("node", node);
        var result: js.Function.Result = undefined;
        self.callback.tryCall(void, .{ievent}, &result) catch {
            log.debug(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "event handler",
            });
        };

        if (self.once) {
            const target = parser.eventTarget(event).?;
            const typ = parser.eventType(event);
            parser.eventTargetRemoveEventListener(
                target,
                typ,
                self.listener,
                self.capture,
            ) catch {};
        }
    }
};

const SignalCallback = struct {
    typ: []const u8,
    capture: bool,
    callback_id: usize,
    node: parser.EventNode,
    target: *parser.EventTarget,
    signal_target: *parser.EventTarget,
    signal_listener: *parser.EventListener,

    fn handle(node: *parser.EventNode, _: *parser.Event) void {
        const self: *SignalCallback = @fieldParentPtr("node", node);
        self._handle() catch |err| {
            log.err(.app, "event signal handler", .{ .err = err });
        };
    }

    fn _handle(self: *SignalCallback) !void {
        const lst = try parser.eventTargetHasListener(
            self.target,
            self.typ,
            self.capture,
            self.callback_id,
        );
        if (lst == null) {
            return;
        }

        try parser.eventTargetRemoveEventListener(
            self.target,
            self.typ,
            lst.?,
            self.capture,
        );

        // remove the abort signal listener itself
        try parser.eventTargetRemoveEventListener(
            self.signal_target,
            "abort",
            self.signal_listener,
            false,
        );
    }
};

const testing = @import("../../testing.zig");
test "Browser: Event" {
    try testing.htmlRunner("events/event.html");
}

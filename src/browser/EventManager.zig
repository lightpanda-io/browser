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
const builtin = @import("builtin");

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const js = @import("js/js.zig");
const Page = @import("Page.zig");

const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");

const Allocator = std.mem.Allocator;

const IS_DEBUG = builtin.mode == .Debug;

pub const EventManager = @This();

page: *Page,
arena: Allocator,
listener_pool: std.heap.MemoryPool(Listener),
lookup: std.AutoHashMapUnmanaged(usize, std.DoublyLinkedList),

pub fn init(page: *Page) EventManager {
    return .{
        .page = page,
        .lookup = .{},
        .arena = page.arena,
        .listener_pool = std.heap.MemoryPool(Listener).init(page.arena),
    };
}

pub const RegisterOptions = struct {
    once: bool = false,
    capture: bool = false,
    passive: bool = false,
    signal: ?*@import("webapi/AbortSignal.zig") = null,
};
pub fn register(self: *EventManager, target: *EventTarget, typ: []const u8, function: js.Function, opts: RegisterOptions) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "eventManager.register", .{ .type = typ, .capture = opts.capture, .once = opts.once });
    }

    // If a signal is provided and already aborted, don't register the listener
    if (opts.signal) |signal| {
        if (signal.getAborted()) {
            return;
        }
    }

    const gop = try self.lookup.getOrPut(self.arena, @intFromPtr(target));
    if (gop.found_existing) {
        // check for duplicate functions already registered
        var node = gop.value_ptr.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            if (listener.function.eql(function) and listener.capture == opts.capture) {
                return;
            }
            node = n.next;
        }
    } else {
        gop.value_ptr.* = .{};
    }

    const listener = try self.listener_pool.create();
    listener.* = .{
        .node = .{},
        .once = opts.once,
        .capture = opts.capture,
        .passive = opts.passive,
        .function = .{ .value = function },
        .signal = opts.signal,
        .typ = try String.init(self.arena, typ, .{}),
    };
    // append the listener to the list of listeners for this target
    gop.value_ptr.append(&listener.node);
}

pub fn remove(self: *EventManager, target: *EventTarget, typ: []const u8, function: js.Function, use_capture: bool) void {
    const list = self.lookup.getPtr(@intFromPtr(target)) orelse return;
    if (findListener(list, typ, function, use_capture)) |listener| {
        self.removeListener(list, listener);
    }
}

pub fn dispatch(self: *EventManager, target: *EventTarget, event: *Event) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "eventManager.dispatch", .{ .type = event._type_string.str(), .bubbles = event._bubbles });
    }

    event._target = target;
    var was_handled = false;

    defer if (was_handled) {
        self.page.js.runMicrotasks();
    };

    switch (target._type) {
        .node => |node| try self.dispatchNode(node, event, &was_handled),
        .xhr, .window, .abort_signal, .media_query_list => {
            const list = self.lookup.getPtr(@intFromPtr(target)) orelse return;
            try self.dispatchAll(list, target, event, &was_handled);
        },
    }
}

// There are a lot of events that can be attached via addEventListener or as
// a property, like the XHR events, or window.onload. You might think that the
// property is just a shortcut for calling addEventListener, but they are distinct.
// An event set via property cannot be removed by removeEventListener. If you
// set both the property and add a listener, they both execute.
const DispatchWithFunctionOptions = struct {
    context: []const u8,
    inject_target: bool = true,
};
pub fn dispatchWithFunction(self: *EventManager, target: *EventTarget, event: *Event, function_: ?js.Function, comptime opts: DispatchWithFunctionOptions) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "dispatchWithFunction", .{ .type = event._type_string.str(), .context = opts.context, .has_function = function_ != null });
    }

    if (comptime opts.inject_target) {
        event._target = target;
    }

    var was_dispatched = false;
    defer if (was_dispatched) {
        self.page.js.runMicrotasks();
    };

    if (function_) |func| {
        event._current_target = target;
        if (func.call(void, .{event})) {
            was_dispatched = true;
        } else |err| {
            // a non-JS error
            log.warn(.event, opts.context, .{ .err = err });
        }
    }

    const list = self.lookup.getPtr(@intFromPtr(target)) orelse return;
    try self.dispatchAll(list, target, event, &was_dispatched);
}

fn dispatchNode(self: *EventManager, target: *Node, event: *Event, was_handled: *bool) !void {
    var path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;

    var node: ?*Node = target;
    while (node) |n| : (node = n._parent) {
        if (path_len >= path_buffer.len) break;
        path_buffer[path_len] = n.asEventTarget();
        path_len += 1;
    }

    // Even though the window isn't part of the DOM, events always propagate
    // through it in the capture phase
    if (path_len < path_buffer.len) {
        path_buffer[path_len] = self.page.window.asEventTarget();
        path_len += 1;
    }

    const path = path_buffer[0..path_len];

    // Phase 1: Capturing phase (root → target, excluding target)
    // This happens for all events, regardless of bubbling
    event._event_phase = .capturing_phase;
    var i: usize = path_len;
    while (i > 1) {
        i -= 1;
        const current_target = path[i];
        if (self.lookup.getPtr(@intFromPtr(current_target))) |list| {
            try self.dispatchPhase(list, current_target, event, was_handled, true);
            if (event._stop_propagation) {
                event._event_phase = .none;
                return;
            }
        }
    }

    // Phase 2: At target
    event._event_phase = .at_target;
    const target_et = target.asEventTarget();
    if (self.lookup.getPtr(@intFromPtr(target_et))) |list| {
        try self.dispatchPhase(list, target_et, event, was_handled, null);
        if (event._stop_propagation) {
            event._event_phase = .none;
            return;
        }
    }

    // Phase 3: Bubbling phase (target → root, excluding target)
    // This only happens if the event bubbles
    if (event._bubbles) {
        event._event_phase = .bubbling_phase;
        for (path[1..]) |current_target| {
            if (self.lookup.getPtr(@intFromPtr(current_target))) |list| {
                try self.dispatchPhase(list, current_target, event, was_handled, false);
                if (event._stop_propagation) {
                    break;
                }
            }
        }
    }

    event._event_phase = .none;
}

fn dispatchPhase(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool, comptime capture_only: ?bool) !void {
    const page = self.page;
    const typ = event._type_string;

    var node = list.first;
    while (node) |n| {
        // do this now, in case we need to remove n (once: true or aborted signal)
        node = n.next;

        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        if (!listener.typ.eql(typ)) {
            continue;
        }

        // Can be null when dispatching to the target itself
        if (comptime capture_only) |capture| {
            if (listener.capture != capture) {
                continue;
            }
        }

        // If the listener has an aborted signal, remove it and skip
        if (listener.signal) |signal| {
            if (signal.getAborted()) {
                self.removeListener(list, listener);
                continue;
            }
        }

        was_handled.* = true;
        event._current_target = current_target;

        switch (listener.function) {
            .value => |value| try value.call(void, .{event}),
            .string => |string| {
                const str = try page.call_arena.dupeZ(u8, string.str());
                try self.page.js.eval(str, null);
            },
        }

        if (listener.once) {
            self.removeListener(list, listener);
        }

        if (event._stop_immediate_propagation) {
            return;
        }
    }
}

//  Non-Node dispatching (XHR, Window without propagation)
fn dispatchAll(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool) !void {
    return self.dispatchPhase(list, current_target, event, was_handled, null);
}

fn removeListener(self: *EventManager, list: *std.DoublyLinkedList, listener: *Listener) void {
    list.remove(&listener.node);
    self.listener_pool.destroy(listener);
}

fn findListener(list: *const std.DoublyLinkedList, typ: []const u8, function: js.Function, capture: bool) ?*Listener {
    var node = list.first;
    while (node) |n| {
        node = n.next;
        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        if (!listener.function.eql(function)) {
            continue;
        }
        if (listener.capture != capture) {
            continue;
        }
        if (!listener.typ.eqlSlice(typ)) {
            continue;
        }
        return listener;
    }
    return null;
}

const Listener = struct {
    typ: String,
    once: bool,
    capture: bool,
    passive: bool,
    function: Function,
    signal: ?*@import("webapi/AbortSignal.zig") = null,
    node: std.DoublyLinkedList.Node,
};

const Function = union(enum) {
    value: js.Function,
    string: String,

    fn eql(self: Function, func: js.Function) bool {
        return switch (self) {
            .string => false,
            .value => |v| return v.id == func.id,
        };
    }
};

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
list_pool: std.heap.MemoryPool(std.DoublyLinkedList),
lookup: std.AutoHashMapUnmanaged(usize, *std.DoublyLinkedList),
dispatch_depth: usize,
deferred_removals: std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }),

pub fn init(page: *Page) EventManager {
    return .{
        .page = page,
        .lookup = .{},
        .arena = page.arena,
        .list_pool = std.heap.MemoryPool(std.DoublyLinkedList).init(page.arena),
        .listener_pool = std.heap.MemoryPool(Listener).init(page.arena),
        .dispatch_depth = 0,
        .deferred_removals = .{},
    };
}

pub const RegisterOptions = struct {
    once: bool = false,
    capture: bool = false,
    passive: bool = false,
    signal: ?*@import("webapi/AbortSignal.zig") = null,
};

pub const Callback = union(enum) {
    function: js.Function,
    object: js.Object,
};

pub fn register(self: *EventManager, target: *EventTarget, typ: []const u8, callback: Callback, opts: RegisterOptions) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "eventManager.register", .{ .type = typ, .capture = opts.capture, .once = opts.once, .target = target });
    }

    // If a signal is provided and already aborted, don't register the listener
    if (opts.signal) |signal| {
        if (signal.getAborted()) {
            return;
        }
    }

    const gop = try self.lookup.getOrPut(self.arena, @intFromPtr(target));
    if (gop.found_existing) {
        // check for duplicate callbacks already registered
        var node = gop.value_ptr.*.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            if (listener.typ.eqlSlice(typ)) {
                const is_duplicate = switch (callback) {
                    .object => |obj| listener.function.eqlObject(obj),
                    .function => |func| listener.function.eqlFunction(func),
                };
                if (is_duplicate and listener.capture == opts.capture) {
                    return;
                }
            }
            node = n.next;
        }
    } else {
        gop.value_ptr.* = try self.list_pool.create();
        gop.value_ptr.*.* = .{};
    }

    const func = switch (callback) {
        .function => |f| Function{ .value = try f.persist() },
        .object => |o| Function{ .object = try o.persist() },
    };

    const listener = try self.listener_pool.create();
    listener.* = .{
        .node = .{},
        .once = opts.once,
        .capture = opts.capture,
        .passive = opts.passive,
        .function = func,
        .signal = opts.signal,
        .typ = try String.init(self.arena, typ, .{}),
    };
    // append the listener to the list of listeners for this target
    gop.value_ptr.*.append(&listener.node);
}

pub fn remove(self: *EventManager, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    const list = self.lookup.get(@intFromPtr(target)) orelse return;
    if (findListener(list, typ, callback, use_capture)) |listener| {
        self.removeListener(list, listener);
    }
}

pub fn dispatch(self: *EventManager, target: *EventTarget, event: *Event) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "eventManager.dispatch", .{ .type = event._type_string.str(), .bubbles = event._bubbles });
    }

    event._target = target;
    event._dispatch_target = target; // Store original target for composedPath()
    var was_handled = false;

    defer if (was_handled) {
        self.page.js.runMicrotasks();
    };

    switch (target._type) {
        .node => |node| try self.dispatchNode(node, event, &was_handled),
        .xhr,
        .window,
        .abort_signal,
        .media_query_list,
        .message_port,
        .text_track_cue,
        .navigation,
        .screen,
        .screen_orientation,
        .generic,
        => {
            const list = self.lookup.get(@intFromPtr(target)) orelse return;
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
        event._dispatch_target = target; // Store original target for composedPath()
    }

    var was_dispatched = false;
    defer if (was_dispatched) {
        self.page.js.runMicrotasks();
    };

    if (function_) |func| {
        event._current_target = target;
        if (func.callWithThis(void, target, .{event})) {
            was_dispatched = true;
        } else |err| {
            // a non-JS error
            log.warn(.event, opts.context, .{ .err = err });
        }
    }

    const list = self.lookup.get(@intFromPtr(target)) orelse return;
    try self.dispatchAll(list, target, event, &was_dispatched);
}

fn dispatchNode(self: *EventManager, target: *Node, event: *Event, was_handled: *bool) !void {
    const ShadowRoot = @import("webapi/ShadowRoot.zig");

    // Defer runs even on early return - ensures event phase is reset
    // and default actions execute (unless prevented)
    defer {
        event._event_phase = .none;

        // Execute default action if not prevented
        if (event._prevent_default) {
            // can't return in a defer (╯°□°)╯︵ ┻━┻
        } else if (event._type_string.eqlSlice("click")) {
            self.page.handleClick(target) catch |err| {
                log.warn(.event, "page.click", .{ .err = err });
            };
        } else if (event._type_string.eqlSlice("keydown")) {
            self.page.handleKeydown(target, event) catch |err| {
                log.warn(.event, "page.keydown", .{ .err = err });
            };
        }
    }

    var path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;

    var node: ?*Node = target;
    while (node) |n| {
        if (path_len >= path_buffer.len) break;
        path_buffer[path_len] = n.asEventTarget();
        path_len += 1;

        // Check if this node is a shadow root
        if (n.is(ShadowRoot)) |shadow| {
            event._needs_retargeting = true;

            // If event is not composed, stop at shadow boundary
            if (!event._composed) {
                break;
            }

            // Otherwise, jump to the shadow host and continue
            node = shadow._host.asNode();
            continue;
        }

        node = n._parent;
    }

    // Even though the window isn't part of the DOM, events always propagate
    // through it in the capture phase (unless we stopped at a shadow boundary)
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
        if (self.lookup.get(@intFromPtr(current_target))) |list| {
            try self.dispatchPhase(list, current_target, event, was_handled, true);
            if (event._stop_propagation) {
                return;
            }
        }
    }

    // Phase 2: At target
    event._event_phase = .at_target;
    const target_et = target.asEventTarget();
    if (self.lookup.get(@intFromPtr(target_et))) |list| {
        try self.dispatchPhase(list, target_et, event, was_handled, null);
        if (event._stop_propagation) {
            return;
        }
    }

    // Phase 3: Bubbling phase (target → root, excluding target)
    // This only happens if the event bubbles
    if (event._bubbles) {
        event._event_phase = .bubbling_phase;
        for (path[1..]) |current_target| {
            if (self.lookup.get(@intFromPtr(current_target))) |list| {
                try self.dispatchPhase(list, current_target, event, was_handled, false);
                if (event._stop_propagation) {
                    break;
                }
            }
        }
    }
}

fn dispatchPhase(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool, comptime capture_only: ?bool) !void {
    const page = self.page;
    const typ = event._type_string;

    // Track dispatch depth for deferred removal
    self.dispatch_depth += 1;
    defer {
        const dispatch_depth = self.dispatch_depth;
        // Only destroy deferred listeners when we exit the outermost dispatch
        if (dispatch_depth == 1) {
            for (self.deferred_removals.items) |removal| {
                removal.list.remove(&removal.listener.node);
                self.listener_pool.destroy(removal.listener);
            }
            self.deferred_removals.clearRetainingCapacity();
        } else {
            self.dispatch_depth = dispatch_depth - 1;
        }
    }

    // Use the last listener in the list as sentinel - listeners added during dispatch will be after it
    const last_node = list.last orelse return;
    const last_listener: *Listener = @alignCast(@fieldParentPtr("node", last_node));

    // Iterate through the list, stopping after we've encountered the last_listener
    var node = list.first;
    var is_done = false;
    while (node) |n| {
        if (is_done) {
            break;
        }

        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        is_done = (listener == last_listener);
        node = n.next;

        // Skip non-matching listeners
        if (!listener.typ.eql(typ)) {
            continue;
        }
        if (comptime capture_only) |capture| {
            if (listener.capture != capture) {
                continue;
            }
        }

        // Skip removed listeners
        if (listener.removed) {
            continue;
        }

        // If the listener has an aborted signal, remove it and skip
        if (listener.signal) |signal| {
            if (signal.getAborted()) {
                self.removeListener(list, listener);
                continue;
            }
        }

        // Remove "once" listeners BEFORE calling them so nested dispatches don't see them
        if (listener.once) {
            self.removeListener(list, listener);
        }

        was_handled.* = true;
        event._current_target = current_target;

        // Compute adjusted target for shadow DOM retargeting (only if needed)
        const original_target = event._target;
        if (event._needs_retargeting) {
            event._target = getAdjustedTarget(original_target, current_target);
        }

        switch (listener.function) {
            .value => |value| try value.local().callWithThis(void, current_target, .{event}),
            .string => |string| {
                const str = try page.call_arena.dupeZ(u8, string.str());
                try self.page.js.eval(str, null);
            },
            .object => |*obj_global| {
                const obj = obj_global.local();
                if (try obj.getFunction("handleEvent")) |handleEvent| {
                    try handleEvent.callWithThis(void, obj, .{event});
                }
            },
        }

        // Restore original target (only if we changed it)
        if (event._needs_retargeting) {
            event._target = original_target;
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
    // If we're in a dispatch, defer removal to avoid invalidating iteration
    if (self.dispatch_depth > 0) {
        listener.removed = true;
        self.deferred_removals.append(self.arena, .{ .list = list, .listener = listener }) catch unreachable;
    } else {
        // Outside dispatch, remove immediately
        list.remove(&listener.node);
        self.listener_pool.destroy(listener);
    }
}

fn findListener(list: *const std.DoublyLinkedList, typ: []const u8, callback: Callback, capture: bool) ?*Listener {
    var node = list.first;
    while (node) |n| {
        node = n.next;
        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        const matches = switch (callback) {
            .object => |obj| listener.function.eqlObject(obj),
            .function => |func| listener.function.eqlFunction(func),
        };
        if (!matches) {
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
    removed: bool = false,
};

const Function = union(enum) {
    value: js.Function.Global,
    string: String,
    object: js.Object.Global,

    fn eqlFunction(self: Function, func: js.Function) bool {
        return switch (self) {
            .value => |v| v.isEqual(func),
            else => false,
        };
    }

    fn eqlObject(self: Function, obj: js.Object) bool {
        return switch (self) {
            .object => |o| return o.isEqual(obj),
            else => false,
        };
    }
};

// Computes the adjusted target for shadow DOM event retargeting
// Returns the lowest shadow-including ancestor of original_target that is
// also an ancestor-or-self of current_target
fn getAdjustedTarget(original_target: ?*EventTarget, current_target: *EventTarget) ?*EventTarget {
    const ShadowRoot = @import("webapi/ShadowRoot.zig");

    const orig_node = switch ((original_target orelse return null)._type) {
        .node => |n| n,
        else => return original_target,
    };
    const curr_node = switch (current_target._type) {
        .node => |n| n,
        else => return original_target,
    };

    // Walk up from original target, checking if we can reach current target
    var node: ?*Node = orig_node;
    while (node) |n| {
        // Check if current_target is an ancestor of n (or n itself)
        if (isAncestorOrSelf(curr_node, n)) {
            return n.asEventTarget();
        }

        // Cross shadow boundary if needed
        if (n.is(ShadowRoot)) |shadow| {
            node = shadow._host.asNode();
            continue;
        }

        node = n._parent;
    }

    return original_target;
}

// Check if ancestor is an ancestor of (or the same as) node
// WITHOUT crossing shadow boundaries (just regular DOM tree)
fn isAncestorOrSelf(ancestor: *Node, node: *Node) bool {
    if (ancestor == node) {
        return true;
    }

    var current: ?*Node = node._parent;
    while (current) |n| {
        if (n == ancestor) {
            return true;
        }
        current = n._parent;
    }

    return false;
}

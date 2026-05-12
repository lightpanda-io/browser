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
const builtin = @import("builtin");

const js = @import("js/js.zig");
const Page = @import("Page.zig");

const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const EventKey = struct {
    event_target: usize,
    type_string: String,
};

const EventKeyContext = struct {
    pub fn hash(_: @This(), key: EventKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.event_target));
        hasher.update(key.type_string.str());
        return hasher.final();
    }

    pub fn eql(_: @This(), a: EventKey, b: EventKey) bool {
        return a.event_target == b.event_target and a.type_string.eql(b.type_string);
    }
};

// EventManagerBase provides core event listener management without DOM-specific
// functionality. It handles listener registration, removal, and the basic dispatch
// loop for non-propagating events.
pub const EventManagerBase = @This();

arena: Allocator,
listener_pool: std.heap.MemoryPool(Listener),
list_pool: std.heap.MemoryPool(std.DoublyLinkedList),
lookup: std.HashMapUnmanaged(
    EventKey,
    *std.DoublyLinkedList,
    EventKeyContext,
    std.hash_map.default_max_load_percentage,
),
dispatch_depth: usize,
deferred_removals: std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }),

pub fn init(arena: Allocator) EventManagerBase {
    return .{
        .arena = arena,
        .lookup = .{},
        .list_pool = .init(arena),
        .listener_pool = .init(arena),
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

// Returns null when the listener is a no-op per spec: signal already
// aborted, or a duplicate (same type + callback + capture) of an
// already-registered listener. Real errors (OOM, StringTooLarge) still
// propagate. Callers don't have to distinguish "skipped" from "registered"
// unless they need the resulting *Listener (e.g. Frame's load-listener
// tracking).
pub fn register(self: *EventManagerBase, target: *EventTarget, typ: []const u8, callback: Callback, opts: RegisterOptions) !?*Listener {
    if (comptime IS_DEBUG) {
        log.debug(.event, "EventManager.register", .{
            .type = typ,
            .capture = opts.capture,
            .once = opts.once,
            .target = target.toString(),
        });
    }

    // If a signal is provided and already aborted, don't register the listener
    if (opts.signal) |signal| {
        if (signal.getAborted()) {
            return null;
        }
    }

    // Allocate the type string we'll use in both listener and key
    const type_string = try String.init(self.arena, typ, .{});

    const gop = try self.lookup.getOrPut(self.arena, .{
        .type_string = type_string,
        .event_target = @intFromPtr(target),
    });
    if (gop.found_existing) {
        // check for duplicate callbacks already registered. Listeners that
        // have been removed (e.g. a `once` listener that fired mid-dispatch
        // and is awaiting destruction in deferred_removals) are not "in"
        // the listener list per spec — skip them.
        var node = gop.value_ptr.*.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            node = n.next;
            if (listener.removed) continue;
            const is_duplicate = switch (callback) {
                .object => |obj| listener.function.eqlObject(obj),
                .function => |func| listener.function.eqlFunction(func),
            };
            if (is_duplicate and listener.capture == opts.capture) {
                return null;
            }
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
        .typ = type_string,
    };
    // append the listener to the list of listeners for this target
    gop.value_ptr.*.append(&listener.node);

    return listener;
}

pub fn remove(self: *EventManagerBase, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    const list = self.lookup.get(.{
        .type_string = .wrap(typ),
        .event_target = @intFromPtr(target),
    }) orelse return;
    if (findListener(list, callback, use_capture)) |listener| {
        self.removeListener(list, listener);
    }
}

pub fn removeListener(self: *EventManagerBase, list: *std.DoublyLinkedList, listener: *Listener) void {
    // Already removed (or queued for removal). Avoids double-pushing the
    // same listener into deferred_removals — which would double-free at
    // the outer-dispatch cleanup — if e.g. a `once` listener also calls
    // removeEventListener on itself.
    if (listener.removed) return;
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

/// Check if there are any listeners registered for a target/type combination.
pub fn hasListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8) bool {
    return self.lookup.get(.{
        .event_target = @intFromPtr(target),
        .type_string = .wrap(typ),
    }) != null;
}

/// Get the listener list for a target/type, if any exist.
pub fn getListeners(self: *EventManagerBase, target: *EventTarget, event_type: String) ?*std.DoublyLinkedList {
    return self.lookup.get(.{
        .event_target = @intFromPtr(target),
        .type_string = event_type,
    });
}

// Dispatching can be recursive from the compiler's point of view, so we need to
// give it an explicit error set so that other parts of the code can use an
// inferred error.
pub const DispatchError = error{
    OutOfMemory,
    StringTooLarge,
    CompilationError,
    JsException,
};

pub const DispatchDirectOptions = struct {
    context: []const u8 = "dispatchDirect",
    inject_target: bool = true,
};

/// Direct dispatch for non-DOM targets. No propagation - just calls the property
/// handler and registered listeners. Caller is responsible for event ref counting.
/// Handler can be: null, ?js.Function.Global, ?js.Function.Temp, or js.Function
pub fn dispatchDirect(
    self: *EventManagerBase,
    arena: Allocator,
    ctx: *js.Context,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    page: *Page,
    comptime opts: DispatchDirectOptions,
) DispatchError!void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "dispatchDirect", .{ .type = event._type_string, .context = opts.context });
    }

    event.acquireRef();
    defer _ = event.releaseRef(page);

    if (comptime opts.inject_target) {
        event._target = target;
        event._dispatch_target = target;
    }

    var ls: js.Local.Scope = undefined;
    ctx.localScope(&ls);
    defer {
        ls.local.runMicrotasks();
        ls.deinit();
    }

    // Call the property handler (e.g., onmessage) if present
    if (getFunction(handler, &ls.local)) |func| {
        event._current_target = target;
        _ = func.callWithThis(void, target, .{event}) catch |err| {
            log.warn(.event, opts.context, .{ .err = err });
        };
    }

    // Call listeners registered via addEventListener
    const list = self.getListeners(target, event._type_string) orelse return;

    // This is a slightly simplified version of what you'll find in EventManager.
    // dispatchPhase. It is simpler because, for direct dispatching, we know
    // there's no ancestors and only the single target phase.

    // Track dispatch depth for deferred removal
    self.dispatch_depth += 1;
    defer {
        self.dispatch_depth -= 1;
        // Only destroy deferred listeners when we exit the outermost dispatch
        if (self.dispatch_depth == 0) {
            for (self.deferred_removals.items) |removal| {
                removal.list.remove(&removal.listener.node);
                self.listener_pool.destroy(removal.listener);
            }
            self.deferred_removals.clearRetainingCapacity();
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

        event._current_target = target;
        event._in_passive_listener = listener.passive;

        try listener.run(arena, &ls.local, event, opts.context);

        event._in_passive_listener = false;

        if (event._stop_immediate_propagation) {
            return;
        }
    }
}

fn getFunction(handler: anytype, local: *const js.Local) ?js.Function {
    const T = @TypeOf(handler);
    const ti = @typeInfo(T);

    if (ti == .null) {
        return null;
    }
    if (ti == .optional) {
        return getFunction(handler orelse return null, local);
    }
    return switch (T) {
        js.Function => handler,
        js.Function.Temp => local.toLocal(handler),
        js.Function.Global => local.toLocal(handler),
        else => @compileError("handler must be null or \\??js.Function(\\.(Temp|Global))?"),
    };
}

/// Check if there are any listeners for a direct dispatch (non-DOM target).
/// Use this to avoid creating an event when there are no listeners.
pub fn hasDirectListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    if (hasHandler(handler)) {
        return true;
    }
    return self.hasListeners(target, typ);
}

fn hasHandler(handler: anytype) bool {
    const ti = @typeInfo(@TypeOf(handler));
    if (ti == .null) {
        return false;
    }
    if (ti == .optional) {
        return handler != null;
    }
    return true;
}

fn findListener(list: *const std.DoublyLinkedList, callback: Callback, capture: bool) ?*Listener {
    var node = list.first;
    while (node) |n| {
        node = n.next;
        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        // Per spec, a removed listener isn't "in" the list anymore; skip
        // entries still present only because their deferred removal hasn't
        // been flushed yet.
        if (listener.removed) continue;
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
        return listener;
    }
    return null;
}

pub const Listener = struct {
    typ: String,
    once: bool,
    capture: bool,
    passive: bool,
    function: Function,
    signal: ?*@import("webapi/AbortSignal.zig") = null,
    node: std.DoublyLinkedList.Node,
    removed: bool = false,

    // Per DOM §2.9 step 4 substep 8 ("Inner invoke"), a listener callback that
    // throws must have its exception *reported* to the global error handler,
    // not propagated to the dispatch caller — subsequent listeners on the same
    // target and the rest of the propagation path must still run.
    //
    // Caller must set `event._current_target` before invoking — the function-
    // listener variant uses it as `this`, matching the spec contract that a
    // listener sees its current target via both `event.currentTarget` and `this`.
    pub fn run(
        self: *const Listener,
        arena: Allocator,
        local: *const js.Local,
        event: *Event,
        comptime context: []const u8,
    ) error{OutOfMemory}!void {
        switch (self.function) {
            .value => |value| local.toLocal(value).callWithThis(void, event._current_target.?, .{event}) catch |err| {
                log.warn(.event, context, .{ .err = err });
            },
            .string => |string| {
                const str = try arena.dupeZ(u8, string.str());
                local.eval(str, null) catch |err| {
                    log.warn(.event, context, .{ .err = err });
                };
            },
            .object => |obj_global| {
                const obj = local.toLocal(obj_global);
                const handle_event = obj.getFunction("handleEvent") catch |err| blk: {
                    log.warn(.event, context, .{ .err = err });
                    break :blk null;
                };
                if (handle_event) |handleEvent| {
                    handleEvent.callWithThis(void, obj, .{event}) catch |err| {
                        log.warn(.event, context, .{ .err = err });
                    };
                }
            },
        }
    }
};

pub const Function = union(enum) {
    value: js.Function.Global,
    string: String,
    object: js.Object.Global,

    pub fn eqlFunction(self: Function, func: js.Function) bool {
        return switch (self) {
            .value => |v| v.isEqual(func),
            else => false,
        };
    }

    pub fn eqlObject(self: Function, obj: js.Object) bool {
        return switch (self) {
            .object => |o| return o.isEqual(obj),
            else => false,
        };
    }
};

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

const js = @import("js/js.zig");
const Page = @import("Page.zig");

const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const ErrorEvent = @import("webapi/event/ErrorEvent.zig");
const BeforeUnloadEvent = @import("webapi/event/BeforeUnloadEvent.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

// EventManagerBase provides core event listener management without DOM-specific
// functionality. It handles listener registration, removal, and the basic dispatch
// loop for non-propagating events.
pub const EventManagerBase = @This();

arena: Allocator,
listener_pool: std.heap.MemoryPool(Listener),
list_pool: std.heap.MemoryPool(std.DoublyLinkedList),
// @intFromPtr(event_target) -> [{type, listener-linked-list}]
lookup: std.AutoHashMapUnmanaged(usize, std.ArrayList(TypeListeners)),
dispatch_depth: usize,
deferred_removals: std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }),

pub fn init(arena: Allocator) EventManagerBase {
    return .{
        .arena = arena,
        .lookup = .{},
        .list_pool = .empty,
        .listener_pool = .empty,
        .dispatch_depth = 0,
        .deferred_removals = .empty,
    };
}

const TypeListeners = struct {
    typ: String,
    list: *std.DoublyLinkedList,
};

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
    if (comptime lp.IS_DEBUG) {
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

    const list, const type_string = try self.getOrCreateList(target, typ);

    // check for duplicate callbacks already registered. Listeners that
    // have been removed (e.g. a `once` listener that fired mid-dispatch
    // and is awaiting destruction in deferred_removals) are not "in"
    // the listener list per spec — skip them.
    var node = list.first;
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

    const func = switch (callback) {
        .function => |f| Function{ .value = try f.persist() },
        .object => |o| Function{ .object = try o.persist() },
    };

    const listener = try self.listener_pool.create(self.arena);
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
    list.append(&listener.node);

    return listener;
}

// re-setting keeps its order in the list
pub fn setHandler(self: *EventManagerBase, target: *EventTarget, typ: []const u8, handler: ?js.Function.Global) !?*Listener {
    return self.setHandlerFunction(target, typ, if (handler) |h| .{ .handler = h } else null);
}

// An event handler content attribute, compiled on first use. The source must
// live as long as the page. Currently, the source is always from an attribute
// entry's slice (attribute values are also tied to the page.arena).
// As always careful not to use String.str() on a stack-allocated String!
pub fn setHandlerSource(self: *EventManagerBase, target: *EventTarget, typ: []const u8, source: ?[]const u8) !?*Listener {
    return self.setHandlerFunction(target, typ, if (source) |s| .{ .handler_source = s } else null);
}

// The handler's function, compiling a content attribute in `ctx`.
pub fn getHandler(self: *EventManagerBase, ctx: *js.Context, target: *EventTarget, typ: []const u8) ?js.Function.Global {
    const list = self.getListeners(target, .wrap(typ)) orelse return null;
    const listener = findHandler(list) orelse return null;
    return listener.compileHandler(ctx, target);
}

fn setHandlerFunction(self: *EventManagerBase, target: *EventTarget, typ: []const u8, function: ?Function) !?*Listener {
    if (self.getListeners(target, .wrap(typ))) |list| {
        if (findHandler(list)) |listener| {
            if (function) |f| {
                listener.function.release();
                listener.function = f;
            } else {
                self.removeListener(list, listener);
            }
            return null;
        }
    }
    const f = function orelse return null;

    const list, const type_string = try self.getOrCreateList(target, typ);
    const listener = try self.listener_pool.create(self.arena);
    listener.* = .{
        .node = .{},
        .once = false,
        .capture = false,
        .passive = false,
        .function = f,
        .typ = type_string,
    };
    list.append(&listener.node);
    return listener;
}

fn findHandler(list: *const std.DoublyLinkedList) ?*Listener {
    var node = list.first;
    while (node) |n| : (node = n.next) {
        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        if (listener.removed) {
            continue;
        }
        switch (listener.function) {
            .handler, .handler_source => return listener,
            .value, .object => {},
        }
    }
    return null;
}

fn getOrCreateList(self: *EventManagerBase, target: *EventTarget, typ: []const u8) !struct { *std.DoublyLinkedList, String } {
    const arena = self.arena;
    const gop = try self.lookup.getOrPut(arena, @intFromPtr(target));
    if (gop.found_existing == false) {
        gop.value_ptr.* = .empty;
    }
    const types = gop.value_ptr;

    if (findType(types.items, .wrap(typ))) |existing| {
        return .{ existing.list, existing.typ };
    }
    const type_string = try String.init(arena, typ, .{});
    const list = try self.list_pool.create(arena);
    list.* = .{};
    try types.append(arena, .{ .typ = type_string, .list = list });
    return .{ list, type_string };
}

pub fn remove(self: *EventManagerBase, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    const list = self.getListeners(target, .wrap(typ)) orelse return;
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
        self.destroyListener(listener);
    }
}

pub fn destroyListener(self: *EventManagerBase, listener: *Listener) void {
    listener.function.release();
    self.listener_pool.destroy(listener);
}

/// Drops every listener on `target`.
pub fn removeTarget(self: *EventManagerBase, target: *EventTarget) void {
    var kv = self.lookup.fetchRemove(@intFromPtr(target)) orelse return;
    for (kv.value.items) |type_listeners| {
        const list = type_listeners.list;
        var node = list.first;
        while (node) |n| {
            node = n.next;
            self.removeListener(list, @alignCast(@fieldParentPtr("node", n)));
        }
        if (self.dispatch_depth == 0) {
            self.list_pool.destroy(list);
        } else {
            // we leak this until the arena is cleared, no big deal
        }
    }
    kv.value.deinit(self.arena);
}

/// Check if there are any listeners registered for a target/type combination.
fn hasListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8) bool {
    const list = self.getListeners(target, .wrap(typ)) orelse return false;
    return hasListener(list, .any);
}

/// Get the listener list for a target/type, if any exist.
pub fn getListeners(self: *EventManagerBase, target: *EventTarget, event_type: String) ?*std.DoublyLinkedList {
    const types = self.lookup.get(@intFromPtr(target)) orelse return null;
    const entry = findType(types.items, event_type) orelse return null;
    return entry.list;
}

fn findType(types: []const TypeListeners, event_type: String) ?*const TypeListeners {
    for (types) |*entry| {
        if (entry.typ.eql(event_type)) {
            return entry;
        }
    }
    return null;
}

/// Whether the list still holds a listener, or one that can call
/// preventDefault. A listener removed during a dispatch stays linked until
/// the dispatch unwinds, but isn't "in" the list anymore, same as
/// findListener.
pub fn hasListener(list: *const std.DoublyLinkedList, comptime which: enum { any, non_passive }) bool {
    var node = list.first;
    while (node) |n| : (node = n.next) {
        const listener: *align(8) Listener = @fieldParentPtr("node", n);
        if (listener.removed) {
            continue;
        }
        if (which == .any or !listener.passive) {
            return true;
        }
    }
    return false;
}

// Dispatching can be recursive from the compiler's point of view, so we need to
// give it an explicit error set so that other parts of the code can use an
// inferred error.
pub const DispatchError = error{
    OutOfMemory,
    StringTooLarge,
    CompilationError,
    JsException,
    ExecutionTerminated,
};

pub const DispatchDirectOptions = struct {
    context: []const u8 = "dispatchDirect",
    inject_target: bool = true,
    run_microtasks: bool = true,
};

/// Direct dispatch for non-DOM targets. No propagation - just calls the
/// registered listeners. Caller is responsible for event ref counting.
pub fn dispatchDirect(
    self: *EventManagerBase,
    ctx: *js.Context,
    target: *EventTarget,
    event: *Event,
    page: *Page,
    comptime opts: DispatchDirectOptions,
) DispatchError!void {
    if (comptime lp.IS_DEBUG) {
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
        if (comptime opts.run_microtasks) {
            ls.local.runMicrotasks();
        }
        ls.deinit();
    }

    // This is a slightly simplified version of what you'll find in EventManager.
    // dispatchPhase. It is simpler because, for direct dispatching, we know
    // there's no ancestors and only the single target phase.
    event._event_phase = .at_target;
    defer {
        event._event_phase = .none;
        // Per spec, currentTarget is only set while listeners are being invoked
        event._current_target = null;
        event._stop_propagation = false;
        event._stop_immediate_propagation = false;
    }

    // Track dispatch depth for deferred removal.
    self.dispatch_depth += 1;
    defer {
        self.dispatch_depth -= 1;
        // Only destroy deferred listeners when we exit the outermost dispatch
        if (self.dispatch_depth == 0) {
            for (self.deferred_removals.items) |removal| {
                removal.list.remove(&removal.listener.node);
                self.destroyListener(removal.listener);
            }
            self.deferred_removals.clearRetainingCapacity();
        }
    }

    // Per spec the set of listeners is collected at the start of dispatch, so
    // a listener added while we're dispatching must not be invoked for this
    // event.
    const list = self.getListeners(target, event._type_string) orelse return;
    const last_node = list.last orelse return;

    // Use the last listener present at dispatch start as sentinel - listeners
    // added during dispatch will be after it
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

        try listener.run(&ls.local, event, opts.context);

        event._in_passive_listener = false;

        if (event._stop_immediate_propagation) {
            return;
        }
    }
}

/// Check if there are any listeners for a direct dispatch (non-DOM target).
/// Use this to avoid creating an event when there are no listeners.
pub fn hasDirectListeners(self: *EventManagerBase, target: *EventTarget, typ: []const u8) bool {
    return self.hasListeners(target, typ);
}

pub fn hasHandler(self: *EventManagerBase, target: *EventTarget, typ: []const u8) bool {
    const list = self.getListeners(target, .wrap(typ)) orelse return false;
    return findHandler(list) != null;
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
        self: *Listener,
        local: *const js.Local,
        event: *Event,
        comptime context: []const u8,
    ) error{ExecutionTerminated}!void {
        // An event caused from an isolated world (e.g. element.focus() called
        // over CDP) must reach a main-world listener with main-world wrappers.
        if (self.function == .handler_source) {
            _ = self.compileHandler(local.ctx, event._current_target.?);
        }
        if (self.otherWorldContext(local)) |ctx| {
            var ls: js.Local.Scope = undefined;
            ctx.localScope(&ls);
            defer ls.deinit();
            return self.invoke(&ls.local, event, context);
        }
        return self.invoke(local, event, context);
    }

    // The context the callback was created in, when it belongs to another
    // world than `local`.
    fn otherWorldContext(self: *const Listener, local: *const js.Local) ?*js.Context {
        const handle: *const js.v8.Object = switch (self.function) {
            .value => |f| @ptrCast(local.toLocal(f).handle),
            .object => |o| local.toLocal(o).handle,
            .handler => |h| @ptrCast(local.toLocal(h orelse return null).handle),
            // compiled by run() before this is called
            .handler_source => unreachable,
        };
        const ctx = js.Context.fromObject(handle) orelse return null;
        if (ctx.identity == local.ctx.identity) {
            return null;
        }
        return ctx;
    }

    fn invoke(
        self: *Listener,
        local: *const js.Local,
        event: *Event,
        comptime context: []const u8,
    ) error{ExecutionTerminated}!void {
        switch (self.function) {
            .value => |value| {
                var try_catch: js.TryCatch = undefined;
                try_catch.init(local);
                defer try_catch.deinit();
                local.toLocal(value).callWithThisRethrow(void, event._current_target.?, .{event}) catch |err| switch (err) {
                    // The rethrow variant surfaces a thrown JS exception as
                    // TryCatchRethrow so our enclosing TryCatch holds it.
                    error.JsException, error.TryCatchRethrow => {
                        event._listeners_did_throw = true;
                        reportException(&try_catch, local);
                    },
                    error.ExecutionTerminated => return error.ExecutionTerminated,
                    else => log.debug(.event, context, .{ .err = err }),
                };
            },
            .handler => |h| try runHandler(local.toLocal(h orelse return), local, event, context),
            // compiled by run() before this is called
            .handler_source => unreachable,
            .object => |obj_global| {
                const obj = local.toLocal(obj_global);

                var try_catch: js.TryCatch = undefined;
                try_catch.init(local);
                defer try_catch.deinit();

                // Get(handleEvent) can run a getter: a thrown exception is
                // reported like an exception from the listener itself.
                const handle_event_value = obj.get("handleEvent") catch |err| {
                    if (err == error.JsException) {
                        event._listeners_did_throw = true;
                        reportException(&try_catch, local);
                    } else {
                        log.debug(.event, context, .{ .err = err });
                    }
                    return;
                };

                if (!handle_event_value.isFunction()) {
                    // Per the callback interface invocation steps, a
                    // non-callable handleEvent is a reported TypeError.
                    event._listeners_did_throw = true;
                    reportExceptionValue(local, .{
                        .local = local,
                        .handle = local.isolate.createTypeError("handleEvent is not a function"),
                    });
                    return;
                }

                const handle_event = js.Function{
                    .local = local,
                    .handle = @ptrCast(handle_event_value.handle),
                };
                handle_event.callWithThisRethrow(void, obj, .{event}) catch |err| switch (err) {
                    error.JsException, error.TryCatchRethrow => {
                        event._listeners_did_throw = true;
                        reportException(&try_catch, local);
                    },
                    error.ExecutionTerminated => return error.ExecutionTerminated,
                    else => log.debug(.event, context, .{ .err = err }),
                };
            },
        }
    }

    fn compileHandler(self: *Listener, ctx: *js.Context, target: *EventTarget) ?js.Function.Global {
        switch (self.function) {
            .handler => |h| return h,
            .handler_source => |source| {
                // compiled on first use (then turned into a handler), in the
                // main world whichever world asks first.
                // on error, the handler becomes null.
                const main_ctx = switch (ctx.global) {
                    .frame => |frame| frame.main_js,
                    .worker => ctx,
                };
                var ls: js.Local.Scope = undefined;
                main_ctx.localScope(&ls);
                defer ls.deinit();

                var try_catch: js.TryCatch = undefined;
                try_catch.init(&ls.local);
                defer try_catch.deinit();

                // window.onerror (incl. <body onerror>) gets the decomposed
                // ErrorEvent: see runHandler.
                const is_window_error = target._type == .window and self.typ.eql(comptime .wrap("error"));
                const compiled = if (is_window_error)
                    ls.local.compileFunction(source, &.{ "event", "source", "lineno", "colno", "error" }, &.{})
                else
                    ls.local.compileFunction(source, &.{"event"}, &.{});

                const handler: ?js.Function.Global = blk: {
                    const func = compiled catch |err| {
                        log.debug(.js, "event handler source", .{ .source = source, .err = err });
                        reportException(&try_catch, &ls.local);
                        break :blk null;
                    };
                    break :blk func.persist() catch null;
                };
                self.function = .{ .handler = handler };
                return handler;
            },
            .value, .object => unreachable,
        }
    }

    // Runs an on* handler. Returning true cancels the event. Special handling
    // for the window.onerror's ErrorEvent callback which is decomposed into parameters :/
    fn runHandler(handler: js.Function, local: *const js.Local, event: *Event, comptime context: []const u8) error{ExecutionTerminated}!void {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const this = event._current_target.?;
        const error_event: ?*ErrorEvent = blk: {
            if (this._type != .window and this._type != .worker_global_scope) break :blk null;
            if (event._type_string.eql(comptime .wrap("error")) == false) break :blk null;
            break :blk event.is(ErrorEvent);
        };

        const result = blk: {
            if (error_event) |e| {
                break :blk handler.callWithThisRethrow(js.Value, this, .{
                    e._message,
                    e._filename,
                    e._line_number,
                    e._column_number,
                    e._error,
                });
            }
            break :blk handler.callWithThisRethrow(js.Value, this, .{event});
        } catch |err| switch (err) {
            error.JsException, error.TryCatchRethrow => {
                event._listeners_did_throw = true;
                reportException(&try_catch, local);
                return;
            },
            error.ExecutionTerminated => return error.ExecutionTerminated,
            else => {
                local.ctx.page.recordJsError(err);
                log.debug(.event, context, .{ .err = err });
                return;
            },
        };

        if (this._type == .window and event._type_string.eql(comptime .wrap("beforeunload"))) {
            const before_unload = event.is(BeforeUnloadEvent) orelse return;
            if (result.isNullOrUndefined()) {
                return;
            }
            event.preventDefault();
            if (before_unload._return_value.len == 0) {
                // onbeforeunload is weird, the return value is converting to
                // a string, so false -> "false" and it doesn't cancel. Only
                // a null does.
                const str = result.toStringSlice() catch |err| {
                    log.debug(.event, context, .{ .err = err });
                    return;
                };
                before_unload.setReturnValue(str) catch |err| {
                    log.debug(.event, context, .{ .err = err });
                };
            }
            return;
        }

        const cancel = if (error_event != null) result.isTrue() else result.isFalse();
        if (cancel) {
            event.preventDefault();
        }
    }

    // Reports a listener exception to the relevant global (firing
    // window.onerror / an "error" event) without stopping the dispatch.
    pub fn reportException(try_catch: *js.TryCatch, local: *const js.Local) void {
        const exc = try_catch.exceptionValue() orelse return;
        reportExceptionValue(local, exc);
    }

    fn reportExceptionValue(local: *const js.Local, exc: js.Value) void {
        local.ctx.global.reportError(exc) catch |err| {
            log.debug(.event, "listener report error", .{ .err = err });
        };
    }
};

pub const Function = union(enum) {
    value: js.Function.Global,
    object: js.Object.Global,
    // An event handler (onclick, ...): see setHandler. Null when its content
    // attribute didn't compile.
    handler: ?js.Function.Global,
    handler_source: []const u8,

    fn release(self: Function) void {
        switch (self) {
            .value => |f| f.release(),
            .handler => |h| if (h) |f| f.release(),
            .object => |o| o.release(),
            .handler_source => {},
        }
    }

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

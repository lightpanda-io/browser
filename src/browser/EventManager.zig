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
const Frame = @import("Frame.zig");
const EventManagerBase = @import("EventManagerBase.zig");

const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const Window = @import("webapi/Window.zig");
const Element = @import("webapi/Element.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const MediaQueryList = @import("webapi/css/MediaQueryList.zig");
const XMLHttpRequestEventTarget = @import("webapi/net/XMLHttpRequestEventTarget.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

// Re-export types from EventManagerBase for API compatibility
pub const RegisterOptions = EventManagerBase.RegisterOptions;
pub const Callback = EventManagerBase.Callback;
pub const Listener = EventManagerBase.Listener;

pub const EventManager = @This();

frame: *Frame,
base: EventManagerBase,

// Used as an optimization in Page._documentIsComplete. If we know there are no
// 'load' listeners in the document, we can skip dispatching the per-resource
// 'load' event (e.g. amazon product page has no listener and ~350 resources)
has_dom_load_listener: bool,

pub fn init(arena: Allocator, frame: *Frame) EventManager {
    return .{
        .frame = frame,
        .has_dom_load_listener = false,
        .base = EventManagerBase.init(arena),
    };
}

pub fn register(self: *EventManager, target: *EventTarget, typ: []const u8, callback: Callback, opts: RegisterOptions) !void {
    const listener = (try self.base.register(target, typ, callback, opts)) orelse return;

    // Track load listeners on DOM nodes for optimization
    if (target._type == .node and listener.typ.eql(comptime .wrap("load"))) {
        self.has_dom_load_listener = true;
    }
}

pub fn remove(self: *EventManager, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    self.base.remove(target, typ, callback, use_capture);
}

// Re-export DispatchError from base
pub const DispatchError = EventManagerBase.DispatchError;

pub fn dispatch(self: *EventManager, target: *EventTarget, event: *Event) DispatchError!void {
    event.acquireRef();
    defer _ = event.releaseRef(self.frame._page);

    // Increment event count for Event Timing API
    self.frame.window._performance._event_counts.increment(event._type_string.str());

    if (comptime lp.IS_DEBUG) {
        log.debug(.event, "eventManager.dispatch", .{ .type = event._type_string.str(), .bubbles = event._bubbles });
    }

    switch (target._type) {
        .node => try self.dispatchNode(target.subtype(Node), event),
        .xhr => try self.dispatchDirect(target, event, target.subtype(XMLHttpRequestEventTarget).inlineHandler(event._type_string), .{ .context = "dispatch" }),
        .media_query_list => try self.dispatchDirect(target, event, target.subtype(MediaQueryList).inlineHandler(event._type_string), .{ .context = "dispatch" }),
        .performance => try self.dispatchDirect(target, event, target.subtype(Performance).inlineHandler(event._type_string), .{ .context = "dispatch" }),
        .window => try self.dispatchDirect(target, event, windowInlineHandler(target.subtype(Window), event._type_string), .{ .context = "dispatch" }),
        else => try self.dispatchDirect(target, event, null, .{ .context = "dispatch" }),
    }
}

// Resolves the Window's property event handler for the given event type.
fn windowInlineHandler(window: *Window, typ: lp.String) ?js.Function.Global {
    const global_event_handlers = @import("webapi/global_event_handlers.zig");
    const handler_type = global_event_handlers.fromEventType(typ.str()) orelse return null;
    return switch (handler_type) {
        .onerror => window._on_error,
        .onload => window._on_load,
        .onblur => window._on_blur,
        .onfocus => window._on_focus,
        .onresize => window._on_resize,
        .onscroll => window._on_scroll,
        else => null,
    };
}

// There are a lot of events that can be attached via addEventListener or as
// a property, like the XHR events, or window.onload. You might think that the
// property is just a shortcut for calling addEventListener, but they are distinct.
// An event set via property cannot be removed by removeEventListener. If you
// set both the property and add a listener, they both execute.
pub const DispatchDirectOptions = EventManagerBase.DispatchDirectOptions;

// Direct dispatch for non-DOM targets (Window, XHR, AbortSignal) or DOM nodes with
// property handlers. No propagation - just calls the handler and registered listeners.
// Handler can be: null, ?js.Function.Global or js.Function
pub fn dispatchDirect(self: *EventManager, target: *EventTarget, event: *Event, handler: anytype, comptime opts: DispatchDirectOptions) !void {
    const frame = self.frame;

    // Set window.event to the currently dispatching event (WHATWG spec)
    const window = frame.window;
    const prev_event = window._current_event;
    window._current_event = event;
    defer window._current_event = prev_event;

    try self.base.dispatchDirect(frame.call_arena, frame.js, target, event, handler, frame._page, opts);
}

/// Check if there are any listeners for a direct dispatch (non-DOM target).
/// Use this to avoid creating an event when there are no listeners.
pub fn hasDirectListeners(self: *EventManager, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self.base.hasDirectListeners(target, typ, handler);
}

fn dispatchNode(self: *EventManager, target: *Node, event: *Event) !void {
    const target_et = target.asEventTarget();
    event._target = target_et;
    event._dispatch_target = target_et; // Store original target for composedPath()

    // The relatedTarget as authored. Every invocation sees it retargeted
    // against its own currentTarget (DOM dispatch step 5.7), so the event
    // keeps the unadjusted value between invocations.
    const original_related: ?*EventTarget = if (event.relatedTargetPtr()) |p| p.* else null;
    event._dispatch_related_target = original_related;
    if (original_related) |related| {
        if (rootIsShadowRoot(related)) {
            event._needs_retargeting = true;
        }
        // DOM dispatch step 5: an event whose relatedTarget retargets onto the
        // target itself isn't dispatched at all.
        const adjusted = getAdjustedTarget(related, target_et);
        if (adjusted == target_et and related != target_et) {
            return;
        }
    }

    const frame = self.frame;

    // Set window.event to the currently dispatching event (WHATWG spec)
    const window = frame.window;
    const prev_event = window._current_event;
    window._current_event = event;
    defer window._current_event = prev_event;

    var was_handled = false;

    // Create a single scope for all event handlers in this dispatch.
    // This ensures function handles passed to queueMicrotask remain valid
    // throughout the entire dispatch, preventing crashes when microtasks run.
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer {
        if (was_handled) {
            ls.local.runMicrotasks();
        }
        ls.deinit();
    }

    const activation_state = try ActivationState.create(event, target, frame);

    var path_len: usize = 0;
    var node_path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;
    var clear_targets = false;

    // Defer runs even on early return - ensures event phase is reset
    // and default actions execute (unless prevented)
    defer {
        event._event_phase = .none;
        event._current_target = null;
        event._stop_propagation = false;
        event._stop_immediate_propagation = false;
        if (clear_targets) {
            // Don't leak nodes living in a shadow tree: reset the targets
            // (decided on the pre-dispatch tree, see below).
            event._target = null;
            if (event.relatedTargetPtr()) |related_ptr| {
                related_ptr.* = null;
            }
        } else if (event._needs_retargeting and node_path_len > 0) {
            const last = path_buffer[node_path_len - 1];
            const adjusted = getAdjustedTarget(event._dispatch_target, last);
            event._target = if (rootIsShadowRoot(adjusted)) null else adjusted;
            if (event.relatedTargetPtr()) |related_ptr| {
                related_ptr.* = getAdjustedTarget(original_related, last);
            }
        }
        // Handle checkbox/radio activation rollback or commit
        if (activation_state) |state| {
            state.restore(event, frame);
        }

        // Execute default action if not prevented
        if (event._prevent_default) {
            // can't return in a defer (╯°□°)╯︵ ┻━┻
        } else if (event._type_string.eql(comptime .wrap("click"))) {
            // Per spec, only a MouseEvent "click" is an activation event, and
            // the activation target is the nearest inclusive ancestor with
            // activation behavior (ancestors only for bubbling events).
            if (event.is(@import("webapi/event/MouseEvent.zig")) != null) {
                if (Frame.user_input.findClickActivationTarget(target, event._bubbles)) |activation_target| {
                    Frame.user_input.handleClick(frame, activation_target, target) catch |err| {
                        log.warn(.event, "frame.click", .{ .err = err });
                    };
                }
            }
        } else if (event._type_string.eql(comptime .wrap("keydown"))) {
            Frame.user_input.handleKeydown(frame, target, event) catch |err| {
                log.warn(.event, "frame.keydown", .{ .err = err });
            };
        } else if (event._type_string.eql(comptime .wrap("keyup"))) {
            Frame.user_input.handleKeyup(frame, target, event) catch |err| {
                log.warn(.event, "frame.keyup", .{ .err = err });
            };
        }
    }

    const built = buildEventPath(target, event, frame, &path_buffer);
    path_len = built.len;
    node_path_len = path_len;
    if (built.crosses_shadow_root) {
        event._needs_retargeting = true;
    }

    // Even though the window isn't part of the DOM, most events propagate
    // through it in the capture phase. It only participates when the tree's
    // root is the document (not for detached trees, and not when propagation
    // stopped at a shadow boundary). The only explicit exception is "load".
    if (event._type_string.eql(comptime .wrap("load")) == false and path_len < path_buffer.len) {
        const root_is_document = blk: {
            if (path_len == 0) break :blk false;
            const root = path_buffer[path_len - 1].is(Node) orelse break :blk false;
            break :blk root._type == .document;
        };
        if (root_is_document) {
            path_buffer[path_len] = frame.window.asEventTarget();
            path_len += 1;
        }
    }

    // DOM dispatch: decide up front — on the pre-dispatch tree, so listener
    // mutations can't affect it — whether target and relatedTarget must be
    // reset after dispatch because they would expose nodes inside a shadow
    // tree.
    if (node_path_len > 0) {
        const last = path_buffer[node_path_len - 1];
        if (event._needs_retargeting) {
            if (rootIsShadowRoot(getAdjustedTarget(event._dispatch_target, last))) {
                clear_targets = true;
            }
        }
        if (event.relatedTargetPtr()) |related_ptr| {
            if (related_ptr.*) |related| {
                if (rootIsShadowRoot(getAdjustedTarget(related, last))) {
                    clear_targets = true;
                }
            }
        }
    }

    const path = path_buffer[0..path_len];

    // Phase 1: Capturing phase (root → target, excluding target)
    // This happens for all events, regardless of bubbling
    event._event_phase = .capturing_phase;
    var i: usize = path_len;
    while (i > 1) {
        i -= 1;
        if (event._stop_propagation) return;
        const current_target = path[i];
        if (self.base.getListeners(current_target, event._type_string)) |list| {
            try self.dispatchPhase(list, current_target, event, &was_handled, &ls.local, true);
        }
    }

    // Phase 2: At target
    if (event._stop_propagation) return;
    event._event_phase = .at_target;

    blk: {
        // Get inline handler (e.g., onclick property) for this target
        if (self.getInlineHandler(target_et, event)) |inline_handler| {
            was_handled = true;
            event._current_target = target_et;

            const prev_current_event = window._current_event;
            window._current_event = currentEventForTarget(target_et, event);
            defer window._current_event = prev_current_event;

            const adjusted: ?AdjustedTargets = if (event._needs_retargeting) .apply(event, target_et) else null;

            // Inline handlers (e.g. onclick property) follow the same "report,
            // don't propagate" rule as addEventListener listeners — see Listener.run.
            var caught: js.TryCatch.Caught = .{};
            const handler_return: ?js.Value = ls.toLocal(inline_handler).tryCallWithThis(js.Value, target_et, .{event}, &caught) catch |err| ret: {
                if (err == error.ExecutionTerminated) {
                    return error.ExecutionTerminated;
                }
                frame._page.recordJsError(err);
                log.warn(.event, "inline handler", .{ .err = err, .caught = caught });
                break :ret null;
            };
            processHandlerReturnValue(event, handler_return);

            if (adjusted) |a| {
                a.restore(event);
            }

            if (event._stop_propagation) {
                return;
            }

            if (event._stop_immediate_propagation) {
                break :blk;
            }
        }

        // Per spec, the target is invoked once during the capturing iteration
        // and once during the bubbling iteration, each with its own snapshot
        // of the listener list: a bubble listener added while running the
        // target's capture listeners must run.
        if (self.base.getListeners(target_et, event._type_string)) |list| {
            try self.dispatchPhase(list, target_et, event, &was_handled, &ls.local, true);
            if (event._stop_propagation) {
                return;
            }
        }
        if (self.base.getListeners(target_et, event._type_string)) |list| {
            try self.dispatchPhase(list, target_et, event, &was_handled, &ls.local, false);
            if (event._stop_propagation) {
                return;
            }
        }
    }

    // Phase 3: Bubbling phase (target → root, excluding target)
    // This only happens if the event bubbles
    if (event._bubbles) {
        event._event_phase = .bubbling_phase;
        for (path[1..]) |current_target| {
            if (event._stop_propagation) break;

            // Inline handlers (e.g. shadowRoot.onslotchange, div.onclick) are
            // regular non-capture listeners and also fire on ancestors.
            if (self.getInlineHandler(current_target, event)) |inline_handler| {
                was_handled = true;
                event._current_target = current_target;

                const prev_current_event = window._current_event;
                window._current_event = currentEventForTarget(current_target, event);
                defer window._current_event = prev_current_event;

                const adjusted: ?AdjustedTargets = if (event._needs_retargeting) .apply(event, current_target) else null;

                var caught: js.TryCatch.Caught = .{};
                const handler_return: ?js.Value = ls.toLocal(inline_handler).tryCallWithThis(js.Value, current_target, .{event}, &caught) catch |err| ret: {
                    if (err == error.ExecutionTerminated) {
                        return error.ExecutionTerminated;
                    }
                    frame._page.recordJsError(err);
                    log.warn(.event, "inline handler", .{ .err = err, .caught = caught });
                    break :ret null;
                };
                processHandlerReturnValue(event, handler_return);

                if (adjusted) |a| {
                    a.restore(event);
                }

                if (event._stop_propagation) {
                    break;
                }
                if (event._stop_immediate_propagation) {
                    continue;
                }
            }

            if (self.base.getListeners(current_target, event._type_string)) |list| {
                try self.dispatchPhase(list, current_target, event, &was_handled, &ls.local, false);
            }
        }
    }
}

fn processHandlerReturnValue(event: *Event, handler_return: ?js.Value) void {
    const ret = handler_return orelse return;
    if (ret.isFalse() and !event._type_string.eql(comptime .wrap("error"))) {
        event.preventDefault();
    }
}

// Per spec ("invocation target in shadow tree"), window.event is left
// undefined while invoking listeners whose target lives in a shadow tree.
fn currentEventForTarget(target: *EventTarget, event: *Event) ?*Event {
    return if (rootIsShadowRoot(target)) null else event;
}

fn dispatchPhase(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool, local: *const js.Local, comptime capture_only: ?bool) !void {
    const frame = self.frame;
    const base = &self.base;

    const window = frame.window;
    const prev_current_event = window._current_event;
    window._current_event = currentEventForTarget(current_target, event);
    defer window._current_event = prev_current_event;

    // Track dispatch depth for deferred removal
    base.dispatch_depth += 1;
    defer {
        base.dispatch_depth -= 1;
        // Only destroy deferred listeners when we exit the outermost dispatch
        if (base.dispatch_depth == 0) {
            for (base.deferred_removals.items) |removal| {
                removal.list.remove(&removal.listener.node);
                base.listener_pool.destroy(removal.listener);
            }
            base.deferred_removals.clearRetainingCapacity();
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
                base.removeListener(list, listener);
                continue;
            }
        }

        // Remove "once" listeners BEFORE calling them so nested dispatches don't see them
        if (listener.once) {
            base.removeListener(list, listener);
        }

        was_handled.* = true;
        event._current_target = current_target;
        event._in_passive_listener = listener.passive;

        // Compute adjusted targets for shadow DOM retargeting (only if needed)
        const adjusted: ?AdjustedTargets = if (event._needs_retargeting) .apply(event, current_target) else null;

        try listener.run(frame.call_arena, local, event, "listener");

        event._in_passive_listener = false;

        if (adjusted) |a| {
            a.restore(event);
        }

        if (event._stop_immediate_propagation) {
            return;
        }
    }
}

fn getInlineHandler(self: *EventManager, target: *EventTarget, event: *Event) ?js.Function.Global {
    const global_event_handlers = @import("webapi/global_event_handlers.zig");
    const handler_type = global_event_handlers.fromEventType(event._type_string.str()) orelse return null;

    // Non-element targets (e.g. ShadowRoot.onslotchange) only ever set their
    // handler via the property, so the lookup alone covers them.
    if (self.frame._event_target_attr_listeners.get(.{ .target = target, .handler = handler_type })) |cached| {
        return cached;
    }

    // Look up the inline handler for this target
    const html_element = switch (target._type) {
        .node => target.subtype(Node).is(Element.Html) orelse return null,
        // The Window stores its event handlers in dedicated fields; an event
        // propagating to the window must fire them too.
        .window => {
            const w = target.subtype(Window);
            return switch (handler_type) {
                .onerror => w._on_error,
                .onload => w._on_load,
                .onblur => w._on_blur,
                .onfocus => w._on_focus,
                .onresize => w._on_resize,
                .onscroll => w._on_scroll,
                else => null,
            };
        },
        else => return null,
    };

    return html_element.getAttributeFunction(handler_type, self.frame) catch |err| {
        log.warn(.event, "inline html callback", .{ .type = handler_type, .err = err });
        return null;
    };
}

// An invocation sees the target and the relatedTarget retargeted against its
// own currentTarget (DOM dispatch step 5.7). The event carries the unadjusted
// values in between, so each invocation adjusts and then restores them.
const AdjustedTargets = struct {
    target: ?*EventTarget,
    related: ?*EventTarget,
    related_ptr: ?*?*EventTarget,

    fn apply(event: *Event, current_target: *EventTarget) AdjustedTargets {
        const related_ptr = event.relatedTargetPtr();
        const original: AdjustedTargets = .{
            .target = event._target,
            .related = if (related_ptr) |p| p.* else null,
            .related_ptr = related_ptr,
        };

        event._target = getAdjustedTarget(original.target, current_target);
        if (related_ptr) |p| {
            p.* = getAdjustedTarget(original.related, current_target);
        }
        return original;
    }

    fn restore(self: AdjustedTargets, event: *Event) void {
        event._target = self.target;
        if (self.related_ptr) |p| {
            p.* = self.related;
        }
    }
};

pub const EventPath = struct {
    len: usize,
    // Whether a shadow root sits on the path, i.e. whether an invocation can
    // see a target other than the one the event was dispatched at.
    crosses_shadow_root: bool,
};

// Builds the node portion of an event's propagation path (DOM dispatch step
// 5.7) into `buffer`. Window, which follows the document at the end of the
// path, is left to the caller: the rules for including it differ between
// dispatch and composedPath().
pub fn buildEventPath(target: *Node, event: *Event, frame: ?*Frame, buffer: []*EventTarget) EventPath {
    if (buffer.len == 0) {
        return .{ .len = 0, .crosses_shadow_root = false };
    }

    const target_root = target.getRootNode(.{});
    const related = event._dispatch_related_target;

    // The root of the spec's `target` variable, which moves to each host we
    // cross on the way out. A node it still contains is inside the current
    // target's tree, where the event always propagates; the first node beyond
    // it is where the relatedTarget can cut the path short.
    var scope_root = target_root;

    buffer[0] = target.asEventTarget();
    var path: EventPath = .{ .len = 1, .crosses_shadow_root = target.is(ShadowRoot) != null };

    var node = eventPathParent(target, event, target_root, frame);
    while (node) |n| {
        if (path.len == buffer.len) {
            break;
        }

        const et = n.asEventTarget();
        if (!isShadowIncludingInclusiveAncestor(scope_root, n)) {
            // DOM dispatch step 5.7: the path stops at the relatedTarget.
            if (related != null and getAdjustedTarget(related, et) == et) {
                break;
            }
            scope_root = n.getRootNode(.{});
        }

        if (n.is(ShadowRoot) != null) {
            path.crosses_shadow_root = true;
        }
        buffer[path.len] = et;
        path.len += 1;

        node = eventPathParent(n, event, target_root, frame);
    }

    return path;
}

// DOM spec "get the parent" for a node on the event path: an assigned
// slottable's parent is its slot, routing the event into the slot's shadow
// tree, and a shadow root's is its host — except for a non-composed event,
// which stops at the root of the tree it was dispatched in.
fn eventPathParent(node: *Node, event: *Event, target_root: *Node, frame: ?*Frame) ?*Node {
    if (node.is(ShadowRoot)) |shadow| {
        if (!event._composed and node == target_root) {
            return null;
        }
        return shadow._host.asNode();
    }

    if (frame) |f| {
        if (node.assignedSlot(f)) |slot| {
            return slot.asNode();
        }
    }

    return node._parent;
}

// DOM spec "retarget": walk original_target out of shadow trees until the
// node is visible from current_target's tree.
fn getAdjustedTarget(original_target: ?*EventTarget, current_target: *EventTarget) ?*EventTarget {
    const orig_node = (original_target orelse return null).is(Node) orelse return original_target;
    const curr_node = current_target.is(Node) orelse return original_target;

    var node = orig_node;
    while (true) {
        const root = node.getRootNode(.{});
        const shadow = root.is(ShadowRoot) orelse return node.asEventTarget();
        if (isShadowIncludingInclusiveAncestor(root, curr_node)) {
            return node.asEventTarget();
        }
        node = shadow._host.asNode();
    }
}

fn isShadowIncludingInclusiveAncestor(ancestor: *Node, node: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| {
        if (cur == ancestor) {
            return true;
        }
        if (cur.is(ShadowRoot)) |shadow| {
            n = shadow._host.asNode();
            continue;
        }
        n = cur._parent;
    }
    return false;
}

// Whether the target's tree root (without crossing shadow boundaries) is a
// shadow root. Used for the spec's post-dispatch "clear targets" step.
fn rootIsShadowRoot(target_: ?*EventTarget) bool {
    const target = target_ orelse return false;
    const node = target.is(Node) orelse return false;
    return node.containingShadowRoot() != null;
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

// Handles the default action for clicking on input checked/radio. Maybe this
// could be generalized if needed, but I'm not sure. This wasn't obvious to me
// but when an input is clicked, it's important to think about both the intent
// and the actual result. Imagine you have an unchecked checkbox. When clicked,
// the checkbox immediately becomes checked, and event handlers see this "checked"
// intent. But a listener can preventDefault() in which case the check we did at
// the start will be undone.
// This is a bit more complicated for radio buttons, as the checking/unchecking
// and the rollback can impact a different radio input. So if you "check" a radio
// the intent is that it becomes checked and whatever was checked before becomes
// unchecked, so that if you have to rollback (because of a preventDefault())
// then both inputs have to revert to their original values.
const ActivationState = struct {
    old_checked: bool,
    input: *Element.Html.Input,
    previously_checked_radio: ?*Input,

    const Input = Element.Html.Input;

    fn create(event: *Event, target: *Node, frame: *Frame) !?ActivationState {
        if (event._type_string.eql(comptime .wrap("click")) == false) {
            return null;
        }

        // Per spec, only a MouseEvent "click" is an activation event.
        if (event.is(@import("webapi/event/MouseEvent.zig")) == null) {
            return null;
        }

        const activation_node = Frame.user_input.findClickActivationTarget(target, event._bubbles) orelse return null;
        const input = activation_node.is(Element.Html.Input) orelse return null;
        if (input._input_type != .checkbox and input._input_type != .radio) {
            return null;
        }

        const old_checked = input._checked;
        var previously_checked_radio: ?*Element.Html.Input = null;

        // For radio buttons, find the currently checked radio in the group
        if (input._input_type == .radio and !old_checked) {
            previously_checked_radio = try findCheckedRadioInGroup(input, frame);
        }

        // Toggle checkbox or check radio (which unchecks others in group)
        const new_checked = if (input._input_type == .checkbox) !old_checked else true;
        try input.setChecked(new_checked, frame);

        return .{
            .input = input,
            .old_checked = old_checked,
            .previously_checked_radio = previously_checked_radio,
        };
    }

    fn restore(self: *const ActivationState, event: *const Event, frame: *Frame) void {
        const input = self.input;
        if (event._prevent_default) {
            // Rollback: restore previous state
            input._checked = self.old_checked;
            input._checked_dirty = true;
            if (self.previously_checked_radio) |prev_radio| {
                prev_radio._checked = true;
                prev_radio._checked_dirty = true;
            }
            return;
        }

        // Commit: fire input and change events only if state actually changed
        // and the element is connected to a document (detached elements don't fire).
        // For checkboxes, state always changes. For radios, only if was unchecked.
        const state_changed = (input._input_type == .checkbox) or !self.old_checked;
        if (state_changed and input.asElement().asNode().isConnected()) {
            fireEvent(frame, input, "input") catch |err| {
                log.warn(.event, "input event", .{ .err = err });
            };
            fireEvent(frame, input, "change") catch |err| {
                log.warn(.event, "change event", .{ .err = err });
            };
        }
    }

    fn findCheckedRadioInGroup(input: *Input, frame: *Frame) !?*Input {
        const elem = input.asElement();

        const name = elem.getAttributeSafe(comptime .wrap("name")) orelse return null;
        if (name.len == 0) {
            return null;
        }

        const form = input.getForm(frame);

        // Walk from the root of the tree containing this element
        // This handles both document-attached and orphaned elements
        const root = elem.asNode().getRootNode(.{});

        const TreeWalker = @import("webapi/TreeWalker.zig");
        var walker = TreeWalker.Full.init(root, .{});

        while (walker.next()) |node| {
            const other_element = node.is(Element) orelse continue;
            const other_input = other_element.is(Input) orelse continue;

            if (other_input._input_type != .radio) {
                continue;
            }

            // Skip the input we're checking from
            if (other_input == input) {
                continue;
            }

            const other_name = other_element.getAttributeSafe(comptime .wrap("name")) orelse continue;
            if (!std.mem.eql(u8, name, other_name)) {
                continue;
            }

            // Check if same form context
            const other_form = other_input.getForm(frame);
            if (form) |f| {
                const of = other_form orelse continue;
                if (f != of) {
                    continue; // Different forms
                }
            } else if (other_form != null) {
                continue; // form is null but other has a form
            }

            if (other_input._checked) {
                return other_input;
            }
        }

        return null;
    }

    // Fire input or change event
    fn fireEvent(frame: *Frame, input: *Input, comptime typ: []const u8) !void {
        const event = try Event.initTrusted(comptime .wrap(typ), .{
            .bubbles = true,
            .cancelable = false,
        }, frame._page);

        const target = input.asElement().asEventTarget();
        try frame._event_manager.dispatch(target, event);
    }
};

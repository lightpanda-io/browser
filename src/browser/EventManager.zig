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
const Element = @import("webapi/Element.zig");

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

pub const EventManager = @This();

page: *Page,
arena: Allocator,
// Used as an optimization in Page._documentIsComplete. If we know there are no
// 'load' listeners in the document, we can skip dispatching the per-resource
// 'load' event (e.g. amazon product page has no listener and ~350 resources)
has_dom_load_listener: bool,
listener_pool: std.heap.MemoryPool(Listener),
ignore_list: std.ArrayList(*Listener),
list_pool: std.heap.MemoryPool(std.DoublyLinkedList),
lookup: std.HashMapUnmanaged(
    EventKey,
    *std.DoublyLinkedList,
    EventKeyContext,
    std.hash_map.default_max_load_percentage,
),
dispatch_depth: usize,
deferred_removals: std.ArrayList(struct { list: *std.DoublyLinkedList, listener: *Listener }),

pub fn init(arena: Allocator, page: *Page) EventManager {
    return .{
        .page = page,
        .lookup = .{},
        .arena = arena,
        .ignore_list = .{},
        .list_pool = .init(arena),
        .listener_pool = .init(arena),
        .dispatch_depth = 0,
        .deferred_removals = .{},
        .has_dom_load_listener = false,
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
        log.debug(.event, "eventManager.register", .{ .type = typ, .capture = opts.capture, .once = opts.once, .target = target.toString() });
    }

    // If a signal is provided and already aborted, don't register the listener
    if (opts.signal) |signal| {
        if (signal.getAborted()) {
            return;
        }
    }

    // Allocate the type string we'll use in both listener and key
    const type_string = try String.init(self.arena, typ, .{});

    if (type_string.eql(comptime .wrap("load")) and target._type == .node) {
        self.has_dom_load_listener = true;
    }

    const gop = try self.lookup.getOrPut(self.arena, .{
        .type_string = type_string,
        .event_target = @intFromPtr(target),
    });
    if (gop.found_existing) {
        // check for duplicate callbacks already registered
        var node = gop.value_ptr.*.first;
        while (node) |n| {
            const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
            const is_duplicate = switch (callback) {
                .object => |obj| listener.function.eqlObject(obj),
                .function => |func| listener.function.eqlFunction(func),
            };
            if (is_duplicate and listener.capture == opts.capture) {
                return;
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
        .typ = type_string,
    };
    // append the listener to the list of listeners for this target
    gop.value_ptr.*.append(&listener.node);

    // Track load listeners for script execution ignore list
    if (type_string.eql(comptime .wrap("load"))) {
        try self.ignore_list.append(self.arena, listener);
    }
}

pub fn remove(self: *EventManager, target: *EventTarget, typ: []const u8, callback: Callback, use_capture: bool) void {
    const list = self.lookup.get(.{
        .type_string = .wrap(typ),
        .event_target = @intFromPtr(target),
    }) orelse return;
    if (findListener(list, callback, use_capture)) |listener| {
        self.removeListener(list, listener);
    }
}

pub fn clearIgnoreList(self: *EventManager) void {
    self.ignore_list.clearRetainingCapacity();
}

// Dispatching can be recursive from the compiler's point of view, so we need to
// give it an explicit error set so that other parts of the code can use and
// inferred error.
const DispatchError = error{
    OutOfMemory,
    StringTooLarge,
    JSExecCallback,
    CompilationError,
    ExecutionError,
    JsException,
};

pub const DispatchOpts = struct {
    // A "load" event triggered by a script (in ScriptManager) should not trigger
    // a "load" listener added within that script. Therefore, any "load" listener
    // that we add go into an ignore list until after the script finishes executing.
    // The ignore list is only checked when apply_ignore  == true, which is only
    // set by the ScriptManager when raising the script's "load" event.
    apply_ignore: bool = false,
};

pub fn dispatch(self: *EventManager, target: *EventTarget, event: *Event) DispatchError!void {
    return self.dispatchOpts(target, event, .{});
}

pub fn dispatchOpts(self: *EventManager, target: *EventTarget, event: *Event, comptime opts: DispatchOpts) DispatchError!void {
    event.acquireRef();
    defer event.deinit(false, self.page);

    if (comptime IS_DEBUG) {
        log.debug(.event, "eventManager.dispatch", .{ .type = event._type_string.str(), .bubbles = event._bubbles });
    }

    event._target = target;
    event._dispatch_target = target; // Store original target for composedPath()
    var was_handled = false;

    defer if (was_handled) {
        var ls: js.Local.Scope = undefined;
        self.page.js.localScope(&ls);
        defer ls.deinit();
        ls.local.runMicrotasks();
    };

    switch (target._type) {
        .node => |node| try self.dispatchNode(node, event, &was_handled, opts),
        .xhr,
        .window,
        .abort_signal,
        .media_query_list,
        .message_port,
        .text_track_cue,
        .navigation,
        .screen,
        .screen_orientation,
        .visual_viewport,
        .file_reader,
        .generic,
        => {
            const list = self.lookup.get(.{
                .event_target = @intFromPtr(target),
                .type_string = event._type_string,
            }) orelse return;
            try self.dispatchAll(list, target, event, &was_handled, opts);
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
    event.acquireRef();
    defer event.deinit(false, self.page);

    if (comptime IS_DEBUG) {
        log.debug(.event, "dispatchWithFunction", .{ .type = event._type_string.str(), .context = opts.context, .has_function = function_ != null });
    }

    if (comptime opts.inject_target) {
        event._target = target;
        event._dispatch_target = target; // Store original target for composedPath()
    }

    var was_dispatched = false;
    defer if (was_dispatched) {
        var ls: js.Local.Scope = undefined;
        self.page.js.localScope(&ls);
        defer ls.deinit();
        ls.local.runMicrotasks();
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

    const list = self.lookup.get(.{
        .event_target = @intFromPtr(target),
        .type_string = event._type_string,
    }) orelse return;
    try self.dispatchAll(list, target, event, &was_dispatched, .{});
}

fn dispatchNode(self: *EventManager, target: *Node, event: *Event, was_handled: *bool, comptime opts: DispatchOpts) !void {
    const ShadowRoot = @import("webapi/ShadowRoot.zig");

    const page = self.page;
    const activation_state = ActivationState.create(event, target, page);

    // Defer runs even on early return - ensures event phase is reset
    // and default actions execute (unless prevented)
    defer {
        event._event_phase = .none;
        event._stop_propagation = false;
        event._stop_immediate_propagation = false;
        // Handle checkbox/radio activation rollback or commit
        if (activation_state) |state| {
            state.restore(event, page);
        }

        // Execute default action if not prevented
        if (event._prevent_default) {
            // can't return in a defer (╯°□°)╯︵ ┻━┻
        } else if (event._type_string.eql(comptime .wrap("click"))) {
            page.handleClick(target) catch |err| {
                log.warn(.event, "page.click", .{ .err = err });
            };
        } else if (event._type_string.eql(comptime .wrap("keydown"))) {
            page.handleKeydown(target, event) catch |err| {
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

    // Even though the window isn't part of the DOM, most events propagate
    // through it in the capture phase (unless we stopped at a shadow boundary)
    // The only explicit exception is "load"
    if (event._type_string.eql(comptime .wrap("load")) == false) {
        if (path_len < path_buffer.len) {
            path_buffer[path_len] = page.window.asEventTarget();
            path_len += 1;
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
        if (self.lookup.get(.{
            .event_target = @intFromPtr(current_target),
            .type_string = event._type_string,
        })) |list| {
            try self.dispatchPhase(list, current_target, event, was_handled, comptime .init(true, opts));
        }
    }

    // Phase 2: At target
    if (event._stop_propagation) return;
    event._event_phase = .at_target;
    const target_et = target.asEventTarget();

    blk: {
        // Get inline handler (e.g., onclick property) for this target
        if (self.getInlineHandler(target_et, event)) |inline_handler| {
            was_handled.* = true;
            event._current_target = target_et;

            var ls: js.Local.Scope = undefined;
            self.page.js.localScope(&ls);
            defer ls.deinit();

            try ls.toLocal(inline_handler).callWithThis(void, target_et, .{event});

            if (event._stop_propagation) {
                return;
            }

            if (event._stop_immediate_propagation) {
                break :blk;
            }
        }

        if (self.lookup.get(.{
            .type_string = event._type_string,
            .event_target = @intFromPtr(target_et),
        })) |list| {
            try self.dispatchPhase(list, target_et, event, was_handled, comptime .init(null, opts));
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
            if (self.lookup.get(.{
                .type_string = event._type_string,
                .event_target = @intFromPtr(current_target),
            })) |list| {
                try self.dispatchPhase(list, current_target, event, was_handled, comptime .init(false, opts));
            }
        }
    }
}

const DispatchPhaseOpts = struct {
    capture_only: ?bool = null,
    apply_ignore: bool = false,

    fn init(capture_only: ?bool, opts: DispatchOpts) DispatchPhaseOpts {
        return .{
            .capture_only = capture_only,
            .apply_ignore = opts.apply_ignore,
        };
    }
};

fn dispatchPhase(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool, comptime opts: DispatchPhaseOpts) !void {
    const page = self.page;

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
    node_loop: while (node) |n| {
        if (is_done) {
            break;
        }

        const listener: *Listener = @alignCast(@fieldParentPtr("node", n));
        is_done = (listener == last_listener);
        node = n.next;

        // Skip non-matching listeners
        if (comptime opts.capture_only) |capture| {
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

        if (comptime opts.apply_ignore) {
            for (self.ignore_list.items) |ignored| {
                if (ignored == listener) {
                    continue :node_loop;
                }
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

        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        switch (listener.function) {
            .value => |value| try ls.toLocal(value).callWithThis(void, current_target, .{event}),
            .string => |string| {
                const str = try page.call_arena.dupeZ(u8, string.str());
                try ls.local.eval(str, null);
            },
            .object => |obj_global| {
                const obj = ls.toLocal(obj_global);
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
fn dispatchAll(self: *EventManager, list: *std.DoublyLinkedList, current_target: *EventTarget, event: *Event, was_handled: *bool, comptime opts: DispatchOpts) !void {
    return self.dispatchPhase(list, current_target, event, was_handled, comptime .init(null, opts));
}

fn getInlineHandler(self: *EventManager, target: *EventTarget, event: *Event) ?js.Function.Global {
    const global_event_handlers = @import("webapi/global_event_handlers.zig");
    const handler_type = global_event_handlers.fromEventType(event._type_string.str()) orelse return null;

    // Look up the inline handler for this target
    const html_element = switch (target._type) {
        .node => |n| n.is(Element.Html) orelse return null,
        else => return null,
    };

    return html_element.getAttributeFunction(handler_type, self.page) catch |err| {
        log.warn(.event, "inline html callback", .{ .type = handler_type, .err = err });
        return null;
    };
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

fn findListener(list: *const std.DoublyLinkedList, callback: Callback, capture: bool) ?*Listener {
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

    fn create(event: *const Event, target: *Node, page: *Page) ?ActivationState {
        if (event._type_string.eql(comptime .wrap("click")) == false) {
            return null;
        }

        const input = target.is(Element.Html.Input) orelse return null;
        if (input._input_type != .checkbox and input._input_type != .radio) {
            return null;
        }

        const old_checked = input._checked;
        var previously_checked_radio: ?*Element.Html.Input = null;

        // For radio buttons, find the currently checked radio in the group
        if (input._input_type == .radio and !old_checked) {
            previously_checked_radio = try findCheckedRadioInGroup(input, page);
        }

        // Toggle checkbox or check radio (which unchecks others in group)
        const new_checked = if (input._input_type == .checkbox) !old_checked else true;
        try input.setChecked(new_checked, page);

        return .{
            .input = input,
            .old_checked = old_checked,
            .previously_checked_radio = previously_checked_radio,
        };
    }

    fn restore(self: *const ActivationState, event: *const Event, page: *Page) void {
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
            fireEvent(page, input, "input") catch |err| {
                log.warn(.event, "input event", .{ .err = err });
            };
            fireEvent(page, input, "change") catch |err| {
                log.warn(.event, "change event", .{ .err = err });
            };
        }
    }

    fn findCheckedRadioInGroup(input: *Input, page: *Page) !?*Input {
        const elem = input.asElement();

        const name = elem.getAttributeSafe(comptime .wrap("name")) orelse return null;
        if (name.len == 0) {
            return null;
        }

        const form = input.getForm(page);

        // Walk from the root of the tree containing this element
        // This handles both document-attached and orphaned elements
        const root = elem.asNode().getRootNode(null);

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
            const other_form = other_input.getForm(page);
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
    fn fireEvent(page: *Page, input: *Input, comptime typ: []const u8) !void {
        const event = try Event.initTrusted(comptime .wrap(typ), .{
            .bubbles = true,
            .cancelable = false,
        }, page);

        const target = input.asElement().asEventTarget();
        try page._event_manager.dispatch(target, event);
    }
};

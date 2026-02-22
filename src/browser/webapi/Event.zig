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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const EventTarget = @import("EventTarget.zig");
const Node = @import("Node.zig");
const String = @import("../../string.zig").String;

const Allocator = std.mem.Allocator;

pub const Event = @This();

pub const _prototype_root = true;
_type: Type,
_arena: Allocator,
_bubbles: bool = false,
_cancelable: bool = false,
_composed: bool = false,
_type_string: String,
_target: ?*EventTarget = null,
_current_target: ?*EventTarget = null,
_dispatch_target: ?*EventTarget = null, // Original target for composedPath()
_prevent_default: bool = false,
_stop_propagation: bool = false,
_stop_immediate_propagation: bool = false,
_event_phase: EventPhase = .none,
_time_stamp: u64,
_needs_retargeting: bool = false,
_isTrusted: bool = false,

// There's a period of time between creating an event and handing it off to v8
// where things can fail. If it does fail, we need to deinit the event. This flag
// when true, tells us the event is registered in the js.Contxt and thus, at
// the very least, will be finalized on context shutdown.
_v8_handoff: bool = false,

pub const EventPhase = enum(u8) {
    none = 0,
    capturing_phase = 1,
    at_target = 2,
    bubbling_phase = 3,
};

pub const Type = union(enum) {
    generic,
    error_event: *@import("event/ErrorEvent.zig"),
    custom_event: *@import("event/CustomEvent.zig"),
    message_event: *@import("event/MessageEvent.zig"),
    progress_event: *@import("event/ProgressEvent.zig"),
    composition_event: *@import("event/CompositionEvent.zig"),
    navigation_current_entry_change_event: *@import("event/NavigationCurrentEntryChangeEvent.zig"),
    page_transition_event: *@import("event/PageTransitionEvent.zig"),
    pop_state_event: *@import("event/PopStateEvent.zig"),
    ui_event: *@import("event/UIEvent.zig"),
    promise_rejection_event: *@import("event/PromiseRejectionEvent.zig"),
};

pub const Options = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.{ .debug = "Event" });
    errdefer page.releaseArena(arena);
    const str = try String.init(arena, typ, .{});
    return initWithTrusted(arena, str, opts_, false);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.{ .debug = "Event.trusted" });
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool) !*Event {
    const opts = opts_ orelse Options{};

    // Round to 2ms for privacy (browsers do this)
    const raw_timestamp = @import("../../datetime.zig").milliTimestamp(.monotonic);
    const time_stamp = (raw_timestamp / 2) * 2;

    const event = try arena.create(Event);
    event.* = .{
        ._arena = arena,
        ._type = .generic,
        ._bubbles = opts.bubbles,
        ._time_stamp = time_stamp,
        ._cancelable = opts.cancelable,
        ._composed = opts.composed,
        ._type_string = typ,
        ._isTrusted = trusted,
    };
    return event;
}

pub fn initEvent(
    self: *Event,
    event_string: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
) !void {
    if (self._event_phase != .none) {
        return;
    }

    self._type_string = try String.init(self._arena, event_string, .{});
    self._bubbles = bubbles orelse false;
    self._cancelable = cancelable orelse false;
    self._stop_propagation = false;
    self._stop_immediate_propagation = false;
    self._prevent_default = false;
}

pub fn deinit(self: *Event, shutdown: bool, page: *Page) void {
    _ = shutdown;
    page.releaseArena(self._arena);
}

pub fn as(self: *Event, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *Event, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == Event) self else null,
        .error_event => |e| return if (T == @import("event/ErrorEvent.zig")) e else null,
        .custom_event => |e| return if (T == @import("event/CustomEvent.zig")) e else null,
        .message_event => |e| return if (T == @import("event/MessageEvent.zig")) e else null,
        .progress_event => |e| return if (T == @import("event/ProgressEvent.zig")) e else null,
        .composition_event => |e| return if (T == @import("event/CompositionEvent.zig")) e else null,
        .navigation_current_entry_change_event => |e| return if (T == @import("event/NavigationCurrentEntryChangeEvent.zig")) e else null,
        .page_transition_event => |e| return if (T == @import("event/PageTransitionEvent.zig")) e else null,
        .pop_state_event => |e| return if (T == @import("event/PopStateEvent.zig")) e else null,
        .promise_rejection_event => |e| return if (T == @import("event/PromiseRejectionEvent.zig")) e else null,
        .ui_event => |e| {
            if (T == @import("event/UIEvent.zig")) {
                return e;
            }
            return e.is(T);
        },
    }
    return null;
}

pub fn getType(self: *const Event) []const u8 {
    return self._type_string.str();
}

pub fn getBubbles(self: *const Event) bool {
    return self._bubbles;
}

pub fn getCancelable(self: *const Event) bool {
    return self._cancelable;
}

pub fn getComposed(self: *const Event) bool {
    return self._composed;
}

pub fn getTarget(self: *const Event) ?*EventTarget {
    return self._target;
}

pub fn getCurrentTarget(self: *const Event) ?*EventTarget {
    return self._current_target;
}

pub fn preventDefault(self: *Event) void {
    if (self._cancelable) {
        self._prevent_default = true;
    }
}

pub fn stopPropagation(self: *Event) void {
    self._stop_propagation = true;
}

pub fn stopImmediatePropagation(self: *Event) void {
    self._stop_immediate_propagation = true;
    self._stop_propagation = true;
}

pub fn getDefaultPrevented(self: *const Event) bool {
    return self._prevent_default;
}

pub fn getReturnValue(self: *const Event) bool {
    return !self._prevent_default;
}

pub fn setReturnValue(self: *Event, v: bool) void {
    if (!v) {
        // Setting returnValue=false is equivalent to preventDefault()
        if (self._cancelable) {
            self._prevent_default = true;
        }
    }
}

pub fn getCancelBubble(self: *const Event) bool {
    return self._stop_propagation;
}

pub fn setCancelBubble(self: *Event) void {
    self.stopPropagation();
}

pub fn getEventPhase(self: *const Event) u8 {
    return @intFromEnum(self._event_phase);
}

pub fn getTimeStamp(self: *const Event) u64 {
    return self._time_stamp;
}

pub fn setTrusted(self: *Event) void {
    self._isTrusted = true;
}

pub fn setUntrusted(self: *Event) void {
    self._isTrusted = false;
}

pub fn getIsTrusted(self: *const Event) bool {
    return self._isTrusted;
}

pub fn composedPath(self: *Event, page: *Page) ![]const *EventTarget {
    // Return empty array if event is not being dispatched
    if (self._event_phase == .none) {
        return &.{};
    }

    // Use dispatch_target (original target) if available, otherwise fall back to target
    // This is important because _target gets retargeted during event dispatch
    const target = self._dispatch_target orelse self._target orelse return &.{};

    // Only nodes have a propagation path
    const target_node = switch (target._type) {
        .node => |n| n,
        else => return &.{},
    };

    // Build the path by walking up from target
    var path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;
    var stopped_at_shadow_boundary = false;

    // Track closed shadow boundaries (position in path and host position)
    var closed_shadow_boundary: ?struct { shadow_end: usize, host_start: usize } = null;

    var node: ?*Node = target_node;
    while (node) |n| {
        if (path_len >= path_buffer.len) {
            break;
        }
        path_buffer[path_len] = n.asEventTarget();
        path_len += 1;

        // Check if this node is a shadow root
        if (n._type == .document_fragment) {
            if (n._type.document_fragment._type == .shadow_root) {
                const shadow = n._type.document_fragment._type.shadow_root;

                // If event is not composed, stop at shadow boundary
                if (!self._composed) {
                    stopped_at_shadow_boundary = true;
                    break;
                }

                // Track the first closed shadow boundary we encounter
                if (shadow._mode == .closed and closed_shadow_boundary == null) {
                    // Mark where the shadow root is in the path
                    // The next element will be the host
                    closed_shadow_boundary = .{
                        .shadow_end = path_len - 1, // index of shadow root
                        .host_start = path_len, // index where host will be
                    };
                }

                // Jump to the shadow host and continue
                node = shadow._host.asNode();
                continue;
            }
        }

        node = n._parent;
    }

    // Add window at the end (unless we stopped at shadow boundary)
    if (!stopped_at_shadow_boundary) {
        if (path_len < path_buffer.len) {
            path_buffer[path_len] = page.window.asEventTarget();
            path_len += 1;
        }
    }

    // Determine visible path based on current_target and closed shadow boundaries
    var visible_start_index: usize = 0;

    if (closed_shadow_boundary) |boundary| {
        // Check if current_target is outside the closed shadow
        // If current_target is null or is at/after the host position, hide shadow internals
        const current_target = self._current_target;

        if (current_target) |ct| {
            // Find current_target in the path
            var ct_index: ?usize = null;
            for (path_buffer[0..path_len], 0..) |elem, i| {
                if (elem == ct) {
                    ct_index = i;
                    break;
                }
            }

            // If current_target is at or after the host (outside the closed shadow),
            // hide everything from target up to the host
            if (ct_index) |idx| {
                if (idx >= boundary.host_start) {
                    visible_start_index = boundary.host_start;
                }
            }
        }
    }

    // Calculate the visible portion of the path
    const visible_path_len = if (path_len > visible_start_index) path_len - visible_start_index else 0;

    // Allocate and return the visible path using call_arena (short-lived)
    const path = try page.call_arena.alloc(*EventTarget, visible_path_len);
    @memcpy(path, path_buffer[visible_start_index..path_len]);
    return path;
}

pub fn populateFromOptions(self: *Event, opts: anytype) void {
    self._bubbles = opts.bubbles;
    self._cancelable = opts.cancelable;
    self._composed = opts.composed;
}

pub fn inheritOptions(comptime T: type, comptime additions: anytype) type {
    var all_fields: []const std.builtin.Type.StructField = &.{};

    if (@hasField(T, "_proto")) {
        const t_fields = @typeInfo(T).@"struct".fields;

        inline for (t_fields) |field| {
            if (std.mem.eql(u8, field.name, "_proto")) {
                const ProtoType = @typeInfo(field.type).pointer.child;
                if (@hasDecl(ProtoType, "Options")) {
                    const parent_options = @typeInfo(ProtoType.Options);
                    all_fields = all_fields ++ parent_options.@"struct".fields;
                }
            }
        }
    }

    const additions_info = @typeInfo(additions);
    all_fields = all_fields ++ additions_info.@"struct".fields;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = all_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn populatePrototypes(self: anytype, opts: anytype, trusted: bool) void {
    const T = @TypeOf(self.*);

    if (@hasField(T, "_proto")) {
        populatePrototypes(self._proto, opts, trusted);
    }

    if (@hasDecl(T, "populateFromOptions")) {
        T.populateFromOptions(self, opts);
    }

    // Set isTrusted at the Event level (base of prototype chain)
    if (T == Event or @hasField(T, "_isTrusted")) {
        self._isTrusted = trusted;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Event);

    pub const Meta = struct {
        pub const name = "Event";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(Event.deinit);
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(Event.init, .{});
    pub const @"type" = bridge.accessor(Event.getType, null, .{});
    pub const bubbles = bridge.accessor(Event.getBubbles, null, .{});
    pub const cancelable = bridge.accessor(Event.getCancelable, null, .{});
    pub const composed = bridge.accessor(Event.getComposed, null, .{});
    pub const target = bridge.accessor(Event.getTarget, null, .{});
    pub const srcElement = bridge.accessor(Event.getTarget, null, .{});
    pub const currentTarget = bridge.accessor(Event.getCurrentTarget, null, .{});
    pub const eventPhase = bridge.accessor(Event.getEventPhase, null, .{});
    pub const defaultPrevented = bridge.accessor(Event.getDefaultPrevented, null, .{});
    pub const timeStamp = bridge.accessor(Event.getTimeStamp, null, .{});
    pub const isTrusted = bridge.accessor(Event.getIsTrusted, null, .{});
    pub const preventDefault = bridge.function(Event.preventDefault, .{});
    pub const stopPropagation = bridge.function(Event.stopPropagation, .{});
    pub const stopImmediatePropagation = bridge.function(Event.stopImmediatePropagation, .{});
    pub const composedPath = bridge.function(Event.composedPath, .{});
    pub const initEvent = bridge.function(Event.initEvent, .{});
    // deprecated
    pub const returnValue = bridge.accessor(Event.getReturnValue, Event.setReturnValue, .{});
    // deprecated
    pub const cancelBubble = bridge.accessor(Event.getCancelBubble, Event.setCancelBubble, .{});

    // Event phase constants
    pub const NONE = bridge.property(@intFromEnum(EventPhase.none), .{ .template = true });
    pub const CAPTURING_PHASE = bridge.property(@intFromEnum(EventPhase.capturing_phase), .{ .template = true });
    pub const AT_TARGET = bridge.property(@intFromEnum(EventPhase.at_target), .{ .template = true });
    pub const BUBBLING_PHASE = bridge.property(@intFromEnum(EventPhase.bubbling_phase), .{ .template = true });
};

// tested in event_target

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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const EventManager = @import("../EventManager.zig");

const Node = @import("Node.zig");
const EventTarget = @import("EventTarget.zig");

const String = lp.String;
const Execution = js.Execution;

pub const Event = @This();

pub const _prototype_root = true;
_type: Type,
_arena: *lp.Arena,
_bubbles: bool = false,
_cancelable: bool = false,
_composed: bool = false,
_type_string: String,
_target: ?*EventTarget = null,
_current_target: ?*EventTarget = null,
_dispatch_target: ?*EventTarget = null, // Original target for composedPath()
_dispatch_related_target: ?*EventTarget = null,
_prevent_default: bool = false,
_stop_propagation: bool = false,
_stop_immediate_propagation: bool = false,
_event_phase: EventPhase = .none,
_time_stamp: u64,
_needs_retargeting: bool = false,
_is_trusted: bool = false,
_in_passive_listener: bool = false,
_listeners_did_throw: bool = false, // IndexedDB needs to abort on callback throw
// Per spec, events created via document.createEvent are not initialized
// until one of the init*Event methods runs; dispatching one throws an
// InvalidStateError. Events created any other way start initialized.
_initialized: bool = true,
// Time origin of the event's relevant global, captured at creation when
// known; 0 means "use the accessing realm's origin" (see getTimeStamp).
_time_origin: u64 = 0,

// There's a period of time between creating an event and handing it off to v8
// where things can fail. If it does fail, we need to deinit the event. The timing
// window can be difficult to capture, so we use a reference count.
// should be 0, 1, or 2. 0
// - 0: no reference, always a transient state going to either 1 or about to be deinit'd
// - 1: either zig or v8 have a reference
// - 2: both zig and v8 have a reference
_rc: lp.RC = .{},

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
    navigation_current_entry_change_event: *@import("event/NavigationCurrentEntryChangeEvent.zig"),
    page_transition_event: *@import("event/PageTransitionEvent.zig"),
    pop_state_event: *@import("event/PopStateEvent.zig"),
    hash_change_event: *@import("event/HashChangeEvent.zig"),
    before_unload_event: *@import("event/BeforeUnloadEvent.zig"),
    storage_event: *@import("event/StorageEvent.zig"),
    device_motion_event: *@import("event/DeviceMotionEvent.zig"),
    gamepad_event: *@import("event/GamepadEvent.zig"),
    device_orientation_event: *@import("event/DeviceOrientationEvent.zig"),
    ui_event: *@import("event/UIEvent.zig"),
    promise_rejection_event: *@import("event/PromiseRejectionEvent.zig"),
    submit_event: *@import("event/SubmitEvent.zig"),
    form_data_event: *@import("event/FormDataEvent.zig"),
    close_event: *@import("event/CloseEvent.zig"),
    cookie_change_event: *@import("event/CookieChangeEvent.zig"),
    idb_version_change_event: *@import("storage/idb/IDBVersionChangeEvent.zig"),
    toggle_event: *@import("event/ToggleEvent.zig"),
    task_priority_change_event: *@import("event/TaskPriorityChangeEvent.zig"),
};

pub const Options = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event");
    errdefer arena.release();
    const str = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, str, opts_, false);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts_, true);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts_: ?Options, comptime trusted: bool) !*Event {
    const opts = opts_ orelse Options{};

    // Same (already coarsened) clock as the performance time origin, so the
    // timeStamp getter can report it relative to that origin.
    const time_stamp = @import("Performance.zig").highResTimestamp();

    const event = try arena.create(Event);
    event.* = .{
        ._arena = arena,
        ._type = .generic,
        ._bubbles = opts.bubbles,
        ._time_stamp = time_stamp,
        ._cancelable = opts.cancelable,
        ._composed = opts.composed,
        ._type_string = typ,
        ._is_trusted = trusted,
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

    self._initialized = true;
    self._type_string = try String.init(self._arena.allocator(), event_string, .{});
    self._bubbles = bubbles orelse false;
    self._cancelable = cancelable orelse false;
    self._stop_propagation = false;
    self._stop_immediate_propagation = false;
    self._prevent_default = false;
}

pub fn acquireRef(self: *Event) void {
    self._rc.acquire();
}

pub fn deinit(self: *Event, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Event, page: *Page) void {
    self._rc.release(self, page);
}

pub fn as(self: *Event, comptime T: type) *T {
    return self.is(T).?;
}

// Storage of the subtype's relatedTarget, for event types that have one.
// Used by dispatch for retargeting and shadow-tree resets.
pub fn relatedTargetPtr(self: *Event) ?*?*EventTarget {
    switch (self._type) {
        .ui_event => |ui| switch (ui._type) {
            .mouse_event => |me| return &me._related_target,
            .focus_event => |fe| return &fe._related_target,
            else => return null,
        },
        else => return null,
    }
}

pub fn is(self: *Event, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == Event) self else null,
        .error_event => |e| return if (T == @import("event/ErrorEvent.zig")) e else null,
        .custom_event => |e| return if (T == @import("event/CustomEvent.zig")) e else null,
        .message_event => |e| return if (T == @import("event/MessageEvent.zig")) e else null,
        .progress_event => |e| return if (T == @import("event/ProgressEvent.zig")) e else null,
        .navigation_current_entry_change_event => |e| return if (T == @import("event/NavigationCurrentEntryChangeEvent.zig")) e else null,
        .page_transition_event => |e| return if (T == @import("event/PageTransitionEvent.zig")) e else null,
        .pop_state_event => |e| return if (T == @import("event/PopStateEvent.zig")) e else null,
        .hash_change_event => |e| return if (T == @import("event/HashChangeEvent.zig")) e else null,
        .before_unload_event => |e| return if (T == @import("event/BeforeUnloadEvent.zig")) e else null,
        .storage_event => |e| return if (T == @import("event/StorageEvent.zig")) e else null,
        .device_motion_event => |e| return if (T == @import("event/DeviceMotionEvent.zig")) e else null,
        .gamepad_event => |e| return if (T == @import("event/GamepadEvent.zig")) e else null,
        .device_orientation_event => |e| return if (T == @import("event/DeviceOrientationEvent.zig")) e else null,
        .promise_rejection_event => |e| return if (T == @import("event/PromiseRejectionEvent.zig")) e else null,
        .submit_event => |e| return if (T == @import("event/SubmitEvent.zig")) e else null,
        .form_data_event => |e| return if (T == @import("event/FormDataEvent.zig")) e else null,
        .close_event => |e| return if (T == @import("event/CloseEvent.zig")) e else null,
        .cookie_change_event => |e| return if (T == @import("event/CookieChangeEvent.zig")) e else null,
        .idb_version_change_event => |e| return if (T == @import("storage/idb/IDBVersionChangeEvent.zig")) e else null,
        .toggle_event => |e| return if (T == @import("event/ToggleEvent.zig")) e else null,
        .task_priority_change_event => |e| return if (T == @import("event/TaskPriorityChangeEvent.zig")) e else null,
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
    if (self._cancelable and !self._in_passive_listener) {
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
        if (self._cancelable and !self._in_passive_listener) {
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

pub fn getTimeStamp(self: *const Event, exec: *js.Execution) f64 {
    const origin = if (self._time_origin != 0) self._time_origin else exec.performance()._time_origin;
    if (self._time_stamp <= origin) {
        return 0.0;
    }
    return @as(f64, @floatFromInt(self._time_stamp - origin)) / 1000.0;
}

pub fn setTrusted(self: *Event) void {
    self._is_trusted = true;
}

pub fn setUntrusted(self: *Event) void {
    self._is_trusted = false;
}

pub fn getIsTrusted(self: *const Event) bool {
    return self._is_trusted;
}

pub fn composedPath(self: *Event, exec: *Execution) ![]const *EventTarget {
    // Return empty array if event is not being dispatched
    if (self._event_phase == .none) {
        return &.{};
    }

    // Use dispatch_target (original target) if available, otherwise fall back to target
    // This is important because _target gets retargeted during event dispatch
    const target = self._dispatch_target orelse self._target orelse return &.{};

    // Only nodes have a propagation path
    const target_node = target.is(Node) orelse return &.{};

    const frame_ = switch (exec.js.global) {
        .frame => |frame| frame,
        else => null,
    };

    var path_buffer: [128]*EventTarget = undefined;
    var path_len = EventManager.buildEventPath(target_node, self, frame_, &path_buffer).len;
    if (path_len == 0) {
        return &.{};
    }

    // Window follows the document at the end of the path. A path that stopped
    // early — at a shadow boundary, or at the relatedTarget — doesn't end on
    // the document and so doesn't reach it.
    const root_is_document = blk: {
        const root = path_buffer[path_len - 1].is(Node) orelse break :blk false;
        break :blk root._type == .document;
    };
    if (root_is_document and path_len < path_buffer.len) {
        if (frame_) |frame| {
            path_buffer[path_len] = frame.window.asEventTarget();
            path_len += 1;
        }
    }

    // The host of the first closed shadow root on the path. Everything before
    // it is inside that root and hidden from a currentTarget outside it.
    var closed_host_index: ?usize = null;
    for (path_buffer[0..path_len], 0..) |entry, i| {
        const node = entry.is(Node) orelse continue;
        const shadow = node.is(Node.ShadowRoot) orelse continue;
        if (shadow._mode == .closed) {
            closed_host_index = i + 1;
            break;
        }
    }

    // Determine visible path based on current_target and closed shadow boundaries
    var visible_start_index: usize = 0;

    if (closed_host_index) |host_index| {
        // Find current_target in the path; if it's at or after the host, it's
        // outside the closed shadow and must not see the nodes inside it.
        if (self._current_target) |ct| {
            for (path_buffer[0..path_len], 0..) |elem, i| {
                if (elem == ct) {
                    if (i >= host_index) {
                        visible_start_index = host_index;
                    }
                    break;
                }
            }
        }
    }

    // Calculate the visible portion of the path
    const visible_path_len = if (path_len > visible_start_index) path_len - visible_start_index else 0;

    // Allocate and return the visible path using call_arena (short-lived)
    const path = try exec.local_arena.alloc(*EventTarget, visible_path_len);
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

    var names: [all_fields.len][:0]const u8 = undefined;
    var types: [all_fields.len]type = undefined;
    var attrs: [all_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (all_fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{ .@"comptime" = f.is_comptime, .@"align" = f.alignment, .default_value_ptr = f.default_value_ptr };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
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
    if (T == Event or @hasField(T, "is_trusted")) {
        self._is_trusted = trusted;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Event);

    pub const Meta = struct {
        pub const name = "Event";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(struct {
        fn wrap(typ: []const u8, opts_: ?Options, exec: *js.Execution) !*Event {
            const event = try Event.init(typ, opts_, exec.page);
            // capture the realm's time
            event._time_origin = exec.performance()._time_origin;
            return event;
        }
    }.wrap, .{});
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
    pub const isTrusted = bridge.accessor(Event.getIsTrusted, null, .{ .unforgeable = true, .deletable = false });
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

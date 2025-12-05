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

pub const Event = @This();

const _prototype_root = true;
_type: Type,

_bubbles: bool = false,
_cancelable: bool = false,
_composed: bool = false,
_type_string: String,
_target: ?*EventTarget = null,
_current_target: ?*EventTarget = null,
_prevent_default: bool = false,
_stop_propagation: bool = false,
_stop_immediate_propagation: bool = false,
_event_phase: EventPhase = .none,
_time_stamp: u64 = 0,
_needs_retargeting: bool = false,

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
};

const Options = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Event {
    const opts = opts_ orelse Options{};

    // Round to 2ms for privacy (browsers do this)
    const raw_timestamp = @import("../../datetime.zig").milliTimestamp(.monotonic);
    const time_stamp = (raw_timestamp / 2) * 2;

    return page._factory.create(Event{
        ._type = .generic,
        ._bubbles = opts.bubbles,
        ._time_stamp = time_stamp,
        ._cancelable = opts.cancelable,
        ._composed = opts.composed,
        ._type_string = try String.init(page.arena, typ, .{}),
    });
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
    self._prevent_default = true;
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

pub fn getEventPhase(self: *const Event) u8 {
    return @intFromEnum(self._event_phase);
}

pub fn getTimeStamp(self: *const Event) u64 {
    return self._time_stamp;
}

pub fn composedPath(self: *Event, page: *Page) ![]const *EventTarget {
    // Return empty array if event is not being dispatched
    if (self._event_phase == .none) {
        return &.{};
    }

    // If there's no target, return empty array
    const target = self._target orelse return &.{};

    // Only nodes have a propagation path
    const target_node = switch (target._type) {
        .node => |n| n,
        else => return &.{},
    };

    // Build the path by walking up from target
    var path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;
    var stopped_at_shadow_boundary = false;

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

                // Otherwise, jump to the shadow host and continue
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

    // Allocate and return the path using call_arena (short-lived)
    const path = try page.call_arena.alloc(*EventTarget, path_len);
    @memcpy(path, path_buffer[0..path_len]);
    return path;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Event);

    pub const Meta = struct {
        pub const name = "Event";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Event.init, .{});
    pub const @"type" = bridge.accessor(Event.getType, null, .{});
    pub const bubbles = bridge.accessor(Event.getBubbles, null, .{});
    pub const cancelable = bridge.accessor(Event.getCancelable, null, .{});
    pub const composed = bridge.accessor(Event.getComposed, null, .{});
    pub const target = bridge.accessor(Event.getTarget, null, .{});
    pub const currentTarget = bridge.accessor(Event.getCurrentTarget, null, .{});
    pub const eventPhase = bridge.accessor(Event.getEventPhase, null, .{});
    pub const defaultPrevented = bridge.accessor(Event.getDefaultPrevented, null, .{});
    pub const timeStamp = bridge.accessor(Event.getTimeStamp, null, .{});
    pub const preventDefault = bridge.function(Event.preventDefault, .{});
    pub const stopPropagation = bridge.function(Event.stopPropagation, .{});
    pub const stopImmediatePropagation = bridge.function(Event.stopImmediatePropagation, .{});
    pub const composedPath = bridge.function(Event.composedPath, .{});

    // Event phase constants
    pub const NONE = bridge.property(@intFromEnum(EventPhase.none));
    pub const CAPTURING_PHASE = bridge.property(@intFromEnum(EventPhase.capturing_phase));
    pub const AT_TARGET = bridge.property(@intFromEnum(EventPhase.at_target));
    pub const BUBBLING_PHASE = bridge.property(@intFromEnum(EventPhase.bubbling_phase));
};

// tested in event_target

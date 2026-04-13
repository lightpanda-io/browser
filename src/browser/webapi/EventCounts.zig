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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const log = @import("../../log.zig");

pub fn registerTypes() []const type {
    return &.{
        EventCounts,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const EventCounts = @This();

// Event types tracked per the Event Timing spec
// https://w3c.github.io/event-timing/#sec-events-exposed
const tracked_event_types = [_][]const u8{
    "auxclick",
    "click",
    "contextmenu",
    "dblclick",
    "mousedown",
    "mouseenter",
    "mouseleave",
    "mouseout",
    "mouseover",
    "mouseup",
    "pointerover",
    "pointerenter",
    "pointerdown",
    "pointerup",
    "pointercancel",
    "pointerout",
    "pointerleave",
    "gotpointercapture",
    "lostpointercapture",
    "touchstart",
    "touchend",
    "touchcancel",
    "keydown",
    "keypress",
    "keyup",
    "beforeinput",
    "input",
    "compositionstart",
    "compositionupdate",
    "compositionend",
    "dragstart",
    "dragend",
    "dragenter",
    "dragleave",
    "dragover",
    "drop",
};

// Counts stored in a fixed array
_counts: [tracked_event_types.len]u32 = [_]u32{0} ** tracked_event_types.len,

pub fn increment(self: *EventCounts, event_type: []const u8) void {
    if (getIndex(event_type)) |idx| {
        self._counts[idx] +|= 1;
    }
}

pub fn get(self: *const EventCounts, event_type: []const u8) u32 {
    if (getIndex(event_type)) |idx| {
        return self._counts[idx];
    }
    return 0;
}

pub fn has(_: *const EventCounts, event_type: []const u8) bool {
    return getIndex(event_type) != null;
}

pub fn getSize(_: *const EventCounts) u32 {
    return tracked_event_types.len;
}

pub fn keys(self: *EventCounts, page: *Page) !*KeyIterator {
    return .init(.{ .event_counts = self }, page);
}

pub fn values(self: *EventCounts, page: *Page) !*ValueIterator {
    return .init(.{ .event_counts = self }, page);
}

pub fn entries(self: *EventCounts, page: *Page) !*EntryIterator {
    return .init(.{ .event_counts = self }, page);
}

pub fn forEach(self: *EventCounts, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (tracked_event_types, self._counts) |event_type, count| {
        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{ count, event_type, self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "EventCounts" });
        };
    }
}

fn getIndex(event_type: []const u8) ?usize {
    for (tracked_event_types, 0..) |t, i| {
        if (std.mem.eql(u8, t, event_type)) {
            return i;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventCounts);

    pub const Meta = struct {
        pub const name = "EventCounts";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const get = bridge.function(EventCounts.get, .{});
    pub const has = bridge.function(EventCounts.has, .{});
    pub const size = bridge.accessor(EventCounts.getSize, null, .{});
    pub const keys = bridge.function(EventCounts.keys, .{});
    pub const values = bridge.function(EventCounts.values, .{});
    pub const entries = bridge.function(EventCounts.entries, .{});
    pub const forEach = bridge.function(EventCounts.forEach, .{});
    pub const symbol_iterator = bridge.iterator(EventCounts.entries, .{});
};

// Iterator implementation
pub const Iterator = struct {
    index: u32 = 0,
    event_counts: *EventCounts,

    pub const Entry = struct { []const u8, u32 };

    pub fn next(self: *Iterator, _: *const Page) ?Iterator.Entry {
        const index = self.index;
        if (index >= tracked_event_types.len) {
            return null;
        }
        self.index = index + 1;

        return .{ tracked_event_types[index], self.event_counts._counts[index] };
    }
};

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

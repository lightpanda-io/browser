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
const Frame = @import("../Frame.zig");
const Performance = @import("Performance.zig");

const log = lp.log;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ PerformanceObserver, EntryList };
}

/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserver
const PerformanceObserver = @This();

/// Emitted when there are events with same interests.
_callback: js.Function.Global,
/// The threshold to deliver `PerformanceEventTiming` entries.
_duration_threshold: f64,
/// Entry types we're looking for are encoded as bit flags.
_interests: u16,
/// Entries this observer hold.
/// Don't mutate these; other observers may hold pointers to them.
_entries: std.ArrayList(*Performance.Entry),

const DefaultDurationThreshold: f64 = 104;

/// Creates a new PerformanceObserver object with the given observer callback.
pub fn init(callback: js.Function.Global, frame: *Frame) !*PerformanceObserver {
    return frame._factory.create(PerformanceObserver{
        ._callback = callback,
        ._duration_threshold = DefaultDurationThreshold,
        ._interests = 0,
        ._entries = .{},
    });
}

const ObserveOptions = struct {
    buffered: bool = false,
    durationThreshold: f64 = DefaultDurationThreshold,
    entryTypes: ?[]const []const u8 = null,
    type: ?[]const u8 = null,
};

/// TODO: Support `buffered` option.
pub fn observe(
    self: *PerformanceObserver,
    maybe_options: ?ObserveOptions,
    frame: *Frame,
) !void {
    const options: ObserveOptions = maybe_options orelse .{};
    // Update threshold.
    self._duration_threshold = @max(@floor(options.durationThreshold / 8) * 8, 16);

    const entry_types: []const []const u8 = blk: {
        // More likely.
        if (options.type) |entry_type| {
            // Can't have both.
            if (options.entryTypes != null) {
                return error.TypeError;
            }

            break :blk &.{entry_type};
        }

        if (options.entryTypes) |entry_types| {
            break :blk entry_types;
        }

        return error.TypeError;
    };

    // Update entries.
    var interests: u16 = 0;
    for (entry_types) |entry_type| {
        const fields = @typeInfo(Performance.Entry.Type.Enum).@"enum".fields;
        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, entry_type)) {
                const flag = @as(u16, 1) << @as(u16, field.value);
                interests |= flag;
            }
        }
    }

    // Nothing has updated; no need to go further.
    if (interests == 0) {
        return;
    }

    // If we had no interests before, it means Page is not aware of
    // this observer.
    if (self._interests == 0) {
        try frame.registerPerformanceObserver(self);
    }

    // Update interests.
    self._interests = interests;

    // Deliver existing entries if buffered option is set.
    // Per spec, buffered is only valid with the type option, not entryTypes.
    // Delivery is async via a queued task, not synchronous.
    if (options.buffered and options.type != null and !self.hasRecords()) {
        for (frame.window._performance._entries.items) |entry| {
            if (self.interested(entry)) {
                try self._entries.append(frame.arena, entry);
            }
        }
        if (self.hasRecords()) {
            try frame.schedulePerformanceObserverDelivery();
        }
    }
}

pub fn disconnect(self: *PerformanceObserver, frame: *Frame) void {
    frame.unregisterPerformanceObserver(self);
    // Reset observer.
    self._duration_threshold = DefaultDurationThreshold;
    self._interests = 0;
    self._entries.clearRetainingCapacity();
}

/// Returns the current list of PerformanceEntry objects
/// stored in the performance observer, emptying it out.
pub fn takeRecords(self: *PerformanceObserver, frame: *Frame) ![]*Performance.Entry {
    // Use frame.arena instead of call_arena because this slice is wrapped in EntryList
    // and may be accessed later.
    const records = try frame.arena.dupe(*Performance.Entry, self._entries.items);
    self._entries.clearRetainingCapacity();
    return records;
}

pub fn getSupportedEntryTypes() []const []const u8 {
    return &.{ "mark", "measure" };
}

/// Returns true if observer interested with given entry.
pub fn interested(
    self: *const PerformanceObserver,
    entry: *const Performance.Entry,
) bool {
    const flag = @as(u16, 1) << @intCast(@intFromEnum(entry._type));
    return self._interests & flag != 0;
}

pub inline fn hasRecords(self: *const PerformanceObserver) bool {
    return self._entries.items.len > 0;
}

/// Runs the PerformanceObserver's callback with records; emptying it out.
pub fn dispatch(self: *PerformanceObserver, frame: *Frame) !void {
    const records = try self.takeRecords(frame);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var caught: js.TryCatch.Caught = undefined;
    ls.toLocal(self._callback).tryCall(void, .{ EntryList{ ._entries = records }, self }, &caught) catch |err| {
        log.err(.frame, "PerfObserver.dispatch", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PerformanceObserver);

    pub const Meta = struct {
        pub const name = "PerformanceObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PerformanceObserver.init, .{ .dom_exception = true });

    pub const observe = bridge.function(PerformanceObserver.observe, .{ .dom_exception = true });
    pub const disconnect = bridge.function(PerformanceObserver.disconnect, .{});
    pub const takeRecords = bridge.function(PerformanceObserver.takeRecords, .{ .dom_exception = true });
    pub const supportedEntryTypes = bridge.accessor(PerformanceObserver.getSupportedEntryTypes, null, .{ .static = true });
};

/// List of performance events that were explicitly
/// observed via the observe() method.
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserverEntryList
pub const EntryList = struct {
    _entries: []*Performance.Entry,

    pub fn getEntries(self: *const EntryList) []const *Performance.Entry {
        return self._entries;
    }

    pub fn getEntriesByType(self: *const EntryList, entry_type: []const u8, exec: *Execution) ![]const *Performance.Entry {
        return Performance.filterEntriesByType(exec.call_arena, self._entries, entry_type);
    }

    pub fn getEntriesByName(self: *const EntryList, name: []const u8, entry_type: ?[]const u8, exec: *Execution) ![]const *Performance.Entry {
        return Performance.filterEntriesByName(exec.call_arena, self._entries, name, entry_type);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(EntryList);

        pub const Meta = struct {
            pub const name = "PerformanceObserverEntryList";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const getEntries = bridge.function(EntryList.getEntries, .{});
        pub const getEntriesByType = bridge.function(EntryList.getEntriesByType, .{});
        pub const getEntriesByName = bridge.function(EntryList.getEntriesByName, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: PerformanceObserver" {
    try testing.htmlRunner("performance_observer", .{});
}

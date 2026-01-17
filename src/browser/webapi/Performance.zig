const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const datetime = @import("../../datetime.zig");

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure };
}

const std = @import("std");

const Performance = @This();

_time_origin: u64,
_entries: std.ArrayList(*Entry) = .{},

/// Get high-resolution timestamp in microseconds, rounded to 5μs increments
/// to match browser behavior (prevents fingerprinting)
fn highResTimestamp() u64 {
    const ts = datetime.timespec();
    const micros = @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000)));
    // Round to nearest 5 microseconds (like Firefox default)
    const rounded = @divTrunc(micros + 2, 5) * 5;
    return rounded;
}

pub fn init() Performance {
    return .{
        ._time_origin = highResTimestamp(),
        ._entries = .{},
    };
}

pub fn now(self: *const Performance) f64 {
    const current = highResTimestamp();
    const elapsed = current - self._time_origin;
    // Return as milliseconds with microsecond precision
    return @as(f64, @floatFromInt(elapsed)) / 1000.0;
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    // Return as milliseconds
    return @as(f64, @floatFromInt(self._time_origin)) / 1000.0;
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    page: *Page,
) !*Mark {
    const m = try Mark.init(name, _options, page);
    try self._entries.append(page.arena, m._proto);
    // Notify about the change.
    try page.notifyPerformanceObservers(m._proto);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    page: *Page,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                page,
            );
            try self._entries.append(page.arena, m._proto);
            // Notify about the change.
            try page.notifyPerformanceObservers(m._proto);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                page,
            );
            try self._entries.append(page.arena, m._proto);
            // Notify about the change.
            try page.notifyPerformanceObservers(m._proto);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, page);
    try self._entries.append(page.arena, m._proto);
    // Notify about the change.
    try page.notifyPerformanceObservers(m._proto);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn getEntries(self: *const Performance) []*Entry {
    return self._entries.items;
}

pub fn getEntriesByType(self: *const Performance, entry_type: []const u8, page: *Page) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (self._entries.items) |entry| {
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            try result.append(page.call_arena, entry);
        }
    }

    return result.items;
}

pub fn getEntriesByName(self: *const Performance, name: []const u8, entry_type: ?[]const u8, page: *Page) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (self._entries.items) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }

        const et = entry_type orelse {
            try result.append(page.call_arena, entry);
            continue;
        };

        if (std.mem.eql(u8, entry.getEntryType(), et)) {
            try result.append(page.call_arena, entry);
        }
    }

    return result.items;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // Recognized mark names by browsers. `navigationStart` is an equivalent
    // to 0. Others are dependant to request arrival, end of request etc.
    if (std.mem.eql(u8, "navigationStart", mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const now = bridge.function(Performance.now, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{});
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    pub const Type = union(Enum) {
        element,
        event,
        first_input,
        @"largest-contentful-paint",
        @"layout-shift",
        @"long-animation-frame",
        longtask,
        measure: *Measure,
        navigation,
        paint,
        resource,
        taskattribution,
        @"visibility-state",
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            first_input = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            else => |t| @tagName(t),
        };
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
    };
};

pub const Mark = struct {
    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, _opts: ?Options, page: *Page) !*Mark {
        const opts = _opts orelse Options{};
        const start_time = opts.startTime orelse page.window._performance.now();

        if (start_time < 0.0) {
            return error.TypeError;
        }

        const detail = if (opts.detail) |d| try d.persist() else null;
        const m = try page._factory.create(Mark{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try page._factory.create(Entry{
            ._start_time = start_time,
            ._name = try page.dupeString(name),
            ._type = .{ .mark = m },
        });
        m._proto = entry;
        return m;
    }


    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
    };
};

pub const Measure = struct {
    _proto: *Entry,
    _detail: ?js.Object.Global,

    const Options = struct {
        detail: ?js.Object = null,
        start: ?TimestampOrMark,
        end: ?TimestampOrMark,
        duration: ?f64 = null,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Object,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        page: *Page,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try page._factory.create(Measure{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try page._factory.create(Entry{
            ._start_time = start_timestamp,
            ._duration = duration,
            ._name = try page.dupeString(name),
            ._type = .{ .measure = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Object.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

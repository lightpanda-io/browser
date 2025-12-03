const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const datetime = @import("../../datetime.zig");

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure };
}

const std = @import("std");

const Performance = @This();

_time_origin: u64,
_entries: std.ArrayListUnmanaged(*Entry) = .{},

pub fn init() Performance {
    return .{
        ._time_origin = datetime.milliTimestamp(.monotonic),
        ._entries = .{},
    };
}

pub fn now(self: *const Performance) f64 {
    const current = datetime.milliTimestamp(.monotonic);
    const elapsed = current - self._time_origin;
    return @floatFromInt(elapsed);
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    return @floatFromInt(self._time_origin);
}

pub fn mark(self: *Performance, name: []const u8, _options: ?Mark.Options, page: *Page) !*Mark {
    const m = try Mark.init(name, _options, page);
    try self._entries.append(page.arena, m._proto);
    return m;
}

pub fn measure(self: *Performance, name: []const u8, _options: ?Measure.Options, page: *Page) !*Measure {
    const m = try Measure.init(name, _options, page);
    try self._entries.append(page.arena, m._proto);
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

    const Type = union(enum) {
        element,
        event,
        first_input,
        largest_contentful_paint,
        layout_shift,
        long_animation_frame,
        longtask,
        measure: *Measure,
        navigation,
        paint,
        resource,
        taskattribution,
        visibility_state,
        mark: *Mark,
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            .first_input => "first-input",
            .largest_contentful_paint => "largest-contentful-paint",
            .layout_shift => "layout-shift",
            .long_animation_frame => "long-animation-frame",
            .visibility_state => "visibility-state",
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
    _detail: ?js.Object,

    const Options = struct {
        detail: ?js.Object = null,
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

    pub fn getDetail(self: *const Mark) ?js.Object {
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
    _detail: ?js.Object,

    const Options = struct {
        detail: ?js.Object = null,
        start: ?[]const u8 = null,
        end: ?[]const u8 = null,
        duration: ?f64 = null,
    };

    pub fn init(name: []const u8, _opts: ?Options, page: *Page) !*Measure {
        const opts = _opts orelse Options{};
        const perf = &page.window._performance;

        const start_time = if (opts.start) |start_mark|
            try perf.getMarkTime(start_mark)
        else
            0.0;

        const end_time = if (opts.end) |end_mark|
            try perf.getMarkTime(end_mark)
        else
            perf.now();

        const duration = opts.duration orelse (end_time - start_time);

        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (opts.detail) |d| try d.persist() else null;
        const m = try page._factory.create(Measure{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try page._factory.create(Entry{
            ._start_time = start_time,
            ._duration = duration,
            ._name = try page.dupeString(name),
            ._type = .{ .measure = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Object {
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

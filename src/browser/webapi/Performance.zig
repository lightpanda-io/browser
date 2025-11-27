const js = @import("../js/js.zig");
const datetime = @import("../../datetime.zig");

pub fn registerTypes() []const type {
    return &.{
        Performance,
        Entry,
    };
}

const Performance = @This();

_time_origin: u64,

pub fn init() Performance {
    return .{
        ._time_origin = datetime.milliTimestamp(.monotonic),
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const now = bridge.function(Performance.now, .{});
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _entry_type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    const Type = enum {
        element,
        event,
        first_input,
        largest_contentful_paint,
        layout_shift,
        long_animation_frame,
        longtask,
        mark,
        measure,
        navigation,
        paint,
        resource,
        taskattribution,
        visibility_state,
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._entry_type) {
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
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

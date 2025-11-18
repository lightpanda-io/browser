const js = @import("../js/js.zig");
const datetime = @import("../../datetime.zig");

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

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

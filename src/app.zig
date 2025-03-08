const std = @import("std");

const Loop = @import("jsruntime").Loop;
const Allocator = std.mem.Allocator;
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

pub const RunMode = enum {
    serve,
    fetch,
};

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    loop: *Loop,
    allocator: Allocator,
    telemetry: Telemetry,

    pub fn init(allocator: Allocator, run_mode: RunMode) !App {
        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);

        loop.* = try Loop.init(allocator);
        errdefer loop.deinit();

        const telemetry = Telemetry.init(allocator, loop, run_mode);
        errdefer telemetry.deinit();

        return .{
            .loop = loop,
            .allocator = allocator,
            .telemetry = telemetry,
        };
    }

    pub fn deinit(self: *App) void {
        self.telemetry.deinit();
        self.loop.deinit();
        self.allocator.destroy(self.loop);
    }
};

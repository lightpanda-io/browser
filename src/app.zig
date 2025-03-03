const std = @import("std");

const Loop = @import("jsruntime").Loop;
const Allocator = std.mem.Allocator;
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    telemetry: Telemetry,

    pub fn init(allocator: Allocator, loop: *Loop) !App {
        const telemetry = Telemetry.init(allocator, loop);
        errdefer telemetry.deinit();

        return .{
            .telemetry = telemetry,
        };
    }

    pub fn deinit(self: *App) void {
        self.telemetry.deinit();
    }
};

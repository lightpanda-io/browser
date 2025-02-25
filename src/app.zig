const std = @import("std");

const Allocator = std.mem.Allocator;
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    telemetry: Telemetry,

    pub fn init(allocator: Allocator) !App {
        const telemetry = Telemetry.init(allocator);
        errdefer telemetry.deinit();

        return .{
            .telemetry = telemetry,
        };
    }

    pub fn deinit(self: *App) void {
        self.telemetry.deinit();
    }
};

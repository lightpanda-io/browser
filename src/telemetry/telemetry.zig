const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.telemetry);

pub const Telemetry = TelemetryT(blk: {
    if (builtin.mode == .Debug or builtin.is_test) break :blk NoopProvider;
    break :blk @import("plausible.zig").Plausible;
});

fn TelemetryT(comptime P: type) type {
    return struct {
        provider: P,
        disable: bool,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .disable = std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY"),
                .provider = try P.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.provider.deinit();
        }

        pub fn record(self: *Self, event: Event) void {
            if (self.disable) {
                return;
            }

            self.provider.record(event) catch |err| {
                log.warn("failed to record event: {}", .{err});
            };
        }
    };
}

pub const Event = union(enum) {
    run: Run,

    const Run = struct {
        version: []const u8,
        mode: RunMode,

        const RunMode = enum {
            fetch,
            serve,
        };
    };
};

const NoopProvider = struct {
    fn init(_: Allocator) !NoopProvider {
        return .{};
    }
    fn deinit(_: NoopProvider) void {}
    pub fn record(_: NoopProvider, _: Event) !void {}
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;
const testing = std.testing;
test "telemetry: disabled by environment" {
    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));

    const FailingProvider = struct {
        fn init(_: Allocator) !@This() {
            return .{};
        }
        fn deinit(_: @This()) void {}
        pub fn record(_: @This(), _: Event) !void {
            unreachable;
        }
    };

    var telemetry = TelemetryT(FailingProvider).init(testing.allocator);
    defer telemetry.deinit();
    telemetry.record(.{ .run = .{ .mode = .serve, .version = "123" } });
}

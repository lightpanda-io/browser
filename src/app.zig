const std = @import("std");

const Loop = @import("jsruntime").Loop;
const Allocator = std.mem.Allocator;
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

const log = std.log.scoped(.app);

pub const RunMode = enum {
    serve,
    fetch,
};

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    loop: *Loop,
    app_dir_path: ?[]const u8,
    allocator: Allocator,
    telemetry: Telemetry,

    pub fn init(allocator: Allocator, run_mode: RunMode) !App {
        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);

        loop.* = try Loop.init(allocator);
        errdefer loop.deinit();

        const app_dir_path = getAndMakeAppDir(allocator);
        const telemetry = Telemetry.init(allocator, run_mode, app_dir_path);
        errdefer telemetry.deinit();

        return .{
            .loop = loop,
            .allocator = allocator,
            .telemetry = telemetry,
            .app_dir_path = app_dir_path,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.app_dir_path) |app_dir_path| {
            self.allocator.free(app_dir_path);
        }

        self.telemetry.deinit();
        self.loop.deinit();
        self.allocator.destroy(self.loop);
    }
};

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn("failed to get lightpanda data dir: {}", .{err});
        return null;
    };

    std.fs.makeDirAbsolute(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return app_dir_path,
        else => {
            allocator.free(app_dir_path);
            log.warn("failed to create lightpanda data dir: {}", .{err});
            return null;
        },
    };
    return app_dir_path;
}

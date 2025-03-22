const std = @import("std");

const Loop = @import("jsruntime").Loop;
const Allocator = std.mem.Allocator;
const HttpClient = @import("http/Client.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

const log = std.log.scoped(.app);

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    loop: *Loop,
    allocator: Allocator,
    telemetry: Telemetry,
    http_client: HttpClient,
    app_dir_path: ?[]const u8,

    pub const RunMode = enum {
        serve,
        fetch,
    };

    pub fn init(allocator: Allocator, run_mode: RunMode) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);

        loop.* = try Loop.init(allocator);
        errdefer loop.deinit();

        const app_dir_path = getAndMakeAppDir(allocator);

        app.* = .{
            .loop = loop,
            .allocator = allocator,
            .telemetry = undefined,
            .app_dir_path = app_dir_path,
            .http_client = .{ .allocator = allocator },
        };
        app.telemetry = Telemetry.init(app, run_mode);

        return app;
    }

    pub fn deinit(self: *App) void {
        const allocator = self.allocator;
        if (self.app_dir_path) |app_dir_path| {
            allocator.free(app_dir_path);
        }
        self.telemetry.deinit();
        self.loop.deinit();
        allocator.destroy(self.loop);
        self.http_client.deinit();
        allocator.destroy(self);
    }
};

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (@import("builtin").is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }
    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn("failed to get lightpanda data dir: {}", .{err});
        return null;
    };

    std.fs.cwd().makePath(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return app_dir_path,
        else => {
            allocator.free(app_dir_path);
            log.warn("failed to create lightpanda data dir: {}", .{err});
            return null;
        },
    };
    return app_dir_path;
}

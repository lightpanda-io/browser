const std = @import("std");
const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const Loop = @import("runtime/loop.zig").Loop;
const http = @import("http/client.zig");

const Telemetry = @import("telemetry/telemetry.zig").Telemetry;
const Notification = @import("notification.zig").Notification;

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    loop: *Loop,
    config: Config,
    allocator: Allocator,
    telemetry: Telemetry,
    http_client: http.Client,
    app_dir_path: ?[]const u8,
    notification: *Notification,

    pub const RunMode = enum {
        help,
        fetch,
        serve,
        version,
    };

    pub const Config = struct {
        run_mode: RunMode,
        tls_verify_host: bool = true,
        http_proxy: ?std.Uri = null,
        proxy_type: ?http.ProxyType = null,
        proxy_auth: ?http.ProxyAuth = null,
    };

    pub fn init(allocator: Allocator, config: Config) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);

        loop.* = try Loop.init(allocator);
        errdefer loop.deinit();

        const notification = try Notification.init(allocator, null);
        errdefer notification.deinit();

        const app_dir_path = getAndMakeAppDir(allocator);

        app.* = .{
            .loop = loop,
            .allocator = allocator,
            .telemetry = undefined,
            .app_dir_path = app_dir_path,
            .notification = notification,
            .http_client = try http.Client.init(allocator, loop, .{
                .max_concurrent = 3,
                .http_proxy = config.http_proxy,
                .proxy_type = config.proxy_type,
                .proxy_auth = config.proxy_auth,
                .tls_verify_host = config.tls_verify_host,
            }),
            .config = config,
        };
        app.telemetry = Telemetry.init(app, config.run_mode);
        try app.telemetry.register(app.notification);

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
        self.notification.deinit();
        allocator.destroy(self);
    }
};

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (@import("builtin").is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }
    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn(.app, "get data dir", .{ .err = err });
        return null;
    };

    std.fs.cwd().makePath(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return app_dir_path,
        else => {
            allocator.free(app_dir_path);
            log.warn(.app, "create data dir", .{ .err = err, .path = app_dir_path });
            return null;
        },
    };
    return app_dir_path;
}

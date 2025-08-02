const std = @import("std");

const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const Http = @import("http/Http.zig");
const Loop = @import("runtime/loop.zig").Loop;
const Platform = @import("runtime/js.zig").Platform;

const Telemetry = @import("telemetry/telemetry.zig").Telemetry;
const Notification = @import("notification.zig").Notification;

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    http: Http,
    loop: *Loop,
    config: Config,
    platform: ?*const Platform,
    allocator: Allocator,
    telemetry: Telemetry,
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
        platform: ?*const Platform = null,
        tls_verify_host: bool = true,
        http_proxy: ?std.Uri = null,
        proxy_type: ?Http.ProxyType = null,
        proxy_auth: ?Http.ProxyAuth = null,
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

        var http = try Http.init(allocator, .{
            .max_concurrent_transfers = 3,
            .tls_verify_host = config.tls_verify_host,
        });
        errdefer http.deinit();

        const app_dir_path = getAndMakeAppDir(allocator);

        app.* = .{
            .loop = loop,
            .http = http,
            .allocator = allocator,
            .telemetry = undefined,
            .platform = config.platform,
            .app_dir_path = app_dir_path,
            .notification = notification,
            .config = config,
        };

        app.telemetry = try Telemetry.init(app, config.run_mode);
        errdefer app.telemetry.deinit();

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
        self.notification.deinit();
        self.http.deinit();
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

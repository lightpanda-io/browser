const std = @import("std");

const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const Http = @import("http/Http.zig");
const Platform = @import("browser/js/Platform.zig");

const Telemetry = @import("telemetry/telemetry.zig").Telemetry;
const Notification = @import("notification.zig").Notification;

// Container for global state / objects that various parts of the system
// might need.
pub const App = struct {
    http: Http,
    config: Config,
    platform: Platform,
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
        tls_verify_host: bool = true,
        http_proxy: ?[:0]const u8 = null,
        proxy_bearer_token: ?[:0]const u8 = null,
        http_timeout_ms: ?u31 = null,
        http_connect_timeout_ms: ?u31 = null,
        http_max_host_open: ?u8 = null,
        http_max_concurrent: ?u8 = null,
        user_agent: [:0]const u8,
    };

    pub fn init(allocator: Allocator, config: Config) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const notification = try Notification.init(allocator, null);
        errdefer notification.deinit();

        var http = try Http.init(allocator, .{
            .max_host_open = config.http_max_host_open orelse 4,
            .max_concurrent = config.http_max_concurrent orelse 10,
            .timeout_ms = config.http_timeout_ms orelse 5000,
            .connect_timeout_ms = config.http_connect_timeout_ms orelse 0,
            .http_proxy = config.http_proxy,
            .tls_verify_host = config.tls_verify_host,
            .proxy_bearer_token = config.proxy_bearer_token,
            .user_agent = config.user_agent,
        });
        errdefer http.deinit();

        const platform = try Platform.init();
        errdefer platform.deinit();

        const app_dir_path = getAndMakeAppDir(allocator);

        app.* = .{
            .http = http,
            .allocator = allocator,
            .telemetry = undefined,
            .platform = platform,
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
        self.notification.deinit();
        self.http.deinit();
        self.platform.deinit();
        allocator.destroy(self);
    }
};

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (@import("builtin").is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }

    if (@import("builtin").os.tag == .ios) {
        return null; // getAppDataDir is not available on iOS
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

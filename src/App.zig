// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const Http = @import("http/Http.zig");
const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");

const Notification = @import("Notification.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

// Container for global state / objects that various parts of the system
// might need.
const App = @This();

http: Http,
config: Config,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
allocator: Allocator,
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

    app.config = config;
    app.allocator = allocator;

    app.notification = try Notification.init(allocator, null);
    errdefer app.notification.deinit();

    app.http = try Http.init(allocator, .{
        .max_host_open = config.http_max_host_open orelse 4,
        .max_concurrent = config.http_max_concurrent orelse 10,
        .timeout_ms = config.http_timeout_ms orelse 5000,
        .connect_timeout_ms = config.http_connect_timeout_ms orelse 0,
        .http_proxy = config.http_proxy,
        .tls_verify_host = config.tls_verify_host,
        .proxy_bearer_token = config.proxy_bearer_token,
        .user_agent = config.user_agent,
    });
    errdefer app.http.deinit();

    app.platform = try Platform.init();
    errdefer app.platform.deinit();

    app.snapshot = try Snapshot.load(allocator);
    errdefer app.snapshot.deinit(allocator);

    app.app_dir_path = getAndMakeAppDir(allocator);

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
    self.snapshot.deinit(allocator);
    self.platform.deinit();

    allocator.destroy(self);
}

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

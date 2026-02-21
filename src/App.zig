// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Config = @import("Config.zig");
const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;
const RobotStore = @import("browser/Robots.zig").RobotStore;
const WebBotAuth = @import("browser/WebBotAuth.zig");

pub const Http = @import("http/Http.zig");
pub const ArenaPool = @import("ArenaPool.zig");

const App = @This();

http: Http,
config: *const Config,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
allocator: Allocator,
arena_pool: ArenaPool,
robots: RobotStore,
web_bot_auth: ?WebBotAuth,
app_dir_path: ?[]const u8,
shutdown: bool = false,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.config = config;
    app.allocator = allocator;

    app.robots = RobotStore.init(allocator);

    if (config.webBotAuth()) |wba_cfg| {
        app.web_bot_auth = try WebBotAuth.fromConfig(allocator, &wba_cfg);
    } else {
        app.web_bot_auth = null;
    }
    errdefer if (app.web_bot_auth) |wba| wba.deinit(allocator);

    app.http = try Http.init(allocator, &app.robots, &app.web_bot_auth, config);
    errdefer app.http.deinit();

    app.platform = try Platform.init();
    errdefer app.platform.deinit();

    app.snapshot = try Snapshot.load();
    errdefer app.snapshot.deinit();

    app.app_dir_path = getAndMakeAppDir(allocator);

    app.telemetry = try Telemetry.init(app, config.mode);
    errdefer app.telemetry.deinit();

    app.arena_pool = ArenaPool.init(allocator);
    errdefer app.arena_pool.deinit();

    return app;
}

pub fn deinit(self: *App) void {
    if (@atomicRmw(bool, &self.shutdown, .Xchg, true, .monotonic)) {
        return;
    }

    const allocator = self.allocator;
    if (self.app_dir_path) |app_dir_path| {
        allocator.free(app_dir_path);
        self.app_dir_path = null;
    }
    self.telemetry.deinit();
    self.robots.deinit();
    if (self.web_bot_auth) |wba| {
        wba.deinit(allocator);
    }
    self.http.deinit();
    self.snapshot.deinit();
    self.platform.deinit();
    self.arena_pool.deinit();

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

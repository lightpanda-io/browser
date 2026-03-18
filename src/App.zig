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

const Network = @import("network/Runtime.zig");
pub const ArenaPool = @import("ArenaPool.zig");

const App = @This();

network: Network,
config: *const Config,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
allocator: Allocator,
arena_pool: ArenaPool,
app_dir_path: ?[]const u8,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .config = config,
        .allocator = allocator,
        .network = undefined,
        .platform = undefined,
        .snapshot = undefined,
        .app_dir_path = undefined,
        .telemetry = undefined,
        .arena_pool = undefined,
    };

    app.network = try Network.init(allocator, config);
    errdefer app.network.deinit();

    app.platform = try Platform.init();
    errdefer app.platform.deinit();

    app.snapshot = try Snapshot.load();
    errdefer app.snapshot.deinit();

    app.app_dir_path = getAndMakeAppDir(allocator);

    app.telemetry = try Telemetry.init(app, config.mode);
    errdefer app.telemetry.deinit(allocator);

    app.arena_pool = ArenaPool.init(allocator, 512, 1024 * 16);
    errdefer app.arena_pool.deinit();

    return app;
}

pub fn shutdown(self: *const App) bool {
    return self.network.shutdown.load(.acquire);
}

pub fn deinit(self: *App) void {
    const allocator = self.allocator;
    if (self.app_dir_path) |app_dir_path| {
        allocator.free(app_dir_path);
        self.app_dir_path = null;
    }
    self.telemetry.deinit(allocator);
    self.network.deinit();
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

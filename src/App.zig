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
const lp = @import("lightpanda");

const Regex = @import("Regex.zig");
const Config = @import("Config.zig");
const Watchdog = @import("Watchdog.zig");
pub const ArenaPool = @import("ArenaPool.zig");

const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");
const screenshot = @import("browser/screenshot.zig");
const Sanitizer = @import("browser/webapi/Sanitizer.zig");

const Network = @import("network/Network.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;
const zenai = @import("zenai");

const log = lp.log;
const Allocator = std.mem.Allocator;

const App = @This();

network: Network,
config: *const Config,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
watchdog: Watchdog,
allocator: Allocator,
arena_pool: ArenaPool,
app_dir_path: ?[]const u8,

regex_context: *Regex.Context,
default_sanitizer: *Sanitizer,
render_fonts: screenshot.Fonts,

/// Idle TypeSafe clients. A call takes one (or makes one) and puts it back,
/// so concurrent calls each get their own and keep its connection warm.
typesafe_idle: std.ArrayList(*zenai.typesafe.Client) = .empty,
typesafe_mutex: std.Io.Mutex = .init,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    const platform = try Platform.init(.{
        .v8_flags = config.v8Flags(),
        .locale = config.locale(),
        .timezone = config.timezone(),
    });
    errdefer platform.deinit();

    const snapshot = try Snapshot.load();
    errdefer snapshot.deinit();

    const regex_context: *Regex.Context = try .init(allocator);
    errdefer regex_context.deinit();

    var render_fonts: screenshot.Fonts = try .load(allocator, config.renderFonts());
    errdefer render_fonts.deinit(allocator);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .config = config,
        .allocator = allocator,
        .platform = platform,
        .snapshot = snapshot,
        .regex_context = regex_context,
        .render_fonts = render_fonts,
        .network = undefined,
        .app_dir_path = undefined,
        .telemetry = undefined,
        .arena_pool = undefined,
        .default_sanitizer = undefined,
        .watchdog = .init(config.watchdogMs()),
    };
    try app.watchdog.start();
    errdefer app.watchdog.deinit();

    app.network = try Network.init(app);
    errdefer app.network.deinit();

    app.app_dir_path = getAndMakeAppDir(allocator);

    app.telemetry = try Telemetry.init(app);
    errdefer app.telemetry.deinit(allocator);

    app.arena_pool = ArenaPool.init(allocator, .{});
    errdefer app.arena_pool.deinit();

    app.default_sanitizer = try .initDefault(&app.arena_pool);

    return app;
}

pub fn deinit(self: *App) void {
    const allocator = self.allocator;
    // All browsers are gone by now, so the entry list is empty; this just
    // stops the checker thread.
    self.watchdog.deinit();
    if (self.app_dir_path) |app_dir_path| {
        allocator.free(app_dir_path);
        self.app_dir_path = null;
    }
    self.telemetry.deinit(allocator);
    self.network.deinit();
    // After `network`: its adblock regexes free through this context.
    self.regex_context.deinit();
    self.snapshot.deinit();
    self.platform.deinit();
    self.default_sanitizer.deinitDefault();
    self.render_fonts.deinit(allocator);
    self.arena_pool.deinit();

    self.dropTypesafeClients();
    self.typesafe_idle.deinit(allocator);

    allocator.destroy(self);
}

/// On `error.ApiError`, `failure` gets the API's status and message, duped
/// into `arena`. Safe to call from any thread: it touches no browser state.
pub fn askTypesafe(
    self: *App,
    arena: Allocator,
    state: zenai.typesafe.Content,
    questions: zenai.typesafe.Questions,
    options: zenai.typesafe.types.AskOptions,
    failure: *zenai.http.ErrorDetail,
) !zenai.typesafe.Client.Response(zenai.typesafe.types.AskResponse) {
    const client = try self.takeTypesafeClient();
    defer self.putTypesafeClient(client);

    return client.ask(state, questions, options) catch |err| {
        if (err == error.ApiError) failure.* = try client.last_error.dupe(arena);
        return err;
    };
}

fn takeTypesafeClient(self: *App) !*zenai.typesafe.Client {
    {
        self.typesafe_mutex.lockUncancelable(lp.io);
        defer self.typesafe_mutex.unlock(lp.io);
        if (self.typesafe_idle.pop()) |client| return client;
    }

    const key = zenai.typesafe.envApiKey(lp.environ()) orelse return error.MissingApiKey;
    const client = try self.allocator.create(zenai.typesafe.Client);
    client.* = zenai.typesafe.Client.init(lp.io, self.allocator, key, .{
        .base_url = zenai.typesafe.envBaseUrl(lp.environ()),
        // The calling session waits on it: fail fast.
        .retry_policy = .disabled,
        .request_timeout_ms = 10_000,
    });
    return client;
}

fn putTypesafeClient(self: *App, client: *zenai.typesafe.Client) void {
    self.typesafe_mutex.lockUncancelable(lp.io);
    defer self.typesafe_mutex.unlock(lp.io);
    self.typesafe_idle.append(self.allocator, client) catch {
        client.deinit();
        self.allocator.destroy(client);
    };
}

/// Close the idle clients; the next call reads the API key again.
pub fn dropTypesafeClients(self: *App) void {
    self.typesafe_mutex.lockUncancelable(lp.io);
    defer self.typesafe_mutex.unlock(lp.io);
    for (self.typesafe_idle.items) |client| {
        client.deinit();
        self.allocator.destroy(client);
    }
    self.typesafe_idle.clearRetainingCapacity();
}

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (lp.IS_TEST) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }
    const app_dir_path = getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn(.app, "get data dir", .{ .err = err });
        return null;
    };

    std.Io.Dir.cwd().createDirPath(lp.io, app_dir_path) catch |err| switch (err) {
        else => {
            allocator.free(app_dir_path);
            log.warn(.app, "create data dir", .{ .err = err, .path = app_dir_path });
            return null;
        },
    };
    return app_dir_path;
}

pub fn getAppDataDir(allocator: Allocator, appname: []const u8) ![]const u8 {
    switch (@import("builtin").os.tag) {
        .macos, .ios => {
            const home = std.c.getenv("HOME") orelse return error.AppDataDirUnavailable;
            return std.fs.path.join(allocator, &.{ std.mem.span(home), "Library", "Application Support", appname });
        },
        else => {
            if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
                const x = std.mem.span(xdg);
                if (x.len > 0) {
                    return std.fs.path.join(allocator, &.{ x, appname });
                }
            }
            const home = std.c.getenv("HOME") orelse return error.AppDataDirUnavailable;
            return std.fs.path.join(allocator, &.{ std.mem.span(home), ".local", "share", appname });
        },
    }
}

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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = lp.log;
const App = lp.App;
const Config = lp.Config;
const Host = lp.sys.Host;
const SigHandler = @import("Sighandler.zig");
pub const panic = lp.crash_handler.panic;

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa_instance: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    const gpa = if (builtin.mode == .Debug) gpa_instance.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa_instance.detectLeaks()) std.posix.exit(1);
    };

    // arena for main-specific allocations
    var main_arena_instance = std.heap.ArenaAllocator.init(gpa);
    const main_arena = main_arena_instance.allocator();
    defer main_arena_instance.deinit();

    run(gpa, main_arena) catch |err| {
        log.fatal(.app, "exit", .{ .err = err });
        std.posix.exit(1);
    };
}

fn run(allocator: Allocator, main_arena: Allocator) !void {
    const args = try Config.parseArgs(main_arena);
    defer args.deinit(main_arena);

    switch (args.mode) {
        .help => {
            args.printUsageAndExit(args.mode.help);
            return std.process.cleanExit();
        },
        .version => {
            std.debug.print("{s}\n", .{lp.build_config.git_commit});
            return std.process.cleanExit();
        },
        else => {},
    }

    if (args.logLevel()) |ll| {
        log.opts.level = ll;
    }
    if (args.logFormat()) |lf| {
        log.opts.format = lf;
    }
    if (args.logFilterScopes()) |lfs| {
        log.opts.filter_scopes = lfs;
    }

    const requested_browser_mode = args.browserMode();

    // _app is global to handle graceful shutdown.
    var host = Host.initForBuildClass(allocator, lp.build_config.target_class == .bare_metal);
    defer host.deinit();

    var app = try App.init(allocator, &args, &host);

    defer app.deinit();
    const browser_mode = app.display.runtime_mode;
    if (requested_browser_mode != browser_mode) {
        log.warn(.app, "browser mode fallback", .{
            .requested = @tagName(requested_browser_mode),
            .runtime = @tagName(browser_mode),
            .status = "experimental",
        });
    }
    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            const sighandler = try main_arena.create(SigHandler);
            sighandler.* = .{ .arena = main_arena };
            try sighandler.install();

            log.debug(.app, "startup", .{ .mode = "serve", .browser_mode = @tagName(browser_mode), .snapshot = app.snapshot.fromEmbedded() });
            const address = std.net.Address.parseIp(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return args.printUsageAndExit(false);
            };

            // _server is global to handle graceful shutdown.
            var server = try lp.Server.init(app, address);
            defer server.deinit();

            try sighandler.on(lp.Server.stop, .{&server});

            // max timeout of 1 week.
            const timeout = if (opts.timeout > 604_800) 604_800_000 else @as(u32, opts.timeout) * 1000;
            server.run(address, timeout) catch |err| {
                log.fatal(.app, "server run error", .{ .err = err });
                return err;
            };
        },
        .browse => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{
                .mode = "browse",
                .browser_mode = @tagName(browser_mode),
                .url = url,
                .snapshot = app.snapshot.fromEmbedded(),
            });

            lp.browse(app, url, .{}) catch |err| {
                log.fatal(.app, "browse error", .{ .err = err, .url = url });
                return err;
            };
        },
        .fetch => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{ .mode = "fetch", .browser_mode = @tagName(browser_mode), .dump_mode = opts.dump_mode, .url = url, .snapshot = app.snapshot.fromEmbedded() });

            var fetch_opts = lp.FetchOpts{
                .wait_ms = 5000,
                .dump_mode = opts.dump_mode,
                .dump = .{
                    .strip = opts.strip,
                    .with_base = opts.with_base,
                    .with_frames = opts.with_frames,
                },
            };

            var stdout = std.fs.File.stdout();
            var writer = stdout.writer(&.{});
            if (opts.dump_mode != null) {
                fetch_opts.writer = &writer.interface;
            }

            lp.fetch(app, url, fetch_opts) catch |err| {
                log.fatal(.app, "fetch error", .{ .err = err, .url = url });
                return err;
            };
        },
        .mcp => {
            log.info(.mcp, "starting server", .{});

            log.opts.format = .logfmt;

            var stdout = std.fs.File.stdout().writer(&.{});

            var mcp_server: *lp.mcp.Server = try .init(allocator, app, &stdout.interface);
            defer mcp_server.deinit();

            var stdin_buf: [64 * 1024]u8 = undefined;
            var stdin = std.fs.File.stdin().reader(&stdin_buf);

            try lp.mcp.router.processRequests(mcp_server, &stdin.interface);
        },
        else => unreachable,
    }
}

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
pub const App = @import("App.zig");
pub const Server = @import("Server.zig");
pub const Config = @import("Config.zig");
pub const Page = @import("browser/Page.zig");
pub const Browser = @import("browser/Browser.zig");
pub const Session = @import("browser/Session.zig");
pub const Notification = @import("Notification.zig");

pub const log = @import("log.zig");
pub const js = @import("browser/js/js.zig");
pub const dump = @import("browser/dump.zig");
pub const markdown = @import("browser/markdown.zig");
pub const mcp = struct {
    pub const Server = @import("mcp/Server.zig").McpServer;
    pub const protocol = @import("mcp/protocol.zig");
    pub const router = @import("mcp/router.zig");
};
pub const build_config = @import("build_config");
pub const crash_handler = @import("crash_handler.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub const FetchOpts = struct {
    wait_ms: u32 = 5000,
    dump: dump.RootOpts,
    dump_mode: ?Config.DumpFormat = null,
    writer: ?*std.Io.Writer = null,
};
pub fn fetch(app: *App, url: [:0]const u8, opts: FetchOpts) !void {
    const http_client = try app.http.createClient(app.allocator);
    defer http_client.deinit();

    const notification = try Notification.init(app.allocator);
    defer notification.deinit();

    var browser = try Browser.init(app, .{ .http_client = http_client });
    defer browser.deinit();

    var session = try browser.newSession(notification);
    const page = try session.createPage();

    // // Comment this out to get a profile of the JS code in v8/profile.json.
    // // You can open this in Chrome's profiler.
    // // I've seen it generate invalid JSON, but I'm not sure why. It
    // // happens rarely, and I manually fix the file.
    // page.js.startCpuProfiler();
    // defer {
    //     if (page.js.stopCpuProfiler()) |profile| {
    //         std.fs.cwd().writeFile(.{
    //             .sub_path = ".lp-cache/cpu_profile.json",
    //             .data = profile,
    //         }) catch |err| {
    //             log.err(.app, "profile write error", .{ .err = err });
    //         };
    //     } else |err| {
    //         log.err(.app, "profile error", .{ .err = err });
    //     }
    // }

    // // Comment this out to get a heap V8 heap profil
    // page.js.startHeapProfiler();
    // defer {
    //     if (page.js.stopHeapProfiler()) |profile| {
    //         std.fs.cwd().writeFile(.{
    //             .sub_path = ".lp-cache/allocating.heapprofile",
    //             .data = profile.@"0",
    //         }) catch |err| {
    //             log.err(.app, "allocating write error", .{ .err = err });
    //         };
    //         std.fs.cwd().writeFile(.{
    //             .sub_path = ".lp-cache/snapshot.heapsnapshot",
    //             .data = profile.@"1",
    //         }) catch |err| {
    //             log.err(.app, "heapsnapshot write error", .{ .err = err });
    //         };
    //     } else |err| {
    //         log.err(.app, "profile error", .{ .err = err });
    //     }
    // }

    _ = try page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    _ = session.wait(opts.wait_ms);

    const writer = opts.writer orelse return;
    if (opts.dump_mode) |mode| {
        switch (mode) {
            .html => try dump.root(page.window._document, opts.dump, writer, page),
            .markdown => try markdown.dump(page.window._document.asNode(), .{}, writer, page),
        }
    }
    try writer.flush();
}

pub inline fn assert(ok: bool, comptime ctx: []const u8, args: anytype) void {
    if (!ok) {
        if (comptime IS_DEBUG) {
            unreachable;
        }
        assertionFailure(ctx, args);
    }
}

noinline fn assertionFailure(comptime ctx: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint("assertion failure: " ++ ctx, args));
    }
    @import("crash_handler.zig").crash(ctx, args, @returnAddress());
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("mcp/tests.zig");
}

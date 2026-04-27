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

pub const log = @import("log.zig");
pub const App = @import("App.zig");
pub const Network = @import("network/Network.zig");
pub const Server = @import("Server.zig");
pub const Config = @import("Config.zig");
pub const String = @import("string.zig").String;
pub const Notification = @import("Notification.zig");

pub const URL = @import("browser/URL.zig");
pub const Page = @import("browser/Page.zig");
pub const Frame = @import("browser/Frame.zig");
pub const Browser = @import("browser/Browser.zig");
pub const Session = @import("browser/Session.zig");

pub const js = @import("browser/js/js.zig");
pub const dump = @import("browser/dump.zig");
pub const markdown = @import("browser/markdown.zig");
pub const SemanticTree = @import("SemanticTree.zig");
pub const CDPNode = @import("cdp/Node.zig");
pub const interactive = @import("browser/interactive.zig");
pub const links = @import("browser/links.zig");
pub const forms = @import("browser/forms.zig");
pub const actions = @import("browser/actions.zig");
pub const structured_data = @import("browser/structured_data.zig");
pub const HttpClient = @import("browser/HttpClient.zig");

pub const mcp = @import("mcp.zig");
pub const cookies = @import("cookies.zig");
pub const build_config = @import("build_config");
pub const crash_handler = @import("crash_handler.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub const FetchOpts = struct {
    wait_ms: u32 = 5000,
    wait_until: ?Config.WaitUntil = null,
    wait_script: ?[:0]const u8 = null,
    wait_selector: ?[:0]const u8 = null,
    dump: dump.Opts,
    dump_mode: ?Config.DumpFormat = null,
    writer: ?*std.Io.Writer = null,
};
pub fn fetch(app: *App, browser: *Browser, url: [:0]const u8, opts: FetchOpts) !void {
    const notification = try Notification.init(app.allocator);
    defer notification.deinit();

    var session = try browser.newSession(notification);

    if (app.config.cookieFile()) |cookie_path| {
        cookies.loadFromFile(session, cookie_path);
    }

    defer {
        if (app.config.cookieJarFile()) |cookie_jar_path| {
            cookies.saveToFile(&session.cookie_jar, cookie_jar_path);
        }
    }

    const frame = try session.createPage();

    // // Comment this out to get a profile of the JS code in v8/profile.json.
    // // You can open this in Chrome's profiler.
    // // I've seen it generate invalid JSON, but I'm not sure why. It
    // // happens rarely, and I manually fix the file.
    // frame.js.startCpuProfiler();
    // defer {
    //     if (frame.js.stopCpuProfiler()) |profile| {
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
    // frame.js.startHeapProfiler();
    // defer {
    //     if (frame.js.stopHeapProfiler()) |profile| {
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

    const encoded_url = try URL.ensureEncoded(frame.call_arena, url, "UTF-8");
    _ = try frame.navigate(encoded_url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    var runner = try session.runner(.{});

    var timer = try std.time.Timer.start();

    if (opts.wait_until) |wu| {
        try runner.wait(.{ .ms = opts.wait_ms, .until = wu });
    } else if (opts.wait_selector == null and opts.wait_script == null) {
        // We default to .done if both wait_selector and wait_script are null
        // This allows the caller to ONLY --wait-selector or ONLY --wait-script
        // or combine --wait-until WITH --wait-selector/script
        try runner.wait(.{ .ms = opts.wait_ms, .until = .done });
    }

    if (opts.wait_selector) |selector| {
        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        const remaining = opts.wait_ms -| elapsed;
        if (remaining == 0) return error.Timeout;
        _ = try runner.waitForSelector(selector, remaining);
    }

    if (opts.wait_script) |script| {
        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        const remaining = opts.wait_ms -| elapsed;
        if (remaining == 0) return error.Timeout;
        try runner.waitForScript(script, remaining);
    }

    const writer = opts.writer orelse return;
    if (opts.dump_mode) |mode| {
        switch (mode) {
            .html => try dump.root(frame.window._document, opts.dump, writer, frame),
            .markdown => try markdown.dump(frame.window._document.asNode(), .{}, writer, frame),
            .semantic_tree, .semantic_tree_text => {
                var registry = CDPNode.Registry.init(app.allocator);
                defer registry.deinit();

                const st: SemanticTree = .{
                    .dom_node = frame.window._document.asNode(),
                    .registry = &registry,
                    .frame = frame,
                    .arena = frame.call_arena,
                    .prune = (mode == .semantic_tree_text),
                };

                if (mode == .semantic_tree) {
                    try std.json.Stringify.value(st, .{}, writer);
                } else {
                    try st.textStringify(writer);
                }
            },
            .wpt => try dumpWPT(frame, writer),
        }
    }
    try writer.flush();
}

fn dumpWPT(frame: *Frame, writer: *std.Io.Writer) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // return the detailed result.
    const dump_script =
        \\ JSON.stringify((() => {
        \\   const statuses = ['Pass', 'Fail', 'Timeout', 'Not Run', 'Optional Feature Unsupported'];
        \\   const parse = (raw) => {
        \\     for (const status of statuses) {
        \\       const idx = raw.indexOf('|' + status);
        \\       if (idx !== -1) {
        \\         const name = raw.slice(0, idx);
        \\         const rest = raw.slice(idx + status.length + 1);
        \\         const message = rest.length > 0 && rest[0] === '|' ? rest.slice(1) : null;
        \\         return { name, status, message };
        \\       }
        \\     }
        \\     return { name: raw, status: 'Unknown', message: null };
        \\   };
        \\   const cases = Object.values(report.cases).map(parse);
        \\   return {
        \\     url: window.location.href,
        \\     status: report.status,
        \\     message: report.message,
        \\     summary: {
        \\       total: cases.length,
        \\       passed: cases.filter(c => c.status === 'Pass').length,
        \\       failed: cases.filter(c => c.status === 'Fail').length,
        \\       timeout: cases.filter(c => c.status === 'Timeout').length,
        \\       notrun: cases.filter(c => c.status === 'Not Run').length,
        \\       unsupported: cases.filter(c => c.status === 'Optional Feature Unsupported').length
        \\     },
        \\     not_passed: cases.filter(c => c.status !== 'Pass')
        \\   };
        \\ })(), null, 2)
    ;
    const value = ls.local.exec(dump_script, "dump_script") catch |err| {
        const caught = try_catch.caughtOrError(frame.call_arena, err);
        return writer.print("Caught error trying to access WPT's report: {f}\n", .{caught});
    };
    try writer.writeAll("== WPT Results==\n");
    try writer.writeAll(try value.toStringSliceWithAlloc(frame.call_arena));
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

// Reference counting helper
pub fn RC(comptime T: type) type {
    return struct {
        _refs: T = 0,

        pub fn init(refs: T) @This() {
            return .{ ._refs = refs };
        }

        pub fn acquire(self: *@This()) void {
            self._refs += 1;
        }

        pub fn release(self: *@This(), value: anytype, page: *Page) void {
            assert(self._refs > 0, "release overflow", .{ .type = @typeName(@TypeOf(value)) });

            const refs = self._refs - 1;
            self._refs = refs;
            if (refs > 0) {
                return;
            }
            value.deinit(page);
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            return writer.print("{d}", .{self._refs});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

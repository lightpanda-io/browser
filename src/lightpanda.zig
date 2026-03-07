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
pub const URL = @import("browser/URL.zig");
pub const Page = @import("browser/Page.zig");
pub const Browser = @import("browser/Browser.zig");
pub const Session = @import("browser/Session.zig");
pub const Notification = @import("Notification.zig");

pub const log = @import("log.zig");
pub const js = @import("browser/js/js.zig");
pub const dump = @import("browser/dump.zig");
pub const markdown = @import("browser/markdown.zig");
pub const mcp = @import("mcp.zig");
pub const build_config = @import("build_config");
pub const crash_handler = @import("crash_handler.zig");
const BrowserCommand = @import("display/BrowserCommand.zig").BrowserCommand;
const DocumentPainter = @import("render/DocumentPainter.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub const FetchOpts = struct {
    wait_ms: u32 = 5000,
    dump: dump.Opts,
    dump_mode: ?Config.DumpFormat = null,
    writer: ?*std.Io.Writer = null,
};

pub const BrowseOpts = struct {
    wait_ms: u32 = 50,
};

const CommittedBrowseSurface = struct {
    title: []u8 = &.{},
    url: []u8 = &.{},
    body: []u8 = &.{},
    display_list: ?@import("render/DisplayList.zig") = null,
    hash: u64 = 0,

    fn deinit(self: *CommittedBrowseSurface, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.body);
        if (self.display_list) |*display_list| {
            display_list.deinit(allocator);
        }
        self.* = .{};
    }

    fn replace(
        self: *CommittedBrowseSurface,
        allocator: std.mem.Allocator,
        title: []const u8,
        url: []const u8,
        body: []const u8,
        display_list: *const @import("render/DisplayList.zig"),
        hash: u64,
    ) !void {
        const next_title = try allocator.dupe(u8, title);
        errdefer allocator.free(next_title);
        const next_url = try allocator.dupe(u8, url);
        errdefer allocator.free(next_url);
        const next_body = try allocator.dupe(u8, body);
        errdefer allocator.free(next_body);
        const next_display_list = try display_list.cloneOwned(allocator);
        errdefer {
            var owned = next_display_list;
            owned.deinit(allocator);
        }

        self.deinit(allocator);
        self.* = .{
            .title = next_title,
            .url = next_url,
            .body = next_body,
            .display_list = next_display_list,
            .hash = hash,
        };
    }

    fn available(self: *const CommittedBrowseSurface) bool {
        return self.hash != 0;
    }
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

    const encoded_url = try URL.ensureEncoded(page.call_arena, url);
    _ = try page.navigate(encoded_url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    _ = session.wait(opts.wait_ms);

    const writer = opts.writer orelse return;
    if (opts.dump_mode) |mode| {
        switch (mode) {
            .html => try dump.root(page.window._document, opts.dump, writer, page),
            .markdown => try markdown.dump(page.window._document.asNode(), .{}, writer, page),
            .wpt => try dumpWPT(page, writer),
        }
    }
    try writer.flush();
}

pub fn browse(app: *App, url: [:0]const u8, opts: BrowseOpts) !void {
    const http_client = try app.http.createClient(app.allocator);
    defer http_client.deinit();

    const notification = try Notification.init(app.allocator);
    defer notification.deinit();

    var browser = try Browser.init(app, .{ .http_client = http_client });
    defer browser.deinit();

    var session = try browser.newSession(notification);
    var page = try session.createPage();
    var committed_surface: CommittedBrowseSurface = .{};
    defer committed_surface.deinit(app.allocator);
    var restore_committed_surface = false;

    try app.display.presentDocument("Lightpanda Browser", url, "Loading page...");

    const encoded_url = try URL.ensureEncoded(page.call_arena, url);
    _ = try page.navigate(encoded_url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    app.display.setNavigationState(
        session.navigation.getCanGoBack(),
        session.navigation.getCanGoForward(),
        pageIsLoading(page),
    );

    var last_presented_hash: u64 = 0;
    browse_loop: while (!app.shutdown and !app.display.userClosed()) {
        while (app.display.nextBrowserCommand()) |command| {
            defer command.deinit(app.allocator);

            page = session.currentPage() orelse break :browse_loop;
            try handleBrowseCommand(
                app,
                session,
                page,
                command,
                &last_presented_hash,
                &committed_surface,
                &restore_committed_surface,
            );
        }

        _ = session.wait(opts.wait_ms);
        page = session.currentPage() orelse break;
        if (restore_committed_surface and committed_surface.available() and pageIsLoading(page)) {
            app.display.setNavigationState(
                session.navigation.getCanGoBack(),
                session.navigation.getCanGoForward(),
                false,
            );
            try restoreCommittedBrowseSurface(app, &committed_surface, &last_presented_hash);
            continue;
        }
        if (!pageIsLoading(page)) {
            restore_committed_surface = false;
        }
        app.display.setNavigationState(
            session.navigation.getCanGoBack(),
            session.navigation.getCanGoForward(),
            pageIsLoading(page),
        );
        try presentPage(app, page, &last_presented_hash, &committed_surface);
    }
}

fn handleBrowseCommand(
    app: *App,
    session: *Session,
    page: *Page,
    command: BrowserCommand,
    last_presented_hash: *u64,
    committed_surface: *CommittedBrowseSurface,
    restore_committed_surface: *bool,
) !void {
    switch (command) {
        .navigate => |raw_url| {
            restore_committed_surface.* = false;
            const maybe_normalized_url = normalizeBrowseUrl(app.allocator, raw_url) catch {
                try app.display.presentDocument(
                    "Lightpanda Browser",
                    page.url,
                    "Invalid address. Enter a full URL, for example https://example.com",
                );
                last_presented_hash.* = 0;
                return;
            };
            const normalized_url = maybe_normalized_url orelse {
                try app.display.presentDocument("Lightpanda Browser", page.url, "Enter a full URL, for example https://example.com");
                last_presented_hash.* = 0;
                return;
            };
            defer app.allocator.free(normalized_url);

            try app.display.presentDocument("Lightpanda Browser", normalized_url, "Loading page...");
            last_presented_hash.* = 0;

            try page.scheduleNavigation(normalized_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            }, .{ .script = null });
        },
        .back => {
            restore_committed_surface.* = false;
            if (!session.navigation.getCanGoBack()) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            last_presented_hash.* = 0;
            _ = try session.navigation.back(page);
        },
        .forward => {
            restore_committed_surface.* = false;
            if (!session.navigation.getCanGoForward()) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            last_presented_hash.* = 0;
            _ = try session.navigation.forward(page);
        },
        .reload => {
            restore_committed_surface.* = false;
            if (page.url.len == 0) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            last_presented_hash.* = 0;
            try page.scheduleNavigation(page.url, .{
                .reason = .navigation,
                .force = true,
                .kind = .reload,
            }, .{ .script = null });
        },
        .stop => {
            restore_committed_surface.* = committed_surface.available();
            if (page._queued_navigation) |qn| {
                page.arena_pool.release(qn.arena);
                page._queued_navigation = null;
            }
            session.browser.http_client.abort();
            if (try session.restoreSuspendedPage()) |restored_page| {
                restore_committed_surface.* = false;
                app.display.setNavigationState(
                    session.navigation.getCanGoBack(),
                    session.navigation.getCanGoForward(),
                    pageIsLoading(restored_page),
                );
                last_presented_hash.* = 0;
                try presentPage(app, restored_page, last_presented_hash, committed_surface);
            } else if (restore_committed_surface.*) {
                try restoreCommittedBrowseSurface(app, committed_surface, last_presented_hash);
            } else {
                last_presented_hash.* = 0;
            }
        },
    }
}

fn pageIsLoading(page: *Page) bool {
    return page._queued_navigation != null or page._parse_state != .complete;
}

fn normalizeBrowseUrl(allocator: std.mem.Allocator, raw: []const u8) !?[:0]u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }

    if (std.mem.indexOf(u8, trimmed, "://") != null) {
        return try allocator.dupeZ(u8, trimmed);
    }

    inline for (.{ "about:", "data:", "file:", "javascript:", "mailto:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(trimmed, scheme)) {
            return try allocator.dupeZ(u8, trimmed);
        }
    }

    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) {
        return error.InvalidUrl;
    }

    if (looksLikeLoopbackBrowseTarget(trimmed)) {
        return try std.fmt.allocPrintSentinel(allocator, "http://{s}", .{trimmed}, 0);
    }

    return try std.fmt.allocPrintSentinel(allocator, "https://{s}", .{trimmed}, 0);
}

fn looksLikeLoopbackBrowseTarget(raw: []const u8) bool {
    return hasHostPrefix(raw, "localhost") or
        hasHostPrefix(raw, "127.0.0.1") or
        hasHostPrefix(raw, "[::1]");
}

fn hasHostPrefix(raw: []const u8, prefix: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(raw, prefix)) {
        return false;
    }
    if (raw.len == prefix.len) {
        return true;
    }
    return switch (raw[prefix.len]) {
        ':', '/', '?', '#' => true,
        else => false,
    };
}

fn presentPage(
    app: *App,
    page: *Page,
    last_presented_hash: *u64,
    committed_surface: *CommittedBrowseSurface,
) !void {
    if (page._queued_navigation != null or page._parse_state != .complete) {
        const title = (try page.getTitle()) orelse "Lightpanda Browser";
        const url = if (page.url.len > 0) page.url else "about:blank";

        var loading_hasher = std.hash.Wyhash.init(0);
        loading_hasher.update(title);
        loading_hasher.update(url);
        loading_hasher.update("Loading page...");
        const loading_hash = loading_hasher.final();
        if (loading_hash != last_presented_hash.*) {
            last_presented_hash.* = loading_hash;
            try app.display.presentDocument(title, url, "Loading page...");
        }
        return;
    }

    var body = std.Io.Writer.Allocating.init(app.allocator);
    defer body.deinit();

    try markdown.dump(page.window._document.asNode(), .{}, &body.writer, page);
    var display_list = try DocumentPainter.paintDocument(app.allocator, page, .{
        .viewport_width = @intCast(app.display.viewport.width),
    });
    defer display_list.deinit(app.allocator);

    const title = (try page.getTitle()) orelse "";
    const url = page.url;
    const text = body.written();

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(title);
    hasher.update(url);
    hasher.update(text);
    display_list.hashInto(&hasher);
    const next_hash = hasher.final();
    if (next_hash == last_presented_hash.*) {
        return;
    }

    last_presented_hash.* = next_hash;
    try committed_surface.replace(app.allocator, title, url, text, &display_list, next_hash);
    try app.display.presentPageView(title, url, text, &display_list);
}

fn restoreCommittedBrowseSurface(
    app: *App,
    committed_surface: *const CommittedBrowseSurface,
    last_presented_hash: *u64,
) !void {
    if (!committed_surface.available()) {
        return;
    }
    last_presented_hash.* = committed_surface.hash;
    try app.display.presentPageView(
        committed_surface.title,
        committed_surface.url,
        committed_surface.body,
        if (committed_surface.display_list) |*display_list| display_list else null,
    );
}

fn dumpWPT(page: *Page, writer: *std.Io.Writer) !void {
    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
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
        \\     cases
        \\   };
        \\ })(), null, 2)
    ;
    const value = ls.local.exec(dump_script, "dump_script") catch |err| {
        const caught = try_catch.caughtOrError(page.call_arena, err);
        return writer.print("Caught error trying to access WPT's report: {f}\n", .{caught});
    };
    try writer.writeAll("== WPT Results==\n");
    try writer.writeAll(try value.toStringSliceWithAlloc(page.call_arena));
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
}

test "normalizeBrowseUrl keeps explicit schemes" {
    const allocator = std.testing.allocator;

    const explicit = try normalizeBrowseUrl(allocator, "http://example.com");
    defer allocator.free(explicit.?);
    try std.testing.expectEqualStrings("http://example.com", explicit.?);

    const about = try normalizeBrowseUrl(allocator, "about:blank");
    defer allocator.free(about.?);
    try std.testing.expectEqualStrings("about:blank", about.?);
}

test "normalizeBrowseUrl defaults bare hosts to https" {
    const allocator = std.testing.allocator;

    const normalized = try normalizeBrowseUrl(allocator, "example.com/path?q=1");
    defer allocator.free(normalized.?);
    try std.testing.expectEqualStrings("https://example.com/path?q=1", normalized.?);
}

test "normalizeBrowseUrl keeps loopback targets on http" {
    const allocator = std.testing.allocator;

    const localhost = try normalizeBrowseUrl(allocator, "localhost:8123/status");
    defer allocator.free(localhost.?);
    try std.testing.expectEqualStrings("http://localhost:8123/status", localhost.?);

    const ipv4 = try normalizeBrowseUrl(allocator, "127.0.0.1:9222/json/version");
    defer allocator.free(ipv4.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9222/json/version", ipv4.?);

    const ipv6 = try normalizeBrowseUrl(allocator, "[::1]:8080/");
    defer allocator.free(ipv6.?);
    try std.testing.expectEqualStrings("http://[::1]:8080/", ipv6.?);
}

test "normalizeBrowseUrl rejects blank input" {
    try std.testing.expect((try normalizeBrowseUrl(std.testing.allocator, "   ")) == null);
}

test "normalizeBrowseUrl rejects search-like input without a scheme" {
    try std.testing.expectError(error.InvalidUrl, normalizeBrowseUrl(std.testing.allocator, "two words"));
}

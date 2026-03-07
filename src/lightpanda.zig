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
const Display = @import("display/Display.zig");
const BrowserCommand = @import("display/BrowserCommand.zig").BrowserCommand;
const DocumentPainter = @import("render/DocumentPainter.zig");
const HttpClient = @import("http/Client.zig");

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

const BrowseTab = struct {
    http_client: *HttpClient.Client,
    notification: *Notification,
    browser: Browser,
    session: *Session,
    committed_surface: CommittedBrowseSurface = .{},
    restore_committed_surface: bool = false,
    last_presented_hash: u64 = 0,
    zoom_percent: i32 = 100,

    fn deinit(self: *BrowseTab, allocator: std.mem.Allocator) void {
        self.committed_surface.deinit(allocator);
        self.browser.deinit();
        self.notification.deinit();
        self.http_client.deinit();
        allocator.destroy(self);
    }
};

const ClosedBrowseTab = struct {
    url: []u8,
    zoom_percent: i32,

    fn deinit(self: *ClosedBrowseTab, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.* = undefined;
    }
};

const SavedBrowseTab = struct {
    url: []u8,
    zoom_percent: i32,

    fn deinit(self: *SavedBrowseTab, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.* = undefined;
    }
};

const SavedBrowseSession = struct {
    tabs: std.ArrayListUnmanaged(SavedBrowseTab) = .{},
    active_index: usize = 0,

    fn deinit(self: *SavedBrowseSession, allocator: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.deinit(allocator);
        self.* = .{};
    }
};

const BROWSE_SESSION_FILE = "browse-session-v1.txt";
const MAX_CLOSED_BROWSE_TABS = 16;

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
    var tabs: std.ArrayListUnmanaged(*BrowseTab) = .{};
    defer deinitBrowseTabs(app.allocator, &tabs);
    var closed_tabs: std.ArrayListUnmanaged(ClosedBrowseTab) = .{};
    defer deinitClosedBrowseTabs(app.allocator, &closed_tabs);

    var active_tab_index: usize = try initializeBrowseTabs(app, &tabs, url);
    var displayed_tab_index: ?usize = null;
    var last_saved_session_hash: u64 = 0;
    try updateActiveBrowseDisplay(app, tabs.items, active_tab_index, &displayed_tab_index);
    persistBrowseSessionIfChanged(app, tabs.items, active_tab_index, &last_saved_session_hash);

    browse_loop: while (!app.shutdown and !app.display.userClosed()) {
        var handled_command = false;
        while (app.display.nextBrowserCommand()) |command| {
            defer command.deinit(app.allocator);
            handled_command = true;
            try handleBrowseCommand(app, &tabs, &closed_tabs, &active_tab_index, command);
            if (tabs.items.len == 0) {
                clearSavedBrowseSession(app);
                break :browse_loop;
            }
        }

        if (tabs.items.len == 0) {
            break;
        }

        active_tab_index = normalizeActiveTabIndex(active_tab_index, tabs.items.len);
        if (handled_command) {
            try updateActiveBrowseDisplay(app, tabs.items, active_tab_index, &displayed_tab_index);
        }

        for (tabs.items, 0..) |tab, index| {
            _ = if (index == active_tab_index)
                tab.session.wait(opts.wait_ms)
            else
                tab.session.waitNoInput(0);
        }

        if (tabs.items.len == 0) {
            break;
        }

        active_tab_index = normalizeActiveTabIndex(active_tab_index, tabs.items.len);
        try updateActiveBrowseDisplay(app, tabs.items, active_tab_index, &displayed_tab_index);
        persistBrowseSessionIfChanged(app, tabs.items, active_tab_index, &last_saved_session_hash);
    }
}

fn handleBrowseCommand(
    app: *App,
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab),
    active_tab_index: *usize,
    command: BrowserCommand,
) !void {
    switch (command) {
        .tab_new => {
            const tab = try createBrowseTab(app, null);
            try tabs.append(app.allocator, tab);
            active_tab_index.* = tabs.items.len - 1;
            tabs.items[active_tab_index.*].last_presented_hash = 0;
        },
        .tab_activate => |index| {
            if (index >= tabs.items.len) {
                return;
            }
            active_tab_index.* = index;
            tabs.items[index].last_presented_hash = 0;
        },
        .tab_next => {
            if (tabs.items.len <= 1) {
                return;
            }
            active_tab_index.* = (normalizeActiveTabIndex(active_tab_index.*, tabs.items.len) + 1) % tabs.items.len;
            tabs.items[active_tab_index.*].last_presented_hash = 0;
        },
        .tab_previous => {
            if (tabs.items.len <= 1) {
                return;
            }
            const current = normalizeActiveTabIndex(active_tab_index.*, tabs.items.len);
            active_tab_index.* = if (current == 0) tabs.items.len - 1 else current - 1;
            tabs.items[active_tab_index.*].last_presented_hash = 0;
        },
        .tab_close => |index| {
            if (index >= tabs.items.len) {
                return;
            }
            const removed = tabs.orderedRemove(index);
            try pushClosedBrowseTab(app.allocator, closed_tabs, removed);
            removed.deinit(app.allocator);
            if (tabs.items.len == 0) {
                return;
            }
            if (index < active_tab_index.*) {
                active_tab_index.* -= 1;
            } else if (active_tab_index.* >= tabs.items.len) {
                active_tab_index.* = tabs.items.len - 1;
            }
            tabs.items[active_tab_index.*].last_presented_hash = 0;
        },
        .tab_reopen_closed => {
            var closed = popClosedBrowseTab(closed_tabs) orelse return;
            defer closed.deinit(app.allocator);

            var reopened_url_z: ?[:0]u8 = null;
            defer if (reopened_url_z) |owned| app.allocator.free(owned);
            const initial_url = if (std.mem.eql(u8, closed.url, "about:blank"))
                null
            else blk: {
                reopened_url_z = try app.allocator.dupeZ(u8, closed.url);
                break :blk reopened_url_z.?;
            };
            const tab = try createBrowseTab(app, initial_url);
            tab.zoom_percent = closed.zoom_percent;
            try tabs.append(app.allocator, tab);
            active_tab_index.* = tabs.items.len - 1;
            tab.last_presented_hash = 0;
        },
        else => {
            if (tabs.items.len == 0) {
                return;
            }
            const active_index = normalizeActiveTabIndex(active_tab_index.*, tabs.items.len);
            const tab = tabs.items[active_index];
            const page = tab.session.currentPage() orelse return;
            try handleActiveBrowseCommand(app, tab, page, command);
        },
    }
}

fn handleActiveBrowseCommand(
    app: *App,
    tab: *BrowseTab,
    page: *Page,
    command: BrowserCommand,
) !void {
    const session = tab.session;
    switch (command) {
        .navigate => |raw_url| {
            tab.restore_committed_surface = false;
            const maybe_normalized_url = normalizeBrowseUrl(app.allocator, raw_url) catch {
                try app.display.presentDocument(
                    "Lightpanda Browser",
                    page.url,
                    "Invalid address. Enter a full URL, for example https://example.com",
                );
                tab.last_presented_hash = 0;
                return;
            };
            const normalized_url = maybe_normalized_url orelse {
                try app.display.presentDocument("Lightpanda Browser", page.url, "Enter a full URL, for example https://example.com");
                tab.last_presented_hash = 0;
                return;
            };
            defer app.allocator.free(normalized_url);

            try app.display.presentDocument("Lightpanda Browser", normalized_url, "Loading page...");
            tab.last_presented_hash = 0;

            try page.scheduleNavigation(normalized_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            }, .{ .script = null });
        },
        .back => {
            tab.restore_committed_surface = false;
            if (!session.navigation.getCanGoBack()) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.back(page);
        },
        .forward => {
            tab.restore_committed_surface = false;
            if (!session.navigation.getCanGoForward()) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.forward(page);
        },
        .reload => {
            tab.restore_committed_surface = false;
            if (page.url.len == 0) {
                return;
            }
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            try page.scheduleNavigation(page.url, .{
                .reason = .navigation,
                .force = true,
                .kind = .reload,
            }, .{ .script = null });
        },
        .history_traverse => |index| {
            tab.restore_committed_surface = false;
            const entries = session.navigation.entries();
            if (index >= entries.len) {
                return;
            }
            const url = entries[index].url() orelse return;
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.navigateInner(url, .{ .traverse = index }, page);
        },
        .stop => {
            tab.restore_committed_surface = tab.committed_surface.available();
            if (page._queued_navigation) |qn| {
                page.arena_pool.release(qn.arena);
                page._queued_navigation = null;
            }
            session.browser.http_client.abort();
            if (try session.restoreSuspendedPage()) |_| {
                tab.restore_committed_surface = false;
                tab.last_presented_hash = 0;
            } else if (tab.restore_committed_surface) {
                tab.last_presented_hash = 0;
            } else {
                tab.last_presented_hash = 0;
            }
        },
        .zoom_in, .zoom_out, .zoom_reset => {
            const next_zoom = applyZoomCommand(tab.zoom_percent, command);
            if (next_zoom == tab.zoom_percent) {
                return;
            }
            tab.zoom_percent = next_zoom;
            tab.restore_committed_surface = false;
            tab.last_presented_hash = 0;
            if (!pageIsLoading(page)) {
                try presentPage(app, page, &tab.last_presented_hash, &tab.committed_surface, tab.zoom_percent);
            }
        },
        else => {},
    }
}

fn applyZoomCommand(current_zoom: i32, command: BrowserCommand) i32 {
    return switch (command) {
        .zoom_in => std.math.clamp(current_zoom + 10, 30, 300),
        .zoom_out => std.math.clamp(current_zoom - 10, 30, 300),
        .zoom_reset => 100,
        else => current_zoom,
    };
}

fn pageIsLoading(page: *Page) bool {
    if (pageIsBlankIdle(page)) {
        return false;
    }
    return page._queued_navigation != null or page._parse_state != .complete;
}

fn pageIsBlankIdle(page: *Page) bool {
    return page._queued_navigation == null and
        std.mem.eql(u8, page.url, "about:blank") and
        page._parse_state == .pre and
        page._session.browser.http_client.active == 0;
}

fn syncBrowseDisplayState(
    app: *App,
    tabs: []const *BrowseTab,
    active_tab_index: usize,
    loading_override: ?bool,
) !void {
    const active_index = normalizeActiveTabIndex(active_tab_index, tabs.len);
    const active_tab = tabs[active_index];
    const page = active_tab.session.currentPage() orelse return;

    app.display.setNavigationState(
        active_tab.session.navigation.getCanGoBack(),
        active_tab.session.navigation.getCanGoForward(),
        loading_override orelse pageIsLoading(page),
        active_tab.zoom_percent,
    );

    const navigation_entries = active_tab.session.navigation.entries();
    var history_entries = try app.allocator.alloc([]const u8, navigation_entries.len);
    defer app.allocator.free(history_entries);
    for (navigation_entries, 0..) |entry, index| {
        history_entries[index] = entry.url() orelse "about:blank";
    }
    app.display.setHistoryEntries(history_entries, active_tab.session.navigation.getCurrentIndex());

    var tab_entries = try app.allocator.alloc(Display.TabEntry, tabs.len);
    defer app.allocator.free(tab_entries);
    for (tabs, 0..) |tab, index| {
        tab_entries[index] = try browseTabEntry(tab);
    }
    app.display.setTabEntries(tab_entries, active_index);
}

fn deinitBrowseTabs(allocator: std.mem.Allocator, tabs: *std.ArrayListUnmanaged(*BrowseTab)) void {
    while (tabs.items.len > 0) {
        tabs.items.len -= 1;
        tabs.items[tabs.items.len].deinit(allocator);
    }
    tabs.deinit(allocator);
}

fn deinitClosedBrowseTabs(allocator: std.mem.Allocator, closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab)) void {
    while (closed_tabs.items.len > 0) {
        closed_tabs.items.len -= 1;
        closed_tabs.items[closed_tabs.items.len].deinit(allocator);
    }
    closed_tabs.deinit(allocator);
}

fn popClosedBrowseTab(closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab)) ?ClosedBrowseTab {
    if (closed_tabs.items.len == 0) {
        return null;
    }
    return closed_tabs.pop();
}

fn pushClosedBrowseTab(
    allocator: std.mem.Allocator,
    closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab),
    tab: *BrowseTab,
) !void {
    const url = browseTabPersistentUrl(tab);
    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);

    if (closed_tabs.items.len == MAX_CLOSED_BROWSE_TABS) {
        var oldest = closed_tabs.orderedRemove(0);
        oldest.deinit(allocator);
    }
    try closed_tabs.append(allocator, .{
        .url = owned_url,
        .zoom_percent = tab.zoom_percent,
    });
}

fn initializeBrowseTabs(
    app: *App,
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    startup_url: [:0]const u8,
) !usize {
    var saved = loadSavedBrowseSession(app.allocator, app.app_dir_path);
    defer saved.deinit(app.allocator);

    if (saved.tabs.items.len == 0) {
        try tabs.append(app.allocator, try createBrowseTab(app, startup_url));
        return 0;
    }

    for (saved.tabs.items) |saved_tab| {
        var restored_url_z: ?[:0]u8 = null;
        defer if (restored_url_z) |owned| app.allocator.free(owned);
        const initial_url = if (std.mem.eql(u8, saved_tab.url, "about:blank"))
            null
        else blk: {
            restored_url_z = try app.allocator.dupeZ(u8, saved_tab.url);
            break :blk restored_url_z.?;
        };
        const tab = try createBrowseTab(app, initial_url);
        tab.zoom_percent = saved_tab.zoom_percent;
        try tabs.append(app.allocator, tab);
    }

    var active_index = normalizeActiveTabIndex(saved.active_index, tabs.items.len);
    if (shouldAppendStartupUrl(saved.tabs.items, startup_url)) {
        try tabs.append(app.allocator, try createBrowseTab(app, startup_url));
        active_index = tabs.items.len - 1;
    }

    return active_index;
}

fn loadSavedBrowseSession(allocator: std.mem.Allocator, app_dir_path: ?[]const u8) SavedBrowseSession {
    const dir_path = app_dir_path orelse return .{};
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return .{};
    defer dir.close();

    const file = dir.openFile(BROWSE_SESSION_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return .{},
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 64) catch return .{};
    defer allocator.free(data);

    return parseSavedBrowseSession(allocator, data) catch .{};
}

fn parseSavedBrowseSession(allocator: std.mem.Allocator, data: []const u8) !SavedBrowseSession {
    var session: SavedBrowseSession = .{};
    errdefer session.deinit(allocator);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n\t ");
        if (line.len == 0 or std.mem.eql(u8, line, "lightpanda-browse-session-v1")) {
            continue;
        }
        if (std.mem.startsWith(u8, line, "active\t")) {
            session.active_index = std.fmt.parseInt(usize, line["active\t".len..], 10) catch session.active_index;
            continue;
        }
        if (std.mem.startsWith(u8, line, "tab\t")) {
            const rest = line["tab\t".len..];
            const sep = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
            const zoom_percent = std.fmt.parseInt(i32, rest[0..sep], 10) catch 100;
            const url = std.mem.trim(u8, rest[sep + 1 ..], "\r\n\t ");
            if (url.len == 0) {
                continue;
            }
            try session.tabs.append(allocator, .{
                .url = try allocator.dupe(u8, url),
                .zoom_percent = std.math.clamp(zoom_percent, 30, 300),
            });
        }
    }

    return session;
}

fn shouldAppendStartupUrl(saved_tabs: []const SavedBrowseTab, startup_url: []const u8) bool {
    const trimmed_startup = std.mem.trim(u8, startup_url, &std.ascii.whitespace);
    if (trimmed_startup.len == 0) {
        return false;
    }
    for (saved_tabs) |saved_tab| {
        if (std.mem.eql(u8, saved_tab.url, trimmed_startup)) {
            return false;
        }
    }
    return true;
}

fn clearSavedBrowseSession(app: *App) void {
    const dir_path = app.app_dir_path orelse return;
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();
    dir.deleteFile(BROWSE_SESSION_FILE) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn(.app, "browse session delete failed", .{ .err = err }),
    };
}

fn persistBrowseSessionIfChanged(
    app: *App,
    tabs: []const *BrowseTab,
    active_tab_index: usize,
    last_saved_hash: *u64,
) void {
    const next_hash = hashBrowseSessionState(tabs, active_tab_index);
    if (next_hash == last_saved_hash.*) {
        return;
    }
    last_saved_hash.* = next_hash;

    if (tabs.len == 0) {
        clearSavedBrowseSession(app);
        return;
    }

    saveBrowseSession(app, tabs, active_tab_index) catch |err| {
        log.warn(.app, "browse session save failed", .{ .err = err });
    };
}

fn hashBrowseSessionState(tabs: []const *BrowseTab, active_tab_index: usize) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const normalized_active_index = normalizeActiveTabIndex(active_tab_index, tabs.len);
    hasher.update(std.mem.asBytes(&normalized_active_index));
    for (tabs) |tab| {
        hasher.update(browseTabPersistentUrl(tab));
        hasher.update(std.mem.asBytes(&tab.zoom_percent));
    }
    return hasher.final();
}

fn saveBrowseSession(app: *App, tabs: []const *BrowseTab, active_tab_index: usize) !void {
    const dir_path = app.app_dir_path orelse return;
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    var buf = std.Io.Writer.Allocating.init(app.allocator);
    defer buf.deinit();

    try buf.writer.writeAll("lightpanda-browse-session-v1\n");
    try buf.writer.print("active\t{d}\n", .{normalizeActiveTabIndex(active_tab_index, tabs.len)});
    for (tabs) |tab| {
        try buf.writer.print("tab\t{d}\t{s}\n", .{ tab.zoom_percent, browseTabPersistentUrl(tab) });
    }
    try dir.writeFile(.{
        .sub_path = BROWSE_SESSION_FILE,
        .data = buf.written(),
    });
}

fn createBrowseTab(app: *App, initial_url: ?[:0]const u8) !*BrowseTab {
    const tab = try app.allocator.create(BrowseTab);
    errdefer app.allocator.destroy(tab);

    tab.http_client = try app.http.createClient(app.allocator);
    errdefer tab.http_client.deinit();

    tab.notification = try Notification.init(app.allocator);
    errdefer tab.notification.deinit();

    tab.browser = try Browser.init(app, .{ .http_client = tab.http_client });
    errdefer tab.browser.deinit();

    tab.session = try tab.browser.newSession(tab.notification);
    const page = try tab.session.createPage();
    tab.committed_surface = .{};
    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.zoom_percent = 100;

    if (initial_url) |target_url| {
        const encoded_url = try URL.ensureEncoded(page.call_arena, target_url);
        _ = try page.navigate(encoded_url, .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        });
    }
    return tab;
}

fn normalizeActiveTabIndex(index: usize, tab_count: usize) usize {
    if (tab_count == 0) {
        return 0;
    }
    return @min(index, tab_count - 1);
}

fn updateActiveBrowseDisplay(
    app: *App,
    tabs: []const *BrowseTab,
    active_tab_index: usize,
    displayed_tab_index: *?usize,
) !void {
    if (tabs.len == 0) {
        displayed_tab_index.* = null;
        return;
    }

    const active_index = normalizeActiveTabIndex(active_tab_index, tabs.len);
    const active_tab = tabs[active_index];
    const page = active_tab.session.currentPage() orelse return;
    const show_committed_surface = active_tab.restore_committed_surface and
        active_tab.committed_surface.available() and
        pageIsLoading(page);

    try syncBrowseDisplayState(app, tabs, active_index, if (show_committed_surface) false else null);

    if (displayed_tab_index.* == null or displayed_tab_index.*.? != active_index) {
        active_tab.last_presented_hash = 0;
        displayed_tab_index.* = active_index;
    }

    if (show_committed_surface) {
        try restoreCommittedBrowseSurface(app, &active_tab.committed_surface, &active_tab.last_presented_hash);
        return;
    }

    if (!pageIsLoading(page)) {
        active_tab.restore_committed_surface = false;
    }
    try presentPage(
        app,
        page,
        &active_tab.last_presented_hash,
        &active_tab.committed_surface,
        active_tab.zoom_percent,
    );
}

fn trimmedOrNull(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

fn browseTabEntry(tab: *BrowseTab) !Display.TabEntry {
    const page = tab.session.currentPage() orelse {
        return .{
            .title = "Closed Tab",
            .url = "about:blank",
            .is_loading = false,
        };
    };

    if (pageIsBlankIdle(page)) {
        return .{
            .title = "New Tab",
            .url = "about:blank",
            .is_loading = false,
        };
    }

    const page_title = (try page.getTitle()) orelse "";
    const title = trimmedOrNull(page_title) orelse
        trimmedOrNull(tab.committed_surface.title) orelse
        trimmedOrNull(page.url) orelse
        trimmedOrNull(tab.committed_surface.url) orelse
        "New Tab";
    const url = trimmedOrNull(page.url) orelse
        trimmedOrNull(tab.committed_surface.url) orelse
        "about:blank";

    return .{
        .title = title,
        .url = url,
        .is_loading = pageIsLoading(page),
    };
}

fn browseTabPersistentUrl(tab: *BrowseTab) []const u8 {
    const page = tab.session.currentPage() orelse return "about:blank";
    if (trimmedOrNull(page.url)) |url| {
        return url;
    }
    if (trimmedOrNull(tab.committed_surface.url)) |url| {
        return url;
    }
    return "about:blank";
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
    zoom_percent: i32,
) !void {
    if (pageIsBlankIdle(page)) {
        const title = "New Tab";
        const url = "about:blank";
        const body = "Open a page with Ctrl+L or the address bar.";

        var blank_hasher = std.hash.Wyhash.init(0);
        blank_hasher.update(title);
        blank_hasher.update(url);
        blank_hasher.update(body);
        const blank_hash = blank_hasher.final();
        if (blank_hash != last_presented_hash.*) {
            last_presented_hash.* = blank_hash;
            try app.display.presentDocument(title, url, body);
        }
        return;
    }

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
        .layout_scale = zoom_percent,
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

test "applyZoomCommand clamps and resets zoom" {
    try std.testing.expectEqual(@as(i32, 110), applyZoomCommand(100, .zoom_in));
    try std.testing.expectEqual(@as(i32, 90), applyZoomCommand(100, .zoom_out));
    try std.testing.expectEqual(@as(i32, 100), applyZoomCommand(180, .zoom_reset));
    try std.testing.expectEqual(@as(i32, 300), applyZoomCommand(300, .zoom_in));
    try std.testing.expectEqual(@as(i32, 30), applyZoomCommand(30, .zoom_out));
}

test "parseSavedBrowseSession restores active index and zoom" {
    var session = try parseSavedBrowseSession(
        std.testing.allocator,
        "lightpanda-browse-session-v1\nactive\t1\ntab\t125\thttp://one.test/\ntab\t90\thttp://two.test/\n",
    );
    defer session.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), session.active_index);
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqualStrings("http://one.test/", session.tabs.items[0].url);
    try std.testing.expectEqual(@as(i32, 125), session.tabs.items[0].zoom_percent);
    try std.testing.expectEqualStrings("http://two.test/", session.tabs.items[1].url);
    try std.testing.expectEqual(@as(i32, 90), session.tabs.items[1].zoom_percent);
}

test "shouldAppendStartupUrl skips restored duplicates" {
    var saved = SavedBrowseSession{};
    defer saved.deinit(std.testing.allocator);

    try saved.tabs.append(std.testing.allocator, .{
        .url = try std.testing.allocator.dupe(u8, "http://one.test/"),
        .zoom_percent = 100,
    });
    try saved.tabs.append(std.testing.allocator, .{
        .url = try std.testing.allocator.dupe(u8, "http://two.test/"),
        .zoom_percent = 110,
    });

    try std.testing.expect(!shouldAppendStartupUrl(saved.tabs.items, "http://two.test/"));
    try std.testing.expect(shouldAppendStartupUrl(saved.tabs.items, "http://three.test/"));
}

test "normalizeBrowseUrl rejects blank input" {
    try std.testing.expect((try normalizeBrowseUrl(std.testing.allocator, "   ")) == null);
}

test "normalizeBrowseUrl rejects search-like input without a scheme" {
    try std.testing.expectError(error.InvalidUrl, normalizeBrowseUrl(std.testing.allocator, "two words"));
}

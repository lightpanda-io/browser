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
const PopupSource = @import("browser/PopupSource.zig").PopupSource;

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
const testing = @import("testing.zig");

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

const BrowseErrorKind = enum {
    invalid_address,
    navigation_failed,
};

const BrowseErrorState = struct {
    kind: BrowseErrorKind = .navigation_failed,
    retry_value: []u8 = &.{},
    display_value: []u8 = &.{},
    detail: []u8 = &.{},

    fn deinit(self: *BrowseErrorState, allocator: std.mem.Allocator) void {
        allocator.free(self.retry_value);
        allocator.free(self.display_value);
        allocator.free(self.detail);
        self.* = .{};
    }

    fn hasValue(self: *const BrowseErrorState) bool {
        return self.retry_value.len > 0 or self.display_value.len > 0 or self.detail.len > 0;
    }

    fn replace(
        self: *BrowseErrorState,
        allocator: std.mem.Allocator,
        kind: BrowseErrorKind,
        retry_value: []const u8,
        display_value: []const u8,
        detail: []const u8,
    ) !void {
        const owned_retry = try allocator.dupe(u8, retry_value);
        errdefer allocator.free(owned_retry);
        const owned_display = try allocator.dupe(u8, display_value);
        errdefer allocator.free(owned_display);
        const owned_detail = try allocator.dupe(u8, detail);
        errdefer allocator.free(owned_detail);

        self.deinit(allocator);
        self.* = .{
            .kind = kind,
            .retry_value = owned_retry,
            .display_value = owned_display,
            .detail = owned_detail,
        };
    }

    fn clear(self: *BrowseErrorState, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }
};

const BrowseTab = struct {
    http_client: *HttpClient.Client,
    notification: *Notification,
    browser: Browser,
    session: *Session,
    target_name: []u8 = &.{},
    popup_source: PopupSource = .none,
    committed_surface: CommittedBrowseSurface = .{},
    error_state: BrowseErrorState = .{},
    restore_committed_surface: bool = false,
    last_presented_hash: u64 = 0,
    last_internal_page_state_hash: u64 = 0,
    zoom_percent: i32 = 100,

    fn deinit(self: *BrowseTab, allocator: std.mem.Allocator) void {
        freeOwnedBrowseTabTargetName(allocator, self.target_name);
        self.committed_surface.deinit(allocator);
        self.error_state.deinit(allocator);
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

const ClosedBrowseTabDisplayEntry = struct {
    ui_index: usize,
    url: []const u8,
    zoom_percent: i32,
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

const BrowseSettings = struct {
    restore_previous_session: bool = true,
    allow_script_popups: bool = true,
    default_zoom_percent: i32 = 100,
    homepage_url: []u8 = &.{},

    fn deinit(self: *BrowseSettings, allocator: std.mem.Allocator) void {
        allocator.free(self.homepage_url);
        self.* = .{};
    }

    fn homeUrl(self: *const BrowseSettings) ?[]const u8 {
        return trimmedOrNull(self.homepage_url);
    }
};

const BROWSE_SESSION_FILE = "browse-session-v1.txt";
const BROWSE_SETTINGS_FILE = "browse-settings-v1.txt";
const BROWSE_DOWNLOADS_FILE = "downloads-v1.txt";
const BROWSE_BOOKMARKS_FILE = "bookmarks.txt";
const BROWSE_DOWNLOADS_DIR = "downloads";
const MAX_CLOSED_BROWSE_TABS = 16;
const MAX_DOWNLOADS_HISTORY = 64;

const InternalBrowsePage = enum {
    start,
    error_page,
    tabs,
    history,
    bookmarks,
    downloads,
    settings,
};

const InternalBrowseRoute = union(enum) {
    page: InternalBrowsePage,
    command: BrowserCommand,
};

const BrowseShell = struct {
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab),
    active_tab_index: *usize,
};

const BrowseDownloadStatus = enum(u8) {
    queued,
    downloading,
    completed,
    failed,
    interrupted,
};

const BrowseDownloadEntry = struct {
    filename: []u8,
    path: []u8,
    url: []u8,
    detail: []u8 = &.{},
    bytes_received: usize = 0,
    total_bytes: usize = 0,
    has_total_bytes: bool = false,
    status: BrowseDownloadStatus = .queued,

    fn deinit(self: *BrowseDownloadEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.path);
        allocator.free(self.url);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

const BrowseDownloads = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(BrowseDownloadEntry) = .{},
    active: std.ArrayListUnmanaged(*ActiveBrowseDownload) = .{},
    last_saved_hash: u64 = 0,

    fn init(allocator: std.mem.Allocator, app_dir_path: ?[]const u8) BrowseDownloads {
        var downloads: BrowseDownloads = .{ .allocator = allocator };
        downloads.loadFromDisk(app_dir_path);
        return downloads;
    }

    fn deinit(self: *BrowseDownloads, app_dir_path: ?[]const u8) void {
        for (self.active.items) |download| {
            download.cancel(.interrupted, "Browser shutting down");
        }
        while (self.active.items.len > 0) {
            const download = self.active.items[self.active.items.len - 1];
            self.active.items.len -= 1;
            download.deinit();
        }
        self.active.deinit(self.allocator);

        self.persistIfChanged(app_dir_path);
        while (self.entries.items.len > 0) {
            var entry = self.entries.items[self.entries.items.len - 1];
            self.entries.items.len -= 1;
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    fn setDetail(entry: *BrowseDownloadEntry, allocator: std.mem.Allocator, detail: []const u8) void {
        allocator.free(entry.detail);
        entry.detail = allocator.dupe(u8, detail) catch &.{};
    }

    fn removeEntry(self: *BrowseDownloads, app_dir_path: ?[]const u8, index: usize) bool {
        if (index >= self.entries.items.len) {
            return false;
        }
        for (self.active.items) |download| {
            if (download.entry_index == index) {
                return false;
            }
        }
        var removed = self.entries.orderedRemove(index);
        if (removed.path.len > 0) {
            std.fs.deleteFileAbsolute(removed.path) catch {};
        }
        removed.deinit(self.allocator);
        for (self.active.items) |download| {
            if (download.entry_index > index) {
                download.entry_index -= 1;
            }
        }
        self.persistIfChanged(app_dir_path);
        return true;
    }

    fn clearInactiveEntries(self: *BrowseDownloads, app_dir_path: ?[]const u8) bool {
        var removed_any = false;
        var index: usize = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            if (downloadEntryActive(self, index)) {
                continue;
            }
            var removed = self.entries.orderedRemove(index);
            if (removed.path.len > 0) {
                std.fs.deleteFileAbsolute(removed.path) catch {};
            }
            removed.deinit(self.allocator);
            for (self.active.items) |download| {
                if (download.entry_index > index) {
                    download.entry_index -= 1;
                }
            }
            removed_any = true;
        }
        if (removed_any) {
            self.persistIfChanged(app_dir_path);
        }
        return removed_any;
    }

    fn cancelDownloadsForTab(self: *BrowseDownloads, tab: *BrowseTab, app_dir_path: ?[]const u8) void {
        for (self.active.items) |download| {
            if (download.source_tab == tab) {
                download.cancel(.interrupted, "Tab closed");
            }
        }
        self.persistIfChanged(app_dir_path);
    }

    fn processPendingRequests(self: *BrowseDownloads, app: *App, tab: *BrowseTab) !void {
        var pending = tab.session.takePendingDownloads();
        defer {
            while (pending.items.len > 0) {
                var request = pending.items[pending.items.len - 1];
                pending.items.len -= 1;
                request.deinit(app.allocator);
            }
            pending.deinit(app.allocator);
        }

        for (pending.items) |request| {
            try self.startDownload(app, tab, request);
        }
    }

    fn startDownloadFromValues(
        self: *BrowseDownloads,
        app: *App,
        tab: *BrowseTab,
        url: []const u8,
        suggested_filename: []const u8,
    ) !void {
        var request = Session.PendingDownload{
            .url = try app.allocator.dupe(u8, url),
            .suggested_filename = try app.allocator.dupe(u8, suggested_filename),
        };
        defer request.deinit(app.allocator);
        try self.startDownload(app, tab, request);
    }

    fn tick(self: *BrowseDownloads, timeout_ms: u32) void {
        for (self.active.items) |download| {
            if (download.finished) {
                continue;
            }
            _ = download.http_client.tick(timeout_ms) catch |err| {
                download.fail("Download tick failed", err);
            };
        }

        var i: usize = 0;
        while (i < self.active.items.len) {
            const download = self.active.items[i];
            if (!download.finished) {
                i += 1;
                continue;
            }
            _ = self.active.orderedRemove(i);
            download.deinit();
        }
    }

    fn trimHistory(self: *BrowseDownloads) void {
        while (self.entries.items.len > MAX_DOWNLOADS_HISTORY) {
            var removed = self.entries.orderedRemove(0);
            removed.deinit(self.allocator);
            for (self.active.items) |download| {
                if (download.entry_index > 0) {
                    download.entry_index -= 1;
                }
            }
        }
    }

    fn startDownload(self: *BrowseDownloads, app: *App, tab: *BrowseTab, request: Session.PendingDownload) !void {
        const page = tab.session.currentPage() orelse return;
        const app_dir_path = app.app_dir_path orelse return;
        const downloads_dir = try ensureBrowseDownloadsDir(app.allocator, app_dir_path);
        defer app.allocator.free(downloads_dir);

        const derived_name = try deriveDownloadFileName(
            app.allocator,
            request.url,
            request.suggested_filename,
        );
        defer app.allocator.free(derived_name);

        const final_name = try makeUniqueDownloadFileName(app.allocator, downloads_dir, derived_name);
        errdefer app.allocator.free(final_name);

        const file_path = try std.fs.path.join(app.allocator, &.{ downloads_dir, final_name });
        errdefer app.allocator.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        errdefer {
            file.close();
            std.fs.deleteFileAbsolute(file_path) catch {};
        }

        const entry_index = self.entries.items.len;
        try self.entries.append(app.allocator, .{
            .filename = try app.allocator.dupe(u8, final_name),
            .path = try app.allocator.dupe(u8, file_path),
            .url = try app.allocator.dupe(u8, request.url),
            .status = .queued,
        });
        errdefer {
            var removed = self.entries.pop().?;
            removed.deinit(app.allocator);
        }

        var download = try app.allocator.create(ActiveBrowseDownload);
        errdefer app.allocator.destroy(download);
        download.* = try ActiveBrowseDownload.init(app, self, tab, entry_index, file);
        errdefer download.deinit();

        try download.start(page, request.url);
        try self.active.append(app.allocator, download);
        self.trimHistory();
        self.persistIfChanged(app.app_dir_path);
    }

    fn toDisplayEntries(self: *BrowseDownloads, allocator: std.mem.Allocator) ![]Display.DownloadEntry {
        var entries = try allocator.alloc(Display.DownloadEntry, self.entries.items.len);
        errdefer allocator.free(entries);

        for (self.entries.items, 0..) |entry, index| {
            entries[index] = .{
                .filename = entry.filename,
                .path = entry.path,
                .status = try formatDownloadStatusLabel(allocator, entry),
                .removable = !downloadEntryActive(self, index),
            };
        }
        return entries;
    }

    fn loadFromDisk(self: *BrowseDownloads, app_dir_path: ?[]const u8) void {
        const dir_path = app_dir_path orelse return;
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
        defer dir.close();

        const file = dir.openFile(BROWSE_DOWNLOADS_FILE, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return,
        };
        if (file == null) {
            return;
        }
        defer file.?.close();

        const data = file.?.readToEndAlloc(self.allocator, 1024 * 128) catch return;
        defer self.allocator.free(data);

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r\n");
            if (line.len == 0) {
                continue;
            }
            const entry = parseSavedDownloadEntry(self.allocator, line) catch continue;
            self.entries.append(self.allocator, entry) catch {
                var owned = entry;
                owned.deinit(self.allocator);
                break;
            };
        }
        self.last_saved_hash = hashSavedDownloads(self.entries.items);
    }

    fn persistIfChanged(self: *BrowseDownloads, app_dir_path: ?[]const u8) void {
        const hash = hashSavedDownloads(self.entries.items);
        if (hash == self.last_saved_hash) {
            return;
        }
        saveBrowseDownloads(self.allocator, app_dir_path, self.entries.items);
        self.last_saved_hash = hash;
    }
};

const ActiveBrowseDownload = struct {
    allocator: std.mem.Allocator,
    manager: *BrowseDownloads,
    source_tab: *BrowseTab,
    http_client: *HttpClient.Client,
    file: ?std.fs.File,
    arena: std.heap.ArenaAllocator,
    entry_index: usize,
    finished: bool = false,

    fn init(
        app: *App,
        manager: *BrowseDownloads,
        source_tab: *BrowseTab,
        entry_index: usize,
        file: std.fs.File,
    ) !ActiveBrowseDownload {
        return .{
            .allocator = app.allocator,
            .manager = manager,
            .source_tab = source_tab,
            .http_client = try app.http.createClient(app.allocator),
            .file = file,
            .arena = std.heap.ArenaAllocator.init(app.allocator),
            .entry_index = entry_index,
        };
    }

    fn deinit(self: *ActiveBrowseDownload) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
        self.http_client.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *ActiveBrowseDownload, page: *Page, request_url: []const u8) !void {
        const arena = self.arena.allocator();
        const url_z = try arena.dupeZ(u8, request_url);
        var headers = try self.http_client.newHeaders();
        try page.headersForRequest(arena, url_z, &headers);

        self.manager.entries.items[self.entry_index].status = .downloading;
        self.manager.persistIfChanged(page._session.browser.app.app_dir_path);

        try self.http_client.request(.{
            .ctx = self,
            .frame_id = page._frame_id,
            .url = url_z,
            .method = .GET,
            .headers = headers,
            .cookie_jar = &page._session.cookie_jar,
            .resource_type = .fetch,
            .notification = self.source_tab.notification,
            .header_callback = browseDownloadHeaderCallback,
            .data_callback = browseDownloadDataCallback,
            .done_callback = browseDownloadDoneCallback,
            .error_callback = browseDownloadErrorCallback,
            .shutdown_callback = browseDownloadShutdownCallback,
        });
    }

    fn fail(self: *ActiveBrowseDownload, detail: []const u8, err: anyerror) void {
        var entry = &self.manager.entries.items[self.entry_index];
        entry.status = .failed;
        const message = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ detail, @errorName(err) }) catch detail;
        defer if (message.ptr != detail.ptr) self.allocator.free(message);
        BrowseDownloads.setDetail(entry, self.allocator, message);
        self.cleanupPartialFile();
        self.finished = true;
    }

    fn cancel(self: *ActiveBrowseDownload, status: BrowseDownloadStatus, detail: []const u8) void {
        if (self.finished) {
            return;
        }
        var entry = &self.manager.entries.items[self.entry_index];
        entry.status = status;
        BrowseDownloads.setDetail(entry, self.allocator, detail);
        self.finished = true;
        self.cleanupPartialFile();
        self.http_client.abort();
    }

    fn cleanupPartialFile(self: *ActiveBrowseDownload) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
        const path = self.manager.entries.items[self.entry_index].path;
        if (path.len > 0) {
            std.fs.deleteFileAbsolute(path) catch {};
        }
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
    var tabs: std.ArrayListUnmanaged(*BrowseTab) = .{};
    defer deinitBrowseTabs(app.allocator, &tabs);
    var closed_tabs: std.ArrayListUnmanaged(ClosedBrowseTab) = .{};
    defer deinitClosedBrowseTabs(app.allocator, &closed_tabs);
    var settings = loadBrowseSettings(app.allocator, app.app_dir_path);
    defer settings.deinit(app.allocator);
    var downloads = BrowseDownloads.init(app.allocator, app.app_dir_path);
    defer downloads.deinit(app.app_dir_path);

    var active_tab_index: usize = try initializeBrowseTabs(app, &tabs, url, &settings);
    var displayed_tab_index: ?usize = null;
    var last_saved_session_hash: u64 = 0;
    var last_saved_settings_hash: u64 = 0;
    var shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_tab_index,
    };
    for (tabs.items, 0..) |tab, index| {
        const page = tab.session.currentPage() orelse continue;
        const internal_page = parseInternalBrowsePage(page.url) orelse continue;
        try openInternalBrowsePage(app, &shell, index, page, &settings, &downloads, internal_page);
    }
    try updateActiveBrowseDisplay(app, tabs.items, &settings, &downloads, active_tab_index, &displayed_tab_index);
    persistBrowseSessionIfChanged(app, tabs.items, active_tab_index, settings.restore_previous_session, &last_saved_session_hash);
    persistBrowseSettingsIfChanged(app, &settings, &last_saved_settings_hash);

    browse_loop: while (!app.shutdown and !app.display.userClosed()) {
        var handled_command = false;
        while (app.display.nextBrowserCommand()) |command| {
            defer command.deinit(app.allocator);
            handled_command = true;
            try handleBrowseCommand(app, &shell, normalizeActiveTabIndex(active_tab_index, tabs.items.len), &settings, &downloads, command);
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
            try updateActiveBrowseDisplay(app, tabs.items, &settings, &downloads, active_tab_index, &displayed_tab_index);
        }

        for (tabs.items, 0..) |tab, index| {
            _ = if (index == active_tab_index)
                tab.session.wait(opts.wait_ms)
            else
                tab.session.waitNoInput(opts.wait_ms);
            _ = try captureBrowseTabRuntimeError(app.allocator, tab);
            try downloads.processPendingRequests(app, tab);
        }
        var pending_nav_index: usize = 0;
        while (pending_nav_index < tabs.items.len) : (pending_nav_index += 1) {
            try processPendingBrowserNavigations(app, &shell, pending_nav_index, &settings, &downloads);
        }
        const settled_tab_count = tabs.items.len;
        var tab_index: usize = 0;
        while (tab_index < settled_tab_count) : (tab_index += 1) {
            try processPendingTabOpens(app, &tabs, &settings, &active_tab_index, tab_index);
        }
        const opened_pending_tab = tabs.items.len != settled_tab_count;
        downloads.tick(0);

        if (tabs.items.len == 0) {
            break;
        }

        active_tab_index = normalizeActiveTabIndex(active_tab_index, tabs.items.len);
        if (tabs.items[active_tab_index].session.currentPage()) |active_page| {
            const active_internal_page = parseInternalBrowsePage(active_page.url);
            if (pageHasRuntimeError(active_page) and (active_internal_page == null or active_internal_page.? != .error_page)) {
                try openInternalErrorPageForTab(app, tabs.items[active_tab_index], active_page, &settings);
            }
        }
        if (tabs.items[active_tab_index].session.currentPage()) |active_page| {
            try refreshCurrentInternalBrowsePage(app, &shell, active_tab_index, active_page, &settings, &downloads, false);
        }
        if (opened_pending_tab) {
            try updateActiveBrowseDisplay(app, tabs.items, &settings, &downloads, active_tab_index, &displayed_tab_index);
            persistBrowseSessionIfChanged(app, tabs.items, active_tab_index, settings.restore_previous_session, &last_saved_session_hash);
            persistBrowseSettingsIfChanged(app, &settings, &last_saved_settings_hash);
            downloads.persistIfChanged(app.app_dir_path);
            continue;
        }
        try updateActiveBrowseDisplay(app, tabs.items, &settings, &downloads, active_tab_index, &displayed_tab_index);
        persistBrowseSessionIfChanged(app, tabs.items, active_tab_index, settings.restore_previous_session, &last_saved_session_hash);
        persistBrowseSettingsIfChanged(app, &settings, &last_saved_settings_hash);
        downloads.persistIfChanged(app.app_dir_path);
    }
}

fn handleBrowseCommand(
    app: *App,
    shell: *BrowseShell,
    source_tab_index: usize,
    settings: *BrowseSettings,
    downloads: *BrowseDownloads,
    command: BrowserCommand,
) anyerror!void {
    defer applyBrowsePopupPolicyToTabs(shell.tabs.items, settings.allow_script_popups);
    switch (command) {
        .tab_new => {
            const tab = try createBrowseTab(app, null, settings.default_zoom_percent, settings.allow_script_popups);
            try appendBrowseTab(app.allocator, shell.tabs, tab, shell.active_tab_index, true);
        },
        .tab_duplicate => {
            const source_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            const source_tab = shell.tabs.items[source_index];
            const source_url = browseTabPersistentUrl(source_tab);
            const tab = try createBrowseTab(app, null, source_tab.zoom_percent, settings.allow_script_popups);
            tab.zoom_percent = source_tab.zoom_percent;
            try appendBrowseTab(app.allocator, shell.tabs, tab, shell.active_tab_index, true);
            try navigateBrowseTabToOwnedUrl(tab, source_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            });
        },
        .tab_duplicate_index => |index| {
            if (index >= shell.tabs.items.len) {
                return;
            }
            const source_tab = shell.tabs.items[index];
            const source_url = browseTabPersistentUrl(source_tab);
            const tab = try createBrowseTab(app, null, source_tab.zoom_percent, settings.allow_script_popups);
            tab.zoom_percent = source_tab.zoom_percent;
            try appendBrowseTab(app.allocator, shell.tabs, tab, shell.active_tab_index, true);
            try navigateBrowseTabToOwnedUrl(tab, source_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            });
        },
        .tab_activate => |index| {
            if (index >= shell.tabs.items.len) {
                return;
            }
            shell.active_tab_index.* = index;
            shell.tabs.items[index].last_presented_hash = 0;
        },
        .tab_next => {
            if (shell.tabs.items.len <= 1) {
                return;
            }
            shell.active_tab_index.* = (normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len) + 1) % shell.tabs.items.len;
            shell.tabs.items[shell.active_tab_index.*].last_presented_hash = 0;
        },
        .tab_previous => {
            if (shell.tabs.items.len <= 1) {
                return;
            }
            const current = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            shell.active_tab_index.* = if (current == 0) shell.tabs.items.len - 1 else current - 1;
            shell.tabs.items[shell.active_tab_index.*].last_presented_hash = 0;
        },
        .tab_close => |index| {
            if (index >= shell.tabs.items.len) {
                return;
            }
            const removed = shell.tabs.orderedRemove(index);
            downloads.cancelDownloadsForTab(removed, app.app_dir_path);
            try pushClosedBrowseTab(app.allocator, shell.closed_tabs, removed);
            removed.deinit(app.allocator);
            if (shell.tabs.items.len == 0) {
                return;
            }
            if (index < shell.active_tab_index.*) {
                shell.active_tab_index.* -= 1;
            } else if (shell.active_tab_index.* >= shell.tabs.items.len) {
                shell.active_tab_index.* = shell.tabs.items.len - 1;
            }
            shell.tabs.items[shell.active_tab_index.*].last_presented_hash = 0;
        },
        .tab_reload_index => |index| {
            if (index >= shell.tabs.items.len) {
                return;
            }
            if (index == shell.active_tab_index.*) {
                try handleActiveBrowseCommand(app, shell, index, settings, downloads, .reload);
                return;
            }
            shell.active_tab_index.* = index;
            shell.tabs.items[index].last_presented_hash = 0;
            try handleActiveBrowseCommand(app, shell, index, settings, downloads, .reload);
        },
        .tab_reopen_closed => {
            var closed = popClosedBrowseTab(shell.closed_tabs) orelse return;
            defer closed.deinit(app.allocator);
            const tab = try createBrowseTab(app, null, settings.default_zoom_percent, settings.allow_script_popups);
            tab.zoom_percent = closed.zoom_percent;
            try appendBrowseTab(app.allocator, shell.tabs, tab, shell.active_tab_index, true);
            try navigateBrowseTabToOwnedUrl(tab, closed.url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            });
        },
        .tab_reopen_closed_index => |index| {
            var closed = popClosedBrowseTabAtUiIndex(shell.closed_tabs, index) orelse return;
            defer closed.deinit(app.allocator);
            const tab = try createBrowseTab(app, null, settings.default_zoom_percent, settings.allow_script_popups);
            tab.zoom_percent = closed.zoom_percent;
            try appendBrowseTab(app.allocator, shell.tabs, tab, shell.active_tab_index, true);
            try navigateBrowseTabToOwnedUrl(tab, closed.url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            });
        },
        .download_remove => |index| {
            _ = downloads.removeEntry(app.app_dir_path, index);
        },
        .bookmark_remove => |index| {
            _ = removePersistedBookmarkAtIndex(app.allocator, app.app_dir_path, index);
        },
        .download => |download| {
            if (shell.tabs.items.len == 0) {
                return;
            }
            const active_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            try downloads.startDownloadFromValues(app, shell.tabs.items[active_index], download.url, download.suggested_filename);
        },
        .activate_link_region => |activation| {
            if (shell.tabs.items.len == 0) {
                return;
            }
            const active_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            const tab = shell.tabs.items[active_index];
            const page = tab.session.currentPage() orelse return;
            if (try handleRenderedLinkActivation(tab, page, activation)) {
                tab.last_presented_hash = 0;
                return;
            }

            if (activation.suggested_filename.len > 0) {
                try downloads.startDownloadFromValues(app, tab, activation.url, activation.suggested_filename);
                tab.last_presented_hash = 0;
                return;
            }
            if (activation.target_name.len > 0) {
                try openOrReuseTargetedBrowseTab(app, shell.tabs, shell.active_tab_index, settings.allow_script_popups, tab.zoom_percent, activation.url, .{
                    .reason = .address_bar,
                    .kind = .{ .push = null },
                }, activation.target_name, true, .anchor);
                return;
            }
            if (activation.open_in_new_tab) {
                try openOrReuseTargetedBrowseTab(app, shell.tabs, shell.active_tab_index, settings.allow_script_popups, tab.zoom_percent, activation.url, .{
                    .reason = .address_bar,
                    .kind = .{ .push = null },
                }, "_blank", true, .anchor);
                return;
            }
            try handleActiveBrowseCommand(app, shell, active_index, settings, downloads, .{
                .navigate = activation.url,
            });
        },
        .navigate_new_tab => |raw_url| {
            const active_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            const source_tab = shell.tabs.items[active_index];
            try openOrReuseTargetedBrowseTab(app, shell.tabs, shell.active_tab_index, settings.allow_script_popups, source_tab.zoom_percent, raw_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            }, "_blank", true, .none);
        },
        .navigate_target_tab => |target| {
            const active_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
            const source_tab = shell.tabs.items[active_index];
            try openOrReuseTargetedBrowseTab(app, shell.tabs, shell.active_tab_index, settings.allow_script_popups, source_tab.zoom_percent, target.url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            }, target.target_name, true, .none);
        },
        else => {
            if (shell.tabs.items.len == 0) {
                return;
            }
            if (source_tab_index >= shell.tabs.items.len) {
                return;
            }
            try handleActiveBrowseCommand(app, shell, source_tab_index, settings, downloads, command);
        },
    }
}

fn handleActiveBrowseCommand(
    app: *App,
    shell: *BrowseShell,
    tab_index: usize,
    settings: *BrowseSettings,
    downloads: *BrowseDownloads,
    command: BrowserCommand,
) anyerror!void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    const page = tab.session.currentPage() orelse return;
    const session = tab.session;
    switch (command) {
        .navigate => |raw_url| {
            tab.restore_committed_surface = false;
            const maybe_normalized_url = normalizeBrowseUrl(app.allocator, raw_url) catch {
                try setBrowseTabErrorState(
                    app.allocator,
                    tab,
                    .invalid_address,
                    raw_url,
                    raw_url,
                    "Enter a full URL, for example https://example.com",
                );
                try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .error_page);
                return;
            };
            const normalized_url = maybe_normalized_url orelse {
                try setBrowseTabErrorState(
                    app.allocator,
                    tab,
                    .invalid_address,
                    raw_url,
                    raw_url,
                    "Enter a full URL, for example https://example.com",
                );
                try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .error_page);
                return;
            };
            defer app.allocator.free(normalized_url);

            if (parseInternalBrowseRoute(normalized_url)) |route| {
                switch (route) {
                    .page => |internal_page| try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, internal_page),
                    .command => |internal_command| {
                        const current_internal_page = parseInternalBrowsePage(page.url);
                        const command_host_page = internalBrowseCommandHostPage(internal_command);
                        if (internalBrowseCommandUsesBrowseLoopHandler(internal_command)) {
                            try handleBrowseCommand(app, shell, tab_index, settings, downloads, internal_command);
                        } else {
                            var route_scope: js.Local.Scope = undefined;
                            const owns_route_scope = page.js.local == null;
                            if (owns_route_scope) {
                                page.js.localScope(&route_scope);
                            }
                            defer if (owns_route_scope) route_scope.deinit();
                            try handleActiveBrowseCommand(app, shell, tab_index, settings, downloads, internal_command);
                            if (internalBrowseCommandKeepsCurrentPage(internal_command)) {
                                if (command_host_page) |host_page| {
                                    if (current_internal_page != null and current_internal_page.? == host_page) {
                                        try refreshCurrentInternalBrowsePage(app, shell, tab_index, page, settings, downloads, true);
                                    } else {
                                        try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, host_page);
                                    }
                                } else if (current_internal_page != null) {
                                    try refreshCurrentInternalBrowsePage(app, shell, tab_index, page, settings, downloads, true);
                                }
                            }
                        }
                    },
                }
                return;
            }

            clearBrowseTabErrorState(app.allocator, tab);
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
            clearBrowseTabErrorState(app.allocator, tab);
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.back(page);
        },
        .forward => {
            tab.restore_committed_surface = false;
            if (!session.navigation.getCanGoForward()) {
                return;
            }
            clearBrowseTabErrorState(app.allocator, tab);
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.forward(page);
        },
        .reload => {
            tab.restore_committed_surface = false;
            if (page.url.len == 0) {
                return;
            }
            if (parseInternalBrowsePage(page.url)) |internal_page| {
                if (internal_page == .error_page) {
                    try handleActiveBrowseCommand(app, shell, tab_index, settings, downloads, .error_retry);
                    return;
                }
                try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, internal_page);
                return;
            }
            clearBrowseTabErrorState(app.allocator, tab);
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
            clearBrowseTabErrorState(app.allocator, tab);
            try app.display.presentDocument("Lightpanda Browser", page.url, "Loading page...");
            tab.last_presented_hash = 0;
            _ = try session.navigation.navigateInner(url, .{ .traverse = index }, page);
        },
        .history_clear_session => {
            _ = clearBrowseHistoryToCurrent(tab);
        },
        .bookmark_add_current => {
            const bookmark_url = browseTabHomepageCandidateUrl(tab) orelse return;
            _ = addPersistedBookmark(app.allocator, app.app_dir_path, bookmark_url);
        },
        .bookmark_open => |index| {
            const bookmark_url = loadPersistedBookmarkAtIndex(app.allocator, app.app_dir_path, index) orelse return;
            defer app.allocator.free(bookmark_url);
            try handleActiveBrowseCommand(app, shell, tab_index, settings, downloads, .{
                .navigate = bookmark_url,
            });
        },
        .bookmark_remove => |index| {
            _ = removePersistedBookmarkAtIndex(app.allocator, app.app_dir_path, index);
        },
        .download_source => |index| {
            const download_url = loadDownloadUrlAtIndex(app.allocator, downloads, index) orelse return;
            defer app.allocator.free(download_url);
            try handleActiveBrowseCommand(app, shell, tab_index, settings, downloads, .{
                .navigate = download_url,
            });
        },
        .download_remove => |index| {
            _ = downloads.removeEntry(app.app_dir_path, index);
        },
        .download_clear => {
            _ = downloads.clearInactiveEntries(app.app_dir_path);
        },
        .home => {
            const home_url = settings.homeUrl() orelse {
                try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .start);
                return;
            };
            if (parseInternalBrowsePage(home_url)) |internal_page| {
                clearBrowseTabErrorState(app.allocator, tab);
                try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, internal_page);
                return;
            }
            clearBrowseTabErrorState(app.allocator, tab);
            try app.display.presentDocument("Lightpanda Browser", home_url, "Loading page...");
            tab.last_presented_hash = 0;
            tab.restore_committed_surface = false;
            try page.scheduleNavigation(home_url, .{
                .reason = .address_bar,
                .kind = .{ .push = null },
            }, .{ .script = null });
        },
        .page_start => {
            try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .start);
        },
        .error_retry => {
            if (trimmedOrNull(tab.error_state.retry_value)) |retry_value| {
                clearBrowseTabErrorState(app.allocator, tab);
                try app.display.presentDocument("Lightpanda Browser", retry_value, "Loading page...");
                tab.last_presented_hash = 0;
                tab.restore_committed_surface = false;
                try page.scheduleNavigation(retry_value, .{
                    .reason = .address_bar,
                    .kind = .{ .push = null },
                }, .{ .script = null });
            }
        },
        .page_tabs => try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .tabs),
        .page_history => try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .history),
        .page_bookmarks => try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .bookmarks),
        .page_downloads => try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .downloads),
        .page_settings => try openInternalBrowsePage(app, shell, tab_index, page, settings, downloads, .settings),
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
        .settings_toggle_restore_session => {
            settings.restore_previous_session = !settings.restore_previous_session;
        },
        .settings_toggle_script_popups => {
            settings.allow_script_popups = !settings.allow_script_popups;
            tab.browser.allow_script_popups = settings.allow_script_popups;
            tab.session.allow_script_popups = settings.allow_script_popups;
        },
        .settings_default_zoom_in, .settings_default_zoom_out, .settings_default_zoom_reset => {
            settings.default_zoom_percent = applyDefaultZoomCommand(settings.default_zoom_percent, command);
        },
        .settings_set_homepage_to_current => {
            const homepage = browseTabHomepageCandidateUrl(tab) orelse return;
            try replaceBrowseHomepage(app.allocator, settings, homepage);
        },
        .settings_clear_homepage => {
            clearBrowseHomepage(app.allocator, settings);
        },
        .zoom_in, .zoom_out, .zoom_reset => {
            const next_zoom = applyZoomCommand(tab.zoom_percent, settings.default_zoom_percent, command);
            if (next_zoom == tab.zoom_percent) {
                return;
            }
            tab.zoom_percent = next_zoom;
            tab.restore_committed_surface = false;
            tab.last_presented_hash = 0;
            if (!pageIsLoading(page)) {
                try presentPage(app, page, &tab.last_presented_hash, &tab.committed_surface, tab.zoom_percent, null);
            }
        },
        else => {},
    }
}

fn processPendingBrowserNavigations(
    app: *App,
    shell: *BrowseShell,
    tab_index: usize,
    settings: *BrowseSettings,
    downloads: *BrowseDownloads,
) !void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    var pending = tab.session.takePendingBrowserNavigations();
    defer {
        while (pending.items.len > 0) {
            var request = pending.items[pending.items.len - 1];
            pending.items.len -= 1;
            request.deinit(app.allocator);
        }
        pending.deinit(app.allocator);
    }

    for (pending.items) |request| {
        try handleActiveBrowseCommand(app, shell, tab_index, settings, downloads, .{
            .navigate = request.url,
        });
    }
}

fn processPendingTabOpens(
    app: *App,
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    settings: *const BrowseSettings,
    active_tab_index: *usize,
    source_index: usize,
) !void {
    if (source_index >= tabs.items.len) {
        return;
    }
    const source_tab = tabs.items[source_index];
    var pending = source_tab.session.takePendingTabOpens();
    defer {
        while (pending.items.len > 0) {
            var request = pending.items[pending.items.len - 1];
            pending.items.len -= 1;
            request.deinit(app.allocator);
        }
        pending.deinit(app.allocator);
    }

    for (pending.items) |request| {
        const zoom_percent = if (request.zoom_percent >= 30 and request.zoom_percent <= 300)
            request.zoom_percent
        else
            settings.default_zoom_percent;
        try openOrReuseTargetedBrowseTab(
            app,
            tabs,
            active_tab_index,
            settings.allow_script_popups,
            zoom_percent,
            request.url,
            request.opts,
            request.target_name,
            request.activate,
            request.popup_source,
        );
    }
}

fn normalizeTopLevelTargetName(target_name: []const u8) []const u8 {
    return std.mem.trim(u8, target_name, &std.ascii.whitespace);
}

fn freeOwnedBrowseTabTargetName(allocator: std.mem.Allocator, target_name: []u8) void {
    if (target_name.len > 0) {
        allocator.free(target_name);
    }
}

fn targetAlwaysOpensFreshTab(target_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalizeTopLevelTargetName(target_name), "_blank");
}

fn setBrowseTabTargetName(allocator: std.mem.Allocator, tab: *BrowseTab, target_name: []const u8) !void {
    const normalized = normalizeTopLevelTargetName(target_name);
    if (normalized.len == 0 or targetAlwaysOpensFreshTab(normalized)) {
        freeOwnedBrowseTabTargetName(allocator, tab.target_name);
        tab.target_name = &.{};
        return;
    }

    const owned = try allocator.dupe(u8, normalized);
    freeOwnedBrowseTabTargetName(allocator, tab.target_name);
    tab.target_name = owned;
}

fn findBrowseTabIndexByTargetName(tabs: []const *BrowseTab, target_name: []const u8) ?usize {
    const normalized = normalizeTopLevelTargetName(target_name);
    if (normalized.len == 0 or targetAlwaysOpensFreshTab(normalized)) {
        return null;
    }
    for (tabs, 0..) |tab, index| {
        if (std.ascii.eqlIgnoreCase(tab.target_name, normalized)) {
            return index;
        }
    }
    return null;
}

fn openOrReuseTargetedBrowseTab(
    app: *App,
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    active_tab_index: *usize,
    allow_script_popups: bool,
    zoom_percent: i32,
    raw_url: []const u8,
    opts: Page.NavigateOpts,
    target_name: []const u8,
    activate: bool,
    popup_source: PopupSource,
) !void {
    if (findBrowseTabIndexByTargetName(tabs.items, target_name)) |target_index| {
        const tab = tabs.items[target_index];
        tab.browser.allow_script_popups = allow_script_popups;
        tab.session.allow_script_popups = allow_script_popups;
        tab.popup_source = popup_source;
        const normalized_target = normalizeTopLevelTargetName(target_name);
        if (popup_source == .script and normalized_target.len > 0 and !targetAlwaysOpensFreshTab(normalized_target)) {
            if (tab.session.currentPage()) |target_page| {
                if (!pageIsBlankIdle(target_page)) {
                    try resetBrowseTabSession(tab);
                }
            }
        }
        if (activate) {
            active_tab_index.* = target_index;
        }
        try navigateBrowseTabToOwnedUrl(tab, raw_url, opts);
        return;
    }

    const tab = try createBrowseTab(app, null, zoom_percent, allow_script_popups);
    errdefer tab.deinit(app.allocator);
    tab.zoom_percent = zoom_percent;
    try setBrowseTabTargetName(app.allocator, tab, target_name);
    tab.popup_source = popup_source;
    try appendBrowseTab(app.allocator, tabs, tab, active_tab_index, activate);
    try navigateBrowseTabToOwnedUrl(tab, raw_url, opts);
}

fn appendBrowseTab(
    allocator: std.mem.Allocator,
    tabs: *std.ArrayListUnmanaged(*BrowseTab),
    tab: *BrowseTab,
    active_tab_index: *usize,
    activate: bool,
) !void {
    try tabs.append(allocator, tab);
    if (activate) {
        active_tab_index.* = tabs.items.len - 1;
    }
    tab.last_presented_hash = 0;
}

fn navigateBrowseTabToOwnedUrl(tab: *BrowseTab, raw_url: []const u8, opts: Page.NavigateOpts) !void {
    if (std.mem.eql(u8, raw_url, "about:blank")) {
        return;
    }
    const page = tab.session.currentPage() orelse return;
    if (parseInternalBrowsePage(raw_url) != null) {
        page.url = try page.arena.dupeZ(u8, raw_url);
        tab.last_internal_page_state_hash = 0;
        tab.last_presented_hash = 0;
        return;
    }
    if (pageIsBlankIdle(page)) {
        try page.navigateOwned(raw_url, opts);
        return;
    }
    try page.scheduleNavigation(raw_url, opts, .{ .script = null });
}

fn resetBrowseTabSession(tab: *BrowseTab) !void {
    tab.committed_surface.deinit(tab.browser.app.allocator);
    tab.browser.closeSession();
    tab.session = try tab.browser.newSession(tab.notification);
    _ = try tab.session.createPage();
    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.last_internal_page_state_hash = 0;
}

fn handleRenderedLinkActivation(
    tab: *BrowseTab,
    page: *Page,
    activation: BrowserCommand.ActivateLinkRegion,
) !bool {
    if (parseInternalBrowseRoute(activation.url) != null) {
        return false;
    }
    const had_pending_navigation = page._queued_navigation != null;
    const had_pending_browser_navigations = tab.session.hasPendingBrowserNavigations();
    const had_pending_tab_opens = tab.session.hasPendingTabOpens();
    const had_pending_downloads = tab.session.hasPendingDownloads();
    var result = if (activation.dom_path.len > 0)
        try page.triggerMouseClickOnNodePathWithResult(activation.dom_path, activation.x, activation.y, .main, .{})
    else
        Page.MouseClickDispatchResult{
            .dispatched = false,
            .default_prevented = false,
        };

    if (!result.dispatched) {
        result = try page.triggerMouseClickWithResult(activation.x, activation.y, .main, .{});
    }

    if (!result.dispatched) {
        return false;
    }
    if (result.default_prevented) {
        return true;
    }
    if (!had_pending_navigation and page._queued_navigation != null) {
        return true;
    }
    if (!had_pending_browser_navigations and tab.session.hasPendingBrowserNavigations()) {
        return true;
    }
    if (!had_pending_tab_opens and tab.session.hasPendingTabOpens()) {
        return true;
    }
    if (!had_pending_downloads and tab.session.hasPendingDownloads()) {
        return true;
    }
    return false;
}

fn applyZoomCommand(current_zoom: i32, default_zoom_percent: i32, command: BrowserCommand) i32 {
    return switch (command) {
        .zoom_in => std.math.clamp(current_zoom + 10, 30, 300),
        .zoom_out => std.math.clamp(current_zoom - 10, 30, 300),
        .zoom_reset => std.math.clamp(default_zoom_percent, 30, 300),
        else => current_zoom,
    };
}

fn applyDefaultZoomCommand(current_zoom: i32, command: BrowserCommand) i32 {
    return switch (command) {
        .settings_default_zoom_in => std.math.clamp(current_zoom + 10, 30, 300),
        .settings_default_zoom_out => std.math.clamp(current_zoom - 10, 30, 300),
        .settings_default_zoom_reset => 100,
        else => current_zoom,
    };
}

fn pageRuntimeError(page: *Page) ?anyerror {
    return switch (page._parse_state) {
        .err => |err| err,
        else => null,
    };
}

fn pageHasRuntimeError(page: *Page) bool {
    return pageRuntimeError(page) != null;
}

fn pageIsLoading(page: *Page) bool {
    if (pageIsBlankIdle(page) or pageHasRuntimeError(page)) {
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
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
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
    var owned_tab_titles = try app.allocator.alloc([]u8, tabs.len);
    defer {
        for (owned_tab_titles) |title| {
            app.allocator.free(title);
        }
        app.allocator.free(owned_tab_titles);
    }
    for (tabs, 0..) |tab, index| {
        owned_tab_titles[index] = try browseTabEntryTitle(
            app.allocator,
            app.app_dir_path,
            tabs,
            index,
            downloads,
        );
        tab_entries[index] = browseTabEntry(tab, owned_tab_titles[index]);
    }
    app.display.setTabEntries(tab_entries, active_index);

    const download_entries = try downloads.toDisplayEntries(app.allocator);
    defer {
        for (download_entries) |entry| {
            app.allocator.free(entry.status);
        }
        app.allocator.free(download_entries);
    }
    app.display.setDownloadEntries(download_entries);
    app.display.setSettingsState(.{
        .restore_previous_session = settings.restore_previous_session,
        .allow_script_popups = settings.allow_script_popups,
        .default_zoom_percent = settings.default_zoom_percent,
        .homepage_url = settings.homeUrl() orelse "",
    });
}

fn applyBrowsePopupPolicyToTabs(tabs: []const *BrowseTab, allow_script_popups: bool) void {
    for (tabs) |tab| {
        tab.browser.allow_script_popups = allow_script_popups;
        tab.session.allow_script_popups = allow_script_popups;
    }
}

fn deinitBrowseTabs(allocator: std.mem.Allocator, tabs: *std.ArrayListUnmanaged(*BrowseTab)) void {
    while (tabs.items.len > 0) {
        const tab = tabs.items[tabs.items.len - 1];
        tabs.items.len -= 1;
        tab.deinit(allocator);
    }
    tabs.deinit(allocator);
}

fn deinitClosedBrowseTabs(allocator: std.mem.Allocator, closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab)) void {
    while (closed_tabs.items.len > 0) {
        var tab = closed_tabs.items[closed_tabs.items.len - 1];
        closed_tabs.items.len -= 1;
        tab.deinit(allocator);
    }
    closed_tabs.deinit(allocator);
}

fn popClosedBrowseTab(closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab)) ?ClosedBrowseTab {
    if (closed_tabs.items.len == 0) {
        return null;
    }
    return closed_tabs.pop();
}

fn popClosedBrowseTabAtUiIndex(closed_tabs: *std.ArrayListUnmanaged(ClosedBrowseTab), ui_index: usize) ?ClosedBrowseTab {
    if (ui_index >= closed_tabs.items.len) {
        return null;
    }
    const storage_index = closed_tabs.items.len - 1 - ui_index;
    return closed_tabs.orderedRemove(storage_index);
}

fn makeClosedBrowseTabDisplayEntries(
    allocator: std.mem.Allocator,
    closed_tabs: []const ClosedBrowseTab,
    limit: usize,
) !std.ArrayListUnmanaged(ClosedBrowseTabDisplayEntry) {
    var entries: std.ArrayListUnmanaged(ClosedBrowseTabDisplayEntry) = .{};
    errdefer entries.deinit(allocator);

    const max_count = @min(limit, closed_tabs.len);
    var ui_index: usize = 0;
    while (ui_index < max_count) : (ui_index += 1) {
        const storage_index = closed_tabs.len - 1 - ui_index;
        const closed = closed_tabs[storage_index];
        try entries.append(allocator, .{
            .ui_index = ui_index,
            .url = closed.url,
            .zoom_percent = closed.zoom_percent,
        });
    }
    return entries;
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
    settings: *const BrowseSettings,
) !usize {
    if (!settings.restore_previous_session) {
        try tabs.append(app.allocator, try createBrowseTab(app, startup_url, settings.default_zoom_percent, settings.allow_script_popups));
        return 0;
    }

    var saved = loadSavedBrowseSession(app.allocator, app.app_dir_path);
    defer saved.deinit(app.allocator);

    if (saved.tabs.items.len == 0) {
        try tabs.append(app.allocator, try createBrowseTab(app, startup_url, settings.default_zoom_percent, settings.allow_script_popups));
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
        const tab = try createBrowseTab(app, initial_url, settings.default_zoom_percent, settings.allow_script_popups);
        tab.zoom_percent = saved_tab.zoom_percent;
        try tabs.append(app.allocator, tab);
    }

    var active_index = normalizeActiveTabIndex(saved.active_index, tabs.items.len);
    if (shouldAppendStartupUrl(saved.tabs.items, startup_url)) {
        try tabs.append(app.allocator, try createBrowseTab(app, startup_url, settings.default_zoom_percent, settings.allow_script_popups));
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

fn loadBrowseSettings(allocator: std.mem.Allocator, app_dir_path: ?[]const u8) BrowseSettings {
    const dir_path = app_dir_path orelse return .{};
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return .{};
    defer dir.close();

    const file = dir.openFile(BROWSE_SETTINGS_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return .{},
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 16) catch return .{};
    defer allocator.free(data);
    return parseBrowseSettings(allocator, data) catch .{};
}

fn parseBrowseSettings(allocator: std.mem.Allocator, data: []const u8) !BrowseSettings {
    var settings: BrowseSettings = .{};
    errdefer settings.deinit(allocator);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n\t ");
        if (line.len == 0 or std.mem.eql(u8, line, "lightpanda-browse-settings-v1")) {
            continue;
        }
        if (std.mem.startsWith(u8, line, "restore_previous_session\t")) {
            const raw = line["restore_previous_session\t".len..];
            settings.restore_previous_session = std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true");
            continue;
        }
        if (std.mem.startsWith(u8, line, "allow_script_popups\t")) {
            const raw = line["allow_script_popups\t".len..];
            settings.allow_script_popups = std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true");
            continue;
        }
        if (std.mem.startsWith(u8, line, "default_zoom_percent\t")) {
            const raw = line["default_zoom_percent\t".len..];
            settings.default_zoom_percent = std.math.clamp(
                std.fmt.parseInt(i32, raw, 10) catch settings.default_zoom_percent,
                30,
                300,
            );
            continue;
        }
        if (std.mem.startsWith(u8, line, "homepage_url\t")) {
            const raw = std.mem.trim(u8, line["homepage_url\t".len..], "\r\n\t ");
            clearBrowseHomepage(allocator, &settings);
            if (raw.len > 0) {
                settings.homepage_url = try allocator.dupe(u8, raw);
            }
        }
    }

    return settings;
}

fn hashBrowseSettings(settings: *const BrowseSettings) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&settings.restore_previous_session));
    hasher.update(std.mem.asBytes(&settings.allow_script_popups));
    hasher.update(std.mem.asBytes(&settings.default_zoom_percent));
    hasher.update(settings.homepage_url);
    return hasher.final();
}

fn persistBrowseSettingsIfChanged(app: *App, settings: *const BrowseSettings, last_saved_hash: *u64) void {
    const next_hash = hashBrowseSettings(settings);
    if (next_hash == last_saved_hash.*) {
        return;
    }
    last_saved_hash.* = next_hash;
    saveBrowseSettings(app, settings) catch |err| {
        log.warn(.app, "browse settings save failed", .{ .err = err });
    };
}

fn saveBrowseSettings(app: *App, settings: *const BrowseSettings) !void {
    const dir_path = app.app_dir_path orelse return;
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    var buf = std.Io.Writer.Allocating.init(app.allocator);
    defer buf.deinit();

    try buf.writer.writeAll("lightpanda-browse-settings-v1\n");
    try buf.writer.print(
        "restore_previous_session\t{d}\nallow_script_popups\t{d}\ndefault_zoom_percent\t{d}\nhomepage_url\t{s}\n",
        .{
            if (settings.restore_previous_session) @as(u8, 1) else @as(u8, 0),
            if (settings.allow_script_popups) @as(u8, 1) else @as(u8, 0),
            settings.default_zoom_percent,
            settings.homeUrl() orelse "",
        },
    );
    try dir.writeFile(.{
        .sub_path = BROWSE_SETTINGS_FILE,
        .data = buf.written(),
    });
}

fn replaceBrowseHomepage(allocator: std.mem.Allocator, settings: *BrowseSettings, url: []const u8) !void {
    clearBrowseHomepage(allocator, settings);
    const trimmed = std.mem.trim(u8, url, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return;
    }
    settings.homepage_url = try allocator.dupe(u8, trimmed);
}

fn clearBrowseHomepage(allocator: std.mem.Allocator, settings: *BrowseSettings) void {
    allocator.free(settings.homepage_url);
    settings.homepage_url = &.{};
}

fn persistBrowseSessionIfChanged(
    app: *App,
    tabs: []const *BrowseTab,
    active_tab_index: usize,
    restore_previous_session: bool,
    last_saved_hash: *u64,
) void {
    if (!restore_previous_session) {
        last_saved_hash.* = std.math.maxInt(u64);
        clearSavedBrowseSession(app);
        return;
    }
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

fn browseDownloadHeaderCallback(transfer: *HttpClient.Transfer) !bool {
    const download: *ActiveBrowseDownload = @ptrCast(@alignCast(transfer.ctx));
    const entry = &download.manager.entries.items[download.entry_index];
    entry.status = .downloading;
    if (transfer.getContentLength()) |content_length| {
        entry.total_bytes = content_length;
        entry.has_total_bytes = true;
    }
    const response_header = transfer.response_header orelse return true;
    if (response_header.status >= 400) {
        return error.BadStatusCode;
    }
    download.manager.persistIfChanged(download.source_tab.browser.app.app_dir_path);
    return true;
}

fn browseDownloadDataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
    const download: *ActiveBrowseDownload = @ptrCast(@alignCast(transfer.ctx));
    const file = download.file orelse return error.Closed;
    try file.writeAll(data);
    download.manager.entries.items[download.entry_index].bytes_received += data.len;
}

fn browseDownloadDoneCallback(ctx: *anyopaque) !void {
    const download: *ActiveBrowseDownload = @ptrCast(@alignCast(ctx));
    if (download.file) |file| {
        file.close();
        download.file = null;
    }
    var entry = &download.manager.entries.items[download.entry_index];
    entry.status = .completed;
    BrowseDownloads.setDetail(entry, download.allocator, "");
    download.finished = true;
    download.manager.persistIfChanged(download.source_tab.browser.app.app_dir_path);
}

fn browseDownloadErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const download: *ActiveBrowseDownload = @ptrCast(@alignCast(ctx));
    if (download.finished) {
        return;
    }
    var entry = &download.manager.entries.items[download.entry_index];
    entry.status = .failed;
    const message = std.fmt.allocPrint(download.allocator, "Failed: {s}", .{@errorName(err)}) catch "Failed";
    defer if (@intFromPtr(message.ptr) != @intFromPtr("Failed".ptr)) download.allocator.free(message);
    BrowseDownloads.setDetail(entry, download.allocator, message);
    download.cleanupPartialFile();
    download.finished = true;
    download.manager.persistIfChanged(download.source_tab.browser.app.app_dir_path);
}

fn browseDownloadShutdownCallback(ctx: *anyopaque) void {
    const download: *ActiveBrowseDownload = @ptrCast(@alignCast(ctx));
    if (download.finished) {
        return;
    }
    var entry = &download.manager.entries.items[download.entry_index];
    entry.status = .interrupted;
    BrowseDownloads.setDetail(entry, download.allocator, "Interrupted");
    download.cleanupPartialFile();
    download.finished = true;
    download.manager.persistIfChanged(download.source_tab.browser.app.app_dir_path);
}

fn downloadEntryActive(downloads: *BrowseDownloads, index: usize) bool {
    for (downloads.active.items) |download| {
        if (download.entry_index == index and !download.finished) {
            return true;
        }
    }
    return false;
}

fn formatDownloadStatusLabel(allocator: std.mem.Allocator, entry: BrowseDownloadEntry) ![]u8 {
    return switch (entry.status) {
        .queued => allocator.dupe(u8, "Queued"),
        .downloading => if (entry.has_total_bytes)
            std.fmt.allocPrint(allocator, "Downloading {d}/{d} B", .{ entry.bytes_received, entry.total_bytes })
        else
            std.fmt.allocPrint(allocator, "Downloading {d} B", .{entry.bytes_received}),
        .completed => std.fmt.allocPrint(allocator, "Complete {d} B", .{entry.bytes_received}),
        .failed, .interrupted => if (entry.detail.len > 0)
            allocator.dupe(u8, entry.detail)
        else if (entry.status == .failed)
            allocator.dupe(u8, "Failed")
        else
            allocator.dupe(u8, "Interrupted"),
    };
}

fn ensureBrowseDownloadsDir(allocator: std.mem.Allocator, app_dir_path: []const u8) ![]u8 {
    var dir = try std.fs.openDirAbsolute(app_dir_path, .{});
    defer dir.close();
    try dir.makePath(BROWSE_DOWNLOADS_DIR);
    return try std.fs.path.join(allocator, &.{ app_dir_path, BROWSE_DOWNLOADS_DIR });
}

fn deriveDownloadFileName(
    allocator: std.mem.Allocator,
    url: []const u8,
    suggested_filename: []const u8,
) ![]u8 {
    const preferred = std.mem.trim(u8, suggested_filename, &std.ascii.whitespace);
    if (preferred.len > 0) {
        return sanitizeDownloadFileName(allocator, preferred);
    }

    const trimmed_url = std.mem.trim(u8, url, &std.ascii.whitespace);
    const slash_index = std.mem.lastIndexOfScalar(u8, trimmed_url, '/') orelse 0;
    const basename = if (slash_index + 1 < trimmed_url.len)
        trimmed_url[slash_index + 1 ..]
    else
        trimmed_url;
    const without_query = basename[0..(std.mem.indexOfAny(u8, basename, "?#") orelse basename.len)];
    if (without_query.len == 0) {
        return allocator.dupe(u8, "download.bin");
    }
    return sanitizeDownloadFileName(allocator, without_query);
}

fn sanitizeDownloadFileName(allocator: std.mem.Allocator, raw_name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const trimmed = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
    for (trimmed) |char| {
        switch (char) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*', '\r', '\n', '\t' => try buf.append(allocator, '_'),
            else => try buf.append(allocator, char),
        }
    }
    const candidate = std.mem.trim(u8, buf.items, ". ");
    if (candidate.len == 0) {
        return allocator.dupe(u8, "download.bin");
    }
    return allocator.dupe(u8, candidate);
}

fn makeUniqueDownloadFileName(allocator: std.mem.Allocator, downloads_dir: []const u8, base_name: []const u8) ![]u8 {
    var dir = try std.fs.openDirAbsolute(downloads_dir, .{});
    defer dir.close();

    const ext_index = std.mem.lastIndexOfScalar(u8, base_name, '.');
    const stem = if (ext_index) |index| base_name[0..index] else base_name;
    const ext = if (ext_index) |index| base_name[index..] else "";

    if (!fileExistsInDir(dir, base_name)) {
        return allocator.dupe(u8, base_name);
    }

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, suffix, ext });
        errdefer allocator.free(candidate);
        if (!fileExistsInDir(dir, candidate)) {
            return candidate;
        }
    }
}

fn fileExistsInDir(dir: std.fs.Dir, sub_path: []const u8) bool {
    dir.access(sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn hashSavedDownloads(entries: []const BrowseDownloadEntry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (entries) |entry| {
        hasher.update(entry.filename);
        hasher.update(entry.path);
        hasher.update(entry.url);
        hasher.update(entry.detail);
        hasher.update(std.mem.asBytes(&entry.bytes_received));
        hasher.update(std.mem.asBytes(&entry.total_bytes));
        hasher.update(std.mem.asBytes(&entry.has_total_bytes));
        hasher.update(std.mem.asBytes(&@intFromEnum(entry.status)));
    }
    return hasher.final();
}

fn saveBrowseDownloads(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    entries: []const BrowseDownloadEntry,
) void {
    const dir_path = app_dir_path orelse return;
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();

    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    for (entries) |entry| {
        buf.writer.print(
            "{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n",
            .{
                @intFromEnum(entry.status),
                entry.bytes_received,
                entry.total_bytes,
                if (entry.has_total_bytes) @as(u8, 1) else @as(u8, 0),
                sanitizePersistedDownloadField(entry.filename),
                sanitizePersistedDownloadField(entry.path),
                sanitizePersistedDownloadField(entry.url),
                sanitizePersistedDownloadField(entry.detail),
            },
        ) catch return;
    }

    dir.writeFile(.{ .sub_path = BROWSE_DOWNLOADS_FILE, .data = buf.written() }) catch |err| {
        log.warn(.app, "browse downloads write failed", .{ .err = err });
    };
}

fn sanitizePersistedDownloadField(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, "\r\n\t");
}

fn parseSavedDownloadEntry(allocator: std.mem.Allocator, line: []const u8) !BrowseDownloadEntry {
    var fields_it = std.mem.splitScalar(u8, line, '\t');
    const status_raw = fields_it.next() orelse return error.InvalidFormat;
    const received_raw = fields_it.next() orelse return error.InvalidFormat;
    const total_raw = fields_it.next() orelse return error.InvalidFormat;
    const has_total_raw = fields_it.next() orelse return error.InvalidFormat;
    const filename = fields_it.next() orelse return error.InvalidFormat;
    const path = fields_it.next() orelse return error.InvalidFormat;
    const url = fields_it.next() orelse return error.InvalidFormat;
    const detail = fields_it.next() orelse "";

    const saved_status: BrowseDownloadStatus = @enumFromInt(try std.fmt.parseInt(u8, status_raw, 10));
    return .{
        .filename = try allocator.dupe(u8, filename),
        .path = try allocator.dupe(u8, path),
        .url = try allocator.dupe(u8, url),
        .detail = try allocator.dupe(u8, detail),
        .bytes_received = try std.fmt.parseInt(usize, received_raw, 10),
        .total_bytes = try std.fmt.parseInt(usize, total_raw, 10),
        .has_total_bytes = try std.fmt.parseInt(u8, has_total_raw, 10) != 0,
        .status = switch (saved_status) {
            .queued, .downloading => .interrupted,
            else => saved_status,
        },
    };
}

fn createBrowseTab(
    app: *App,
    initial_url: ?[:0]const u8,
    default_zoom_percent: i32,
    allow_script_popups: bool,
) !*BrowseTab {
    const tab = try app.allocator.create(BrowseTab);
    errdefer app.allocator.destroy(tab);

    tab.http_client = try app.http.createClient(app.allocator);
    errdefer tab.http_client.deinit();

    tab.notification = try Notification.init(app.allocator);
    errdefer tab.notification.deinit();

    tab.browser = try Browser.init(app, .{ .http_client = tab.http_client });
    errdefer tab.browser.deinit();
    tab.browser.allow_script_popups = allow_script_popups;

    tab.session = try tab.browser.newSession(tab.notification);
    const page = try tab.session.createPage();
    tab.target_name = &.{};
    tab.popup_source = .none;
    tab.committed_surface = .{};
    tab.error_state = .{};
    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.last_internal_page_state_hash = 0;
    tab.zoom_percent = std.math.clamp(default_zoom_percent, 30, 300);

    if (initial_url) |target_url| {
        if (parseInternalBrowsePage(target_url) != null) {
            page.url = try page.arena.dupeZ(u8, target_url);
            return tab;
        }
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
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    active_tab_index: usize,
    displayed_tab_index: *?usize,
) !void {
    if (tabs.len == 0) {
        displayed_tab_index.* = null;
        return;
    }

    const active_index = normalizeActiveTabIndex(active_tab_index, tabs.len);
    const active_tab = tabs[active_index];
    const initial_page = active_tab.session.currentPage() orelse return;
    const initial_internal_page = parseInternalBrowsePage(initial_page.url);
    if (pageHasRuntimeError(initial_page) and (initial_internal_page == null or initial_internal_page.? != .error_page)) {
        _ = try captureBrowseTabRuntimeError(app.allocator, active_tab);
        try openInternalErrorPageForTab(app, active_tab, initial_page, settings);
    }
    const page = active_tab.session.currentPage() orelse return;
    const show_committed_surface = active_tab.restore_committed_surface and
        active_tab.committed_surface.available() and
        pageIsLoading(page);

    try syncBrowseDisplayState(app, tabs, settings, downloads, active_index, if (show_committed_surface) false else null);

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
    const internal_title_override = if (parseInternalBrowsePage(page.url)) |internal_page|
        try makeInternalBrowsePageDisplayTitle(
            app.allocator,
            app.app_dir_path,
            tabs,
            active_index,
            downloads,
            internal_page,
        )
    else
        null;
    defer if (internal_title_override) |title| app.allocator.free(title);
    try presentPage(
        app,
        page,
        &active_tab.last_presented_hash,
        &active_tab.committed_surface,
        active_tab.zoom_percent,
        internal_title_override,
    );
}

fn trimmedOrNull(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

fn browseErrorTitle(kind: BrowseErrorKind) []const u8 {
    return switch (kind) {
        .invalid_address => "Invalid Address",
        .navigation_failed => "Navigation Error",
    };
}

fn browseErrorSummary(kind: BrowseErrorKind) []const u8 {
    return switch (kind) {
        .invalid_address => "The address could not be normalized into a URL.",
        .navigation_failed => "The page could not be loaded by the current browser runtime.",
    };
}

fn browseErrorDetailLabel(kind: BrowseErrorKind, detail: []const u8) []const u8 {
    _ = kind;
    return if (trimmedOrNull(detail)) |value| value else "Unknown";
}

fn hashBrowseErrorState(error_state: *const BrowseErrorState) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&.{@intFromEnum(error_state.kind)});
    hasher.update(error_state.retry_value);
    hasher.update(error_state.display_value);
    hasher.update(error_state.detail);
    return hasher.final();
}

fn setBrowseTabErrorState(
    allocator: std.mem.Allocator,
    tab: *BrowseTab,
    kind: BrowseErrorKind,
    retry_value: []const u8,
    display_value: []const u8,
    detail: []const u8,
) !void {
    try tab.error_state.replace(allocator, kind, retry_value, display_value, detail);
}

fn clearBrowseTabErrorState(allocator: std.mem.Allocator, tab: *BrowseTab) void {
    tab.error_state.clear(allocator);
}

fn captureBrowseTabRuntimeError(allocator: std.mem.Allocator, tab: *BrowseTab) !bool {
    const page = tab.session.currentPage() orelse {
        clearBrowseTabErrorState(allocator, tab);
        return false;
    };
    const runtime_error = pageRuntimeError(page) orelse {
        const internal_page = parseInternalBrowsePage(page.url);
        if (internal_page == null and !pageIsLoading(page)) {
            clearBrowseTabErrorState(allocator, tab);
        }
        return false;
    };
    const display_url = trimmedOrNull(page.url) orelse "about:blank";
    try setBrowseTabErrorState(
        allocator,
        tab,
        .navigation_failed,
        display_url,
        display_url,
        @errorName(runtime_error),
    );
    return true;
}

fn browseTabEntryTitle(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    tabs: []const *BrowseTab,
    tab_index: usize,
    downloads: *BrowseDownloads,
) ![]u8 {
    if (tab_index >= tabs.len) {
        return allocator.dupe(u8, "Closed Tab");
    }
    const tab = tabs[tab_index];
    const page = tab.session.currentPage() orelse {
        return allocator.dupe(u8, "Closed Tab");
    };

    if (pageIsBlankIdle(page)) {
        return allocator.dupe(u8, "New Tab");
    }

    if (tab.error_state.hasValue()) {
        return allocator.dupe(u8, browseErrorTitle(tab.error_state.kind));
    }

    if (!pageIsLoading(page)) {
        if (parseInternalBrowsePage(page.url)) |internal_page| {
            return makeInternalBrowsePageDisplayTitle(
                allocator,
                app_dir_path,
                tabs,
                tab_index,
                downloads,
                internal_page,
            );
        }
        const page_title = (try page.getTitle()) orelse "";
        if (trimmedOrNull(page_title)) |resolved| {
            return allocator.dupe(u8, resolved);
        }
    }

    return allocator.dupe(
        u8,
        trimmedOrNull(tab.committed_surface.title) orelse
            trimmedOrNull(page.url) orelse
            trimmedOrNull(tab.committed_surface.url) orelse
            "New Tab",
    );
}

fn browseTabEntry(tab: *BrowseTab, title: []const u8) Display.TabEntry {
    const page = tab.session.currentPage();
    const url = if (page) |current_page|
        trimmedOrNull(current_page.url) orelse
            trimmedOrNull(tab.committed_surface.url) orelse
            "about:blank"
    else
        trimmedOrNull(tab.committed_surface.url) orelse
            "about:blank";

    return .{
        .title = title,
        .url = url,
        .is_loading = if (page) |current_page| pageIsLoading(current_page) else false,
        .has_error = tab.error_state.hasValue(),
        .target_name = tab.target_name,
        .popup_source = tab.popup_source,
    };
}

fn browseTabPersistentUrl(tab: *BrowseTab) []const u8 {
    const page = tab.session.currentPage() orelse return "about:blank";
    if (parseInternalBrowsePage(page.url)) |internal_page| {
        if (internal_page == .error_page) {
            if (trimmedOrNull(tab.error_state.retry_value)) |retry_value| {
                return retry_value;
            }
        }
    }
    if (trimmedOrNull(page.url)) |url| {
        return url;
    }
    if (trimmedOrNull(tab.committed_surface.url)) |url| {
        return url;
    }
    return "about:blank";
}

fn browseTabHomepageCandidateUrl(tab: *BrowseTab) ?[]const u8 {
    const page = tab.session.currentPage();
    if (page) |current_page| {
        if (parseInternalBrowsePage(current_page.url)) |internal_page| {
            if (internal_page == .error_page) {
                if (trimmedOrNull(tab.error_state.display_value)) |value| {
                    if (parseInternalBrowsePage(value) == null and std.mem.indexOfScalar(u8, value, ' ') == null) {
                        return value;
                    }
                }
            }
        }
        if (trimmedOrNull(current_page.url)) |url| {
            if (parseInternalBrowsePage(url) == null) {
                return url;
            }
        }
    }

    const navigation_entries = tab.session.navigation.entries();
    if (navigation_entries.len > 0) {
        const current_index = tab.session.navigation.getCurrentIndex();
        if (navigation_entries[current_index].url()) |url| {
            if (trimmedOrNull(url)) |trimmed_url| {
                if (parseInternalBrowsePage(trimmed_url) == null) {
                    return trimmed_url;
                }
            }
        }
    }

    if (trimmedOrNull(tab.committed_surface.url)) |url| {
        if (parseInternalBrowsePage(url) == null) {
            return url;
        }
    }
    return null;
}

fn clearBrowseHistoryToCurrent(tab: *BrowseTab) bool {
    const entries = tab.session.navigation.entries();
    if (entries.len == 0) {
        return false;
    }
    const current_index = tab.session.navigation.getCurrentIndex();
    if (current_index >= entries.len) {
        return false;
    }
    const current_entry = entries[current_index];
    tab.session.navigation._entries.items[0] = current_entry;
    tab.session.navigation._entries.items.len = 1;
    tab.session.navigation._index = 0;
    return true;
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

fn internalBrowsePageAlias(internal_page: InternalBrowsePage) []const u8 {
    return switch (internal_page) {
        .start => "browser://start",
        .error_page => "browser://error",
        .tabs => "browser://tabs",
        .history => "browser://history",
        .bookmarks => "browser://bookmarks",
        .downloads => "browser://downloads",
        .settings => "browser://settings",
    };
}

fn parseInternalBrowseNamedPage(page_name: []const u8) ?InternalBrowsePage {
    if (std.ascii.eqlIgnoreCase(page_name, "start")) {
        return .start;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "error")) {
        return .error_page;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "tabs")) {
        return .tabs;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "history")) {
        return .history;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "bookmarks")) {
        return .bookmarks;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "downloads")) {
        return .downloads;
    }
    if (std.ascii.eqlIgnoreCase(page_name, "settings")) {
        return .settings;
    }
    return null;
}

fn parseInternalBrowsePage(raw_url: []const u8) ?InternalBrowsePage {
    const trimmed = std.mem.trim(u8, raw_url, &std.ascii.whitespace);
    if (!std.ascii.startsWithIgnoreCase(trimmed, "browser://")) {
        return null;
    }
    const rest = trimmed["browser://".len..];
    const page_name = rest[0..(std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len)];
    return parseInternalBrowseNamedPage(page_name);
}

fn parseInternalBrowseIndexAction(action_path: []const u8, prefix: []const u8) ?usize {
    if (!std.ascii.startsWithIgnoreCase(action_path, prefix)) {
        return null;
    }
    const raw_index = action_path[prefix.len..];
    if (raw_index.len == 0) {
        return null;
    }
    return std.fmt.parseInt(usize, raw_index, 10) catch null;
}

fn parseInternalBrowseRoute(raw_url: []const u8) ?InternalBrowseRoute {
    const trimmed = std.mem.trim(u8, raw_url, &std.ascii.whitespace);
    if (!std.ascii.startsWithIgnoreCase(trimmed, "browser://")) {
        return null;
    }

    const rest = trimmed["browser://".len..];
    const page_name_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const page_name = rest[0..page_name_end];
    const page = parseInternalBrowseNamedPage(page_name) orelse return null;
    if (page_name_end >= rest.len or rest[page_name_end] != '/') {
        return .{ .page = page };
    }

    const action_path = rest[page_name_end + 1 ..];
    const action = action_path[0..(std.mem.indexOfAny(u8, action_path, "?#") orelse action_path.len)];
    if (action.len == 0) {
        return .{ .page = page };
    }

    return switch (page) {
        .start => .{ .page = .start },
        .error_page => if (std.ascii.eqlIgnoreCase(action, "retry"))
            .{ .command = .error_retry }
        else if (std.ascii.eqlIgnoreCase(action, "home"))
            .{ .command = .home }
        else if (std.ascii.eqlIgnoreCase(action, "start"))
            .{ .command = .page_start }
        else
            .{ .page = .error_page },
        .tabs => if (std.ascii.eqlIgnoreCase(action, "new"))
            .{ .command = .tab_new }
        else if (parseInternalBrowseIndexAction(action, "reopen-closed/")) |index|
            .{ .command = .{ .tab_reopen_closed_index = index } }
        else if (std.ascii.eqlIgnoreCase(action, "reopen-closed"))
            .{ .command = .tab_reopen_closed }
        else if (parseInternalBrowseIndexAction(action, "activate/")) |index|
            .{ .command = .{ .tab_activate = index } }
        else if (parseInternalBrowseIndexAction(action, "close/")) |index|
            .{ .command = .{ .tab_close = index } }
        else if (parseInternalBrowseIndexAction(action, "duplicate/")) |index|
            .{ .command = .{ .tab_duplicate_index = index } }
        else if (parseInternalBrowseIndexAction(action, "reload/")) |index|
            .{ .command = .{ .tab_reload_index = index } }
        else
            .{ .page = .tabs },
        .history => if (parseInternalBrowseIndexAction(action, "traverse/")) |index|
            .{ .command = .{ .history_traverse = index } }
        else if (std.ascii.eqlIgnoreCase(action, "clear-session"))
            .{ .command = .history_clear_session }
        else
            .{ .page = .history },
        .bookmarks => if (std.ascii.eqlIgnoreCase(action, "add-current"))
            .{ .command = .bookmark_add_current }
        else if (parseInternalBrowseIndexAction(action, "open/")) |index|
            .{ .command = .{ .bookmark_open = index } }
        else if (parseInternalBrowseIndexAction(action, "remove/")) |index|
            .{ .command = .{ .bookmark_remove = index } }
        else
            .{ .page = .bookmarks },
        .downloads => if (parseInternalBrowseIndexAction(action, "source/")) |index|
            .{ .command = .{ .download_source = index } }
        else if (parseInternalBrowseIndexAction(action, "remove/")) |index|
            .{ .command = .{ .download_remove = index } }
        else if (std.ascii.eqlIgnoreCase(action, "clear"))
            .{ .command = .download_clear }
        else
            .{ .page = .downloads },
        .settings => if (std.ascii.eqlIgnoreCase(action, "toggle-restore-session"))
            .{ .command = .settings_toggle_restore_session }
        else if (std.ascii.eqlIgnoreCase(action, "toggle-script-popups"))
            .{ .command = .settings_toggle_script_popups }
        else if (std.ascii.eqlIgnoreCase(action, "default-zoom/in"))
            .{ .command = .settings_default_zoom_in }
        else if (std.ascii.eqlIgnoreCase(action, "default-zoom/out"))
            .{ .command = .settings_default_zoom_out }
        else if (std.ascii.eqlIgnoreCase(action, "default-zoom/reset"))
            .{ .command = .settings_default_zoom_reset }
        else if (std.ascii.eqlIgnoreCase(action, "homepage/set-current"))
            .{ .command = .settings_set_homepage_to_current }
        else if (std.ascii.eqlIgnoreCase(action, "homepage/clear"))
            .{ .command = .settings_clear_homepage }
        else
            .{ .page = .settings },
    };
}

fn openInternalBrowsePage(
    app: *App,
    shell: *BrowseShell,
    tab_index: usize,
    page: *Page,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    internal_page: InternalBrowsePage,
) !void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    const html = try buildInternalBrowsePageHtml(
        app.allocator,
        app.app_dir_path,
        shell,
        tab_index,
        settings,
        downloads,
        internal_page,
    );
    defer app.allocator.free(html);

    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.last_internal_page_state_hash = hashInternalBrowsePageState(
        app.allocator,
        app.app_dir_path,
        shell,
        tab_index,
        settings,
        downloads,
        internal_page,
    );
    try replacePageWithInternalHtml(
        app.allocator,
        page,
        internalBrowsePageAlias(internal_page),
        html,
    );
    const title_override = try makeInternalBrowsePageDisplayTitle(
        app.allocator,
        app.app_dir_path,
        shell.tabs.items,
        tab_index,
        downloads,
        internal_page,
    );
    defer app.allocator.free(title_override);
    try presentPage(app, page, &tab.last_presented_hash, &tab.committed_surface, tab.zoom_percent, title_override);
}

fn openInternalErrorPageForTab(
    app: *App,
    tab: *BrowseTab,
    page: *Page,
    settings: *const BrowseSettings,
) !void {
    var html = std.Io.Writer.Allocating.init(app.allocator);
    defer html.deinit();
    try writeInternalErrorPage(&html.writer, tab, settings);

    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.last_internal_page_state_hash = hashBrowseErrorState(&tab.error_state);
    try replacePageWithInternalHtml(
        app.allocator,
        page,
        internalBrowsePageAlias(.error_page),
        html.written(),
    );
    try presentPage(
        app,
        page,
        &tab.last_presented_hash,
        &tab.committed_surface,
        tab.zoom_percent,
        browseErrorTitle(tab.error_state.kind),
    );
}

fn internalBrowseCommandKeepsCurrentPage(command: BrowserCommand) bool {
    return switch (command) {
        .history_clear_session,
        .bookmark_add_current,
        .bookmark_remove,
        .download_clear,
        .download_remove,
        .settings_toggle_restore_session,
        .settings_toggle_script_popups,
        .settings_default_zoom_in,
        .settings_default_zoom_out,
        .settings_default_zoom_reset,
        .settings_set_homepage_to_current,
        .settings_clear_homepage,
        => true,
        else => false,
    };
}

fn internalBrowseCommandUsesBrowseLoopHandler(command: BrowserCommand) bool {
    return switch (command) {
        .tab_new,
        .tab_activate,
        .tab_close,
        .tab_duplicate,
        .tab_duplicate_index,
        .tab_reload_index,
        .tab_reopen_closed,
        .tab_reopen_closed_index,
        => true,
        else => false,
    };
}

fn internalBrowseCommandHostPage(command: BrowserCommand) ?InternalBrowsePage {
    return switch (command) {
        .history_clear_session => .history,
        .bookmark_add_current,
        .bookmark_open,
        .bookmark_remove,
        => .bookmarks,
        .download_source,
        .download_remove,
        .download_clear,
        => .downloads,
        .settings_toggle_restore_session,
        .settings_toggle_script_popups,
        .settings_default_zoom_in,
        .settings_default_zoom_out,
        .settings_default_zoom_reset,
        .settings_set_homepage_to_current,
        .settings_clear_homepage,
        => .settings,
        else => null,
    };
}

fn hashOwnedStringSlice(items: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (items) |item| {
        hasher.update(item);
    }
    return hasher.final();
}

fn hashInternalHistoryPageState(tab: *BrowseTab) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const entries = tab.session.navigation.entries();
    const current_index = tab.session.navigation.getCurrentIndex();
    hasher.update(std.mem.asBytes(&current_index));
    for (entries) |entry| {
        hasher.update(entry.url() orelse "about:blank");
    }
    return hasher.final();
}

fn hashInternalTabsPageState(shell: *const BrowseShell) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const active_index = if (shell.tabs.items.len == 0)
        @as(usize, 0)
    else
        normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
    const closed_count = shell.closed_tabs.items.len;
    hasher.update(std.mem.asBytes(&active_index));
    hasher.update(std.mem.asBytes(&closed_count));
    for (shell.tabs.items) |tab| {
        const url = browseTabPersistentUrl(tab);
        hasher.update(url);
        const error_hash = hashBrowseErrorState(&tab.error_state);
        hasher.update(std.mem.asBytes(&error_hash));
        hasher.update(tab.target_name);
        hasher.update(&.{@intFromEnum(tab.popup_source)});
        hasher.update(std.mem.asBytes(&tab.zoom_percent));
        if (tab.session.currentPage()) |page| {
            const loading = pageIsLoading(page);
            hasher.update(std.mem.asBytes(&loading));
        } else {
            const loading = false;
            hasher.update(std.mem.asBytes(&loading));
        }
    }
    for (shell.closed_tabs.items) |tab| {
        hasher.update(tab.url);
        hasher.update(std.mem.asBytes(&tab.zoom_percent));
    }
    return hasher.final();
}

fn hashInternalBrowsePageState(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    tab_index: usize,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    internal_page: InternalBrowsePage,
) u64 {
    if (tab_index >= shell.tabs.items.len) {
        return 0;
    }
    const tab = shell.tabs.items[tab_index];
    return switch (internal_page) {
        .start => blk: {
            var hasher = std.hash.Wyhash.init(0);
            const tabs_hash = hashInternalTabsPageState(shell);
            hasher.update(std.mem.asBytes(&tabs_hash));
            const history_hash = hashInternalHistoryPageState(tab);
            hasher.update(std.mem.asBytes(&history_hash));
            var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
            defer deinitOwnedStrings(allocator, &bookmarks);
            const bookmark_hash = hashOwnedStringSlice(bookmarks.items);
            hasher.update(std.mem.asBytes(&bookmark_hash));
            const download_hash = hashSavedDownloads(downloads.entries.items);
            hasher.update(std.mem.asBytes(&download_hash));
            const settings_hash = hashBrowseSettings(settings);
            hasher.update(std.mem.asBytes(&settings_hash));
            break :blk hasher.final();
        },
        .error_page => hashBrowseErrorState(&tab.error_state),
        .tabs => hashInternalTabsPageState(shell),
        .history => hashInternalHistoryPageState(tab),
        .bookmarks => blk: {
            var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
            defer deinitOwnedStrings(allocator, &bookmarks);
            break :blk hashOwnedStringSlice(bookmarks.items);
        },
        .downloads => hashSavedDownloads(downloads.entries.items),
        .settings => hashBrowseSettings(settings),
    };
}

fn refreshCurrentInternalBrowsePage(
    app: *App,
    shell: *BrowseShell,
    tab_index: usize,
    page: *Page,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    force: bool,
) !void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    const internal_page = parseInternalBrowsePage(page.url) orelse {
        tab.last_internal_page_state_hash = 0;
        return;
    };

    const next_hash = hashInternalBrowsePageState(
        app.allocator,
        app.app_dir_path,
        shell,
        tab_index,
        settings,
        downloads,
        internal_page,
    );
    if (!force and next_hash == tab.last_internal_page_state_hash) {
        return;
    }

    const html = try buildInternalBrowsePageHtml(
        app.allocator,
        app.app_dir_path,
        shell,
        tab_index,
        settings,
        downloads,
        internal_page,
    );
    defer app.allocator.free(html);

    tab.restore_committed_surface = false;
    tab.last_presented_hash = 0;
    tab.last_internal_page_state_hash = next_hash;
    try replacePageWithInternalHtml(
        app.allocator,
        page,
        internalBrowsePageAlias(internal_page),
        html,
    );
    const title_override = try makeInternalBrowsePageDisplayTitle(
        app.allocator,
        app.app_dir_path,
        shell.tabs.items,
        tab_index,
        downloads,
        internal_page,
    );
    defer app.allocator.free(title_override);
    try presentPage(app, page, &tab.last_presented_hash, &tab.committed_surface, tab.zoom_percent, title_override);
}

fn buildInternalBrowsePageHtml(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    tab_index: usize,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    internal_page: InternalBrowsePage,
) ![]u8 {
    var html = std.Io.Writer.Allocating.init(allocator);
    defer html.deinit();

    if (tab_index >= shell.tabs.items.len) {
        return try allocator.dupe(u8, "");
    }
    const tab = shell.tabs.items[tab_index];
    switch (internal_page) {
        .start => try writeInternalStartPage(allocator, &html.writer, app_dir_path, shell, tab_index, settings, downloads),
        .error_page => try writeInternalErrorPage(&html.writer, tab, settings),
        .tabs => try writeInternalTabsPage(allocator, &html.writer, app_dir_path, shell, downloads),
        .history => try writeInternalHistoryPage(allocator, &html.writer, tab),
        .bookmarks => try writeInternalBookmarksPage(allocator, &html.writer, app_dir_path),
        .downloads => try writeInternalDownloadsPage(allocator, &html.writer, downloads),
        .settings => try writeInternalSettingsPage(&html.writer, tab, settings),
    }

    return try allocator.dupe(u8, html.written());
}

fn replacePageWithInternalHtml(
    allocator: std.mem.Allocator,
    page: *Page,
    alias: []const u8,
    html: []const u8,
) !void {
    const html_literal = try buildJsStringLiteral(allocator, html);
    defer allocator.free(html_literal);

    const script = try std.fmt.allocPrint(
        allocator,
        "document.open();document.write({s});document.close();",
        .{html_literal},
    );
    defer allocator.free(script);

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();
    try ls.local.eval(script, "internal_browser_page");

    page._parse_state = .{ .complete = {} };
    page.url = try page.arena.dupeZ(u8, alias);
}

fn buildJsStringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    try buf.writer.writeByte('\'');
    for (value) |byte| {
        switch (byte) {
            '\\' => try buf.writer.writeAll("\\\\"),
            '\'' => try buf.writer.writeAll("\\'"),
            '\n' => try buf.writer.writeAll("\\n"),
            '\r' => try buf.writer.writeAll("\\r"),
            '\t' => try buf.writer.writeAll("\\t"),
            else => if (byte < 0x20)
                try buf.writer.print("\\x{X:0>2}", .{byte})
            else
                try buf.writer.writeByte(byte),
        }
    }
    try buf.writer.writeByte('\'');
    return try allocator.dupe(u8, buf.written());
}

fn writeInternalPageStart(writer: anytype, title: []const u8, alias: []const u8, subtitle: []const u8) !void {
    try writer.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>");
    try writeHtmlEscaped(writer, title);
    try writer.writeAll("</title></head><body><h1>");
    try writeHtmlEscaped(writer, title);
    try writer.writeAll("</h1><p>");
    try writeHtmlEscaped(writer, subtitle);
    try writer.writeAll("</p><p>Address alias: <code>");
    try writeHtmlEscaped(writer, alias);
    try writer.writeAll("</code></p><p><strong>Shell:</strong> ");
}

fn writeInternalShellNav(writer: anytype, current_page: InternalBrowsePage) !void {
    const nav_pages = [_]InternalBrowsePage{ .start, .tabs, .history, .bookmarks, .downloads, .settings };
    for (nav_pages, 0..) |nav_page, index| {
        if (index != 0) {
            try writer.writeAll(" | ");
        }
        if (nav_page == current_page) {
            try writer.writeAll("<strong>");
            try writeHtmlEscaped(writer, internalBrowsePageTitle(nav_page));
            try writer.writeAll("</strong>");
        } else {
            try writeInternalActionLink(writer, internalBrowsePageAlias(nav_page), internalBrowsePageTitle(nav_page));
        }
    }
    try writer.writeAll("</p>");
}

fn writeInternalShellNavNoSelection(writer: anytype) !void {
    const nav_pages = [_]InternalBrowsePage{ .start, .tabs, .history, .bookmarks, .downloads, .settings };
    for (nav_pages, 0..) |nav_page, index| {
        if (index != 0) {
            try writer.writeAll(" | ");
        }
        try writeInternalActionLink(writer, internalBrowsePageAlias(nav_page), internalBrowsePageTitle(nav_page));
    }
    try writer.writeAll("</p>");
}

fn internalBrowsePageTitle(internal_page: InternalBrowsePage) []const u8 {
    return switch (internal_page) {
        .start => "Start",
        .error_page => "Error",
        .tabs => "Tabs",
        .history => "History",
        .bookmarks => "Bookmarks",
        .downloads => "Downloads",
        .settings => "Settings",
    };
}

fn makeInternalBrowsePageDisplayTitle(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    tabs: []const *BrowseTab,
    tab_index: usize,
    downloads: *BrowseDownloads,
    internal_page: InternalBrowsePage,
) ![]u8 {
    return switch (internal_page) {
        .start => allocator.dupe(u8, "Browser Start"),
        .error_page => blk: {
            if (tab_index >= tabs.len) {
                break :blk allocator.dupe(u8, "Browser Error");
            }
            const tab = tabs[tab_index];
            break :blk std.fmt.allocPrint(allocator, "{s}", .{browseErrorTitle(tab.error_state.kind)});
        },
        .tabs => std.fmt.allocPrint(allocator, "Browser Tabs ({d})", .{tabs.len}),
        .history => blk: {
            if (tab_index >= tabs.len) {
                break :blk allocator.dupe(u8, "Browser History (0)");
            }
            const tab = tabs[tab_index];
            break :blk std.fmt.allocPrint(allocator, "Browser History ({d})", .{tab.session.navigation.entries().len});
        },
        .bookmarks => blk: {
            var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
            defer deinitOwnedStrings(allocator, &bookmarks);
            break :blk std.fmt.allocPrint(allocator, "Browser Bookmarks ({d})", .{bookmarks.items.len});
        },
        .downloads => std.fmt.allocPrint(allocator, "Browser Downloads ({d})", .{downloads.entries.items.len}),
        .settings => allocator.dupe(u8, "Browser Settings"),
    };
}

fn writeInternalPageEnd(writer: anytype) !void {
    try writer.writeAll("</body></html>");
}

fn writeInternalActionLink(writer: anytype, href: []const u8, label: []const u8) !void {
    try writer.writeAll("<a href=\"");
    try writeHtmlEscaped(writer, href);
    try writer.writeAll("\">");
    try writeHtmlEscaped(writer, label);
    try writer.writeAll("</a>");
}

const INTERNAL_START_PREVIEW_LIMIT: usize = 3;

fn writeInternalStartSectionTitle(writer: anytype, title: []const u8) !void {
    try writer.writeAll("<h2>");
    try writeHtmlEscaped(writer, title);
    try writer.writeAll("</h2>");
}

fn writeInternalStartQuickActions(
    writer: anytype,
    tab: *BrowseTab,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
    closed_tabs_count: usize,
) !void {
    try writeInternalStartSectionTitle(writer, "Quick Actions");
    try writer.writeAll("<p>");
    try writeInternalActionLink(writer, "browser://tabs/new", "New tab");
    if (tab.error_state.hasValue()) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://error", "Open current error");
    }
    if (closed_tabs_count > 0) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://tabs/reopen-closed", "Reopen latest closed tab");
    }
    if (browseTabHomepageCandidateUrl(tab) != null) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://bookmarks/add-current", "Add current page");
    }
    if (settings.homeUrl()) |home_url| {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, home_url, "Open homepage");
    }
    if (downloads.entries.items.len > 0) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://downloads/clear", "Clear inactive downloads");
    }
    try writer.writeAll("</p>");
}

fn browseTabStatusLabel(tab: *BrowseTab) []const u8 {
    if (tab.error_state.hasValue()) {
        return browseErrorTitle(tab.error_state.kind);
    }
    const page = tab.session.currentPage() orelse return "No Page";
    if (pageIsBlankIdle(page)) {
        return "Blank";
    }
    if (pageIsLoading(page)) {
        return "Loading";
    }
    return "Ready";
}

fn writeInternalStartCurrentTabStatusSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    tab_index: usize,
    downloads: *BrowseDownloads,
) !void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    const title = try browseTabEntryTitle(allocator, app_dir_path, shell.tabs.items, tab_index, downloads);
    defer allocator.free(title);
    try writeInternalStartSectionTitle(writer, "Current Tab Status");
    try writer.writeAll("<ul><li><strong>Title:</strong> ");
    try writeHtmlEscaped(writer, title);
    try writer.writeAll("</li><li><strong>Status:</strong> ");
    try writeHtmlEscaped(writer, browseTabStatusLabel(tab));
    try writer.writeAll("</li><li><strong>URL:</strong> <code>");
    try writeHtmlEscaped(writer, browseTabPersistentUrl(tab));
    try writer.writeAll("</code></li>");
    if (tab.error_state.hasValue()) {
        try writer.writeAll("<li><strong>Reason:</strong> ");
        try writeHtmlEscaped(writer, browseErrorDetailLabel(tab.error_state.kind, tab.error_state.detail));
        try writer.writeAll(" (");
        try writeInternalActionLink(writer, "browser://error", "details");
        try writer.writeAll(")</li>");
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartRecentTabsSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    downloads: *BrowseDownloads,
) !void {
    try writeInternalStartSectionTitle(writer, "Open Tabs");
    try writer.print("<p><strong>Count:</strong> {d} ", .{shell.tabs.items.len});
    try writeInternalActionLink(writer, "browser://tabs", "Open tabs page");
    try writer.writeAll("</p>");
    if (shell.tabs.items.len == 0) {
        try writer.writeAll("<p>No tabs are currently open.</p>");
        return;
    }

    const active_index = normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
    const preview_count = @min(INTERNAL_START_PREVIEW_LIMIT, shell.tabs.items.len);
    try writer.writeAll("<ul>");
    for (shell.tabs.items[0..preview_count], 0..) |tab, index| {
        const title = try browseTabEntryTitle(allocator, app_dir_path, shell.tabs.items, index, downloads);
        defer allocator.free(title);
        const entry = browseTabEntry(tab, title);
        const activate_href = try std.fmt.allocPrint(allocator, "browser://tabs/activate/{d}", .{index});
        defer allocator.free(activate_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, activate_href, "Activate");
        try writer.writeAll(" <strong>");
        try writeHtmlEscaped(writer, entry.title);
        try writer.writeAll("</strong>");
        if (index == active_index) {
            try writer.writeAll(" <small>(Current)</small>");
        }
        try writer.writeAll("<br><small>");
        try writeHtmlEscaped(writer, entry.url);
        try writer.writeAll("</small></li>");
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartClosedTabsSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    shell: *const BrowseShell,
) !void {
    try writeInternalStartSectionTitle(writer, "Recently Closed");
    try writer.print("<p><strong>Available:</strong> {d} ", .{shell.closed_tabs.items.len});
    try writeInternalActionLink(writer, "browser://tabs", "Open tabs page");
    try writer.writeAll("</p>");
    if (shell.closed_tabs.items.len == 0) {
        try writer.writeAll("<p>No closed tabs are available.</p>");
        return;
    }

    var entries = try makeClosedBrowseTabDisplayEntries(allocator, shell.closed_tabs.items, INTERNAL_START_PREVIEW_LIMIT);
    defer entries.deinit(allocator);
    try writer.writeAll("<ul>");
    for (entries.items) |entry| {
        const reopen_href = try std.fmt.allocPrint(allocator, "browser://tabs/reopen-closed/{d}", .{entry.ui_index});
        defer allocator.free(reopen_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, reopen_href, "Reopen");
        try writer.writeAll(" <strong>");
        try writeHtmlEscaped(writer, entry.url);
        try writer.writeAll("</strong> <small>(");
        try writer.print("{d}%)</small></li>", .{entry.zoom_percent});
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartHistorySection(
    allocator: std.mem.Allocator,
    writer: anytype,
    tab: *BrowseTab,
) !void {
    const entries = tab.session.navigation.entries();
    const current_index = if (entries.len == 0) 0 else tab.session.navigation.getCurrentIndex();
    try writeInternalStartSectionTitle(writer, "Recent History");
    try writer.print("<p><strong>Entries:</strong> {d} ", .{entries.len});
    try writeInternalActionLink(writer, "browser://history", "Open history page");
    if (entries.len > 0) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://history/clear-session", "Clear session history");
    }
    try writer.writeAll("</p>");
    if (entries.len == 0) {
        try writer.writeAll("<p>No history entries yet.</p>");
        return;
    }

    try writer.writeAll("<ul>");
    var shown: usize = 0;
    var offset: usize = 0;
    while (offset < entries.len and shown < INTERNAL_START_PREVIEW_LIMIT) : (offset += 1) {
        const index = entries.len - 1 - offset;
        const url = entries[index].url() orelse continue;
        const open_href = try std.fmt.allocPrint(allocator, "browser://history/traverse/{d}", .{index});
        defer allocator.free(open_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, open_href, "Open");
        try writer.writeAll(" ");
        if (index == current_index) {
            try writer.writeAll("<small>(Current)</small> ");
        }
        try writeHtmlEscaped(writer, url);
        try writer.writeAll("</li>");
        shown += 1;
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartBookmarksSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
    tab: *BrowseTab,
) !void {
    var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
    defer deinitOwnedStrings(allocator, &bookmarks);
    try writeInternalStartSectionTitle(writer, "Recent Bookmarks");
    try writer.print("<p><strong>Entries:</strong> {d} ", .{bookmarks.items.len});
    try writeInternalActionLink(writer, "browser://bookmarks", "Open bookmarks page");
    if (browseTabHomepageCandidateUrl(tab) != null) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://bookmarks/add-current", "Add current page");
    }
    try writer.writeAll("</p>");
    if (bookmarks.items.len == 0) {
        try writer.writeAll("<p>No bookmarks saved yet.</p>");
        return;
    }

    try writer.writeAll("<ul>");
    var shown: usize = 0;
    var offset: usize = 0;
    while (offset < bookmarks.items.len and shown < INTERNAL_START_PREVIEW_LIMIT) : (offset += 1) {
        const index = bookmarks.items.len - 1 - offset;
        const bookmark = bookmarks.items[index];
        const open_href = try std.fmt.allocPrint(allocator, "browser://bookmarks/open/{d}", .{index});
        defer allocator.free(open_href);
        const remove_href = try std.fmt.allocPrint(allocator, "browser://bookmarks/remove/{d}", .{index});
        defer allocator.free(remove_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, open_href, "Open");
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, remove_href, "Remove");
        try writer.writeAll(" ");
        try writeHtmlEscaped(writer, bookmark);
        try writer.writeAll("</li>");
        shown += 1;
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartDownloadsSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    downloads: *BrowseDownloads,
) !void {
    try writeInternalStartSectionTitle(writer, "Recent Downloads");
    try writer.print("<p><strong>Entries:</strong> {d} ", .{downloads.entries.items.len});
    try writeInternalActionLink(writer, "browser://downloads", "Open downloads page");
    if (downloads.entries.items.len > 0) {
        try writer.writeAll(" | ");
        try writeInternalActionLink(writer, "browser://downloads/clear", "Clear inactive downloads");
    }
    try writer.writeAll("</p>");
    if (downloads.entries.items.len == 0) {
        try writer.writeAll("<p>No downloads recorded yet.</p>");
        return;
    }

    try writer.writeAll("<ul>");
    var shown: usize = 0;
    var offset: usize = 0;
    while (offset < downloads.entries.items.len and shown < INTERNAL_START_PREVIEW_LIMIT) : (offset += 1) {
        const index = downloads.entries.items.len - 1 - offset;
        const entry = downloads.entries.items[index];
        const status = try formatDownloadStatusLabel(allocator, entry);
        defer allocator.free(status);
        const source_href = try std.fmt.allocPrint(allocator, "browser://downloads/source/{d}", .{index});
        defer allocator.free(source_href);
        const removable = !downloadEntryActive(downloads, index);
        const remove_href = if (removable)
            try std.fmt.allocPrint(allocator, "browser://downloads/remove/{d}", .{index})
        else
            null;
        defer if (remove_href) |href| allocator.free(href);

        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, source_href, "Source");
        if (remove_href) |href| {
            try writer.writeAll(" ");
            try writeInternalActionLink(writer, href, "Remove");
        }
        try writer.writeAll(" <strong>");
        try writeHtmlEscaped(writer, entry.filename);
        try writer.writeAll("</strong> <small>(");
        try writeHtmlEscaped(writer, status);
        try writer.writeAll(")</small></li>");
        shown += 1;
    }
    try writer.writeAll("</ul>");
}

fn writeInternalStartSettingsSection(
    writer: anytype,
    tab: *BrowseTab,
    settings: *const BrowseSettings,
) !void {
    try writeInternalStartSectionTitle(writer, "Settings Snapshot");
    try writer.writeAll("<ul><li>Restore previous session: <strong>");
    try writer.writeAll(if (settings.restore_previous_session) "On" else "Off");
    try writer.writeAll("</strong> ");
    try writeInternalActionLink(writer, "browser://settings/toggle-restore-session", "Toggle");
    try writer.writeAll("</li><li>Script popups: <strong>");
    try writer.writeAll(if (settings.allow_script_popups) "On" else "Off");
    try writer.writeAll("</strong> ");
    try writeInternalActionLink(writer, "browser://settings/toggle-script-popups", "Toggle");
    try writer.writeAll("</li><li>Default zoom: <strong>");
    try writer.print("{d}%</strong> ", .{settings.default_zoom_percent});
    try writeInternalActionLink(writer, "browser://settings/default-zoom/out", "-");
    try writer.writeAll(" ");
    try writeInternalActionLink(writer, "browser://settings/default-zoom/reset", "Reset");
    try writer.writeAll(" ");
    try writeInternalActionLink(writer, "browser://settings/default-zoom/in", "+");
    try writer.writeAll("</li><li>Homepage: <strong>");
    try writeHtmlEscaped(writer, settings.homeUrl() orelse "(none)");
    try writer.writeAll("</strong>");
    if (browseTabHomepageCandidateUrl(tab) != null) {
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, "browser://settings/homepage/set-current", "Use current site");
    }
    if (settings.homeUrl() != null) {
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, "browser://settings/homepage/clear", "Clear");
    }
    try writer.writeAll("</li><li>");
    try writeInternalActionLink(writer, "browser://settings", "Open full settings page");
    try writer.writeAll("</li></ul>");
}

fn writeInternalStartPage(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    tab_index: usize,
    settings: *const BrowseSettings,
    downloads: *BrowseDownloads,
) !void {
    if (tab_index >= shell.tabs.items.len) {
        return;
    }
    const tab = shell.tabs.items[tab_index];
    const closed_tabs_count = shell.closed_tabs.items.len;

    try writeInternalPageStart(
        writer,
        "Browser Start",
        "browser://start",
        "Internal browser shell hub for headed browse mode.",
    );
    try writeInternalShellNav(writer, .start);
    try writer.writeAll("<p>Browser shell dashboard with live previews and direct actions.</p>");
    try writeInternalStartQuickActions(writer, tab, settings, downloads, closed_tabs_count);
    try writeInternalStartCurrentTabStatusSection(allocator, writer, app_dir_path, shell, tab_index, downloads);
    try writeInternalStartSettingsSection(writer, tab, settings);
    try writeInternalStartRecentTabsSection(allocator, writer, app_dir_path, shell, downloads);
    try writeInternalStartClosedTabsSection(allocator, writer, shell);
    try writeInternalStartHistorySection(allocator, writer, tab);
    try writeInternalStartBookmarksSection(allocator, writer, app_dir_path, tab);
    try writeInternalStartDownloadsSection(allocator, writer, downloads);
    try writeInternalPageEnd(writer);
}

fn writeInternalErrorPage(writer: anytype, tab: *BrowseTab, settings: *const BrowseSettings) !void {
    const error_state = &tab.error_state;
    const title = browseErrorTitle(error_state.kind);
    try writeInternalPageStart(
        writer,
        title,
        "browser://error",
        browseErrorSummary(error_state.kind),
    );
    try writeInternalShellNavNoSelection(writer);
    try writer.writeAll("<p><strong>Status:</strong> Failed navigation in headed browse mode.</p>");
    try writer.writeAll("<ul><li><strong>Reason:</strong> ");
    try writeHtmlEscaped(writer, browseErrorDetailLabel(error_state.kind, error_state.detail));
    try writer.writeAll("</li><li><strong>Requested value:</strong> <code>");
    try writeHtmlEscaped(writer, if (trimmedOrNull(error_state.display_value)) |value| value else "(empty)");
    try writer.writeAll("</code></li>");
    if (trimmedOrNull(error_state.retry_value)) |retry_value| {
        try writer.writeAll("<li><strong>Retry target:</strong> <code>");
        try writeHtmlEscaped(writer, retry_value);
        try writer.writeAll("</code></li>");
    }
    try writer.writeAll("</ul><p>");
    try writeInternalActionLink(writer, "browser://error/retry", "Retry");
    try writer.writeAll(" | ");
    try writeInternalActionLink(writer, "browser://error/home", "Open home");
    try writer.writeAll(" | ");
    try writeInternalActionLink(writer, "browser://error/start", "Open start");
    try writer.writeAll(" | ");
    try writeInternalActionLink(writer, "browser://tabs", "Open tabs page");
    try writer.writeAll("</p>");
    if (settings.homeUrl()) |home_url| {
        try writer.writeAll("<p><strong>Configured home:</strong> <code>");
        try writeHtmlEscaped(writer, home_url);
        try writer.writeAll("</code></p>");
    } else {
        try writer.writeAll("<p><strong>Configured home:</strong> (none, home will fall back to Start)</p>");
    }
    try writer.writeAll("<p>Tip: use Ctrl+L to correct the address directly, or Retry after a temporary network failure.</p>");
    try writeInternalPageEnd(writer);
}

fn popupSourceLabel(source: PopupSource) []const u8 {
    return switch (source) {
        .none => "none",
        .anchor => "anchor",
        .form => "form",
        .script => "script",
    };
}

fn writeInternalTabsPage(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
    shell: *const BrowseShell,
    downloads: *BrowseDownloads,
) !void {
    const active_index = if (shell.tabs.items.len == 0)
        @as(usize, 0)
    else
        normalizeActiveTabIndex(shell.active_tab_index.*, shell.tabs.items.len);
    const title = try std.fmt.allocPrint(allocator, "Browser Tabs ({d})", .{shell.tabs.items.len});
    defer allocator.free(title);
    try writeInternalPageStart(
        writer,
        title,
        "browser://tabs",
        "Current tabs, popup targets, and recovery actions for headed browse mode.",
    );
    try writeInternalShellNav(writer, .tabs);
    try writer.print("<p><strong>Open tabs:</strong> {d} | <strong>Closed tabs available:</strong> {d}</p>", .{
        shell.tabs.items.len,
        shell.closed_tabs.items.len,
    });
    try writer.writeAll("<p>");
    try writeInternalActionLink(writer, "browser://tabs/new", "New tab");
    try writer.writeAll(" | ");
    try writeInternalActionLink(writer, "browser://tabs/reopen-closed", "Reopen closed");
    try writer.writeAll("</p>");
    if (shell.tabs.items.len == 0) {
        try writer.writeAll("<p>No tabs are currently open.</p>");
        try writeInternalPageEnd(writer);
        return;
    }
    try writer.writeAll("<ol>");
    for (shell.tabs.items, 0..) |tab, index| {
        const tab_title = try browseTabEntryTitle(
            allocator,
            app_dir_path,
            shell.tabs.items,
            index,
            downloads,
        );
        const entry = browseTabEntry(tab, tab_title);
        const activate_href = try std.fmt.allocPrint(allocator, "browser://tabs/activate/{d}", .{index});
        defer allocator.free(activate_href);
        const duplicate_href = try std.fmt.allocPrint(allocator, "browser://tabs/duplicate/{d}", .{index});
        defer allocator.free(duplicate_href);
        const reload_href = try std.fmt.allocPrint(allocator, "browser://tabs/reload/{d}", .{index});
        defer allocator.free(reload_href);
        const close_href = try std.fmt.allocPrint(allocator, "browser://tabs/close/{d}", .{index});
        defer allocator.free(close_href);

        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, activate_href, "Activate");
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, duplicate_href, "Duplicate");
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, reload_href, "Reload");
        try writer.writeAll(" ");
        if (shell.tabs.items.len > 1) {
            try writeInternalActionLink(writer, close_href, "Close");
        } else {
            try writer.writeAll("<span>Keep</span>");
        }
        try writer.writeAll("<br><strong>");
        try writeHtmlEscaped(writer, entry.title);
        try writer.writeAll("</strong>");
        if (index == active_index) {
            try writer.writeAll(" <strong>(Current)</strong>");
        }
        if (entry.is_loading) {
            try writer.writeAll(" <strong>(Loading)</strong>");
        }
        if (tab.error_state.hasValue()) {
            try writer.writeAll(" <strong>(Error)</strong>");
        }
        if (entry.target_name.len > 0) {
            try writer.writeAll(" <small>target=");
            try writeHtmlEscaped(writer, entry.target_name);
            try writer.writeAll("</small>");
        }
        if (entry.popup_source != .none) {
            try writer.writeAll(" <small>popup=");
            try writeHtmlEscaped(writer, popupSourceLabel(entry.popup_source));
            try writer.writeAll("</small>");
        }
        try writer.writeAll("<br><small>");
        try writeHtmlEscaped(writer, entry.url);
        try writer.writeAll("</small>");
        if (tab.error_state.hasValue()) {
            try writer.writeAll("<br><small>Reason: ");
            try writeHtmlEscaped(writer, browseErrorDetailLabel(tab.error_state.kind, tab.error_state.detail));
            try writer.writeAll("</small>");
            if (index == active_index) {
                try writer.writeAll(" <small>(");
                try writeInternalActionLink(writer, "browser://error", "details");
                try writer.writeAll(")</small>");
            }
        }
        try writer.writeAll("</li>");
        allocator.free(tab_title);
    }
    try writer.writeAll("</ol>");
    try writeInternalStartSectionTitle(writer, "Closed Tabs");
    try writer.print("<p><strong>Available:</strong> {d} ", .{shell.closed_tabs.items.len});
    try writeInternalActionLink(writer, "browser://tabs/reopen-closed", "Reopen latest");
    try writer.writeAll("</p>");
    if (shell.closed_tabs.items.len == 0) {
        try writer.writeAll("<p>No closed tabs available.</p>");
        try writeInternalPageEnd(writer);
        return;
    }
    var closed_entries = try makeClosedBrowseTabDisplayEntries(allocator, shell.closed_tabs.items, shell.closed_tabs.items.len);
    defer closed_entries.deinit(allocator);
    try writer.writeAll("<ol>");
    for (closed_entries.items) |entry| {
        const reopen_href = try std.fmt.allocPrint(allocator, "browser://tabs/reopen-closed/{d}", .{entry.ui_index});
        defer allocator.free(reopen_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, reopen_href, "Reopen");
        try writer.writeAll(" <strong>");
        try writeHtmlEscaped(writer, entry.url);
        try writer.writeAll("</strong> <small>(");
        try writer.print("{d}%)</small></li>", .{entry.zoom_percent});
    }
    try writer.writeAll("</ol>");
    try writeInternalPageEnd(writer);
}

fn writeInternalHistoryPage(allocator: std.mem.Allocator, writer: anytype, tab: *BrowseTab) !void {
    const entries = tab.session.navigation.entries();
    const current_index = if (entries.len == 0) 0 else tab.session.navigation.getCurrentIndex();
    const title = try std.fmt.allocPrint(allocator, "Browser History ({d})", .{entries.len});
    defer allocator.free(title);
    try writeInternalPageStart(
        writer,
        title,
        "browser://history",
        "Current tab navigation entries.",
    );
    try writeInternalShellNav(writer, .history);
    try writer.print("<p><strong>Entries:</strong> {d}</p><p>", .{entries.len});
    try writeInternalActionLink(writer, "browser://history/clear-session", "Clear session history");
    try writer.writeAll("</p>");
    if (entries.len == 0) {
        try writer.writeAll("<p>No history entries yet.</p>");
        try writeInternalPageEnd(writer);
        return;
    }
    try writer.writeAll("<ol>");
    for (entries, 0..) |entry, index| {
        const url = entry.url() orelse continue;
        const traverse_href = try std.fmt.allocPrint(allocator, "browser://history/traverse/{d}", .{index});
        defer allocator.free(traverse_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, traverse_href, "Open");
        try writer.writeAll(" ");
        if (index == current_index) {
            try writer.writeAll("<strong>Current</strong> ");
        }
        try writeHtmlEscaped(writer, url);
        try writer.writeAll("</li>");
    }
    try writer.writeAll("</ol>");
    try writeInternalPageEnd(writer);
}

fn writeInternalBookmarksPage(
    allocator: std.mem.Allocator,
    writer: anytype,
    app_dir_path: ?[]const u8,
) !void {
    var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
    defer deinitOwnedStrings(allocator, &bookmarks);
    const title = try std.fmt.allocPrint(allocator, "Browser Bookmarks ({d})", .{bookmarks.items.len});
    defer allocator.free(title);
    try writeInternalPageStart(
        writer,
        title,
        "browser://bookmarks",
        "Persisted bookmark entries from the current browser profile.",
    );
    try writeInternalShellNav(writer, .bookmarks);
    try writer.print("<p><strong>Entries:</strong> {d}</p><p>", .{bookmarks.items.len});
    try writeInternalActionLink(writer, "browser://bookmarks/add-current", "Add current page");
    try writer.writeAll("</p>");
    if (bookmarks.items.len == 0) {
        try writer.writeAll("<p>No bookmarks saved yet. Press Ctrl+D on a page first.</p>");
        try writeInternalPageEnd(writer);
        return;
    }
    try writer.writeAll("<ol>");
    for (bookmarks.items, 0..) |bookmark, index| {
        const open_href = try std.fmt.allocPrint(allocator, "browser://bookmarks/open/{d}", .{index});
        defer allocator.free(open_href);
        const remove_href = try std.fmt.allocPrint(allocator, "browser://bookmarks/remove/{d}", .{index});
        defer allocator.free(remove_href);
        try writer.writeAll("<li>");
        try writeInternalActionLink(writer, remove_href, "Remove");
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, open_href, "Open");
        try writer.writeAll(" ");
        try writeHtmlEscaped(writer, bookmark);
        try writer.writeAll("</li>");
    }
    try writer.writeAll("</ol>");
    try writeInternalPageEnd(writer);
}

fn writeInternalDownloadsPage(
    allocator: std.mem.Allocator,
    writer: anytype,
    downloads: *BrowseDownloads,
) !void {
    const title = try std.fmt.allocPrint(allocator, "Browser Downloads ({d})", .{downloads.entries.items.len});
    defer allocator.free(title);
    try writeInternalPageStart(
        writer,
        title,
        "browser://downloads",
        "Download history for the current browser profile.",
    );
    try writeInternalShellNav(writer, .downloads);
    try writer.print("<p><strong>Entries:</strong> {d}</p><p>", .{downloads.entries.items.len});
    try writeInternalActionLink(writer, "browser://downloads/clear", "Clear inactive downloads");
    try writer.writeAll("</p>");
    if (downloads.entries.items.len == 0) {
        try writer.writeAll("<p>No downloads recorded yet.</p>");
        try writeInternalPageEnd(writer);
        return;
    }
    try writer.writeAll("<ol>");
    for (downloads.entries.items, 0..) |entry, index| {
        const status = try formatDownloadStatusLabel(allocator, entry);
        defer allocator.free(status);
        try writer.writeAll("<li>");
        if (!downloadEntryActive(downloads, index)) {
            const remove_href = try std.fmt.allocPrint(allocator, "browser://downloads/remove/{d}", .{index});
            defer allocator.free(remove_href);
            try writeInternalActionLink(writer, remove_href, "Remove");
            try writer.writeAll(" ");
        }
        const source_href = try std.fmt.allocPrint(allocator, "browser://downloads/source/{d}", .{index});
        defer allocator.free(source_href);
        try writeInternalActionLink(writer, source_href, "Source");
        try writer.writeAll("<br><strong>");
        try writeHtmlEscaped(writer, entry.filename);
        try writer.writeAll("</strong> - ");
        try writeHtmlEscaped(writer, status);
        try writer.writeAll("<br><small>");
        try writeHtmlEscaped(writer, entry.path);
        try writer.writeAll("</small></li>");
    }
    try writer.writeAll("</ol>");
    try writeInternalPageEnd(writer);
}

fn writeInternalSettingsPage(writer: anytype, tab: *BrowseTab, settings: *const BrowseSettings) !void {
    try writeInternalPageStart(
        writer,
        "Browser Settings",
        "browser://settings",
        "Persisted shell settings for headed browse mode.",
    );
    try writeInternalShellNav(writer, .settings);
    try writer.writeAll("<ul><li>Restore previous session: <strong>");
    try writer.writeAll(if (settings.restore_previous_session) "On" else "Off");
    try writer.writeAll("</strong> ");
    try writeInternalActionLink(writer, "browser://settings/toggle-restore-session", "Toggle");
    try writer.writeAll("</li><li>Script popups: <strong>");
    try writer.writeAll(if (settings.allow_script_popups) "On" else "Off");
    try writer.writeAll("</strong> ");
    try writeInternalActionLink(writer, "browser://settings/toggle-script-popups", "Toggle");
    try writer.writeAll("</li><li>Default zoom: <strong>");
    try writer.print("{d}%</strong> ", .{settings.default_zoom_percent});
    try writeInternalActionLink(writer, "browser://settings/default-zoom/out", "-");
    try writer.writeAll(" ");
    try writeInternalActionLink(writer, "browser://settings/default-zoom/reset", "Reset");
    try writer.writeAll(" ");
    try writeInternalActionLink(writer, "browser://settings/default-zoom/in", "+");
    try writer.writeAll("</li><li>Homepage: <strong>");
    try writeHtmlEscaped(writer, settings.homeUrl() orelse "(none)");
    try writer.writeAll("</strong>");
    if (browseTabHomepageCandidateUrl(tab)) |candidate| {
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, "browser://settings/homepage/set-current", "Use current site");
        try writer.writeAll(" <small>(");
        try writeHtmlEscaped(writer, candidate);
        try writer.writeAll(")</small>");
    }
    if (settings.homeUrl() != null) {
        try writer.writeAll(" ");
        try writeInternalActionLink(writer, "browser://settings/homepage/clear", "Clear");
    }
    try writer.writeAll("</li></ul>");
    try writeInternalPageEnd(writer);
}

fn writeHtmlEscaped(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn loadPersistedBookmarks(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
) std.ArrayListUnmanaged([]u8) {
    var bookmarks: std.ArrayListUnmanaged([]u8) = .{};
    errdefer deinitOwnedStrings(allocator, &bookmarks);

    const dir_path = app_dir_path orelse return bookmarks;
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return bookmarks;
    defer dir.close();

    const file = dir.openFile(BROWSE_BOOKMARKS_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return bookmarks,
        else => return bookmarks,
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 64) catch return bookmarks;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n\t ");
        if (line.len == 0) {
            continue;
        }
        if (indexOfOwnedString(bookmarks.items, line) != null) {
            continue;
        }
        const owned = allocator.dupe(u8, line) catch break;
        bookmarks.append(allocator, owned) catch {
            allocator.free(owned);
            break;
        };
    }
    return bookmarks;
}

fn savePersistedBookmarks(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    bookmarks: []const []const u8,
) void {
    const dir_path = app_dir_path orelse return;
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();

    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    for (bookmarks) |bookmark| {
        const trimmed = std.mem.trim(u8, bookmark, "\r\n\t ");
        if (trimmed.len == 0) {
            continue;
        }
        buf.writer.print("{s}\n", .{trimmed}) catch return;
    }

    dir.writeFile(.{
        .sub_path = BROWSE_BOOKMARKS_FILE,
        .data = buf.written(),
    }) catch {};
}

fn removePersistedBookmarkAtIndex(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    index: usize,
) bool {
    var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
    defer deinitOwnedStrings(allocator, &bookmarks);

    if (index >= bookmarks.items.len) {
        return false;
    }

    const removed = bookmarks.orderedRemove(index);
    allocator.free(removed);
    savePersistedBookmarks(allocator, app_dir_path, bookmarks.items);
    return true;
}

fn addPersistedBookmark(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    raw_url: []const u8,
) bool {
    const trimmed = std.mem.trim(u8, raw_url, "\r\n\t ");
    if (trimmed.len == 0) {
        return false;
    }

    var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
    defer deinitOwnedStrings(allocator, &bookmarks);

    if (indexOfOwnedString(bookmarks.items, trimmed) != null) {
        return false;
    }

    const owned = allocator.dupe(u8, trimmed) catch return false;
    bookmarks.append(allocator, owned) catch {
        allocator.free(owned);
        return false;
    };
    savePersistedBookmarks(allocator, app_dir_path, bookmarks.items);
    return true;
}

fn loadPersistedBookmarkAtIndex(
    allocator: std.mem.Allocator,
    app_dir_path: ?[]const u8,
    index: usize,
) ?[]u8 {
    var bookmarks = loadPersistedBookmarks(allocator, app_dir_path);
    defer deinitOwnedStrings(allocator, &bookmarks);

    if (index >= bookmarks.items.len) {
        return null;
    }

    return allocator.dupe(u8, bookmarks.items[index]) catch null;
}

fn loadDownloadUrlAtIndex(
    allocator: std.mem.Allocator,
    downloads: *BrowseDownloads,
    index: usize,
) ?[]u8 {
    if (index >= downloads.entries.items.len) {
        return null;
    }

    return allocator.dupe(u8, downloads.entries.items[index].url) catch null;
}

fn deinitOwnedStrings(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged([]u8)) void {
    while (items.items.len > 0) {
        const owned = items.items[items.items.len - 1];
        items.items.len -= 1;
        allocator.free(owned);
    }
    items.deinit(allocator);
}

fn indexOfOwnedString(items: []const []u8, needle: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, needle)) {
            return index;
        }
    }
    return null;
}

fn presentPage(
    app: *App,
    page: *Page,
    last_presented_hash: *u64,
    committed_surface: *CommittedBrowseSurface,
    zoom_percent: i32,
    title_override: ?[]const u8,
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
        const title = title_override orelse
            trimmedOrNull(committed_surface.title) orelse
            trimmedOrNull(page.url) orelse
            "Lightpanda Browser";
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

    const title = title_override orelse ((try page.getTitle()) orelse "");
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
    try std.testing.expectEqual(@as(i32, 110), applyZoomCommand(100, 100, .zoom_in));
    try std.testing.expectEqual(@as(i32, 90), applyZoomCommand(100, 100, .zoom_out));
    try std.testing.expectEqual(@as(i32, 120), applyZoomCommand(180, 120, .zoom_reset));
    try std.testing.expectEqual(@as(i32, 300), applyZoomCommand(300, 100, .zoom_in));
    try std.testing.expectEqual(@as(i32, 30), applyZoomCommand(30, 100, .zoom_out));
}

test "parseBrowseSettings restores session, popup policy, zoom, and homepage" {
    var settings = try parseBrowseSettings(
        std.testing.allocator,
        "lightpanda-browse-settings-v1\nrestore_previous_session\t0\nallow_script_popups\t0\ndefault_zoom_percent\t130\nhomepage_url\thttp://home.test/\n",
    );
    defer settings.deinit(std.testing.allocator);

    try std.testing.expect(!settings.restore_previous_session);
    try std.testing.expect(!settings.allow_script_popups);
    try std.testing.expectEqual(@as(i32, 130), settings.default_zoom_percent);
    try std.testing.expectEqualStrings("http://home.test/", settings.homepage_url);
}

test "applyDefaultZoomCommand clamps and resets default zoom" {
    try std.testing.expectEqual(@as(i32, 110), applyDefaultZoomCommand(100, .settings_default_zoom_in));
    try std.testing.expectEqual(@as(i32, 90), applyDefaultZoomCommand(100, .settings_default_zoom_out));
    try std.testing.expectEqual(@as(i32, 100), applyDefaultZoomCommand(180, .settings_default_zoom_reset));
    try std.testing.expectEqual(@as(i32, 300), applyDefaultZoomCommand(300, .settings_default_zoom_in));
    try std.testing.expectEqual(@as(i32, 30), applyDefaultZoomCommand(30, .settings_default_zoom_out));
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

test "targetAlwaysOpensFreshTab only matches _blank" {
    try std.testing.expect(targetAlwaysOpensFreshTab("_blank"));
    try std.testing.expect(targetAlwaysOpensFreshTab(" _BLANK "));
    try std.testing.expect(!targetAlwaysOpensFreshTab(""));
    try std.testing.expect(!targetAlwaysOpensFreshTab("report"));
}

test "findBrowseTabIndexByTargetName ignores blank and matches named targets" {
    var one = BrowseTab{
        .http_client = undefined,
        .notification = undefined,
        .browser = undefined,
        .session = undefined,
        .target_name = @constCast("report"),
    };
    var two = BrowseTab{
        .http_client = undefined,
        .notification = undefined,
        .browser = undefined,
        .session = undefined,
        .target_name = @constCast("audit"),
    };
    const tabs = [_]*BrowseTab{ &one, &two };
    try std.testing.expectEqual(@as(?usize, 0), findBrowseTabIndexByTargetName(&tabs, "report"));
    try std.testing.expectEqual(@as(?usize, 1), findBrowseTabIndexByTargetName(&tabs, " AUDIT "));
    try std.testing.expectEqual(@as(?usize, null), findBrowseTabIndexByTargetName(&tabs, "_blank"));
}

test "openOrReuseTargetedBrowseTab reuses existing named tab" {
    var tabs: std.ArrayListUnmanaged(*BrowseTab) = .{};
    defer deinitBrowseTabs(testing.test_app.allocator, &tabs);

    var active_tab_index: usize = 0;
    const source = try createBrowseTab(testing.test_app, null, 100, true);
    try appendBrowseTab(testing.test_app.allocator, &tabs, source, &active_tab_index, true);

    const first_url = "http://127.0.0.1:9582/src/browser/tests/page/popup-target-result.html";
    const second_url = "http://127.0.0.1:9582/src/browser/tests/page/popup-target-post.html";
    const opts: Page.NavigateOpts = .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    };

    try openOrReuseTargetedBrowseTab(
        testing.test_app,
        &tabs,
        &active_tab_index,
        true,
        100,
        first_url,
        opts,
        "report",
        true,
        .script,
    );
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), active_tab_index);
    try std.testing.expectEqualStrings("report", tabs.items[1].target_name);
    try std.testing.expectEqual(PopupSource.script, tabs.items[1].popup_source);
    _ = tabs.items[1].session.wait(2000);

    active_tab_index = 0;
    try openOrReuseTargetedBrowseTab(
        testing.test_app,
        &tabs,
        &active_tab_index,
        true,
        100,
        second_url,
        opts,
        "report",
        true,
        .form,
    );
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), active_tab_index);
    try std.testing.expectEqualStrings("report", tabs.items[1].target_name);
    try std.testing.expectEqual(PopupSource.form, tabs.items[1].popup_source);
    _ = tabs.items[1].session.wait(2000);

    const target_page = tabs.items[1].session.currentPage() orelse return error.TestPageMissing;
    try std.testing.expectEqualStrings(second_url, target_page.url);
}

test "openOrReuseTargetedBrowseTab resets live named script popup tab before reuse" {
    var tabs: std.ArrayListUnmanaged(*BrowseTab) = .{};
    defer deinitBrowseTabs(testing.test_app.allocator, &tabs);

    var active_tab_index: usize = 0;
    const source = try createBrowseTab(testing.test_app, null, 100, true);
    try appendBrowseTab(testing.test_app.allocator, &tabs, source, &active_tab_index, true);

    const first_url = "http://127.0.0.1:9582/src/browser/tests/page/popup-target-result.html?from=script-one";
    const second_url = "http://127.0.0.1:9582/src/browser/tests/page/popup-target-post.html?from=script-two";
    const opts: Page.NavigateOpts = .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    };

    try openOrReuseTargetedBrowseTab(
        testing.test_app,
        &tabs,
        &active_tab_index,
        true,
        100,
        first_url,
        opts,
        "report",
        true,
        .script,
    );
    _ = tabs.items[1].session.wait(2000);

    const first_page = tabs.items[1].session.currentPage() orelse return error.TestPageMissing;
    try std.testing.expectEqualStrings(first_url, first_page.url);

    active_tab_index = 0;
    try openOrReuseTargetedBrowseTab(
        testing.test_app,
        &tabs,
        &active_tab_index,
        true,
        100,
        second_url,
        opts,
        "report",
        true,
        .script,
    );
    _ = tabs.items[1].session.wait(2000);

    const second_page = tabs.items[1].session.currentPage() orelse return error.TestPageMissing;
    try std.testing.expect(first_page != second_page);
    try std.testing.expectEqualStrings(second_url, second_page.url);
}

test "sanitizeDownloadFileName replaces invalid windows characters" {
    const sanitized = try sanitizeDownloadFileName(std.testing.allocator, "report<>:\\/|?*.txt");
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings("report________.txt", sanitized);
}

test "parseSavedDownloadEntry restores interrupted active downloads" {
    var entry = try parseSavedDownloadEntry(
        std.testing.allocator,
        "1\t12\t20\t1\texample.txt\tC:\\tmp\\example.txt\thttp://example.test/file.txt\tDownloading",
    );
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(BrowseDownloadStatus.interrupted, entry.status);
    try std.testing.expectEqual(@as(usize, 12), entry.bytes_received);
    try std.testing.expectEqual(@as(usize, 20), entry.total_bytes);
    try std.testing.expect(entry.has_total_bytes);
    try std.testing.expectEqualStrings("example.txt", entry.filename);
}

test "normalizeBrowseUrl rejects blank input" {
    try std.testing.expect((try normalizeBrowseUrl(std.testing.allocator, "   ")) == null);
}

test "normalizeBrowseUrl rejects search-like input without a scheme" {
    try std.testing.expectError(error.InvalidUrl, normalizeBrowseUrl(std.testing.allocator, "two words"));
}

test "parseInternalBrowsePage recognizes browser aliases" {
    try std.testing.expectEqual(@as(?InternalBrowsePage, .start), parseInternalBrowsePage("browser://start"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .error_page), parseInternalBrowsePage("browser://error"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .tabs), parseInternalBrowsePage("browser://tabs"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .history), parseInternalBrowsePage("browser://history"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .bookmarks), parseInternalBrowsePage("browser://bookmarks/"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .downloads), parseInternalBrowsePage("browser://downloads?recent=1"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .settings), parseInternalBrowsePage("browser://settings#shell"));
    try std.testing.expectEqual(@as(?InternalBrowsePage, null), parseInternalBrowsePage("https://example.com"));
}

test "parseInternalBrowseRoute recognizes interactive browser page actions" {
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .page = .start },
        parseInternalBrowseRoute("browser://start").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .page = .error_page },
        parseInternalBrowseRoute("browser://error").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .error_retry },
        parseInternalBrowseRoute("browser://error/retry").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .home },
        parseInternalBrowseRoute("browser://error/home").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .page_start },
        parseInternalBrowseRoute("browser://error/start").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .page = .tabs },
        parseInternalBrowseRoute("browser://tabs").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .tab_new },
        parseInternalBrowseRoute("browser://tabs/new").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .tab_reopen_closed },
        parseInternalBrowseRoute("browser://tabs/reopen-closed").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .tab_reopen_closed_index = 1 } },
        parseInternalBrowseRoute("browser://tabs/reopen-closed/1").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .tab_activate = 2 } },
        parseInternalBrowseRoute("browser://tabs/activate/2").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .tab_duplicate_index = 1 } },
        parseInternalBrowseRoute("browser://tabs/duplicate/1").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .tab_reload_index = 0 } },
        parseInternalBrowseRoute("browser://tabs/reload/0").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .tab_close = 3 } },
        parseInternalBrowseRoute("browser://tabs/close/3").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .history_traverse = 2 } },
        parseInternalBrowseRoute("browser://history/traverse/2").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .history_clear_session },
        parseInternalBrowseRoute("browser://history/clear-session").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .bookmark_add_current },
        parseInternalBrowseRoute("browser://bookmarks/add-current").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .bookmark_open = 3 } },
        parseInternalBrowseRoute("browser://bookmarks/open/3").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .bookmark_remove = 1 } },
        parseInternalBrowseRoute("browser://bookmarks/remove/1").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .download_source = 4 } },
        parseInternalBrowseRoute("browser://downloads/source/4").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .{ .download_remove = 0 } },
        parseInternalBrowseRoute("browser://downloads/remove/0").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .download_clear },
        parseInternalBrowseRoute("browser://downloads/clear").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .settings_toggle_script_popups },
        parseInternalBrowseRoute("browser://settings/toggle-script-popups").?,
    );
    try std.testing.expectEqualDeep(
        InternalBrowseRoute{ .command = .settings_set_homepage_to_current },
        parseInternalBrowseRoute("browser://settings/homepage/set-current").?,
    );
}

test "writeInternalShellNav marks current section and links other shell pages" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try writeInternalShellNav(&buf.writer, .downloads);

    const html = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>Downloads</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://start") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://history") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://bookmarks") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://settings") != null);
}

test "hashInternalTabsPageState changes when active tab changes" {
    var session_one: Session = undefined;
    session_one.page = null;
    var session_two: Session = undefined;
    session_two.page = null;
    var tab_one: BrowseTab = undefined;
    var tab_two: BrowseTab = undefined;
    tab_one.session = &session_one;
    tab_one.committed_surface = .{};
    tab_one.error_state = .{};
    tab_one.target_name = &.{};
    tab_one.popup_source = .none;
    tab_one.zoom_percent = 100;
    tab_two.session = &session_two;
    tab_two.committed_surface = .{};
    tab_two.error_state = .{};
    tab_two.target_name = &.{};
    tab_two.popup_source = .none;
    tab_two.zoom_percent = 125;

    var tab_items = [_]*BrowseTab{ &tab_one, &tab_two };
    var tabs = std.ArrayListUnmanaged(*BrowseTab){
        .items = tab_items[0..],
        .capacity = tab_items.len,
    };
    var closed_item = [_]ClosedBrowseTab{.{
        .url = @constCast("about:blank"),
        .zoom_percent = 100,
    }};
    var closed_tabs = std.ArrayListUnmanaged(ClosedBrowseTab){
        .items = closed_item[0..],
        .capacity = closed_item.len,
    };
    var active_index: usize = 1;
    var shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_index,
    };

    const first_hash = hashInternalTabsPageState(&shell);
    active_index = 1;
    const second_hash = hashInternalTabsPageState(&shell);
    try std.testing.expect(first_hash != second_hash);
}

test "hashInternalTabsPageState changes when closed tab content changes" {
    var session: Session = undefined;
    session.page = null;
    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.committed_surface = .{};
    tab.error_state = .{};
    tab.target_name = &.{};
    tab.popup_source = .none;
    tab.zoom_percent = 100;

    var tab_items = [_]*BrowseTab{&tab};
    var tabs = std.ArrayListUnmanaged(*BrowseTab){
        .items = tab_items[0..],
        .capacity = tab_items.len,
    };
    var closed_items = [_]ClosedBrowseTab{
        .{ .url = @constCast("http://closed-one.test/"), .zoom_percent = 100 },
        .{ .url = @constCast("http://closed-two.test/"), .zoom_percent = 110 },
    };
    var closed_tabs = std.ArrayListUnmanaged(ClosedBrowseTab){
        .items = closed_items[0..],
        .capacity = closed_items.len,
    };
    var active_index: usize = 1;
    const shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_index,
    };

    const first_hash = hashInternalTabsPageState(&shell);
    closed_tabs.items[1].url = @constCast("http://closed-three.test/");
    const second_hash = hashInternalTabsPageState(&shell);
    try std.testing.expect(first_hash != second_hash);
}

test "writeInternalTabsPage includes indexed actions and popup metadata" {
    var session_one: Session = undefined;
    session_one.page = null;
    var session_two: Session = undefined;
    session_two.page = null;
    var tab_one: BrowseTab = undefined;
    var tab_two: BrowseTab = undefined;
    tab_one.session = &session_one;
    tab_one.committed_surface = .{};
    tab_one.error_state = .{};
    tab_one.zoom_percent = 100;
    tab_one.target_name = @constCast("report");
    tab_one.popup_source = .script;
    tab_two.session = &session_two;
    tab_two.committed_surface = .{};
    tab_two.error_state = .{};
    try tab_two.error_state.replace(std.testing.allocator, .navigation_failed, "http://failed.test/", "http://failed.test/", "CouldntConnect");
    defer tab_two.error_state.deinit(std.testing.allocator);
    tab_two.zoom_percent = 125;
    tab_two.target_name = &.{};
    tab_two.popup_source = .none;

    var tab_items = [_]*BrowseTab{ &tab_one, &tab_two };
    var tabs = std.ArrayListUnmanaged(*BrowseTab){
        .items = tab_items[0..],
        .capacity = tab_items.len,
    };
    var closed_item = [_]ClosedBrowseTab{
        .{
            .url = @constCast("http://closed-a.test/"),
            .zoom_percent = 100,
        },
        .{
            .url = @constCast("http://closed-b.test/"),
            .zoom_percent = 125,
        },
    };
    var closed_tabs = std.ArrayListUnmanaged(ClosedBrowseTab){
        .items = closed_item[0..],
        .capacity = closed_item.len,
    };
    var active_index: usize = 1;
    const shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_index,
    };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    var downloads = BrowseDownloads{ .allocator = std.testing.allocator };
    defer downloads.deinit(null);
    try writeInternalTabsPage(std.testing.allocator, &buf.writer, null, &shell, &downloads);

    const html = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "Browser Tabs (2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/duplicate/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/reopen-closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/reopen-closed/0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/reopen-closed/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "target=report") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "popup=script") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "(Error)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Reason: CouldntConnect") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://error") != null);
}

test "makeClosedBrowseTabDisplayEntries returns newest first ui ordering" {
    const closed_tabs = [_]ClosedBrowseTab{
        .{ .url = @constCast("http://first.test/"), .zoom_percent = 100 },
        .{ .url = @constCast("http://second.test/"), .zoom_percent = 110 },
        .{ .url = @constCast("http://third.test/"), .zoom_percent = 120 },
    };

    var entries = try makeClosedBrowseTabDisplayEntries(std.testing.allocator, closed_tabs[0..], 3);
    defer entries.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), entries.items[0].ui_index);
    try std.testing.expectEqualStrings("http://third.test/", entries.items[0].url);
    try std.testing.expectEqual(@as(i32, 120), entries.items[0].zoom_percent);
    try std.testing.expectEqual(@as(usize, 1), entries.items[1].ui_index);
    try std.testing.expectEqualStrings("http://second.test/", entries.items[1].url);
    try std.testing.expectEqual(@as(usize, 2), entries.items[2].ui_index);
    try std.testing.expectEqualStrings("http://first.test/", entries.items[2].url);
}

test "writeInternalStartPage includes preview sections and quick actions" {
    const NavigationHistoryEntry = @import("browser/webapi/navigation/NavigationHistoryEntry.zig");
    const rel_dir = ".zig-cache/tmp/internal-start-page-preview-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);
    savePersistedBookmarks(std.testing.allocator, abs_dir, &.{ "http://bookmark-one.test/", "http://bookmark-two.test/" });

    var session: Session = undefined;
    session.page = null;
    session.navigation = .{ ._proto = undefined };
    const history_one = try std.testing.allocator.create(NavigationHistoryEntry);
    errdefer std.testing.allocator.destroy(history_one);
    history_one.* = .{
        ._id = "history-one",
        ._key = "history-one",
        ._url = "http://history-one.test/",
        ._state = .{ .source = .history, .value = null },
    };
    const history_two = try std.testing.allocator.create(NavigationHistoryEntry);
    errdefer std.testing.allocator.destroy(history_two);
    history_two.* = .{
        ._id = "history-two",
        ._key = "history-two",
        ._url = "http://history-two.test/",
        ._state = .{ .source = .history, .value = null },
    };
    try session.navigation._entries.append(std.testing.allocator, history_one);
    try session.navigation._entries.append(std.testing.allocator, history_two);
    defer {
        session.navigation._entries.deinit(std.testing.allocator);
        std.testing.allocator.destroy(history_one);
        std.testing.allocator.destroy(history_two);
    }
    session.navigation._index = 1;

    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.committed_surface = .{ .url = @constCast("http://current.test/") };
    tab.error_state = .{};
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://failed.test/", "http://failed.test/", "CouldntConnect");
    defer tab.error_state.deinit(std.testing.allocator);
    tab.zoom_percent = 100;
    tab.target_name = &.{};
    tab.popup_source = .none;

    var tab_items = [_]*BrowseTab{&tab};
    var tabs = std.ArrayListUnmanaged(*BrowseTab){
        .items = tab_items[0..],
        .capacity = tab_items.len,
    };
    var closed_items = [_]ClosedBrowseTab{
        .{ .url = @constCast("http://closed-one.test/"), .zoom_percent = 100 },
        .{ .url = @constCast("http://closed-two.test/"), .zoom_percent = 125 },
    };
    var closed_tabs = std.ArrayListUnmanaged(ClosedBrowseTab){
        .items = closed_items[0..],
        .capacity = closed_items.len,
    };
    var active_index: usize = 0;
    const shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_index,
    };
    var settings = BrowseSettings{
        .restore_previous_session = true,
        .allow_script_popups = false,
        .default_zoom_percent = 120,
        .homepage_url = try std.testing.allocator.dupe(u8, "http://home.test/"),
    };
    defer settings.deinit(std.testing.allocator);
    var downloads = BrowseDownloads{ .allocator = std.testing.allocator };
    defer downloads.deinit(null);
    try downloads.entries.append(std.testing.allocator, .{
        .filename = try std.testing.allocator.dupe(u8, "seed.txt"),
        .path = try std.testing.allocator.dupe(u8, "C:/tmp/seed.txt"),
        .url = try std.testing.allocator.dupe(u8, "http://download.test/seed.txt"),
        .detail = try std.testing.allocator.dupe(u8, ""),
        .status = .completed,
    });

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try writeInternalStartPage(std.testing.allocator, &buf.writer, abs_dir, &shell, 0, &settings, &downloads);
    const html = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, html, "Quick Actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://error") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/reopen-closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://bookmarks/add-current") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://downloads/clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Open Tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/activate/0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Recently Closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://tabs/reopen-closed/0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Recent History") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://history/traverse/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Recent Bookmarks") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://bookmarks/open/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Recent Downloads") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://downloads/source/0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Settings Snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://settings/toggle-script-popups") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://settings/default-zoom/reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://settings/homepage/clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Current Tab Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "CouldntConnect") != null);
}

test "addPersistedBookmark appends unique bookmark once" {
    const rel_dir = ".zig-cache/tmp/internal-bookmark-add-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);

    try std.testing.expect(addPersistedBookmark(std.testing.allocator, abs_dir, "http://one.test/"));
    try std.testing.expect(!addPersistedBookmark(std.testing.allocator, abs_dir, "http://one.test/"));

    var bookmarks = loadPersistedBookmarks(std.testing.allocator, abs_dir);
    defer deinitOwnedStrings(std.testing.allocator, &bookmarks);
    try std.testing.expectEqual(@as(usize, 1), bookmarks.items.len);
    try std.testing.expectEqualStrings("http://one.test/", bookmarks.items[0]);
}

test "clearInactiveEntries removes completed download files and metadata" {
    const rel_dir = ".zig-cache/tmp/internal-download-clear-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ abs_dir, "gone.txt" });
    defer std.testing.allocator.free(file_path);
    var dir = try std.fs.openDirAbsolute(abs_dir, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "gone.txt", .data = "gone" });

    var downloads = BrowseDownloads{ .allocator = std.testing.allocator };
    defer downloads.deinit(null);
    try downloads.entries.append(std.testing.allocator, .{
        .filename = try std.testing.allocator.dupe(u8, "gone.txt"),
        .path = try std.testing.allocator.dupe(u8, file_path),
        .url = try std.testing.allocator.dupe(u8, "http://one.test/gone.txt"),
        .detail = try std.testing.allocator.dupe(u8, ""),
        .bytes_received = 4,
        .status = .completed,
    });

    try std.testing.expect(downloads.clearInactiveEntries(abs_dir));
    try std.testing.expectEqual(@as(usize, 0), downloads.entries.items.len);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(file_path, .{}));
}

test "makeInternalBrowsePageDisplayTitle reflects live counts" {
    const rel_dir = ".zig-cache/tmp/internal-title-count-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);
    savePersistedBookmarks(std.testing.allocator, abs_dir, &.{ "http://one.test/", "http://two.test/" });

    var session: Session = undefined;
    session.page = null;
    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.error_state = .{};
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://failed.test/", "http://failed.test/", "CouldntConnect");
    defer tab.error_state.deinit(std.testing.allocator);
    tab.zoom_percent = 100;
    tab.target_name = &.{};
    tab.popup_source = .none;

    const tabs = [_]*BrowseTab{&tab};

    var downloads = BrowseDownloads{ .allocator = std.testing.allocator };
    defer downloads.deinit(null);
    try downloads.entries.append(std.testing.allocator, .{
        .filename = try std.testing.allocator.dupe(u8, "file.txt"),
        .path = try std.testing.allocator.dupe(u8, "C:/tmp/file.txt"),
        .url = try std.testing.allocator.dupe(u8, "http://one.test/file.txt"),
        .detail = try std.testing.allocator.dupe(u8, ""),
        .status = .completed,
    });

    const tabs_title = try makeInternalBrowsePageDisplayTitle(std.testing.allocator, abs_dir, tabs[0..], 0, &downloads, .tabs);
    defer std.testing.allocator.free(tabs_title);
    try std.testing.expectEqualStrings("Browser Tabs (1)", tabs_title);

    const bookmarks_title = try makeInternalBrowsePageDisplayTitle(std.testing.allocator, abs_dir, tabs[0..], 0, &downloads, .bookmarks);
    defer std.testing.allocator.free(bookmarks_title);
    try std.testing.expectEqualStrings("Browser Bookmarks (2)", bookmarks_title);

    const downloads_title = try makeInternalBrowsePageDisplayTitle(std.testing.allocator, abs_dir, tabs[0..], 0, &downloads, .downloads);
    defer std.testing.allocator.free(downloads_title);
    try std.testing.expectEqualStrings("Browser Downloads (1)", downloads_title);

    const error_title = try makeInternalBrowsePageDisplayTitle(std.testing.allocator, abs_dir, tabs[0..], 0, &downloads, .error_page);
    defer std.testing.allocator.free(error_title);
    try std.testing.expectEqualStrings("Navigation Error", error_title);
}

test "hashInternalBrowsePageState changes after bookmark and download mutations" {
    const rel_dir = ".zig-cache/tmp/internal-page-hash-mutation-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);

    savePersistedBookmarks(std.testing.allocator, abs_dir, &.{"http://one.test/"});

    var session: Session = undefined;
    session.page = null;
    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.error_state = .{};
    tab.zoom_percent = 100;
    tab.target_name = &.{};
    tab.popup_source = .none;

    var tab_items = [_]*BrowseTab{&tab};
    var tabs = std.ArrayListUnmanaged(*BrowseTab){
        .items = tab_items[0..],
        .capacity = tab_items.len,
    };
    var closed_tabs = std.ArrayListUnmanaged(ClosedBrowseTab){};
    defer closed_tabs.deinit(std.testing.allocator);
    var active_index: usize = 0;
    const shell: BrowseShell = .{
        .tabs = &tabs,
        .closed_tabs = &closed_tabs,
        .active_tab_index = &active_index,
    };
    var settings = BrowseSettings{};
    defer settings.deinit(std.testing.allocator);

    var downloads = BrowseDownloads{ .allocator = std.testing.allocator };
    defer downloads.deinit(null);
    try downloads.entries.append(std.testing.allocator, .{
        .filename = try std.testing.allocator.dupe(u8, "file.txt"),
        .path = try std.testing.allocator.dupe(u8, "C:/tmp/file.txt"),
        .url = try std.testing.allocator.dupe(u8, "http://one.test/file.txt"),
        .detail = try std.testing.allocator.dupe(u8, ""),
        .status = .completed,
    });

    const first_bookmarks_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .bookmarks);
    try std.testing.expect(addPersistedBookmark(std.testing.allocator, abs_dir, "http://two.test/"));
    const second_bookmarks_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .bookmarks);
    try std.testing.expect(first_bookmarks_hash != second_bookmarks_hash);

    const first_downloads_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .downloads);
    try std.testing.expect(downloads.clearInactiveEntries(abs_dir));
    const second_downloads_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .downloads);
    try std.testing.expect(first_downloads_hash != second_downloads_hash);

    const first_error_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .error_page);
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://failed.test/", "http://failed.test/", "CouldntConnect");
    defer tab.error_state.deinit(std.testing.allocator);
    const second_error_hash = hashInternalBrowsePageState(std.testing.allocator, abs_dir, &shell, 0, &settings, &downloads, .error_page);
    try std.testing.expect(first_error_hash != second_error_hash);
}

test "writeInternalErrorPage includes retry home and start actions" {
    var tab: BrowseTab = undefined;
    tab.error_state = .{};
    defer tab.error_state.deinit(std.testing.allocator);
    try tab.error_state.replace(std.testing.allocator, .invalid_address, "two words", "two words", "Enter a full URL, for example https://example.com");
    var settings = BrowseSettings{};
    defer settings.deinit(std.testing.allocator);

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try writeInternalErrorPage(&buf.writer, &tab, &settings);
    const html = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://error/retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://error/home") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "browser://error/start") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "two words") != null);
}

test "browseTabPersistentUrl prefers retry target for error page" {
    var session: Session = undefined;
    session.page = null;
    var page: Page = undefined;
    page.url = @constCast("browser://error");
    session.page = &page;
    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.error_state = .{};
    defer tab.error_state.deinit(std.testing.allocator);
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://retry.test/", "http://retry.test/", "CouldntConnect");
    try std.testing.expectEqualStrings("http://retry.test/", browseTabPersistentUrl(&tab));
}

test "captureBrowseTabRuntimeError preserves error state on internal pages" {
    var session: Session = undefined;
    var page: Page = undefined;
    page.url = @constCast("browser://start");
    page._queued_navigation = null;
    page._parse_state = .{ .complete = {} };
    session.page = &page;

    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.error_state = .{};
    defer tab.error_state.deinit(std.testing.allocator);
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://retry.test/", "http://retry.test/", "CouldntConnect");

    try std.testing.expect(!(try captureBrowseTabRuntimeError(std.testing.allocator, &tab)));
    try std.testing.expect(tab.error_state.hasValue());
}

test "captureBrowseTabRuntimeError clears error state on successful external pages" {
    var session: Session = undefined;
    var page: Page = undefined;
    page.url = @constCast("http://ok.test/");
    page._queued_navigation = null;
    page._parse_state = .{ .complete = {} };
    session.page = &page;

    var tab: BrowseTab = undefined;
    tab.session = &session;
    tab.error_state = .{};
    defer tab.error_state.deinit(std.testing.allocator);
    try tab.error_state.replace(std.testing.allocator, .navigation_failed, "http://retry.test/", "http://retry.test/", "CouldntConnect");

    try std.testing.expect(!(try captureBrowseTabRuntimeError(std.testing.allocator, &tab)));
    try std.testing.expect(!tab.error_state.hasValue());
}

test "internalBrowseCommandHostPage maps stateful internal actions" {
    try std.testing.expectEqual(@as(?InternalBrowsePage, .history), internalBrowseCommandHostPage(.history_clear_session));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .bookmarks), internalBrowseCommandHostPage(.bookmark_add_current));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .downloads), internalBrowseCommandHostPage(.download_clear));
    try std.testing.expectEqual(@as(?InternalBrowsePage, .settings), internalBrowseCommandHostPage(.settings_set_homepage_to_current));
    try std.testing.expectEqual(@as(?InternalBrowsePage, null), internalBrowseCommandHostPage(.reload));
}

test "internalBrowseCommandUsesBrowseLoopHandler includes indexed closed tab reopen" {
    try std.testing.expect(internalBrowseCommandUsesBrowseLoopHandler(.tab_new));
    try std.testing.expect(internalBrowseCommandUsesBrowseLoopHandler(.tab_reopen_closed));
    try std.testing.expect(internalBrowseCommandUsesBrowseLoopHandler(.{ .tab_reopen_closed_index = 1 }));
    try std.testing.expect(!internalBrowseCommandUsesBrowseLoopHandler(.download_clear));
}

test "removePersistedBookmarkAtIndex rewrites bookmark file" {
    const rel_dir = ".zig-cache/tmp/internal-bookmark-remove-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);

    var dir = try std.fs.openDirAbsolute(abs_dir, .{});
    defer dir.close();
    dir.writeFile(.{ .sub_path = BROWSE_BOOKMARKS_FILE, .data = 
        \\http://one.test/
        \\http://two.test/
    }) catch |err| switch (err) {
        else => return err,
    };

    try std.testing.expect(removePersistedBookmarkAtIndex(std.testing.allocator, abs_dir, 0));

    var bookmarks = loadPersistedBookmarks(std.testing.allocator, abs_dir);
    defer deinitOwnedStrings(std.testing.allocator, &bookmarks);
    try std.testing.expectEqual(@as(usize, 1), bookmarks.items.len);
    try std.testing.expectEqualStrings("http://two.test/", bookmarks.items[0]);
}

test "buildJsStringLiteral escapes control characters" {
    const literal = try buildJsStringLiteral(std.testing.allocator, "<title>'Browser'\\Settings\n</title>");
    defer std.testing.allocator.free(literal);

    try std.testing.expect(std.mem.startsWith(u8, literal, "'"));
    try std.testing.expect(std.mem.endsWith(u8, literal, "'"));
    try std.testing.expect(std.mem.indexOf(u8, literal, "\\'Browser\\'") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal, "\\\\Settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal, "\\n") != null);
}

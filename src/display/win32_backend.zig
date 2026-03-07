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
const log = @import("../log.zig");
const Page = @import("../browser/Page.zig");
const URL = @import("../browser/URL.zig");
const BrowserCommand = @import("BrowserCommand.zig").BrowserCommand;
const Display = @import("Display.zig");
const DisplayList = @import("../render/DisplayList.zig").DisplayList;
const DisplayColor = @import("../render/DisplayList.zig").Color;
const ImageCommand = @import("../render/DisplayList.zig").ImageCommand;

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
    @cInclude("urlmon.h");
});

const GpStatus = c_int;
const GpImage = opaque {};
const GpGraphics = opaque {};

const GdiplusStartupInput = extern struct {
    GdiplusVersion: c.UINT,
    DebugEventCallback: ?*const fn (c_int, [*c]u8) callconv(.winapi) void,
    SuppressBackgroundThread: c.BOOL,
    SuppressExternalCodecs: c.BOOL,
};

extern "gdiplus" fn GdiplusStartup(
    token: *c.ULONG_PTR,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdiplusShutdown(token: c.ULONG_PTR) callconv(.winapi) void;
extern "gdiplus" fn GdipDisposeImage(image: *GpImage) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipLoadImageFromFile(filename: [*:0]const u16, image: *?*GpImage) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipGetImageWidth(image: *GpImage, width: *c.UINT) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipGetImageHeight(image: *GpImage, height: *c.UINT) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateFromHDC(hdc: c.HDC, graphics: *?*GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteGraphics(graphics: *GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawImageRectI(
    graphics: *GpGraphics,
    image: *GpImage,
    x: c.INT,
    y: c.INT,
    width: c.INT,
    height: c.INT,
) callconv(.winapi) GpStatus;
const LoadCursorWUnaligned = @extern(
    *const fn (c.HINSTANCE, ?*align(1) const anyopaque) callconv(.winapi) c.HCURSOR,
    .{ .name = "LoadCursorW" },
);

const GDIP_STATUS_OK: GpStatus = 0;

const CachedImage = struct {
    state: enum {
        unloaded,
        loaded,
        failed,
    } = .unloaded,
    cache_path: []u8 = &.{},
    gp_image: ?*GpImage = null,
    width: u32 = 0,
    height: u32 = 0,
    owns_cache_file: bool = false,

    fn deinit(self: *CachedImage, allocator: std.mem.Allocator) void {
        if (self.gp_image) |image| {
            _ = GdipDisposeImage(image);
        }
        if (self.owns_cache_file and self.cache_path.len > 0) {
            if (std.fs.path.isAbsolute(self.cache_path)) {
                std.fs.deleteFileAbsolute(self.cache_path) catch {};
            } else {
                std.fs.cwd().deleteFile(self.cache_path) catch {};
            }
        }
        allocator.free(self.cache_path);
        self.* = .{};
    }
};

pub const Win32Backend = struct {
    allocator: std.mem.Allocator,
    app_data_path: ?[]u8 = null,
    page_count: u32 = 0,

    requested_width: std.atomic.Value(u32),
    requested_height: std.atomic.Value(u32),
    resize_seq: std.atomic.Value(u64) = .init(0),
    open_requested: std.atomic.Value(bool) = .init(false),
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    user_closed: std.atomic.Value(bool) = .init(false),
    pending_high_surrogate: ?u16 = null,
    ime_composing: bool = false,
    suppress_wm_char_units: u32 = 0,

    input_lock: std.Thread.Mutex = .{},
    input_events: std.ArrayListUnmanaged(InputEvent) = .{},

    command_lock: std.Thread.Mutex = .{},
    command_queue: std.ArrayListUnmanaged(BrowserCommand) = .{},

    presentation_lock: std.Thread.Mutex = .{},
    presentation_title: []u8 = &.{},
    presentation_url: []u8 = &.{},
    presentation_body: []u8 = &.{},
    presentation_display_list: ?DisplayList = null,
    presentation_seq: std.atomic.Value(u64) = .init(0),
    presentation_scroll_px: i32 = 0,
    presentation_max_scroll_px: i32 = 0,
    presentation_can_go_back: bool = false,
    presentation_can_go_forward: bool = false,
    presentation_is_loading: bool = false,
    presentation_zoom_percent: i32 = 100,
    address_input: std.ArrayListUnmanaged(u8) = .{},
    address_input_active: bool = false,
    address_input_select_all: bool = false,
    address_pending_high_surrogate: ?u16 = null,
    find_input: std.ArrayListUnmanaged(u8) = .{},
    find_input_active: bool = false,
    find_input_select_all: bool = false,
    find_pending_high_surrogate: ?u16 = null,
    find_match_index: usize = 0,
    presentation_tab_entries: std.ArrayListUnmanaged(PresentationTabEntry) = .{},
    presentation_active_tab_index: usize = 0,
    presentation_history_entries: std.ArrayListUnmanaged([]u8) = .{},
    presentation_history_current_index: usize = 0,
    history_overlay_open: bool = false,
    history_overlay_selected_index: usize = 0,
    history_overlay_scroll_index: usize = 0,
    presentation_bookmark_entries: std.ArrayListUnmanaged([]u8) = .{},
    bookmark_overlay_open: bool = false,
    bookmark_overlay_selected_index: usize = 0,
    bookmark_overlay_scroll_index: usize = 0,
    presentation_download_entries: std.ArrayListUnmanaged(PresentationDownloadEntry) = .{},
    download_overlay_open: bool = false,
    download_overlay_selected_index: usize = 0,
    download_overlay_scroll_index: usize = 0,
    presentation_restore_previous_session: bool = true,
    presentation_default_zoom_percent: i32 = 100,
    presentation_homepage_url: []u8 = &.{},
    settings_overlay_open: bool = false,
    settings_overlay_selected_index: usize = 0,
    presentation_left_mouse_consumed: bool = false,
    pending_presentation_command: ?BrowserCommand = null,
    image_cache_lock: std.Thread.Mutex = .{},
    image_cache: std.StringHashMapUnmanaged(CachedImage) = .{},
    gdiplus_token: c.ULONG_PTR = 0,
    gdiplus_started: bool = false,

    thread: ?std.Thread = null,
    thread_start_lock: std.Thread.Mutex = .{},
    thread_start_cond: std.Thread.Condition = .{},
    thread_started: bool = false,

    const InputEvent = union(enum) {
        mouse_down: MouseEvent,
        mouse_up: MouseEvent,
        mouse_move: MouseMoveEvent,
        mouse_wheel: MouseWheelEvent,
        key_down: KeyEvent,
        key_up: KeyEvent,
        text_input: TextInputEvent,
        window_blur,
    };

    const MouseEvent = struct {
        x: f64,
        y: f64,
        button: Page.MouseButton,
        modifiers: Page.MouseModifiers,
    };

    const MouseMoveEvent = struct {
        x: f64,
        y: f64,
        modifiers: Page.MouseModifiers,
    };

    const MouseWheelEvent = struct {
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        modifiers: Page.MouseModifiers,
    };

    const KeyEvent = struct {
        vk: u32,
        modifiers: Page.KeyboardModifiers,
        repeat: bool = false,
    };

    const TextInputEvent = struct {
        bytes: [4]u8,
        len: u8,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Win32Backend {
        return .{
            .allocator = allocator,
            .requested_width = .init(width),
            .requested_height = .init(height),
        };
    }

    pub fn onPageCreated(self: *Win32Backend) bool {
        self.page_count += 1;
        if (self.page_count != 1) {
            return false;
        }

        if (!self.ensureThreadStarted()) {
            return false;
        }
        self.user_closed.store(false, .release);
        self.open_requested.store(true, .release);
        return true;
    }

    pub fn onPageRemoved(self: *Win32Backend) bool {
        const had_pages = self.page_count > 0;
        if (self.page_count > 0) {
            self.page_count -= 1;
        }
        const should_close = had_pages and self.page_count == 0;
        if (should_close) {
            self.open_requested.store(false, .release);
            self.user_closed.store(false, .release);
        }
        return should_close;
    }

    pub fn onViewportChanged(self: *Win32Backend, width: u32, height: u32) void {
        self.requested_width.store(width, .release);
        self.requested_height.store(height, .release);
        _ = self.resize_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setNavigationState(self: *Win32Backend, can_go_back: bool, can_go_forward: bool, is_loading: bool, zoom_percent: i32) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        if (self.presentation_can_go_back == can_go_back and
            self.presentation_can_go_forward == can_go_forward and
            self.presentation_is_loading == is_loading and
            self.presentation_zoom_percent == zoom_percent)
        {
            return;
        }
        self.presentation_can_go_back = can_go_back;
        self.presentation_can_go_forward = can_go_forward;
        self.presentation_is_loading = is_loading;
        self.presentation_zoom_percent = zoom_percent;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setHistoryEntries(self: *Win32Backend, entries: []const []const u8, current_index: usize) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        const normalized_current_index = if (entries.len == 0)
            0
        else
            @min(current_index, entries.len - 1);
        if (self.presentation_history_current_index == normalized_current_index and
            self.presentation_history_entries.items.len == entries.len)
        {
            var unchanged = true;
            for (entries, self.presentation_history_entries.items) |entry, existing| {
                if (!std.mem.eql(u8, entry, existing)) {
                    unchanged = false;
                    break;
                }
            }
            if (unchanged) {
                return;
            }
        }

        deinitOwnedStringList(&self.presentation_history_entries, self.allocator);
        self.presentation_history_entries.ensureTotalCapacity(self.allocator, entries.len) catch |err| {
            log.warn(.app, "win history reserve failed", .{ .err = err });
            return;
        };
        for (entries) |entry| {
            const owned = self.allocator.dupe(u8, entry) catch |err| {
                log.warn(.app, "win history copy failed", .{ .err = err });
                deinitOwnedStringList(&self.presentation_history_entries, self.allocator);
                return;
            };
            self.presentation_history_entries.appendAssumeCapacity(owned);
        }
        self.presentation_history_current_index = normalized_current_index;
        if (!self.history_overlay_open) {
            self.history_overlay_selected_index = normalized_current_index;
        } else if (self.presentation_history_entries.items.len > 0) {
            self.history_overlay_selected_index = @min(self.history_overlay_selected_index, self.presentation_history_entries.items.len - 1);
        } else {
            self.history_overlay_selected_index = 0;
        }
        self.history_overlay_scroll_index = clampOverlaySelectedIndex(
            self.presentation_history_entries.items.len,
            self.history_overlay_scroll_index,
        );
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setDownloadEntries(self: *Win32Backend, entries: []const Display.DownloadEntry) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        if (self.presentation_download_entries.items.len == entries.len) {
            var unchanged = true;
            for (entries, self.presentation_download_entries.items) |entry, existing| {
                if (entry.removable != existing.removable or
                    !std.mem.eql(u8, entry.filename, existing.filename) or
                    !std.mem.eql(u8, entry.path, existing.path) or
                    !std.mem.eql(u8, entry.status, existing.status))
                {
                    unchanged = false;
                    break;
                }
            }
            if (unchanged) {
                return;
            }
        }

        deinitOwnedDownloadList(&self.presentation_download_entries, self.allocator);
        self.presentation_download_entries.ensureTotalCapacity(self.allocator, entries.len) catch |err| {
            log.warn(.app, "win downloads reserve failed", .{ .err = err });
            return;
        };
        for (entries) |entry| {
            const owned_filename = self.allocator.dupe(u8, entry.filename) catch |err| {
                log.warn(.app, "win dl filename copy", .{ .err = err });
                deinitOwnedDownloadList(&self.presentation_download_entries, self.allocator);
                return;
            };
            errdefer self.allocator.free(owned_filename);
            const owned_path = self.allocator.dupe(u8, entry.path) catch |err| {
                self.allocator.free(owned_filename);
                log.warn(.app, "win dl path copy", .{ .err = err });
                deinitOwnedDownloadList(&self.presentation_download_entries, self.allocator);
                return;
            };
            errdefer self.allocator.free(owned_path);
            const owned_status = self.allocator.dupe(u8, entry.status) catch |err| {
                self.allocator.free(owned_filename);
                self.allocator.free(owned_path);
                log.warn(.app, "win dl status copy", .{ .err = err });
                deinitOwnedDownloadList(&self.presentation_download_entries, self.allocator);
                return;
            };
            self.presentation_download_entries.appendAssumeCapacity(.{
                .filename = owned_filename,
                .path = owned_path,
                .status = owned_status,
                .removable = entry.removable,
            });
        }
        self.download_overlay_selected_index = clampOverlaySelectedIndex(
            self.presentation_download_entries.items.len,
            self.download_overlay_selected_index,
        );
        self.download_overlay_scroll_index = clampOverlayScrollIndex(
            self.presentation_download_entries.items.len,
            self.download_overlay_scroll_index,
            self.presentation_download_entries.items.len,
        );
        if (self.presentation_download_entries.items.len == 0) {
            self.download_overlay_selected_index = 0;
            self.download_overlay_scroll_index = 0;
        }
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setTabEntries(self: *Win32Backend, entries: anytype, active_index: usize) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        const normalized_active_index = if (entries.len == 0)
            0
        else
            @min(active_index, entries.len - 1);

        if (self.presentation_active_tab_index == normalized_active_index and
            self.presentation_tab_entries.items.len == entries.len)
        {
            var unchanged = true;
            for (entries, self.presentation_tab_entries.items) |entry, existing| {
                if (entry.is_loading != existing.is_loading or
                    !std.mem.eql(u8, entry.title, existing.title) or
                    !std.mem.eql(u8, entry.url, existing.url))
                {
                    unchanged = false;
                    break;
                }
            }
            if (unchanged) {
                return;
            }
        }

        deinitOwnedTabList(&self.presentation_tab_entries, self.allocator);
        self.presentation_tab_entries.ensureTotalCapacity(self.allocator, entries.len) catch |err| {
            log.warn(.app, "win tabs reserve failed", .{ .err = err });
            return;
        };
        for (entries) |entry| {
            const owned_title = self.allocator.dupe(u8, entry.title) catch |err| {
                log.warn(.app, "win tab title copy failed", .{ .err = err });
                deinitOwnedTabList(&self.presentation_tab_entries, self.allocator);
                return;
            };
            errdefer self.allocator.free(owned_title);
            const owned_url = self.allocator.dupe(u8, entry.url) catch |err| {
                self.allocator.free(owned_title);
                log.warn(.app, "win tab url copy failed", .{ .err = err });
                deinitOwnedTabList(&self.presentation_tab_entries, self.allocator);
                return;
            };
            self.presentation_tab_entries.appendAssumeCapacity(.{
                .title = owned_title,
                .url = owned_url,
                .is_loading = entry.is_loading,
            });
        }
        self.presentation_active_tab_index = normalized_active_index;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setSettingsState(self: *Win32Backend, settings: Display.SettingsState) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        if (self.presentation_restore_previous_session == settings.restore_previous_session and
            self.presentation_default_zoom_percent == settings.default_zoom_percent and
            std.mem.eql(u8, self.presentation_homepage_url, settings.homepage_url))
        {
            return;
        }

        const owned_homepage = self.allocator.dupe(u8, settings.homepage_url) catch |err| {
            log.warn(.app, "win settings copy failed", .{ .err = err });
            return;
        };
        self.allocator.free(self.presentation_homepage_url);
        self.presentation_homepage_url = owned_homepage;
        self.presentation_restore_previous_session = settings.restore_previous_session;
        self.presentation_default_zoom_percent = settings.default_zoom_percent;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setAppDataPath(self: *Win32Backend, path: ?[]const u8) void {
        if (self.app_data_path) |existing| {
            if (path) |next| {
                if (std.mem.eql(u8, existing, next)) {
                    return;
                }
            }
            self.allocator.free(existing);
            self.app_data_path = null;
        }

        if (path) |next| {
            self.app_data_path = self.allocator.dupe(u8, next) catch |err| {
                log.warn(.app, "win appdir copy failed", .{ .err = err });
                return;
            };
        }
        self.loadBookmarksFromDisk();
    }

    fn loadBookmarksFromDisk(self: *Win32Backend) void {
        var loaded: std.ArrayListUnmanaged([]u8) = .{};
        errdefer deinitOwnedStringList(&loaded, self.allocator);

        if (self.app_data_path) |app_data_path| {
            var dir = std.fs.openDirAbsolute(app_data_path, .{}) catch |err| {
                log.warn(.app, "win bm dir open", .{ .err = err });
                return;
            };
            defer dir.close();

            const file = dir.openFile(BOOKMARKS_FILE, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    log.warn(.app, "win bm open", .{ .err = err });
                    return;
                },
            };
            if (file) |bookmark_file| {
                defer bookmark_file.close();

                const data = bookmark_file.readToEndAlloc(self.allocator, 1024 * 64) catch |err| {
                    log.warn(.app, "win bm read", .{ .err = err });
                    return;
                };
                defer self.allocator.free(data);

                var it = std.mem.splitScalar(u8, data, '\n');
                while (it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, "\r\n\t ");
                    if (line.len == 0) {
                        continue;
                    }
                    if (stringListIndexOf(loaded.items, line) != null) {
                        continue;
                    }
                    const owned = self.allocator.dupe(u8, line) catch |err| {
                        log.warn(.app, "win bm copy", .{ .err = err });
                        return;
                    };
                    loaded.append(self.allocator, owned) catch |err| {
                        self.allocator.free(owned);
                        log.warn(.app, "win bm copy", .{ .err = err });
                        return;
                    };
                }
            }
        }

        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        deinitOwnedStringList(&self.presentation_bookmark_entries, self.allocator);
        self.presentation_bookmark_entries = loaded;
        loaded = .{};
        self.bookmark_overlay_selected_index = clampOverlaySelectedIndex(
            self.presentation_bookmark_entries.items.len,
            self.bookmark_overlay_selected_index,
        );
        self.bookmark_overlay_scroll_index = clampOverlayScrollIndex(
            self.presentation_bookmark_entries.items.len,
            self.bookmark_overlay_scroll_index,
            self.presentation_bookmark_entries.items.len,
        );
        if (self.presentation_bookmark_entries.items.len == 0) {
            self.bookmark_overlay_selected_index = 0;
            self.bookmark_overlay_scroll_index = 0;
            self.bookmark_overlay_open = false;
        }
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    fn saveBookmarksToDiskLocked(self: *Win32Backend) void {
        const app_data_path = self.app_data_path orelse return;

        var dir = std.fs.openDirAbsolute(app_data_path, .{}) catch |err| {
            log.warn(.app, "win bm dir open", .{ .err = err });
            return;
        };
        defer dir.close();

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        for (self.presentation_bookmark_entries.items, 0..) |entry, index| {
            if (index > 0) {
                buf.writer.writeByte('\n') catch |err| {
                    log.warn(.app, "win bm ser", .{ .err = err });
                    return;
                };
            }
            buf.writer.writeAll(entry) catch |err| {
                log.warn(.app, "win bm ser", .{ .err = err });
                return;
            };
        }

        dir.writeFile(.{ .sub_path = BOOKMARKS_FILE, .data = buf.written() }) catch |err| {
            log.warn(.app, "win bm write", .{ .err = err });
        };
    }

    pub fn deinit(self: *Win32Backend) void {
        self.open_requested.store(false, .release);
        self.shutdown_requested.store(true, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.input_events.deinit(self.allocator);
        if (self.app_data_path) |path| {
            self.allocator.free(path);
            self.app_data_path = null;
        }
        self.command_lock.lock();
        for (self.command_queue.items) |command| {
            command.deinit(self.allocator);
        }
        self.command_queue.deinit(self.allocator);
        self.command_lock.unlock();
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();
        self.allocator.free(self.presentation_title);
        self.allocator.free(self.presentation_url);
        self.allocator.free(self.presentation_body);
        if (self.presentation_display_list) |*display_list| {
            display_list.deinit(self.allocator);
        }
        self.address_input.deinit(self.allocator);
        self.find_input.deinit(self.allocator);
        deinitOwnedTabList(&self.presentation_tab_entries, self.allocator);
        deinitOwnedStringList(&self.presentation_history_entries, self.allocator);
        deinitOwnedStringList(&self.presentation_bookmark_entries, self.allocator);
        deinitOwnedDownloadList(&self.presentation_download_entries, self.allocator);
        self.allocator.free(self.presentation_homepage_url);
        if (self.pending_presentation_command) |command| {
            command.deinit(self.allocator);
        }

        self.image_cache_lock.lock();
        defer self.image_cache_lock.unlock();
        var image_it = self.image_cache.iterator();
        while (image_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.image_cache.deinit(self.allocator);
        if (self.gdiplus_started) {
            GdiplusShutdown(self.gdiplus_token);
            self.gdiplus_started = false;
            self.gdiplus_token = 0;
        }
    }

    pub fn dispatchInput(self: *Win32Backend, page: *Page) !void {
        var pending: std.ArrayListUnmanaged(InputEvent) = .{};
        self.input_lock.lock();
        std.mem.swap(std.ArrayListUnmanaged(InputEvent), &pending, &self.input_events);
        self.input_lock.unlock();
        defer pending.deinit(self.allocator);

        var key_buf: [2]u8 = undefined;
        for (pending.items) |event| {
            switch (event) {
                .mouse_down => |mouse| try page.triggerMouseDown(mouse.x, mouse.y, mouse.button, mouse.modifiers),
                .mouse_up => |mouse| {
                    try page.triggerMouseUp(mouse.x, mouse.y, mouse.button, mouse.modifiers);
                    if (mouse.button == .main) {
                        try page.triggerMouseClickWithModifiers(mouse.x, mouse.y, .main, mouse.modifiers);
                    }
                },
                .mouse_move => |mouse| try page.triggerMouseMove(mouse.x, mouse.y, mouse.modifiers),
                .mouse_wheel => |wheel| try page.triggerMouseWheel(
                    wheel.x,
                    wheel.y,
                    wheel.delta_x,
                    wheel.delta_y,
                    wheel.modifiers,
                ),
                .key_down => |key_down| {
                    const key = mapVirtualKey(key_down.vk, key_down.modifiers.shift, &key_buf) orelse continue;
                    const default_allowed = try page.triggerKeyboardKeyDownNoTextWithRepeat(
                        key,
                        key_down.modifiers,
                        key_down.repeat,
                    );
                    if (default_allowed) {
                        if (clipboardShortcutAction(key_down.vk, key_down.modifiers)) |action| {
                            try handleClipboardShortcut(self.allocator, page, action);
                        }
                    }
                },
                .key_up => |key_up| {
                    const key = mapVirtualKey(key_up.vk, key_up.modifiers.shift, &key_buf) orelse continue;
                    _ = try page.triggerKeyboardKeyUp(key, key_up.modifiers);
                },
                .text_input => |text_input| {
                    try page.insertText(text_input.bytes[0..text_input.len]);
                },
                .window_blur => try page.triggerWindowBlur(),
            }
        }
    }

    pub fn presentDocument(self: *Win32Backend, title: []const u8, url: []const u8, body: []const u8) !void {
        try self.presentPageView(title, url, body, null);
    }

    pub fn presentPageView(
        self: *Win32Backend,
        title: []const u8,
        url: []const u8,
        body: []const u8,
        display_list: ?*const DisplayList,
    ) !void {
        const next_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(next_title);
        const next_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(next_url);
        const next_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(next_body);
        const next_display_list = if (display_list) |list|
            try list.cloneOwned(self.allocator)
        else
            null;
        errdefer if (next_display_list) |list| {
            var owned_list = list;
            owned_list.deinit(self.allocator);
        };

        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        self.allocator.free(self.presentation_title);
        self.allocator.free(self.presentation_url);
        self.allocator.free(self.presentation_body);
        if (self.presentation_display_list) |*list| {
            list.deinit(self.allocator);
        }

        self.presentation_title = next_title;
        self.presentation_url = next_url;
        self.presentation_body = next_body;
        self.presentation_display_list = next_display_list;
        self.presentation_scroll_px = 0;
        self.presentation_max_scroll_px = 0;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn saveBitmap(self: *Win32Backend, path: []const u8) bool {
        return savePresentationBitmap(self, path);
    }

    pub fn savePng(self: *Win32Backend, path: []const u8) bool {
        return savePresentationPng(self, path);
    }

    pub fn userClosed(self: *const Win32Backend) bool {
        return self.user_closed.load(.acquire);
    }

    pub fn nextBrowserCommand(self: *Win32Backend) ?BrowserCommand {
        self.command_lock.lock();
        defer self.command_lock.unlock();

        if (self.command_queue.items.len == 0) {
            return null;
        }

        return self.command_queue.orderedRemove(0);
    }

    fn ensureThreadStarted(self: *Win32Backend) bool {
        self.thread_start_lock.lock();
        defer self.thread_start_lock.unlock();

        if (self.thread != null) {
            return true;
        }

        self.thread_started = false;
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            log.warn(.app, "win thread spawn failed", .{ .err = err });
            return false;
        };

        while (!self.thread_started) {
            self.thread_start_cond.wait(&self.thread_start_lock);
        }
        return true;
    }

    fn workerMain(self: *Win32Backend) void {
        self.thread_start_lock.lock();
        self.thread_started = true;
        self.thread_start_cond.signal();
        self.thread_start_lock.unlock();

        var hwnd: ?c.HWND = null;
        var last_resize_seq: u64 = self.resize_seq.load(.acquire);
        var last_presentation_seq: u64 = self.presentation_seq.load(.acquire);
        var creation_blocked = false;

        while (!self.shutdown_requested.load(.acquire)) {
            pumpMessages();

            const should_open = self.open_requested.load(.acquire);
            if (should_open) {
                const was_closed_by_user = self.user_closed.load(.acquire);
                if (hwnd == null and !creation_blocked and !was_closed_by_user) {
                    const created = createWindow(
                        self,
                        self.requested_width.load(.acquire),
                        self.requested_height.load(.acquire),
                    );
                    hwnd = created catch |err| {
                        creation_blocked = true;
                        log.warn(.app, "win create window failed", .{ .err = err });
                        continue;
                    };
                    if (hwnd) |window| {
                        last_resize_seq = self.resize_seq.load(.acquire);
                        last_presentation_seq = self.presentation_seq.load(.acquire);
                        syncWindowPresentation(window, self);
                    }
                }
            } else {
                creation_blocked = false;
                if (hwnd) |window| {
                    destroyWindow(window);
                    hwnd = null;
                }
            }

            if (hwnd) |window| {
                if (c.IsWindow(window) == 0) {
                    hwnd = null;
                    creation_blocked = false;
                } else {
                    const seq = self.resize_seq.load(.acquire);
                    if (seq != last_resize_seq) {
                        setClientSize(window, self.requested_width.load(.acquire), self.requested_height.load(.acquire));
                        last_resize_seq = seq;
                    }
                    const presentation_seq = self.presentation_seq.load(.acquire);
                    if (presentation_seq != last_presentation_seq) {
                        syncWindowPresentation(window, self);
                        last_presentation_seq = presentation_seq;
                    }
                }
            }

            std.Thread.sleep(15 * std.time.ns_per_ms);
        }

        if (hwnd) |window| {
            destroyWindow(window);
        }
    }
};

fn queueInputEvent(self: *Win32Backend, event: Win32Backend.InputEvent) void {
    self.input_lock.lock();
    defer self.input_lock.unlock();
    self.input_events.append(self.allocator, event) catch |err| {
        log.warn(.app, "win input queue overflow", .{ .err = err });
    };
}

const PresentationSnapshot = struct {
    title: []u8,
    url: []u8,
    body: []u8,
    display_list: ?DisplayList,
    scroll_px: i32,
    can_go_back: bool,
    can_go_forward: bool,
    is_loading: bool,
    zoom_percent: i32,
    address_text: []u8,
    address_editing: bool,
    find_text: []u8,
    find_editing: bool,
    find_match_index: usize,
    tab_entries: std.ArrayListUnmanaged(PresentationTabEntry),
    active_tab_index: usize,
    history_entries: std.ArrayListUnmanaged([]u8),
    history_current_index: usize,
    history_overlay_open: bool,
    history_selected_index: usize,
    history_scroll_index: usize,
    bookmark_entries: std.ArrayListUnmanaged([]u8),
    bookmark_overlay_open: bool,
    bookmark_selected_index: usize,
    bookmark_scroll_index: usize,
    download_entries: std.ArrayListUnmanaged(PresentationDownloadEntry),
    download_overlay_open: bool,
    download_selected_index: usize,
    download_scroll_index: usize,
    restore_previous_session: bool,
    default_zoom_percent: i32,
    homepage_url: []u8,
    settings_overlay_open: bool,
    settings_selected_index: usize,

    fn deinit(self: PresentationSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.body);
        if (self.display_list) |display_list| {
            var owned_list = display_list;
            owned_list.deinit(allocator);
        }
        allocator.free(self.address_text);
        allocator.free(self.find_text);
        var tab_entries = self.tab_entries;
        deinitOwnedTabList(&tab_entries, allocator);
        var history_entries = self.history_entries;
        deinitOwnedStringList(&history_entries, allocator);
        var bookmark_entries = self.bookmark_entries;
        deinitOwnedStringList(&bookmark_entries, allocator);
        var download_entries = self.download_entries;
        deinitOwnedDownloadList(&download_entries, allocator);
        allocator.free(self.homepage_url);
    }
};

const PRESENTATION_HEADER_HEIGHT: c_int = 92;
const PRESENTATION_MARGIN: c_int = 12;
const PRESENTATION_TAB_TOP: c_int = 6;
const PRESENTATION_TAB_BOTTOM: c_int = 24;
const PRESENTATION_TAB_GAP: c_int = 4;
const PRESENTATION_TAB_CLOSE_WIDTH: c_int = 18;
const PRESENTATION_TAB_NEW_WIDTH: c_int = 22;
const PRESENTATION_TAB_MIN_WIDTH: c_int = 56;
const PRESENTATION_TAB_MAX_WIDTH: c_int = 180;
const PRESENTATION_SCROLL_STEP: i32 = 48;
const PRESENTATION_PAGE_STEP: i32 = 320;
const PRESENTATION_ADDRESS_TOP: c_int = 28;
const PRESENTATION_ADDRESS_BOTTOM: c_int = 52;
const PRESENTATION_HINT_TOP: c_int = 58;
const PRESENTATION_HINT_BOTTOM: c_int = 78;
const PRESENTATION_FIND_TOP: c_int = 6;
const PRESENTATION_FIND_BOTTOM: c_int = 24;
const PRESENTATION_FIND_WIDTH: c_int = 300;
const PRESENTATION_FIND_BUTTON_WIDTH: c_int = 24;
const PRESENTATION_HISTORY_PANEL_WIDTH: c_int = 420;
const PRESENTATION_HISTORY_PANEL_TOP: c_int = PRESENTATION_HEADER_HEIGHT + 8;
const PRESENTATION_HISTORY_PANEL_ROW_HEIGHT: c_int = 24;
const PRESENTATION_HISTORY_PANEL_PADDING: c_int = 10;
const PRESENTATION_OVERLAY_FOOTER_HEIGHT: c_int = 18;
const PRESENTATION_OVERLAY_BUTTON_WIDTH: c_int = 24;
const PRESENTATION_OVERLAY_DELETE_BUTTON_WIDTH: c_int = 34;
const PRESENTATION_OVERLAY_BUTTON_GAP: c_int = 4;
const PRESENTATION_CHROME_BUTTON_WIDTH: c_int = 26;
const PRESENTATION_CHROME_BUTTON_GAP: c_int = 6;
const PRESENTATION_ADDRESS_LEFT_OFFSET: c_int =
    (PRESENTATION_CHROME_BUTTON_WIDTH * 3) + (PRESENTATION_CHROME_BUTTON_GAP * 3);

const ClientPoint = struct {
    x: f64,
    y: f64,
};

const HistoryOverlayChromeAction = enum {
    close,
};

const BookmarkOverlayChromeAction = enum {
    close,
    delete,
};

const DownloadOverlayChromeAction = enum {
    close,
    delete,
};

const SettingsOverlayChromeAction = enum {
    close,
    clear_homepage,
};

const SettingsOverlayAction = enum {
    toggle_restore_previous_session,
    default_zoom_decrease,
    default_zoom_increase,
    default_zoom_reset,
    set_homepage_to_current,
    clear_homepage,
};

const SettingsOverlayMove = enum {
    up,
    down,
    home,
    end,
};

const TabStripAction = union(enum) {
    activate: usize,
    close: usize,
    new_tab,
};

const ChromeButtonKind = enum {
    back,
    forward,
    reload,
};

const PresentationTabEntry = struct {
    title: []u8,
    url: []u8,
    is_loading: bool,

    fn deinit(self: *PresentationTabEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        self.* = undefined;
    }
};

const PresentationDownloadEntry = struct {
    filename: []u8,
    path: []u8,
    status: []u8,
    removable: bool,

    fn deinit(self: *PresentationDownloadEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.path);
        allocator.free(self.status);
        self.* = undefined;
    }
};

const FindMatch = struct {
    command_index: usize,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const FindChromeAction = enum {
    edit,
    previous,
    next,
};

const SettingsOverlayRow = enum(usize) {
    restore_previous_session = 0,
    default_zoom = 1,
    homepage = 2,
};

const BOOKMARKS_FILE = "bookmarks.txt";

fn deinitOwnedStringList(list: *std.ArrayListUnmanaged([]u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| {
        allocator.free(item);
    }
    list.deinit(allocator);
    list.* = .{};
}

fn deinitOwnedTabList(list: *std.ArrayListUnmanaged(PresentationTabEntry), allocator: std.mem.Allocator) void {
    for (list.items) |*entry| {
        entry.deinit(allocator);
    }
    list.deinit(allocator);
    list.* = .{};
}

fn deinitOwnedDownloadList(list: *std.ArrayListUnmanaged(PresentationDownloadEntry), allocator: std.mem.Allocator) void {
    for (list.items) |*entry| {
        entry.deinit(allocator);
    }
    list.deinit(allocator);
    list.* = .{};
}

fn presentationHasContent(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_body.len > 0 or
        backend.presentation_url.len > 0 or
        backend.presentation_title.len > 0 or
        backend.presentation_tab_entries.items.len > 0 or
        backend.address_input_active or
        backend.find_input_active or
        backend.history_overlay_open or
        backend.bookmark_overlay_open or
        backend.download_overlay_open or
        backend.settings_overlay_open;
}

fn copyPresentationSnapshot(backend: *Win32Backend) !PresentationSnapshot {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const address_source = if (backend.address_input_active) backend.address_input.items else backend.presentation_url;
    return .{
        .title = try backend.allocator.dupe(u8, backend.presentation_title),
        .url = try backend.allocator.dupe(u8, backend.presentation_url),
        .body = try backend.allocator.dupe(u8, backend.presentation_body),
        .display_list = if (backend.presentation_display_list) |*display_list|
            try display_list.cloneOwned(backend.allocator)
        else
            null,
        .scroll_px = backend.presentation_scroll_px,
        .can_go_back = backend.presentation_can_go_back,
        .can_go_forward = backend.presentation_can_go_forward,
        .is_loading = backend.presentation_is_loading,
        .zoom_percent = backend.presentation_zoom_percent,
        .address_text = try backend.allocator.dupe(u8, address_source),
        .address_editing = backend.address_input_active,
        .find_text = try backend.allocator.dupe(u8, backend.find_input.items),
        .find_editing = backend.find_input_active,
        .find_match_index = backend.find_match_index,
        .tab_entries = blk: {
            var tab_entries: std.ArrayListUnmanaged(PresentationTabEntry) = .{};
            errdefer deinitOwnedTabList(&tab_entries, backend.allocator);
            try tab_entries.ensureTotalCapacity(backend.allocator, backend.presentation_tab_entries.items.len);
            for (backend.presentation_tab_entries.items) |entry| {
                const owned_title = try backend.allocator.dupe(u8, entry.title);
                errdefer backend.allocator.free(owned_title);
                const owned_url = try backend.allocator.dupe(u8, entry.url);
                errdefer backend.allocator.free(owned_url);
                tab_entries.appendAssumeCapacity(.{
                    .title = owned_title,
                    .url = owned_url,
                    .is_loading = entry.is_loading,
                });
            }
            break :blk tab_entries;
        },
        .active_tab_index = if (backend.presentation_tab_entries.items.len == 0)
            0
        else
            @min(backend.presentation_active_tab_index, backend.presentation_tab_entries.items.len - 1),
        .history_entries = blk: {
            var history_entries: std.ArrayListUnmanaged([]u8) = .{};
            errdefer deinitOwnedStringList(&history_entries, backend.allocator);
            try history_entries.ensureTotalCapacity(backend.allocator, backend.presentation_history_entries.items.len);
            for (backend.presentation_history_entries.items) |entry| {
                history_entries.appendAssumeCapacity(try backend.allocator.dupe(u8, entry));
            }
            break :blk history_entries;
        },
        .history_current_index = backend.presentation_history_current_index,
        .history_overlay_open = backend.history_overlay_open,
        .history_selected_index = backend.history_overlay_selected_index,
        .history_scroll_index = backend.history_overlay_scroll_index,
        .bookmark_entries = blk: {
            var bookmark_entries: std.ArrayListUnmanaged([]u8) = .{};
            errdefer deinitOwnedStringList(&bookmark_entries, backend.allocator);
            try bookmark_entries.ensureTotalCapacity(backend.allocator, backend.presentation_bookmark_entries.items.len);
            for (backend.presentation_bookmark_entries.items) |entry| {
                bookmark_entries.appendAssumeCapacity(try backend.allocator.dupe(u8, entry));
            }
            break :blk bookmark_entries;
        },
        .bookmark_overlay_open = backend.bookmark_overlay_open,
        .bookmark_selected_index = backend.bookmark_overlay_selected_index,
        .bookmark_scroll_index = backend.bookmark_overlay_scroll_index,
        .download_entries = blk: {
            var download_entries: std.ArrayListUnmanaged(PresentationDownloadEntry) = .{};
            errdefer deinitOwnedDownloadList(&download_entries, backend.allocator);
            try download_entries.ensureTotalCapacity(backend.allocator, backend.presentation_download_entries.items.len);
            for (backend.presentation_download_entries.items) |entry| {
                download_entries.appendAssumeCapacity(.{
                    .filename = try backend.allocator.dupe(u8, entry.filename),
                    .path = try backend.allocator.dupe(u8, entry.path),
                    .status = try backend.allocator.dupe(u8, entry.status),
                    .removable = entry.removable,
                });
            }
            break :blk download_entries;
        },
        .download_overlay_open = backend.download_overlay_open,
        .download_selected_index = backend.download_overlay_selected_index,
        .download_scroll_index = backend.download_overlay_scroll_index,
        .restore_previous_session = backend.presentation_restore_previous_session,
        .default_zoom_percent = backend.presentation_default_zoom_percent,
        .homepage_url = try backend.allocator.dupe(u8, backend.presentation_homepage_url),
        .settings_overlay_open = backend.settings_overlay_open,
        .settings_selected_index = clampSettingsOverlaySelectedIndex(backend.settings_overlay_selected_index),
    };
}

fn scalePresentationValue(value: i32, zoom_percent: i32) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(zoom_percent)) / 100.0));
}

fn unscalePresentationValue(value: f64, zoom_percent: i32) f64 {
    return value * 100.0 / @as(f64, @floatFromInt(@max(@as(i32, 1), zoom_percent)));
}

fn zoomCommandForWheelDelta(raw_delta: i16) ?BrowserCommand {
    if (raw_delta > 0) {
        return .zoom_in;
    }
    if (raw_delta < 0) {
        return .zoom_out;
    }
    return null;
}

fn presentationClientToDisplayListLocked(
    backend: *Win32Backend,
    x: f64,
    y: f64,
) ?ClientPoint {
    const display_list = backend.presentation_display_list orelse return null;

    const content_x = x - @as(f64, @floatFromInt(PRESENTATION_MARGIN));
    const content_y = y - @as(f64, @floatFromInt(PRESENTATION_HEADER_HEIGHT + 8)) +
        @as(f64, @floatFromInt(backend.presentation_scroll_px));
    if (content_x < 0 or content_y < 0) {
        return null;
    }

    return .{
        .x = unscalePresentationValue(content_x, display_list.layout_scale),
        .y = unscalePresentationValue(content_y, display_list.layout_scale),
    };
}

fn presentationClientToPage(
    backend: *Win32Backend,
    x: f64,
    y: f64,
) ?ClientPoint {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const display_list = backend.presentation_display_list orelse return null;
    const point = presentationClientToDisplayListLocked(backend, x, y) orelse return null;

    return .{
        .x = point.x - @as(f64, @floatFromInt(display_list.page_margin)),
        .y = point.y - @as(f64, @floatFromInt(display_list.page_margin)),
    };
}

fn presentationHasNavigateAtClientPoint(backend: *Win32Backend, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return findPresentationLinkRegionLocked(backend, x, y) != null;
}

fn presentationCommandAtClientPoint(backend: *Win32Backend, hwnd: c.HWND, x: f64, y: f64) ?BrowserCommand {
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) {
        return presentationCommandAtClientPointWithClient(backend, null, x, y);
    }
    return presentationCommandAtClientPointWithClient(backend, client, x, y);
}

fn presentationNavigateCommandAtClientPoint(backend: *Win32Backend, x: f64, y: f64) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const region = findPresentationLinkRegionLocked(backend, x, y) orelse return null;
    const owned_url = backend.allocator.dupe(u8, region.url) catch |err| {
        log.warn(.app, "win link hit dupe", .{ .err = err });
        return null;
    };
    if (region.download_filename.len > 0) {
        const owned_filename = backend.allocator.dupe(u8, region.download_filename) catch |err| {
            backend.allocator.free(owned_url);
            log.warn(.app, "win dl hit dupe", .{ .err = err });
            return null;
        };
        return .{ .download = .{
            .url = owned_url,
            .suggested_filename = owned_filename,
        } };
    }
    return .{ .navigate = owned_url };
}

fn beginPendingPresentationCommand(backend: *Win32Backend, hwnd: c.HWND, x: f64, y: f64) bool {
    const command = presentationCommandAtClientPoint(backend, hwnd, x, y) orelse return false;
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.pending_presentation_command) |pending| {
        pending.deinit(backend.allocator);
    }
    backend.pending_presentation_command = command;
    return true;
}

fn takePendingPresentationCommand(backend: *Win32Backend) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const command = backend.pending_presentation_command orelse return null;
    backend.pending_presentation_command = null;
    return command;
}

fn cancelPendingPresentationCommand(backend: *Win32Backend) void {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.pending_presentation_command) |command| {
        command.deinit(backend.allocator);
        backend.pending_presentation_command = null;
    }
}

fn findPresentationLinkRegionLocked(backend: *Win32Backend, x: f64, y: f64) ?DisplayList.LinkRegion {
    const display_list = backend.presentation_display_list orelse return null;
    const point = presentationClientToDisplayListLocked(backend, x, y) orelse return null;
    const px: i32 = @intFromFloat(point.x);
    const py: i32 = @intFromFloat(point.y);
    var index = display_list.link_regions.items.len;
    while (index > 0) {
        index -= 1;
        const region = display_list.link_regions.items[index];
        if (px >= region.x and py >= region.y and px < region.x + region.width and py < region.y + region.height) {
            return region;
        }
    }
    return null;
}

fn presentationTabEntryCount(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_tab_entries.items.len;
}

fn presentationActiveTabIndex(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (backend.presentation_tab_entries.items.len == 0) {
        return 0;
    }
    return @min(backend.presentation_active_tab_index, backend.presentation_tab_entries.items.len - 1);
}

fn tabStripActionAtClientPoint(
    backend: *Win32Backend,
    client: c.RECT,
    x: f64,
    y: f64,
) ?TabStripAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (clientPointInRect(tabNewButtonRect(client), x, y)) {
        return .new_tab;
    }

    for (backend.presentation_tab_entries.items, 0..) |_, index| {
        const rect = tabRect(client, backend.presentation_tab_entries.items.len, index);
        if (tabHasCloseButton(rect) and clientPointInRect(tabCloseButtonRect(rect), x, y)) {
            return .{ .close = index };
        }
        if (clientPointInRect(rect, x, y)) {
            return .{ .activate = index };
        }
    }

    return null;
}

fn visibleHistoryEntryCount(client: c.RECT, entry_count: usize) usize {
    const reserved_height = 34 + PRESENTATION_OVERLAY_FOOTER_HEIGHT + PRESENTATION_HISTORY_PANEL_PADDING;
    const available_height = @max(0, client.bottom - PRESENTATION_HISTORY_PANEL_TOP - PRESENTATION_MARGIN - reserved_height);
    const visible = @max(1, @divTrunc(available_height, PRESENTATION_HISTORY_PANEL_ROW_HEIGHT));
    return @min(entry_count, @as(usize, @intCast(visible)));
}

fn clampOverlaySelectedIndex(entry_count: usize, selected_index: usize) usize {
    if (entry_count == 0) {
        return 0;
    }
    return @min(selected_index, entry_count - 1);
}

fn clampOverlayScrollIndex(entry_count: usize, scroll_index: usize, visible_count: usize) usize {
    if (entry_count == 0 or visible_count == 0 or entry_count <= visible_count) {
        return 0;
    }
    return @min(scroll_index, entry_count - visible_count);
}

fn scrollIndexForSelection(entry_count: usize, selected_index: usize, visible_count: usize) usize {
    if (entry_count == 0 or visible_count == 0 or entry_count <= visible_count) {
        return 0;
    }
    const clamped_selected = clampOverlaySelectedIndex(entry_count, selected_index);
    if (clamped_selected < visible_count) {
        return 0;
    }
    return @min(clamped_selected + 1 - visible_count, entry_count - visible_count);
}

fn ensureSelectionVisible(
    entry_count: usize,
    selected_index: usize,
    scroll_index: usize,
    visible_count: usize,
) usize {
    if (entry_count == 0 or visible_count == 0 or entry_count <= visible_count) {
        return 0;
    }
    const clamped_selected = clampOverlaySelectedIndex(entry_count, selected_index);
    const clamped_scroll = clampOverlayScrollIndex(entry_count, scroll_index, visible_count);
    if (clamped_selected < clamped_scroll) {
        return clamped_selected;
    }
    if (clamped_selected >= clamped_scroll + visible_count) {
        return clamped_selected + 1 - visible_count;
    }
    return clamped_scroll;
}

fn historyEntryWindowStart(client: c.RECT, entry_count: usize, scroll_index: usize, selected_index: usize) usize {
    const visible = visibleHistoryEntryCount(client, entry_count);
    return ensureSelectionVisible(entry_count, selected_index, scroll_index, visible);
}

fn bookmarkEntryWindowStart(client: c.RECT, entry_count: usize, scroll_index: usize, selected_index: usize) usize {
    const visible = visibleHistoryEntryCount(client, entry_count);
    return ensureSelectionVisible(entry_count, selected_index, scroll_index, visible);
}

fn stringListIndexOf(items: []const []const u8, value: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, value)) {
            return index;
        }
    }
    return null;
}

fn splitUrlForOverlay(url: []const u8) struct { host: []const u8, tail: []const u8 } {
    if (url.len == 0) {
        return .{ .host = "about:blank", .tail = "" };
    }

    const scheme_index = std.mem.indexOf(u8, url, "://");
    const host_start = if (scheme_index) |index| index + 3 else 0;
    const remainder = url[host_start..];
    const host_end_rel = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    const host = if (host_end_rel == 0) url else remainder[0..host_end_rel];
    const tail_full = if (host_end_rel < remainder.len) remainder[host_end_rel..] else "/";
    const tail = if (tail_full.len > 48) tail_full[0..48] else tail_full;
    return .{ .host = host, .tail = tail };
}

fn formatOverlayUrlLabel(
    allocator: std.mem.Allocator,
    url: []const u8,
    entry_index: usize,
    current: bool,
    bookmarked: bool,
) ![]u8 {
    const parts = splitUrlForOverlay(url);
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{d}. {s} {s}",
        .{
            if (current) ">" else " ",
            if (bookmarked) "*" else " ",
            entry_index + 1,
            parts.host,
            parts.tail,
        },
    );
}

fn formatOverlayStatusLabel(
    allocator: std.mem.Allocator,
    start_index: usize,
    visible_entries: usize,
    entry_count: usize,
    selected_index: usize,
    current_index: ?usize,
) ![]u8 {
    if (entry_count == 0 or visible_entries == 0) {
        return allocator.dupe(u8, "0/0");
    }

    const first = start_index + 1;
    const last = @min(entry_count, start_index + visible_entries);
    const selected_ordinal = clampOverlaySelectedIndex(entry_count, selected_index) + 1;
    const has_prev = start_index > 0;
    const has_next = last < entry_count;

    if (current_index) |current| {
        return std.fmt.allocPrint(
            allocator,
            "{d}-{d}/{d}  Sel {d}  Current {d}{s}{s}",
            .{
                first,
                last,
                entry_count,
                selected_ordinal,
                @min(entry_count, current + 1),
                if (has_prev) "  ^" else "",
                if (has_next) "  v" else "",
            },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{d}-{d}/{d}  Sel {d}{s}{s}",
        .{
            first,
            last,
            entry_count,
            selected_ordinal,
            if (has_prev) "  ^" else "",
            if (has_next) "  v" else "",
        },
    );
}

fn chromeButtonRect(kind: ChromeButtonKind) c.RECT {
    const slot: c_int = switch (kind) {
        .back => 0,
        .forward => 1,
        .reload => 2,
    };
    const left = PRESENTATION_MARGIN + (slot * (PRESENTATION_CHROME_BUTTON_WIDTH + PRESENTATION_CHROME_BUTTON_GAP));
    return .{
        .left = left,
        .top = PRESENTATION_ADDRESS_TOP,
        .right = left + PRESENTATION_CHROME_BUTTON_WIDTH,
        .bottom = PRESENTATION_ADDRESS_BOTTOM,
    };
}

fn tabStripRight(client: c.RECT) c_int {
    return findBoxRect(client).left - PRESENTATION_TAB_GAP;
}

fn tabNewButtonRect(client: c.RECT) c.RECT {
    const right = tabStripRight(client);
    return .{
        .left = @max(client.left + PRESENTATION_MARGIN, right - PRESENTATION_TAB_NEW_WIDTH),
        .top = PRESENTATION_TAB_TOP,
        .right = right,
        .bottom = PRESENTATION_TAB_BOTTOM,
    };
}

fn tabWidthForClient(client: c.RECT, tab_count: usize) c_int {
    if (tab_count == 0) {
        return 0;
    }
    const available_right = tabNewButtonRect(client).left - PRESENTATION_TAB_GAP;
    const gaps = @as(c_int, @intCast(@max(tab_count, 1) - 1)) * PRESENTATION_TAB_GAP;
    const available_width = @max(1, available_right - client.left - PRESENTATION_MARGIN - gaps);
    const raw = @divTrunc(available_width, @as(c_int, @intCast(tab_count)));
    return @max(1, @min(PRESENTATION_TAB_MAX_WIDTH, raw));
}

fn tabRect(client: c.RECT, tab_count: usize, index: usize) c.RECT {
    const width = tabWidthForClient(client, tab_count);
    const left = client.left + PRESENTATION_MARGIN +
        (@as(c_int, @intCast(index)) * (width + PRESENTATION_TAB_GAP));
    return .{
        .left = left,
        .top = PRESENTATION_TAB_TOP,
        .right = left + width,
        .bottom = PRESENTATION_TAB_BOTTOM,
    };
}

fn tabHasCloseButton(rect: c.RECT) bool {
    return rect.right - rect.left >= 44;
}

fn tabCloseButtonRect(rect: c.RECT) c.RECT {
    return .{
        .left = rect.right - PRESENTATION_TAB_CLOSE_WIDTH - 4,
        .top = rect.top + 2,
        .right = rect.right - 4,
        .bottom = rect.bottom - 2,
    };
}

fn clientPointInRect(rect: c.RECT, x: f64, y: f64) bool {
    return x >= @as(f64, @floatFromInt(rect.left)) and
        x < @as(f64, @floatFromInt(rect.right)) and
        y >= @as(f64, @floatFromInt(rect.top)) and
        y < @as(f64, @floatFromInt(rect.bottom));
}

fn findPreviousButtonRect(client: c.RECT) c.RECT {
    const box = findBoxRect(client);
    return .{
        .left = box.right - (PRESENTATION_FIND_BUTTON_WIDTH * 2),
        .top = box.top,
        .right = box.right - PRESENTATION_FIND_BUTTON_WIDTH,
        .bottom = box.bottom,
    };
}

fn findNextButtonRect(client: c.RECT) c.RECT {
    const box = findBoxRect(client);
    return .{
        .left = box.right - PRESENTATION_FIND_BUTTON_WIDTH,
        .top = box.top,
        .right = box.right,
        .bottom = box.bottom,
    };
}

fn historyPanelRect(client: c.RECT, entry_count: usize) c.RECT {
    const width = @min(PRESENTATION_HISTORY_PANEL_WIDTH, client.right - client.left - (PRESENTATION_MARGIN * 2));
    const right = client.right - PRESENTATION_MARGIN;
    const visible_entries = visibleHistoryEntryCount(client, entry_count);
    const height = 34 + (@as(c_int, @intCast(visible_entries)) * PRESENTATION_HISTORY_PANEL_ROW_HEIGHT) + PRESENTATION_OVERLAY_FOOTER_HEIGHT + PRESENTATION_HISTORY_PANEL_PADDING;
    return .{
        .left = right - width,
        .top = PRESENTATION_HISTORY_PANEL_TOP,
        .right = right,
        .bottom = @min(client.bottom - PRESENTATION_MARGIN, PRESENTATION_HISTORY_PANEL_TOP + height),
    };
}

fn historyOverlayCloseButtonRect(panel: c.RECT) c.RECT {
    return .{
        .left = panel.right - PRESENTATION_HISTORY_PANEL_PADDING - PRESENTATION_OVERLAY_BUTTON_WIDTH,
        .top = panel.top + 6,
        .right = panel.right - PRESENTATION_HISTORY_PANEL_PADDING,
        .bottom = panel.top + 24,
    };
}

fn bookmarkOverlayCloseButtonRect(panel: c.RECT) c.RECT {
    return historyOverlayCloseButtonRect(panel);
}

fn bookmarkOverlayDeleteButtonRect(panel: c.RECT) c.RECT {
    const right = bookmarkOverlayCloseButtonRect(panel).left - PRESENTATION_OVERLAY_BUTTON_GAP;
    return .{
        .left = right - PRESENTATION_OVERLAY_DELETE_BUTTON_WIDTH,
        .top = panel.top + 6,
        .right = right,
        .bottom = panel.top + 24,
    };
}

fn overlayFooterRect(panel: c.RECT) c.RECT {
    return .{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = panel.bottom - PRESENTATION_HISTORY_PANEL_PADDING - PRESENTATION_OVERLAY_FOOTER_HEIGHT,
        .right = panel.right - PRESENTATION_HISTORY_PANEL_PADDING,
        .bottom = panel.bottom - 4,
    };
}

fn settingsRowCount() usize {
    return 3;
}

fn settingsPanelRect(client: c.RECT) c.RECT {
    return historyPanelRect(client, settingsRowCount());
}

fn settingsOverlayCloseButtonRect(panel: c.RECT) c.RECT {
    return historyOverlayCloseButtonRect(panel);
}

fn settingsOverlayClearButtonRect(panel: c.RECT) c.RECT {
    return bookmarkOverlayDeleteButtonRect(panel);
}

fn settingsRowRect(client: c.RECT, row_index: usize) c.RECT {
    return historyEntryRect(client, settingsRowCount(), row_index);
}

fn historyEntryRect(client: c.RECT, entry_count: usize, index: usize) c.RECT {
    const panel = historyPanelRect(client, entry_count);
    const top = panel.top + 28 + (@as(c_int, @intCast(index)) * PRESENTATION_HISTORY_PANEL_ROW_HEIGHT);
    return .{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = top,
        .right = panel.right - PRESENTATION_HISTORY_PANEL_PADDING,
        .bottom = top + PRESENTATION_HISTORY_PANEL_ROW_HEIGHT,
    };
}

fn presentationHistoryOverlayOpen(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.history_overlay_open;
}

fn presentationHistoryEntryCount(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_history_entries.items.len;
}

fn presentationBookmarkOverlayOpen(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.bookmark_overlay_open;
}

fn presentationBookmarkEntryCount(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_bookmark_entries.items.len;
}

fn presentationDownloadOverlayOpen(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.download_overlay_open;
}

fn presentationDownloadEntryCount(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_download_entries.items.len;
}

fn presentationSettingsOverlayOpen(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.settings_overlay_open;
}

fn currentSettingsOverlaySelectedIndex(backend: *Win32Backend) usize {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return clampSettingsOverlaySelectedIndex(backend.settings_overlay_selected_index);
}

fn setHistoryOverlayOpen(backend: *Win32Backend, open: bool) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.history_overlay_open == open) {
        return false;
    }
    backend.history_overlay_open = open;
    if (open) {
        backend.bookmark_overlay_open = false;
        backend.download_overlay_open = false;
        backend.settings_overlay_open = false;
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        backend.address_input.clearRetainingCapacity();
        backend.find_input_active = false;
        backend.find_input_select_all = false;
        backend.find_pending_high_surrogate = null;
        backend.history_overlay_selected_index = backend.presentation_history_current_index;
        backend.history_overlay_scroll_index = 0;
    } else {
        backend.history_overlay_scroll_index = 0;
    }
    return true;
}

fn bookmarkIndexOfLocked(backend: *Win32Backend, url: []const u8) ?usize {
    return stringListIndexOf(backend.presentation_bookmark_entries.items, url);
}

fn bookmarkCurrentUrlIndexLocked(backend: *Win32Backend) ?usize {
    if (backend.presentation_url.len == 0) {
        return null;
    }
    return bookmarkIndexOfLocked(backend, backend.presentation_url);
}

fn currentUrlBookmarked(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return bookmarkCurrentUrlIndexLocked(backend) != null;
}

fn setBookmarkOverlayOpen(backend: *Win32Backend, open: bool) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.bookmark_overlay_open == open) {
        return false;
    }
    backend.bookmark_overlay_open = open;
    if (open) {
        backend.history_overlay_open = false;
        backend.download_overlay_open = false;
        backend.settings_overlay_open = false;
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        backend.address_input.clearRetainingCapacity();
        backend.find_input_active = false;
        backend.find_input_select_all = false;
        backend.find_pending_high_surrogate = null;
        backend.bookmark_overlay_selected_index = bookmarkCurrentUrlIndexLocked(backend) orelse 0;
        backend.bookmark_overlay_scroll_index = 0;
    } else {
        backend.bookmark_overlay_scroll_index = 0;
    }
    return true;
}

fn setDownloadOverlayOpen(backend: *Win32Backend, open: bool) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.download_overlay_open == open) {
        return false;
    }
    backend.download_overlay_open = open;
    if (open) {
        backend.history_overlay_open = false;
        backend.bookmark_overlay_open = false;
        backend.settings_overlay_open = false;
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        backend.address_input.clearRetainingCapacity();
        backend.find_input_active = false;
        backend.find_input_select_all = false;
        backend.find_pending_high_surrogate = null;
        backend.download_overlay_selected_index = if (backend.presentation_download_entries.items.len == 0)
            0
        else
            @min(backend.download_overlay_selected_index, backend.presentation_download_entries.items.len - 1);
        backend.download_overlay_scroll_index = 0;
    } else {
        backend.download_overlay_scroll_index = 0;
    }
    return true;
}

fn setSettingsOverlayOpen(backend: *Win32Backend, open: bool) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.settings_overlay_open == open) {
        return false;
    }
    backend.settings_overlay_open = open;
    if (open) {
        backend.history_overlay_open = false;
        backend.bookmark_overlay_open = false;
        backend.download_overlay_open = false;
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        backend.address_input.clearRetainingCapacity();
        backend.find_input_active = false;
        backend.find_input_select_all = false;
        backend.find_pending_high_surrogate = null;
        backend.settings_overlay_selected_index = 0;
    }
    return true;
}

fn clampSettingsOverlaySelectedIndex(selected_index: usize) usize {
    return @min(selected_index, settingsRowCount() - 1);
}

fn settingsActionForSelectedRow(selected_index: usize, variant: enum { primary, secondary, tertiary, clear }) ?SettingsOverlayAction {
    const row: SettingsOverlayRow = @enumFromInt(clampSettingsOverlaySelectedIndex(selected_index));
    return switch (row) {
        .restore_previous_session => switch (variant) {
            .primary, .secondary, .tertiary => .toggle_restore_previous_session,
            .clear => null,
        },
        .default_zoom => switch (variant) {
            .primary => .default_zoom_increase,
            .secondary => .default_zoom_decrease,
            .tertiary => .default_zoom_reset,
            .clear => null,
        },
        .homepage => switch (variant) {
            .primary, .secondary, .tertiary => .set_homepage_to_current,
            .clear => .clear_homepage,
        },
    };
}

fn queueSettingsOverlayAction(backend: *Win32Backend, action: SettingsOverlayAction) bool {
    switch (action) {
        .toggle_restore_previous_session => queueBrowserCommand(backend, .settings_toggle_restore_session),
        .default_zoom_decrease => queueBrowserCommand(backend, .settings_default_zoom_out),
        .default_zoom_increase => queueBrowserCommand(backend, .settings_default_zoom_in),
        .default_zoom_reset => queueBrowserCommand(backend, .settings_default_zoom_reset),
        .set_homepage_to_current => queueBrowserCommand(backend, .settings_set_homepage_to_current),
        .clear_homepage => queueBrowserCommand(backend, .settings_clear_homepage),
    }
    return true;
}

fn handleSettingsOverlayMove(hwnd: c.HWND, backend: *Win32Backend, move: SettingsOverlayMove) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.settings_overlay_open) {
        return false;
    }
    const next_index: usize = switch (move) {
        .up => if (backend.settings_overlay_selected_index == 0) 0 else backend.settings_overlay_selected_index - 1,
        .down => @min(backend.settings_overlay_selected_index + 1, settingsRowCount() - 1),
        .home => 0,
        .end => settingsRowCount() - 1,
    };
    if (next_index == backend.settings_overlay_selected_index) {
        return false;
    }
    backend.settings_overlay_selected_index = next_index;
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    return true;
}

fn settingsPanelHitTest(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.settings_overlay_open) {
        return false;
    }
    return clientPointInRect(settingsPanelRect(client), x, y);
}

fn settingsOverlayChromeActionAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?SettingsOverlayChromeAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.settings_overlay_open) {
        return null;
    }
    const panel = settingsPanelRect(client);
    if (clientPointInRect(settingsOverlayCloseButtonRect(panel), x, y)) {
        return .close;
    }
    if (backend.presentation_homepage_url.len > 0 and clientPointInRect(settingsOverlayClearButtonRect(panel), x, y)) {
        return .clear_homepage;
    }
    return null;
}

fn handleSettingsOverlayChromeClick(hwnd: c.HWND, backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    const action = settingsOverlayChromeActionAtClientPoint(backend, client, x, y) orelse return false;
    _ = c.SetFocus(hwnd);
    const changed = switch (action) {
        .close => setSettingsOverlayOpen(backend, false),
        .clear_homepage => queueSettingsOverlayAction(backend, .clear_homepage),
    };
    if (changed) {
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
    }
    return true;
}

fn selectSettingsRowAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.settings_overlay_open) {
        return false;
    }
    for (0..settingsRowCount()) |row_index| {
        if (!clientPointInRect(settingsRowRect(client, row_index), x, y)) {
            continue;
        }
        backend.settings_overlay_selected_index = row_index;
        return true;
    }
    return false;
}

fn toggleCurrentBookmark(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const current_url = std.mem.trim(u8, backend.presentation_url, &std.ascii.whitespace);
    if (current_url.len == 0) {
        return false;
    }

    if (bookmarkIndexOfLocked(backend, current_url)) |index| {
        const removed = backend.presentation_bookmark_entries.orderedRemove(index);
        backend.allocator.free(removed);
        backend.bookmark_overlay_selected_index = clampOverlaySelectedIndex(
            backend.presentation_bookmark_entries.items.len,
            backend.bookmark_overlay_selected_index,
        );
        if (backend.presentation_bookmark_entries.items.len == 0) {
            backend.bookmark_overlay_open = false;
            backend.bookmark_overlay_scroll_index = 0;
            backend.bookmark_overlay_selected_index = 0;
        }
    } else {
        const owned = backend.allocator.dupe(u8, current_url) catch |err| {
            log.warn(.app, "win bm copy", .{ .err = err });
            return false;
        };
        backend.presentation_bookmark_entries.append(backend.allocator, owned) catch |err| {
            backend.allocator.free(owned);
            log.warn(.app, "win bm add", .{ .err = err });
            return false;
        };
        backend.bookmark_overlay_selected_index = backend.presentation_bookmark_entries.items.len - 1;
    }

    backend.saveBookmarksToDiskLocked();
    _ = backend.presentation_seq.fetchAdd(1, .acq_rel);
    return true;
}

fn findChromeActionAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?FindChromeAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.find_input_active and backend.find_input.items.len == 0) {
        return null;
    }
    if (clientPointInRect(findPreviousButtonRect(client), x, y)) {
        return .previous;
    }
    if (clientPointInRect(findNextButtonRect(client), x, y)) {
        return .next;
    }
    if (clientPointInRect(findBoxRect(client), x, y)) {
        return .edit;
    }
    return null;
}

fn handleFindChromeClick(hwnd: c.HWND, backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    const action = findChromeActionAtClientPoint(backend, client, x, y) orelse return false;
    _ = c.SetFocus(hwnd);

    switch (action) {
        .edit => _ = beginFindEdit(backend),
        .previous => _ = updateFindSelection(hwnd, backend, .previous),
        .next => _ = updateFindSelection(hwnd, backend, .next),
    }
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    return true;
}

fn historyPanelHitTest(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open) {
        return false;
    }
    return clientPointInRect(historyPanelRect(client, backend.presentation_history_entries.items.len), x, y);
}

fn historyEntryCommandAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open) {
        return null;
    }
    const visible_entries = visibleHistoryEntryCount(client, backend.presentation_history_entries.items.len);
    const start_index = historyEntryWindowStart(
        client,
        backend.presentation_history_entries.items.len,
        backend.history_overlay_scroll_index,
        backend.history_overlay_selected_index,
    );
    for (0..visible_entries) |row_index| {
        if (!clientPointInRect(historyEntryRect(client, visible_entries, row_index), x, y)) {
            continue;
        }
        return .{ .history_traverse = start_index + row_index };
    }
    return null;
}

fn bookmarkPanelHitTest(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open) {
        return false;
    }
    return clientPointInRect(historyPanelRect(client, backend.presentation_bookmark_entries.items.len), x, y);
}

fn bookmarkEntryCommandAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open) {
        return null;
    }
    const visible_entries = visibleHistoryEntryCount(client, backend.presentation_bookmark_entries.items.len);
    const start_index = bookmarkEntryWindowStart(
        client,
        backend.presentation_bookmark_entries.items.len,
        backend.bookmark_overlay_scroll_index,
        backend.bookmark_overlay_selected_index,
    );
    for (0..visible_entries) |row_index| {
        if (!clientPointInRect(historyEntryRect(client, visible_entries, row_index), x, y)) {
            continue;
        }
        const entry_index = start_index + row_index;
        if (entry_index >= backend.presentation_bookmark_entries.items.len) {
            return null;
        }
        const url = backend.presentation_bookmark_entries.items[entry_index];
        const owned = backend.allocator.dupe(u8, url) catch |err| {
            log.warn(.app, "win bm nav", .{ .err = err });
            return null;
        };
        return .{ .navigate = owned };
    }
    return null;
}

fn historyOverlayChromeActionAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?HistoryOverlayChromeAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open) {
        return null;
    }
    const panel = historyPanelRect(client, backend.presentation_history_entries.items.len);
    if (clientPointInRect(historyOverlayCloseButtonRect(panel), x, y)) {
        return .close;
    }
    return null;
}

fn bookmarkOverlayChromeActionAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?BookmarkOverlayChromeAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open) {
        return null;
    }
    const panel = historyPanelRect(client, backend.presentation_bookmark_entries.items.len);
    if (clientPointInRect(bookmarkOverlayCloseButtonRect(panel), x, y)) {
        return .close;
    }
    if (backend.presentation_bookmark_entries.items.len > 0 and clientPointInRect(bookmarkOverlayDeleteButtonRect(panel), x, y)) {
        return .delete;
    }
    return null;
}

fn downloadPanelHitTest(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.download_overlay_open) {
        return false;
    }
    return clientPointInRect(historyPanelRect(client, backend.presentation_download_entries.items.len), x, y);
}

fn downloadOverlayChromeActionAtClientPoint(backend: *Win32Backend, client: c.RECT, x: f64, y: f64) ?DownloadOverlayChromeAction {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.download_overlay_open) {
        return null;
    }
    const panel = historyPanelRect(client, backend.presentation_download_entries.items.len);
    if (clientPointInRect(bookmarkOverlayCloseButtonRect(panel), x, y)) {
        return .close;
    }
    if (backend.presentation_download_entries.items.len > 0 and clientPointInRect(bookmarkOverlayDeleteButtonRect(panel), x, y)) {
        return .delete;
    }
    return null;
}

fn handleDownloadOverlayChromeClick(hwnd: c.HWND, backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    const action = downloadOverlayChromeActionAtClientPoint(backend, client, x, y) orelse return false;
    _ = c.SetFocus(hwnd);
    const changed = switch (action) {
        .close => setDownloadOverlayOpen(backend, false),
        .delete => deleteSelectedDownload(backend),
    };
    if (changed) {
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
    }
    return true;
}

fn handleHistoryOverlayChromeClick(hwnd: c.HWND, backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    const action = historyOverlayChromeActionAtClientPoint(backend, client, x, y) orelse return false;
    _ = c.SetFocus(hwnd);
    switch (action) {
        .close => _ = setHistoryOverlayOpen(backend, false),
    }
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    return true;
}

fn handleBookmarkOverlayChromeClick(hwnd: c.HWND, backend: *Win32Backend, client: c.RECT, x: f64, y: f64) bool {
    const action = bookmarkOverlayChromeActionAtClientPoint(backend, client, x, y) orelse return false;
    _ = c.SetFocus(hwnd);
    switch (action) {
        .close => _ = setBookmarkOverlayOpen(backend, false),
        .delete => _ = deleteSelectedBookmark(backend),
    }
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    return true;
}

fn presentationHasInteractiveAtClientPoint(backend: *Win32Backend, hwnd: c.HWND, x: f64, y: f64) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return tabStripActionAtClientPoint(backend, client, x, y) != null or
        chromeCommandKindAtClientPointEnabled(backend, x, y) != null or
        presentationHasNavigateAtClientPoint(backend, x, y) or
        findChromeActionAtClientPoint(backend, client, x, y) != null or
        historyOverlayChromeActionAtClientPoint(backend, client, x, y) != null or
        bookmarkOverlayChromeActionAtClientPoint(backend, client, x, y) != null or
        downloadOverlayChromeActionAtClientPoint(backend, client, x, y) != null or
        settingsOverlayChromeActionAtClientPoint(backend, client, x, y) != null or
        historyEntryCommandAtClientPoint(backend, client, x, y) != null or
        bookmarkEntryCommandAtClientPoint(backend, client, x, y) != null or
        downloadPanelHitTest(backend, client, x, y) or
        settingsPanelHitTest(backend, client, x, y);
}

fn presentationCommandAtClientPointWithClient(
    backend: *Win32Backend,
    maybe_client: ?c.RECT,
    x: f64,
    y: f64,
) ?BrowserCommand {
    if (maybe_client) |client| {
        if (tabStripActionAtClientPoint(backend, client, x, y)) |action| {
            return switch (action) {
                .activate => |index| .{ .tab_activate = index },
                .close => |index| .{ .tab_close = index },
                .new_tab => .tab_new,
            };
        }
        if (bookmarkEntryCommandAtClientPoint(backend, client, x, y)) |command| {
            return command;
        }
        if (historyEntryCommandAtClientPoint(backend, client, x, y)) |command| {
            return command;
        }
    }
    if (chromeCommandKindAtClientPointEnabled(backend, x, y)) |kind| {
        return switch (kind) {
            .back => .back,
            .forward => .forward,
            .reload => if (presentationChromeShowsStop(backend)) .stop else .reload,
        };
    }
    return presentationNavigateCommandAtClientPoint(backend, x, y);
}

fn chromeCommandKindAtClientPoint(x: f64, y: f64) ?ChromeButtonKind {
    return chromeButtonKindAtClientPoint(x, y);
}

fn chromeButtonKindAtClientPoint(x: f64, y: f64) ?ChromeButtonKind {
    inline for ([_]ChromeButtonKind{ .back, .forward, .reload }) |kind| {
        if (clientPointInRect(chromeButtonRect(kind), x, y)) {
            return kind;
        }
    }
    return null;
}

fn chromeCommandKindAtClientPointEnabled(backend: *Win32Backend, x: f64, y: f64) ?ChromeButtonKind {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const kind = chromeButtonKindAtClientPoint(x, y) orelse return null;
    return switch (kind) {
        .back => if (backend.presentation_can_go_back) .back else null,
        .forward => if (backend.presentation_can_go_forward) .forward else null,
        .reload => if (backend.presentation_is_loading or backend.presentation_url.len > 0) .reload else null,
    };
}

fn presentationChromeShowsStop(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_is_loading;
}

fn setPresentationCursor(hwnd: c.HWND, backend: *Win32Backend, x: f64, y: f64) void {
    const cursor_id: usize = if (presentationHasInteractiveAtClientPoint(backend, hwnd, x, y)) 32649 else 32512;
    if (loadCursorResource(cursor_id)) |cursor| {
        _ = c.SetCursor(cursor);
    }
}

fn loadCursorResource(cursor_id: usize) c.HCURSOR {
    return LoadCursorWUnaligned(null, @ptrFromInt(cursor_id));
}

fn queueBrowserCommand(backend: *Win32Backend, command: BrowserCommand) void {
    backend.command_lock.lock();
    defer backend.command_lock.unlock();
    backend.command_queue.append(backend.allocator, command) catch |err| {
        command.deinit(backend.allocator);
        log.warn(.app, "win command queue failed", .{ .err = err });
    };
}

fn beginAddressEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    backend.address_input.clearRetainingCapacity();
    backend.address_input.appendSlice(backend.allocator, backend.presentation_url) catch |err| {
        log.warn(.app, "win address edit failed", .{ .err = err });
        return false;
    };
    backend.address_input_active = true;
    backend.address_input_select_all = true;
    backend.address_pending_high_surrogate = null;
    backend.find_input_active = false;
    backend.find_input_select_all = false;
    backend.find_pending_high_surrogate = null;
    backend.history_overlay_open = false;
    backend.bookmark_overlay_open = false;
    return true;
}

fn cancelAddressEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active) {
        return false;
    }
    backend.address_input_active = false;
    backend.address_input_select_all = false;
    backend.address_input.clearRetainingCapacity();
    backend.address_pending_high_surrogate = null;
    return true;
}

fn commitAddressEdit(hwnd: c.HWND, backend: *Win32Backend) bool {
    _ = hwnd;

    backend.presentation_lock.lock();
    if (!backend.address_input_active) {
        backend.presentation_lock.unlock();
        return false;
    }

    const trimmed = std.mem.trim(u8, backend.address_input.items, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_input.clearRetainingCapacity();
        backend.address_pending_high_surrogate = null;
        backend.presentation_lock.unlock();
        return true;
    }

    const url = backend.allocator.dupe(u8, trimmed) catch |err| {
        log.warn(.app, "win address commit failed", .{ .err = err });
        backend.presentation_lock.unlock();
        return false;
    };
    backend.address_input_active = false;
    backend.address_input_select_all = false;
    backend.address_input.clearRetainingCapacity();
    backend.address_pending_high_surrogate = null;
    backend.presentation_lock.unlock();
    queueBrowserCommand(backend, .{ .navigate = url });
    return true;
}

fn deleteLastAddressCodepoint(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active or backend.address_input.items.len == 0) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.items.len = 0;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        return true;
    }

    var start = backend.address_input.items.len;
    while (start > 0) {
        start -= 1;
        if ((backend.address_input.items[start] & 0xC0) != 0x80) {
            break;
        }
    }
    backend.address_input.items.len = start;
    backend.address_pending_high_surrogate = null;
    return true;
}

fn appendAddressCodePoint(backend: *Win32Backend, cp_in: u32) bool {
    if (cp_in == 0 or cp_in > 0x10FFFF) {
        return false;
    }

    const cp: u21 = @intCast(if (cp_in == '\r') @as(u32, '\n') else cp_in);
    if (cp < 0x20 and cp != '\n' and cp != '\t') {
        return false;
    }
    if (!std.unicode.utf8ValidCodepoint(cp)) {
        return false;
    }

    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &bytes) catch return false;

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.address_input_active) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.clearRetainingCapacity();
        backend.address_input_select_all = false;
    }
    backend.address_input.appendSlice(backend.allocator, bytes[0..len]) catch |err| {
        log.warn(.app, "win address append failed", .{ .err = err });
        return false;
    };
    return true;
}

fn appendAddressUtf16Unit(backend: *Win32Backend, code_unit: u16) bool {
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        backend.address_pending_high_surrogate = code_unit;
        backend.presentation_lock.unlock();
        return true;
    }
    if (std.unicode.utf16IsLowSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        const high = backend.address_pending_high_surrogate;
        backend.address_pending_high_surrogate = null;
        backend.presentation_lock.unlock();
        if (high) |high_surrogate| {
            return appendAddressCodePoint(
                backend,
                std.unicode.utf16DecodeSurrogatePair(&.{ high_surrogate, code_unit }) catch return false,
            );
        }
        return false;
    }

    backend.presentation_lock.lock();
    backend.address_pending_high_surrogate = null;
    backend.presentation_lock.unlock();
    return appendAddressCodePoint(backend, code_unit);
}

fn appendClipboardToAddress(backend: *Win32Backend) bool {
    const clipboard = readClipboardTextUtf8(backend.allocator) catch |err| {
        log.warn(.app, "win clipboard read failed", .{ .err = err });
        return false;
    } orelse return false;
    defer backend.allocator.free(clipboard);

    const trimmed = std.mem.trim(u8, clipboard, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return false;
    }

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.address_input_active) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.clearRetainingCapacity();
        backend.address_input_select_all = false;
    }
    backend.address_input.appendSlice(backend.allocator, trimmed) catch |err| {
        log.warn(.app, "win address paste failed", .{ .err = err });
        return false;
    };
    backend.address_pending_high_surrogate = null;
    return true;
}

fn selectAllAddressInput(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active) {
        return false;
    }
    backend.address_input_select_all = true;
    backend.address_pending_high_surrogate = null;
    return true;
}

fn beginFindEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    backend.address_input_active = false;
    backend.address_input_select_all = false;
    backend.address_pending_high_surrogate = null;
    backend.address_input.clearRetainingCapacity();
    backend.find_input_active = true;
    backend.find_input_select_all = true;
    backend.find_pending_high_surrogate = null;
    backend.history_overlay_open = false;
    backend.bookmark_overlay_open = false;
    return true;
}

fn cancelFindEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.find_input_active) {
        return false;
    }
    backend.find_input_active = false;
    backend.find_input_select_all = false;
    backend.find_pending_high_surrogate = null;
    return true;
}

fn deleteLastFindCodepoint(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.find_input_active or backend.find_input.items.len == 0) {
        return false;
    }
    if (backend.find_input_select_all) {
        backend.find_input.items.len = 0;
        backend.find_input_select_all = false;
        backend.find_pending_high_surrogate = null;
        backend.find_match_index = 0;
        return true;
    }

    var start = backend.find_input.items.len;
    while (start > 0) {
        start -= 1;
        if ((backend.find_input.items[start] & 0xC0) != 0x80) {
            break;
        }
    }
    backend.find_input.items.len = start;
    backend.find_pending_high_surrogate = null;
    backend.find_match_index = 0;
    return true;
}

fn appendFindCodePoint(backend: *Win32Backend, cp_in: u32) bool {
    if (cp_in == 0 or cp_in > 0x10FFFF) {
        return false;
    }

    const cp: u21 = @intCast(if (cp_in == '\r') @as(u32, '\n') else cp_in);
    if (cp < 0x20 and cp != '\n' and cp != '\t') {
        return false;
    }
    if (!std.unicode.utf8ValidCodepoint(cp)) {
        return false;
    }

    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &bytes) catch return false;

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.find_input_active) {
        return false;
    }
    if (backend.find_input_select_all) {
        backend.find_input.clearRetainingCapacity();
        backend.find_input_select_all = false;
    }
    backend.find_input.appendSlice(backend.allocator, bytes[0..len]) catch |err| {
        log.warn(.app, "win find append failed", .{ .err = err });
        return false;
    };
    backend.find_match_index = 0;
    return true;
}

fn appendFindUtf16Unit(backend: *Win32Backend, code_unit: u16) bool {
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        backend.find_pending_high_surrogate = code_unit;
        backend.presentation_lock.unlock();
        return true;
    }
    if (std.unicode.utf16IsLowSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        const high = backend.find_pending_high_surrogate;
        backend.find_pending_high_surrogate = null;
        backend.presentation_lock.unlock();
        if (high) |high_surrogate| {
            return appendFindCodePoint(
                backend,
                std.unicode.utf16DecodeSurrogatePair(&.{ high_surrogate, code_unit }) catch return false,
            );
        }
        return false;
    }

    backend.presentation_lock.lock();
    backend.find_pending_high_surrogate = null;
    backend.presentation_lock.unlock();
    return appendFindCodePoint(backend, code_unit);
}

fn appendClipboardToFind(backend: *Win32Backend) bool {
    const clipboard = readClipboardTextUtf8(backend.allocator) catch |err| {
        log.warn(.app, "win clipboard read failed", .{ .err = err });
        return false;
    } orelse return false;
    defer backend.allocator.free(clipboard);

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.find_input_active) {
        return false;
    }
    if (backend.find_input_select_all) {
        backend.find_input.clearRetainingCapacity();
        backend.find_input_select_all = false;
    }
    backend.find_input.appendSlice(backend.allocator, clipboard) catch |err| {
        log.warn(.app, "win find paste failed", .{ .err = err });
        return false;
    };
    backend.find_pending_high_surrogate = null;
    backend.find_match_index = 0;
    return true;
}

fn selectAllFindInput(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.find_input_active) {
        return false;
    }
    backend.find_input_select_all = true;
    backend.find_pending_high_surrogate = null;
    return true;
}

fn presentationFindEditing(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.find_input_active;
}

fn normalizeFindMatchIndex(index: usize, match_count: usize) usize {
    if (match_count == 0) {
        return 0;
    }
    return index % match_count;
}

fn stepFindMatchIndex(index: usize, match_count: usize, forward: bool) usize {
    if (match_count == 0) {
        return 0;
    }
    const current = normalizeFindMatchIndex(index, match_count);
    if (forward) {
        return (current + 1) % match_count;
    }
    return if (current == 0) match_count - 1 else current - 1;
}

fn utf8CodepointCountLossy(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn collectFindMatchesForDisplayList(
    allocator: std.mem.Allocator,
    display_list: *const DisplayList,
    query: []const u8,
) !std.ArrayListUnmanaged(FindMatch) {
    var matches: std.ArrayListUnmanaged(FindMatch) = .{};
    errdefer matches.deinit(allocator);

    if (query.len == 0) {
        return matches;
    }

    for (display_list.commands.items, 0..) |command, command_index| {
        switch (command) {
            .text => |text_cmd| {
                const total_units = @max(@as(usize, 1), utf8CodepointCountLossy(text_cmd.text));
                const total_units_i32 = @as(i32, @intCast(@min(total_units, @as(usize, std.math.maxInt(i32)))));
                var search_start: usize = 0;
                while (search_start < text_cmd.text.len) {
                    const relative = std.ascii.indexOfIgnoreCase(text_cmd.text[search_start..], query) orelse break;
                    const match_start = search_start + relative;
                    const match_end = match_start + query.len;
                    const prefix_units = utf8CodepointCountLossy(text_cmd.text[0..match_start]);
                    const match_units = @max(@as(usize, 1), utf8CodepointCountLossy(text_cmd.text[match_start..match_end]));
                    const prefix_i32 = @as(i32, @intCast(@min(prefix_units, @as(usize, std.math.maxInt(i32)))));
                    const match_i32 = @as(i32, @intCast(@min(match_units, @as(usize, std.math.maxInt(i32)))));
                    const x_offset = @divTrunc(text_cmd.width * prefix_i32, total_units_i32);
                    const remaining_width = @max(1, text_cmd.width - x_offset);
                    const estimated_width = @max(
                        @as(i32, 8),
                        @divTrunc(text_cmd.width * match_i32, total_units_i32),
                    );
                    try matches.append(allocator, .{
                        .command_index = command_index,
                        .x = text_cmd.x + x_offset,
                        .y = text_cmd.y,
                        .width = @min(remaining_width, estimated_width),
                        .height = text_cmd.font_size + 8,
                    });
                    search_start = match_end;
                }
            },
            else => {},
        }
    }

    return matches;
}

const FindSelectionMode = enum {
    preserve,
    next,
    previous,
};

fn updateFindSelection(hwnd: c.HWND, backend: *Win32Backend, mode: FindSelectionMode) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const visible_height = @max(1, client.bottom - PRESENTATION_HEADER_HEIGHT - PRESENTATION_MARGIN);

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const display_list = backend.presentation_display_list orelse {
        backend.find_match_index = 0;
        return false;
    };
    if (backend.find_input.items.len == 0) {
        backend.find_match_index = 0;
        return false;
    }

    var matches = collectFindMatchesForDisplayList(backend.allocator, &display_list, backend.find_input.items) catch |err| {
        log.warn(.app, "win find match collect failed", .{ .err = err });
        return false;
    };
    defer matches.deinit(backend.allocator);

    if (matches.items.len == 0) {
        backend.find_match_index = 0;
        return false;
    }

    backend.find_match_index = switch (mode) {
        .preserve => normalizeFindMatchIndex(backend.find_match_index, matches.items.len),
        .next => stepFindMatchIndex(backend.find_match_index, matches.items.len, true),
        .previous => stepFindMatchIndex(backend.find_match_index, matches.items.len, false),
    };

    const current = matches.items[backend.find_match_index];
    const scaled_top = scalePresentationValue(current.y, display_list.layout_scale);
    const scaled_bottom = scalePresentationValue(current.y + current.height, display_list.layout_scale);
    const max_scroll = @max(0, scalePresentationValue(display_list.content_height, display_list.layout_scale) - visible_height);
    backend.presentation_max_scroll_px = max_scroll;

    var next_scroll = backend.presentation_scroll_px;
    if (scaled_top < next_scroll) {
        next_scroll = scaled_top;
    } else if (scaled_bottom > next_scroll + visible_height) {
        next_scroll = scaled_bottom - visible_height;
    }
    backend.presentation_scroll_px = std.math.clamp(next_scroll, 0, max_scroll);
    return true;
}

fn addressBarHitTest(x: f64, y: f64) bool {
    return x >= @as(f64, @floatFromInt(PRESENTATION_MARGIN + PRESENTATION_ADDRESS_LEFT_OFFSET)) and
        y >= @as(f64, @floatFromInt(PRESENTATION_ADDRESS_TOP - 4)) and
        y <= @as(f64, @floatFromInt(PRESENTATION_ADDRESS_BOTTOM + 4));
}

fn updatePresentationMaxScroll(backend: *Win32Backend, max_scroll: i32) i32 {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    backend.presentation_max_scroll_px = @max(0, max_scroll);
    if (backend.presentation_scroll_px > backend.presentation_max_scroll_px) {
        backend.presentation_scroll_px = backend.presentation_max_scroll_px;
    }
    if (backend.presentation_scroll_px < 0) {
        backend.presentation_scroll_px = 0;
    }
    return backend.presentation_scroll_px;
}

fn scrollPresentationBy(backend: *Win32Backend, delta: i32) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const unclamped = backend.presentation_scroll_px + delta;
    const clamped = std.math.clamp(unclamped, 0, backend.presentation_max_scroll_px);
    if (clamped == backend.presentation_scroll_px) {
        return false;
    }
    backend.presentation_scroll_px = clamped;
    return true;
}

fn scrollPresentationTo(backend: *Win32Backend, value: i32) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const clamped = std.math.clamp(value, 0, backend.presentation_max_scroll_px);
    if (clamped == backend.presentation_scroll_px) {
        return false;
    }
    backend.presentation_scroll_px = clamped;
    return true;
}

fn syncWindowPresentation(hwnd: c.HWND, backend: *Win32Backend) void {
    const snapshot = copyPresentationSnapshot(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return;
    };
    defer snapshot.deinit(backend.allocator);

    const title = formatWindowTitle(backend.allocator, snapshot.title, snapshot.url) catch |err| {
        log.warn(.app, "win title format failed", .{ .err = err });
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return;
    };
    defer backend.allocator.free(title);

    setWindowTextUtf8(hwnd, title);
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
}

fn formatWindowTitle(allocator: std.mem.Allocator, title: []const u8, url: []const u8) ![]u8 {
    const trimmed_title = std.mem.trim(u8, title, &std.ascii.whitespace);
    if (trimmed_title.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} - Lightpanda Browser", .{trimmed_title});
    }
    const trimmed_url = std.mem.trim(u8, url, &std.ascii.whitespace);
    if (trimmed_url.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} - Lightpanda Browser", .{trimmed_url});
    }
    return allocator.dupe(u8, "Lightpanda Browser");
}

fn setWindowTextUtf8(hwnd: c.HWND, text: []const u8) void {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(utf16);
    _ = c.SetWindowTextW(hwnd, utf16.ptr);
}

fn drawChromeButton(hdc: c.HDC, rect: c.RECT, label: []const u8, enabled: bool) void {
    const fill = if (enabled)
        c.CreateSolidBrush(c.RGB(245, 245, 245))
    else
        c.CreateSolidBrush(c.RGB(236, 236, 236));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = rect;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }

    const border = if (enabled)
        c.CreateSolidBrush(c.RGB(180, 180, 180))
    else
        c.CreateSolidBrush(c.RGB(210, 210, 210));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = rect;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    const previous_color = c.SetTextColor(hdc, if (enabled) c.RGB(32, 32, 32) else c.RGB(150, 150, 150));
    defer _ = c.SetTextColor(hdc, previous_color);

    var text_rect = rect;
    drawPresentationText(
        hdc,
        &text_rect,
        label,
        c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
}

fn drawTabStrip(
    hdc: c.HDC,
    client: c.RECT,
    snapshot: *const PresentationSnapshot,
    allocator: std.mem.Allocator,
) void {
    if (snapshot.tab_entries.items.len == 0) {
        var title_rect = c.RECT{
            .left = client.left + PRESENTATION_MARGIN,
            .top = client.top + 8,
            .right = findBoxRect(client).left - PRESENTATION_TAB_GAP,
            .bottom = client.top + 24,
        };
        const title_text = if (snapshot.title.len > 0) snapshot.title else "Lightpanda Browser";
        drawPresentationText(
            hdc,
            &title_rect,
            title_text,
            c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
        return;
    }

    for (snapshot.tab_entries.items, 0..) |entry, index| {
        const rect = tabRect(client, snapshot.tab_entries.items.len, index);
        const is_active = index == snapshot.active_tab_index;

        const fill = c.CreateSolidBrush(if (is_active)
            c.RGB(255, 255, 255)
        else
            c.RGB(240, 240, 240));
        if (fill != null) {
            defer _ = c.DeleteObject(fill);
            var fill_rect = rect;
            _ = c.FillRect(hdc, &fill_rect, fill);
        }

        const border = c.CreateSolidBrush(if (is_active)
            c.RGB(150, 150, 150)
        else
            c.RGB(190, 190, 190));
        if (border != null) {
            defer _ = c.DeleteObject(border);
            var border_rect = rect;
            _ = c.FrameRect(hdc, &border_rect, border);
        }

        const label = if (entry.is_loading)
            std.fmt.allocPrint(allocator, "* {s}", .{entry.title}) catch entry.title
        else
            entry.title;
        defer if (label.ptr != entry.title.ptr) allocator.free(label);

        var text_rect = rect;
        text_rect.left += 8;
        text_rect.right -= 6;
        if (tabHasCloseButton(rect)) {
            text_rect.right = tabCloseButtonRect(rect).left - 4;
        }

        drawPresentationText(
            hdc,
            &text_rect,
            label,
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );

        if (tabHasCloseButton(rect)) {
            drawChromeButton(hdc, tabCloseButtonRect(rect), "x", true);
        }
    }

    drawChromeButton(hdc, tabNewButtonRect(client), "+", true);
}

fn findBoxRect(client: c.RECT) c.RECT {
    const right = client.right - PRESENTATION_MARGIN;
    return .{
        .left = @max(client.left + PRESENTATION_MARGIN + 120, right - PRESENTATION_FIND_WIDTH),
        .top = client.top + PRESENTATION_FIND_TOP,
        .right = right,
        .bottom = client.top + PRESENTATION_FIND_BOTTOM,
    };
}

fn drawFindBox(
    hdc: c.HDC,
    client: c.RECT,
    query: []const u8,
    active: bool,
    current_match_ordinal: usize,
    match_count: usize,
    allocator: std.mem.Allocator,
) void {
    if (!active and query.len == 0) {
        return;
    }

    const rect = findBoxRect(client);
    const fill = c.CreateSolidBrush(if (match_count == 0 and query.len > 0)
        c.RGB(255, 236, 236)
    else if (active)
        c.RGB(255, 251, 223)
    else
        c.RGB(248, 248, 248));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = rect;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }

    const border = c.CreateSolidBrush(if (match_count == 0 and query.len > 0)
        c.RGB(210, 120, 120)
    else
        c.RGB(180, 180, 180));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = rect;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    var owned_label: ?[]u8 = null;
    defer if (owned_label) |label| allocator.free(label);
    const label = blk: {
        if (query.len == 0) {
            break :blk if (active) "Find: _" else "Find";
        }

        owned_label = if (active)
            std.fmt.allocPrint(allocator, "Find {d}/{d}: {s}_", .{ current_match_ordinal, match_count, query }) catch return
        else
            std.fmt.allocPrint(allocator, "Find {d}/{d}: {s}", .{ current_match_ordinal, match_count, query }) catch return;
        break :blk owned_label.?;
    };

    var text_rect = rect;
    text_rect.left += 8;
    text_rect.right = findPreviousButtonRect(client).left - 6;
    const previous_color = c.SetTextColor(hdc, c.RGB(32, 32, 32));
    defer _ = c.SetTextColor(hdc, previous_color);
    drawPresentationText(
        hdc,
        &text_rect,
        label,
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    drawChromeButton(hdc, findPreviousButtonRect(client), "<", match_count > 0);
    drawChromeButton(hdc, findNextButtonRect(client), ">", match_count > 0);
}

fn drawHistoryOverlay(
    hdc: c.HDC,
    client: c.RECT,
    entries: []const []const u8,
    current_index: usize,
    selected_index: usize,
    scroll_index: usize,
    allocator: std.mem.Allocator,
) void {
    const visible_entries = visibleHistoryEntryCount(client, entries.len);
    if (entries.len == 0 or visible_entries == 0) {
        return;
    }

    const panel = historyPanelRect(client, entries.len);
    const start_index = historyEntryWindowStart(client, entries.len, scroll_index, selected_index);
    const fill = c.CreateSolidBrush(c.RGB(248, 248, 248));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = panel;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }
    const border = c.CreateSolidBrush(c.RGB(180, 180, 180));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = panel;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    var header_rect = c.RECT{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = panel.top + 8,
        .right = historyOverlayCloseButtonRect(panel).left - 6,
        .bottom = panel.top + 26,
    };
    drawPresentationText(
        hdc,
        &header_rect,
        "History  Up/Down Enter  Ctrl+H close",
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
    drawChromeButton(hdc, historyOverlayCloseButtonRect(panel), "x", true);

    for (entries[start_index .. start_index + visible_entries], 0..) |entry, row_index| {
        const entry_index = start_index + row_index;
        var row_rect = historyEntryRect(client, visible_entries, row_index);
        if (entry_index == current_index) {
            const current_fill = c.CreateSolidBrush(c.RGB(229, 239, 255));
            if (current_fill != null) {
                defer _ = c.DeleteObject(current_fill);
                var fill_rect = row_rect;
                _ = c.FillRect(hdc, &fill_rect, current_fill);
            }
        }
        if (entry_index == selected_index) {
            const selected_border = c.CreateSolidBrush(c.RGB(185, 140, 40));
            if (selected_border != null) {
                defer _ = c.DeleteObject(selected_border);
                var selected_rect = row_rect;
                _ = c.FrameRect(hdc, &selected_rect, selected_border);
            }
        }

        const owned_label = formatOverlayUrlLabel(
            allocator,
            entry,
            entry_index,
            entry_index == current_index,
            false,
        ) catch null;
        defer if (owned_label) |label| allocator.free(label);
        const label = owned_label orelse entry;
        row_rect.left += 6;
        row_rect.right -= 6;
        drawPresentationText(
            hdc,
            &row_rect,
            label,
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
    }

    const owned_footer = formatOverlayStatusLabel(
        allocator,
        start_index,
        visible_entries,
        entries.len,
        selected_index,
        current_index,
    ) catch null;
    defer if (owned_footer) |footer| allocator.free(footer);
    var footer_rect = overlayFooterRect(panel);
    drawPresentationText(
        hdc,
        &footer_rect,
        owned_footer orelse "",
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

fn drawBookmarkOverlay(
    hdc: c.HDC,
    client: c.RECT,
    entries: []const []const u8,
    current_url: []const u8,
    selected_index: usize,
    scroll_index: usize,
    allocator: std.mem.Allocator,
) void {
    const panel = historyPanelRect(client, entries.len);
    const fill = c.CreateSolidBrush(c.RGB(248, 248, 248));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = panel;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }
    const border = c.CreateSolidBrush(c.RGB(180, 180, 180));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = panel;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    var header_rect = c.RECT{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = panel.top + 8,
        .right = bookmarkOverlayDeleteButtonRect(panel).left - 6,
        .bottom = panel.top + 26,
    };
    const owned_header: ?[]u8 = std.fmt.allocPrint(
        allocator,
        "Bookmarks {d}  Ctrl+Shift+B close",
        .{entries.len},
    ) catch null;
    defer if (owned_header) |header| allocator.free(header);
    const header = owned_header orelse "Bookmarks";
    drawPresentationText(
        hdc,
        &header_rect,
        header,
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
    drawChromeButton(hdc, bookmarkOverlayDeleteButtonRect(panel), "Del", entries.len > 0);
    drawChromeButton(hdc, bookmarkOverlayCloseButtonRect(panel), "x", true);

    if (entries.len == 0) {
        var empty_rect = c.RECT{
            .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
            .top = panel.top + 36,
            .right = panel.right - PRESENTATION_HISTORY_PANEL_PADDING,
            .bottom = panel.bottom - PRESENTATION_HISTORY_PANEL_PADDING,
        };
        drawPresentationText(
            hdc,
            &empty_rect,
            "No bookmarks yet. Press Ctrl+D on a page.",
            c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
        );
        return;
    }

    const visible_entries = visibleHistoryEntryCount(client, entries.len);
    const start_index = bookmarkEntryWindowStart(client, entries.len, scroll_index, selected_index);
    for (entries[start_index .. start_index + visible_entries], 0..) |entry, row_index| {
        const entry_index = start_index + row_index;
        var row_rect = historyEntryRect(client, visible_entries, row_index);
        if (std.mem.eql(u8, entry, current_url)) {
            const current_fill = c.CreateSolidBrush(c.RGB(229, 239, 255));
            if (current_fill != null) {
                defer _ = c.DeleteObject(current_fill);
                var fill_rect = row_rect;
                _ = c.FillRect(hdc, &fill_rect, current_fill);
            }
        }
        if (entry_index == selected_index) {
            const selected_border = c.CreateSolidBrush(c.RGB(185, 140, 40));
            if (selected_border != null) {
                defer _ = c.DeleteObject(selected_border);
                var selected_rect = row_rect;
                _ = c.FrameRect(hdc, &selected_rect, selected_border);
            }
        }

        const owned_label = formatOverlayUrlLabel(
            allocator,
            entry,
            entry_index,
            std.mem.eql(u8, entry, current_url),
            true,
        ) catch null;
        defer if (owned_label) |label| allocator.free(label);
        const label = owned_label orelse entry;
        row_rect.left += 6;
        row_rect.right -= 6;
        drawPresentationText(
            hdc,
            &row_rect,
            label,
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
    }

    const current_index = stringListIndexOf(entries, current_url);
    const owned_footer = formatOverlayStatusLabel(
        allocator,
        start_index,
        visible_entries,
        entries.len,
        selected_index,
        current_index,
    ) catch null;
    defer if (owned_footer) |footer| allocator.free(footer);
    var footer_rect = overlayFooterRect(panel);
    drawPresentationText(
        hdc,
        &footer_rect,
        owned_footer orelse "",
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

fn drawDownloadOverlay(
    hdc: c.HDC,
    client: c.RECT,
    entries: []const PresentationDownloadEntry,
    selected_index: usize,
    scroll_index: usize,
    allocator: std.mem.Allocator,
) void {
    const panel = historyPanelRect(client, entries.len);
    const fill = c.CreateSolidBrush(c.RGB(248, 248, 248));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = panel;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }
    const border = c.CreateSolidBrush(c.RGB(180, 180, 180));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = panel;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    var header_rect = c.RECT{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = panel.top + 8,
        .right = bookmarkOverlayDeleteButtonRect(panel).left - 6,
        .bottom = panel.top + 26,
    };
    const owned_header: ?[]u8 = std.fmt.allocPrint(
        allocator,
        "Downloads {d}  Ctrl+J close",
        .{entries.len},
    ) catch null;
    defer if (owned_header) |header| allocator.free(header);
    drawPresentationText(
        hdc,
        &header_rect,
        owned_header orelse "Downloads",
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
    const can_delete = entries.len > 0 and entries[clampOverlaySelectedIndex(entries.len, selected_index)].removable;
    drawChromeButton(hdc, bookmarkOverlayDeleteButtonRect(panel), "Del", can_delete);
    drawChromeButton(hdc, bookmarkOverlayCloseButtonRect(panel), "x", true);

    if (entries.len == 0) {
        var empty_rect = c.RECT{
            .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
            .top = panel.top + 36,
            .right = panel.right - PRESENTATION_HISTORY_PANEL_PADDING,
            .bottom = panel.bottom - PRESENTATION_HISTORY_PANEL_PADDING,
        };
        drawPresentationText(
            hdc,
            &empty_rect,
            "No downloads yet. Click a download link or use site flows that trigger downloads.",
            c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
        );
        return;
    }

    const visible_entries = visibleHistoryEntryCount(client, entries.len);
    const start_index = bookmarkEntryWindowStart(client, entries.len, scroll_index, selected_index);
    for (entries[start_index .. start_index + visible_entries], 0..) |entry, row_index| {
        const entry_index = start_index + row_index;
        var row_rect = historyEntryRect(client, visible_entries, row_index);
        if (entry_index == selected_index) {
            const selected_border = c.CreateSolidBrush(c.RGB(185, 140, 40));
            if (selected_border != null) {
                defer _ = c.DeleteObject(selected_border);
                var selected_rect = row_rect;
                _ = c.FrameRect(hdc, &selected_rect, selected_border);
            }
        }

        const owned_label = std.fmt.allocPrint(
            allocator,
            "{d}. {s}  [{s}]",
            .{ entry_index + 1, entry.filename, entry.status },
        ) catch null;
        defer if (owned_label) |label| allocator.free(label);
        row_rect.left += 6;
        row_rect.right -= 6;
        drawPresentationText(
            hdc,
            &row_rect,
            owned_label orelse entry.filename,
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
    }

    const selected = entries[clampOverlaySelectedIndex(entries.len, selected_index)];
    const owned_footer = std.fmt.allocPrint(
        allocator,
        "{d}-{d}/{d}  Sel {d}  {s}",
        .{
            start_index + 1,
            @min(entries.len, start_index + visible_entries),
            entries.len,
            clampOverlaySelectedIndex(entries.len, selected_index) + 1,
            selected.path,
        },
    ) catch null;
    defer if (owned_footer) |footer| allocator.free(footer);
    var footer_rect = overlayFooterRect(panel);
    drawPresentationText(
        hdc,
        &footer_rect,
        owned_footer orelse selected.path,
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

fn drawSettingsOverlay(
    hdc: c.HDC,
    client: c.RECT,
    snapshot: PresentationSnapshot,
    allocator: std.mem.Allocator,
) void {
    const panel = settingsPanelRect(client);
    const fill = c.CreateSolidBrush(c.RGB(248, 248, 248));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = panel;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }
    const border = c.CreateSolidBrush(c.RGB(180, 180, 180));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = panel;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    var header_rect = c.RECT{
        .left = panel.left + PRESENTATION_HISTORY_PANEL_PADDING,
        .top = panel.top + 8,
        .right = settingsOverlayClearButtonRect(panel).left - 6,
        .bottom = panel.top + 26,
    };
    drawPresentationText(
        hdc,
        &header_rect,
        "Settings  Ctrl+, close  Alt+Home home",
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
    drawChromeButton(hdc, settingsOverlayClearButtonRect(panel), "Clr", snapshot.homepage_url.len > 0);
    drawChromeButton(hdc, settingsOverlayCloseButtonRect(panel), "x", true);

    for (0..settingsRowCount()) |row_index| {
        var row_rect = settingsRowRect(client, row_index);
        if (row_index == snapshot.settings_selected_index) {
            const selected_border = c.CreateSolidBrush(c.RGB(185, 140, 40));
            if (selected_border != null) {
                defer _ = c.DeleteObject(selected_border);
                var selected_rect = row_rect;
                _ = c.FrameRect(hdc, &selected_rect, selected_border);
            }
        }

        const label = switch (@as(SettingsOverlayRow, @enumFromInt(row_index))) {
            .restore_previous_session => std.fmt.allocPrint(
                allocator,
                "1. Restore previous session: {s}  [Enter/Space toggle]",
                .{if (snapshot.restore_previous_session) "On" else "Off"},
            ) catch null,
            .default_zoom => std.fmt.allocPrint(
                allocator,
                "2. Default zoom: {d}%  [Left/Right adjust, Enter reset]",
                .{snapshot.default_zoom_percent},
            ) catch null,
            .homepage => std.fmt.allocPrint(
                allocator,
                "3. Homepage: {s}  [Enter set current, Delete clear]",
                .{if (snapshot.homepage_url.len > 0) snapshot.homepage_url else "(none)"},
            ) catch null,
        };
        defer if (label) |owned_label| allocator.free(owned_label);
        row_rect.left += 6;
        row_rect.right -= 6;
        drawPresentationText(
            hdc,
            &row_rect,
            label orelse "",
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
    }

    const footer = switch (@as(SettingsOverlayRow, @enumFromInt(snapshot.settings_selected_index))) {
        .restore_previous_session => "Up/Down move  Enter/Space toggle this setting",
        .default_zoom => "Up/Down move  Left/Right change  Enter reset default zoom",
        .homepage => "Up/Down move  Enter set homepage to current page  Delete clears",
    };
    var footer_rect = overlayFooterRect(panel);
    drawPresentationText(
        hdc,
        &footer_rect,
        footer,
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

fn drawPresentationText(hdc: c.HDC, rect: *c.RECT, text: []const u8, flags: c.UINT) void {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(utf16);
    if (utf16.len == 0) {
        return;
    }
    _ = c.DrawTextW(hdc, utf16.ptr, @intCast(utf16.len), rect, flags);
}

fn colorRef(color: DisplayColor) c.COLORREF {
    return @as(c.COLORREF, color.r) |
        (@as(c.COLORREF, color.g) << 8) |
        (@as(c.COLORREF, color.b) << 16);
}

fn ensureGdiplusStarted(backend: *Win32Backend) bool {
    if (backend.gdiplus_started) {
        return true;
    }

    var input = GdiplusStartupInput{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = c.FALSE,
        .SuppressExternalCodecs = c.FALSE,
    };
    var token: c.ULONG_PTR = 0;
    const status = GdiplusStartup(&token, &input, null);
    if (status != GDIP_STATUS_OK) {
        log.warn(.app, "win gdiplus startup failed", .{ .status = status });
        return false;
    }

    backend.gdiplus_token = token;
    backend.gdiplus_started = true;
    return true;
}

fn downloadHttpImageCacheFile(backend: *Win32Backend, url: []const u8) ![]u8 {
    const wide_url = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, url);
    defer std.heap.c_allocator.free(wide_url);

    var wide_path: [c.MAX_PATH + 1]u16 = [_]u16{0} ** (c.MAX_PATH + 1);
    const hr = c.URLDownloadToCacheFileW(
        null,
        wide_url.ptr,
        &wide_path,
        wide_path.len,
        0,
        null,
    );
    if (hr != 0) {
        return error.UrlDownloadFailed;
    }

    const path_len = std.mem.indexOfScalar(u16, wide_path[0..], 0) orelse wide_path.len;
    return std.unicode.utf16LeToUtf8Alloc(backend.allocator, wide_path[0..path_len]);
}

const CachedImageSource = struct {
    path: []u8,
    owns_file: bool = false,
};

fn localFilePathFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "file://")) {
        return error.UnsupportedImageUrl;
    }

    const after_scheme = url["file://".len..];
    const end = std.mem.indexOfAny(u8, after_scheme, "?#") orelse after_scheme.len;
    var raw_path = after_scheme[0..end];

    if (std.mem.startsWith(u8, raw_path, "localhost/")) {
        raw_path = raw_path["localhost".len..];
    }

    raw_path = std.mem.trimLeft(u8, raw_path, "/");
    if (raw_path.len == 0) {
        return error.InvalidFileUrl;
    }

    const unescaped = try URL.unescape(allocator, raw_path);
    defer if (unescaped.ptr != raw_path.ptr) allocator.free(unescaped);

    const owned = try allocator.dupe(u8, unescaped);
    for (owned) |*ch| {
        if (ch.* == '/') {
            ch.* = '\\';
        }
    }
    return owned;
}

fn parseDataUriBytes(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return error.InvalidDataUrl;
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUrl;
    const data = uri[data_starts + 1 ..];

    const unescaped = try URL.unescape(allocator, data);
    const metadata = uri[0..data_starts];
    if (!std.mem.endsWith(u8, metadata, ";base64")) {
        defer if (unescaped.ptr != data.ptr) allocator.free(unescaped);
        return allocator.dupe(u8, unescaped);
    }
    defer if (unescaped.ptr != data.ptr) allocator.free(unescaped);

    var stripped = try std.ArrayList(u8).initCapacity(allocator, unescaped.len);
    defer stripped.deinit(allocator);
    for (unescaped) |cch| {
        if (!std.ascii.isWhitespace(cch)) {
            stripped.appendAssumeCapacity(cch);
        }
    }
    const trimmed = std.mem.trimRight(u8, stripped.items, "=");
    if (trimmed.len % 4 == 1) {
        return error.InvalidDataUrl;
    }

    const decoded_size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return error.InvalidDataUrl;
    const buffer = try allocator.alloc(u8, decoded_size);
    std.base64.standard_no_pad.Decoder.decode(buffer, trimmed) catch return error.InvalidDataUrl;
    return buffer;
}

fn tempImageCacheFilePath(allocator: std.mem.Allocator, url: []const u8, extension: []const u8) ![]u8 {
    const temp_root = std.process.getEnvVarOwned(allocator, "TEMP") catch try allocator.dupe(u8, ".");
    defer allocator.free(temp_root);

    const cache_dir = try std.fs.path.join(allocator, &.{ temp_root, "lightpanda-image-cache" });
    defer allocator.free(cache_dir);
    if (std.fs.path.isAbsolute(cache_dir)) {
        std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(url);
    const hash = hasher.final();
    return std.fmt.allocPrint(allocator, "{s}\\{x}.{s}", .{ cache_dir, hash, extension });
}

fn dataUriFileExtension(src: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return "img";
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return "img";
    const metadata = uri[0..data_starts];
    const media_type = metadata[0 .. std.mem.indexOfScalar(u8, metadata, ';') orelse metadata.len];

    if (std.ascii.eqlIgnoreCase(media_type, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(media_type, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(media_type, "image/jpg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(media_type, "image/gif")) return "gif";
    if (std.ascii.eqlIgnoreCase(media_type, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(media_type, "image/bmp")) return "bmp";
    return "img";
}

fn writeDataImageCacheFile(backend: *Win32Backend, url: []const u8) ![]u8 {
    const data = try parseDataUriBytes(backend.allocator, url);
    defer backend.allocator.free(data);

    const path = try tempImageCacheFilePath(backend.allocator, url, dataUriFileExtension(url));
    errdefer backend.allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
    return path;
}

fn resolveImageCacheSource(backend: *Win32Backend, url: []const u8) !CachedImageSource {
    if (std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://"))
    {
        return .{ .path = try downloadHttpImageCacheFile(backend, url) };
    }
    if (std.ascii.startsWithIgnoreCase(url, "file://")) {
        return .{ .path = try localFilePathFromUrl(backend.allocator, url) };
    }
    if (std.ascii.startsWithIgnoreCase(url, "data:")) {
        return .{ .path = try writeDataImageCacheFile(backend, url), .owns_file = true };
    }
    return error.UnsupportedImageUrl;
}

fn loadCachedImageLocked(backend: *Win32Backend, image: *CachedImage, url: []const u8) void {
    if (!ensureGdiplusStarted(backend)) {
        image.state = .failed;
        return;
    }

    const source = resolveImageCacheSource(backend, url) catch |err| {
        log.warn(.app, "win image src fail", .{ .url = url, .err = err });
        image.state = .failed;
        return;
    };
    const cache_path = source.path;
    errdefer backend.allocator.free(cache_path);

    const wide_path = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, cache_path) catch |err| {
        log.warn(.app, "win image path encode failed", .{ .path = cache_path, .err = err });
        image.state = .failed;
        return;
    };
    defer std.heap.c_allocator.free(wide_path);

    var gp_image: ?*GpImage = null;
    const status = GdipLoadImageFromFile(wide_path.ptr, &gp_image);
    if (status != GDIP_STATUS_OK or gp_image == null) {
        log.warn(.app, "win image decode failed", .{ .status = status, .path = cache_path });
        image.state = .failed;
        return;
    }

    var width: c.UINT = 0;
    var height: c.UINT = 0;
    if (GdipGetImageWidth(gp_image.?, &width) != GDIP_STATUS_OK or
        GdipGetImageHeight(gp_image.?, &height) != GDIP_STATUS_OK)
    {
        _ = GdipDisposeImage(gp_image.?);
        log.warn(.app, "win image dimension failed", .{ .path = cache_path });
        image.state = .failed;
        return;
    }

    image.cache_path = cache_path;
    image.gp_image = gp_image;
    image.width = width;
    image.height = height;
    image.owns_cache_file = source.owns_file;
    image.state = .loaded;
}

fn imagePlaceholderText(image: ImageCommand) []const u8 {
    const alt = std.mem.trim(u8, image.alt, &std.ascii.whitespace);
    if (alt.len > 0) {
        return alt;
    }

    const basename = std.fs.path.basename(image.url);
    if (basename.len > 0 and !std.mem.eql(u8, basename, "/")) {
        return basename;
    }

    return "[image]";
}

fn drawPresentationImagePlaceholder(hdc: c.HDC, rect: c.RECT, image: ImageCommand) void {
    var text_rect = rect;
    text_rect.left += 8;
    text_rect.top += 8;
    text_rect.right -= 8;
    text_rect.bottom -= 8;

    const previous = c.SetTextColor(hdc, colorRef(.{ .r = 110, .g = 110, .b = 110 }));
    defer _ = c.SetTextColor(hdc, previous);

    drawPresentationText(
        hdc,
        &text_rect,
        imagePlaceholderText(image),
        c.DT_CENTER | c.DT_VCENTER | c.DT_WORDBREAK | c.DT_NOPREFIX,
    );
}

fn fitImageRect(rect: c.RECT, image_width: u32, image_height: u32) c.RECT {
    const target_width = rect.right - rect.left;
    const target_height = rect.bottom - rect.top;
    if (target_width <= 0 or target_height <= 0 or image_width == 0 or image_height == 0) {
        return rect;
    }

    const width_scale = @as(f64, @floatFromInt(target_width)) / @as(f64, @floatFromInt(image_width));
    const height_scale = @as(f64, @floatFromInt(target_height)) / @as(f64, @floatFromInt(image_height));
    const scale = @min(width_scale, height_scale);
    const draw_width: c.INT = @max(1, @as(c.INT, @intFromFloat(@round(@as(f64, @floatFromInt(image_width)) * scale))));
    const draw_height: c.INT = @max(1, @as(c.INT, @intFromFloat(@round(@as(f64, @floatFromInt(image_height)) * scale))));
    const offset_x = @divTrunc(target_width - draw_width, 2);
    const offset_y = @divTrunc(target_height - draw_height, 2);

    return .{
        .left = rect.left + offset_x,
        .top = rect.top + offset_y,
        .right = rect.left + offset_x + draw_width,
        .bottom = rect.top + offset_y + draw_height,
    };
}

fn drawPresentationImage(
    backend: *Win32Backend,
    hdc: c.HDC,
    rect: c.RECT,
    image_cmd: ImageCommand,
) void {
    backend.image_cache_lock.lock();
    defer backend.image_cache_lock.unlock();

    const owned_key = backend.allocator.dupe(u8, image_cmd.url) catch {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    };
    errdefer backend.allocator.free(owned_key);

    const gop = backend.image_cache.getOrPut(backend.allocator, owned_key) catch {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    };
    if (gop.found_existing) {
        backend.allocator.free(owned_key);
    } else {
        gop.key_ptr.* = owned_key;
        gop.value_ptr.* = .{};
    }

    const cached = gop.value_ptr;
    if (cached.state == .unloaded) {
        loadCachedImageLocked(backend, cached, image_cmd.url);
    }

    if (cached.state != .loaded or cached.gp_image == null) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    }

    var graphics: ?*GpGraphics = null;
    if (GdipCreateFromHDC(hdc, &graphics) != GDIP_STATUS_OK or graphics == null) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    }
    defer _ = GdipDeleteGraphics(graphics.?);

    const draw_rect = fitImageRect(rect, cached.width, cached.height);
    const status = GdipDrawImageRectI(
        graphics.?,
        cached.gp_image.?,
        draw_rect.left,
        draw_rect.top,
        draw_rect.right - draw_rect.left,
        draw_rect.bottom - draw_rect.top,
    );
    if (status != GDIP_STATUS_OK) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
    }
}

fn renderPresentationDisplayList(
    backend: *Win32Backend,
    hdc: c.HDC,
    client: c.RECT,
    snapshot: *const PresentationSnapshot,
    scroll_px: i32,
    find_matches: []const FindMatch,
    current_find_match: ?usize,
) void {
    const display_list = snapshot.display_list orelse return;
    for (display_list.commands.items, 0..) |command, command_index| {
        switch (command) {
            .fill_rect => |rect_cmd| {
                const left = scalePresentationValue(rect_cmd.x, display_list.layout_scale);
                const top = scalePresentationValue(rect_cmd.y, display_list.layout_scale);
                const width = @max(1, scalePresentationValue(rect_cmd.width, display_list.layout_scale));
                const height = @max(1, scalePresentationValue(rect_cmd.height, display_list.layout_scale));
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + left,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + left + width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px + height,
                };
                const brush = c.CreateSolidBrush(colorRef(rect_cmd.color));
                if (brush == null) continue;
                defer _ = c.DeleteObject(brush);
                _ = c.FillRect(hdc, &rect, brush);
            },
            .stroke_rect => |rect_cmd| {
                const left = scalePresentationValue(rect_cmd.x, display_list.layout_scale);
                const top = scalePresentationValue(rect_cmd.y, display_list.layout_scale);
                const width = @max(1, scalePresentationValue(rect_cmd.width, display_list.layout_scale));
                const height = @max(1, scalePresentationValue(rect_cmd.height, display_list.layout_scale));
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + left,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + left + width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px + height,
                };
                const brush = c.CreateSolidBrush(colorRef(rect_cmd.color));
                if (brush == null) continue;
                defer _ = c.DeleteObject(brush);
                _ = c.FrameRect(hdc, &rect, brush);
            },
            .text => |text_cmd| {
                const left = scalePresentationValue(text_cmd.x, display_list.layout_scale);
                const top = scalePresentationValue(text_cmd.y, display_list.layout_scale);
                const width = @max(1, scalePresentationValue(text_cmd.width, display_list.layout_scale));
                const font_size = @max(1, scalePresentationValue(text_cmd.font_size, display_list.layout_scale));
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + left,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + left + width,
                    .bottom = client.bottom + scalePresentationValue(snapshot.display_list.?.content_height, display_list.layout_scale),
                };
                if (current_find_match) |find_index| {
                    const match = find_matches[find_index];
                    if (match.command_index == command_index) {
                        const highlight_left = client.left + PRESENTATION_MARGIN + scalePresentationValue(match.x, display_list.layout_scale);
                        const highlight_top = PRESENTATION_HEADER_HEIGHT + 8 + scalePresentationValue(match.y, display_list.layout_scale) - scroll_px;
                        const highlight_width = @max(1, scalePresentationValue(match.width, display_list.layout_scale));
                        const highlight_height = @max(1, scalePresentationValue(match.height, display_list.layout_scale));
                        var highlight_rect = c.RECT{
                            .left = highlight_left - 1,
                            .top = highlight_top - 1,
                            .right = highlight_left + highlight_width + 1,
                            .bottom = highlight_top + highlight_height + 1,
                        };
                        const highlight_fill = c.CreateSolidBrush(c.RGB(255, 245, 160));
                        if (highlight_fill != null) {
                            defer _ = c.DeleteObject(highlight_fill);
                            _ = c.FillRect(hdc, &highlight_rect, highlight_fill);
                        }
                        const highlight_border = c.CreateSolidBrush(c.RGB(214, 170, 20));
                        if (highlight_border != null) {
                            defer _ = c.DeleteObject(highlight_border);
                            _ = c.FrameRect(hdc, &highlight_rect, highlight_border);
                        }
                    }
                }
                const previous = c.SetTextColor(hdc, colorRef(text_cmd.color));
                const font_height: c_int = -@as(c_int, @intCast(font_size));
                const font = c.CreateFontW(
                    font_height,
                    0,
                    0,
                    0,
                    c.FW_NORMAL,
                    0,
                    @as(c.DWORD, @intFromBool(text_cmd.underline)),
                    0,
                    c.DEFAULT_CHARSET,
                    c.OUT_DEFAULT_PRECIS,
                    c.CLIP_DEFAULT_PRECIS,
                    c.CLEARTYPE_QUALITY,
                    c.DEFAULT_PITCH | c.FF_SWISS,
                    null,
                );
                const previous_font = if (font != null) c.SelectObject(hdc, font) else null;
                defer if (font != null) {
                    _ = c.SelectObject(hdc, previous_font);
                    _ = c.DeleteObject(font);
                };
                drawPresentationText(
                    hdc,
                    &rect,
                    text_cmd.text,
                    c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
                );
                _ = c.SetTextColor(hdc, previous);
            },
            .image => |image_cmd| {
                const left = scalePresentationValue(image_cmd.x, display_list.layout_scale);
                const top = scalePresentationValue(image_cmd.y, display_list.layout_scale);
                const width = @max(1, scalePresentationValue(image_cmd.width, display_list.layout_scale));
                const height = @max(1, scalePresentationValue(image_cmd.height, display_list.layout_scale));
                const rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + left,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + left + width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + top - scroll_px + height,
                };
                drawPresentationImage(backend, hdc, rect, image_cmd);
            },
        }
    }
}

fn renderPresentationScene(
    backend: *Win32Backend,
    hdc: c.HDC,
    client: c.RECT,
    snapshot: *const PresentationSnapshot,
    scroll_px: i32,
    allocator: std.mem.Allocator,
) void {
    const white_brush = c.CreateSolidBrush(c.RGB(255, 255, 255));
    if (white_brush != null) {
        defer _ = c.DeleteObject(white_brush);
        _ = c.FillRect(hdc, &client, white_brush);
    }
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    var find_matches: std.ArrayListUnmanaged(FindMatch) = .{};
    defer find_matches.deinit(allocator);
    if (snapshot.display_list) |display_list| {
        find_matches = collectFindMatchesForDisplayList(allocator, &display_list, snapshot.find_text) catch .{};
    }
    const current_find_match = if (find_matches.items.len > 0)
        normalizeFindMatchIndex(snapshot.find_match_index, find_matches.items.len)
    else
        null;
    const current_find_ordinal = if (current_find_match) |index| index + 1 else 0;

    drawTabStrip(hdc, client, snapshot, allocator);

    drawFindBox(
        hdc,
        client,
        snapshot.find_text,
        snapshot.find_editing,
        current_find_ordinal,
        find_matches.items.len,
        allocator,
    );

    drawChromeButton(hdc, chromeButtonRect(.back), "<", snapshot.can_go_back);
    drawChromeButton(hdc, chromeButtonRect(.forward), ">", snapshot.can_go_forward);
    drawChromeButton(
        hdc,
        chromeButtonRect(.reload),
        if (snapshot.is_loading) "X" else "R",
        snapshot.is_loading or snapshot.url.len > 0,
    );

    var address_buf = std.Io.Writer.Allocating.init(allocator);
    defer address_buf.deinit();
    const current_bookmarked = stringListIndexOf(snapshot.bookmark_entries.items, snapshot.url) != null;
    if (snapshot.address_editing) {
        address_buf.writer.print("Address{s}: {s}_", .{ if (current_bookmarked) "*" else "", snapshot.address_text }) catch return;
    } else if (snapshot.address_text.len > 0) {
        address_buf.writer.print("Address{s}: {s}", .{ if (current_bookmarked) "*" else "", snapshot.address_text }) catch return;
    } else {
        address_buf.writer.writeAll("Address: Ctrl+L or click here") catch return;
    }

    var address_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN + PRESENTATION_ADDRESS_LEFT_OFFSET,
        .top = client.top + PRESENTATION_ADDRESS_TOP,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = client.top + PRESENTATION_ADDRESS_BOTTOM,
    };
    drawPresentationText(
        hdc,
        &address_rect,
        address_buf.written(),
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    var hint_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN,
        .top = client.top + PRESENTATION_HINT_TOP,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = client.top + PRESENTATION_HINT_BOTTOM,
    };
    const hint_text = std.fmt.allocPrint(
        allocator,
        "Ctrl+T new tab  Ctrl+W close tab  Ctrl+Shift+T reopen  Ctrl+Tab next  Ctrl+Shift+Tab prev  Ctrl+L address  Ctrl+F find  Ctrl+H history  Ctrl+J downloads  Ctrl+D bookmark  Ctrl+Shift+B bookmarks  Ctrl+, settings  Alt+Home home  Alt+Left back  Alt+Right forward  F5 reload  Esc stop  Ctrl++ zoom in  Ctrl+- zoom out  Ctrl+0 reset  Ctrl+Wheel zoom  Zoom {d}%",
        .{snapshot.zoom_percent},
    ) catch return;
    defer allocator.free(hint_text);
    drawPresentationText(
        hdc,
        &hint_rect,
        hint_text,
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    _ = c.MoveToEx(hdc, client.left + PRESENTATION_MARGIN, PRESENTATION_HEADER_HEIGHT, null);
    _ = c.LineTo(hdc, client.right - PRESENTATION_MARGIN, PRESENTATION_HEADER_HEIGHT);

    if (snapshot.display_list) |_| {
        renderPresentationDisplayList(backend, hdc, client, snapshot, scroll_px, find_matches.items, current_find_match);
    } else {
        const body_text = if (snapshot.body.len > 0) snapshot.body else "Loading page...";
        const body_utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, body_text) catch return;
        defer std.heap.c_allocator.free(body_utf16);

        if (body_utf16.len == 0) {
            return;
        }

        var measure_rect = c.RECT{
            .left = 0,
            .top = 0,
            .right = @max(1, client.right - (PRESENTATION_MARGIN * 2)),
            .bottom = 0,
        };
        _ = c.DrawTextW(
            hdc,
            body_utf16.ptr,
            @intCast(body_utf16.len),
            &measure_rect,
            c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_CALCRECT,
        );

        const content_height = measure_rect.bottom - measure_rect.top;

        var body_rect = c.RECT{
            .left = client.left + PRESENTATION_MARGIN,
            .top = PRESENTATION_HEADER_HEIGHT + 8 - scroll_px,
            .right = client.right - PRESENTATION_MARGIN,
            .bottom = PRESENTATION_HEADER_HEIGHT + 8 - scroll_px + content_height,
        };
        _ = c.DrawTextW(
            hdc,
            body_utf16.ptr,
            @intCast(body_utf16.len),
            &body_rect,
            c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
        );
    }

    if (snapshot.history_overlay_open) {
        drawHistoryOverlay(
            hdc,
            client,
            snapshot.history_entries.items,
            snapshot.history_current_index,
            snapshot.history_selected_index,
            snapshot.history_scroll_index,
            allocator,
        );
    }
    if (snapshot.bookmark_overlay_open) {
        drawBookmarkOverlay(
            hdc,
            client,
            snapshot.bookmark_entries.items,
            snapshot.url,
            snapshot.bookmark_selected_index,
            snapshot.bookmark_scroll_index,
            allocator,
        );
    }
    if (snapshot.download_overlay_open) {
        drawDownloadOverlay(
            hdc,
            client,
            snapshot.download_entries.items,
            snapshot.download_selected_index,
            snapshot.download_scroll_index,
            allocator,
        );
    }
    if (snapshot.settings_overlay_open) {
        drawSettingsOverlay(hdc, client, snapshot.*, allocator);
    }
}

fn renderWindowPresentation(hwnd: c.HWND, backend: *Win32Backend) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);
    if (hdc == null) {
        return;
    }

    const snapshot = copyPresentationSnapshot(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return;
    };
    defer snapshot.deinit(backend.allocator);

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const visible_height = @max(0, client.bottom - PRESENTATION_HEADER_HEIGHT - PRESENTATION_MARGIN);
    const scroll_px = if (snapshot.display_list) |display_list|
        updatePresentationMaxScroll(backend, scalePresentationValue(display_list.content_height, display_list.layout_scale) - visible_height)
    else
        snapshot.scroll_px;

    renderPresentationScene(backend, hdc, client, &snapshot, scroll_px, backend.allocator);
}

const BitmapFileHeader = extern struct {
    bfType: u16,
    bfSize: u32,
    bfReserved1: u16,
    bfReserved2: u16,
    bfOffBits: u32,
};

const RenderedPresentation = struct {
    snapshot: PresentationSnapshot,
    width: c_int,
    height: c_int,
    pixels: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *RenderedPresentation) void {
        self.snapshot.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }
};

fn openOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{});
    }
    return std.fs.cwd().createFile(path, .{});
}

fn capturePresentationPixels(backend: *Win32Backend) !RenderedPresentation {
    const snapshot = try copyPresentationSnapshot(backend);
    errdefer snapshot.deinit(backend.allocator);

    const width = clampU32ToCInt(backend.requested_width.load(.acquire));
    const height = clampU32ToCInt(backend.requested_height.load(.acquire));
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }

    const mem_dc = c.CreateCompatibleDC(null);
    if (mem_dc == null) {
        return error.CreateCompatibleDcFailed;
    }
    defer _ = c.DeleteDC(mem_dc);

    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const hbitmap = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (hbitmap == null or bits == null) {
        return error.CreateDibSectionFailed;
    }
    defer _ = c.DeleteObject(hbitmap);

    const previous_bitmap = c.SelectObject(mem_dc, hbitmap);
    defer _ = c.SelectObject(mem_dc, previous_bitmap);

    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = width,
        .bottom = height,
    };
    renderPresentationScene(backend, mem_dc, client, &snapshot, snapshot.scroll_px, backend.allocator);

    const pixel_bytes = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const owned_pixels = try backend.allocator.alloc(u8, pixel_bytes);
    errdefer backend.allocator.free(owned_pixels);

    const src_pixels: [*]u8 = @ptrCast(bits.?);
    @memcpy(owned_pixels, src_pixels[0..pixel_bytes]);

    return .{
        .snapshot = snapshot,
        .width = width,
        .height = height,
        .pixels = owned_pixels,
        .allocator = backend.allocator,
    };
}

fn savePresentationPngAuto(backend: *Win32Backend) bool {
    const filename = std.fmt.allocPrint(
        backend.allocator,
        "lightpanda-screenshot-{d}.png",
        .{std.time.timestamp()},
    ) catch |err| {
        log.warn(.app, "win png name fail", .{ .err = err });
        return false;
    };
    defer backend.allocator.free(filename);
    return savePresentationPng(backend, filename);
}

fn savePresentationBitmapAuto(backend: *Win32Backend) bool {
    const filename = std.fmt.allocPrint(
        backend.allocator,
        "lightpanda-screenshot-{d}.bmp",
        .{std.time.timestamp()},
    ) catch |err| {
        log.warn(.app, "win bmp name failed", .{ .err = err });
        return false;
    };
    defer backend.allocator.free(filename);
    return savePresentationBitmap(backend, filename);
}

fn savePresentationBitmap(backend: *Win32Backend, path: []const u8) bool {
    var rendered = capturePresentationPixels(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return false;
    };
    defer rendered.deinit();

    const pixel_bytes = rendered.pixels.len;
    const headers_bytes = @sizeOf(BitmapFileHeader) + @sizeOf(c.BITMAPINFOHEADER);
    const file = openOutputFile(path) catch |err| {
        log.warn(.app, "win bmp create failed", .{ .err = err });
        return false;
    };
    defer file.close();

    const file_header = BitmapFileHeader{
        .bfType = 0x4D42,
        .bfSize = @intCast(headers_bytes + pixel_bytes),
        .bfReserved1 = 0,
        .bfReserved2 = 0,
        .bfOffBits = headers_bytes,
    };
    var bmi_header: c.BITMAPINFOHEADER = std.mem.zeroes(c.BITMAPINFOHEADER);
    bmi_header.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi_header.biWidth = rendered.width;
    bmi_header.biHeight = -rendered.height;
    bmi_header.biPlanes = 1;
    bmi_header.biBitCount = 32;
    bmi_header.biCompression = c.BI_RGB;

    file.writeAll(std.mem.asBytes(&file_header)) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };
    file.writeAll(std.mem.asBytes(&bmi_header)) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };

    file.writeAll(rendered.pixels[0..pixel_bytes]) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };
    log.info(.app, "win bmp saved", .{ .path = path });
    return true;
}

fn savePresentationPng(backend: *Win32Backend, path: []const u8) bool {
    var rendered = capturePresentationPixels(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return false;
    };
    defer rendered.deinit();

    var file = openOutputFile(path) catch |err| {
        log.warn(.app, "win png create fail", .{ .err = err });
        return false;
    };
    defer file.close();

    writePngFromBgra(
        &file,
        @intCast(rendered.width),
        @intCast(rendered.height),
        rendered.pixels,
        backend.allocator,
    ) catch |err| {
        log.warn(.app, "win png write fail", .{ .err = err });
        return false;
    };
    log.info(.app, "win png saved", .{ .path = path });
    return true;
}

fn writePngFromBgra(
    file: *std.fs.File,
    width: u32,
    height: u32,
    bgra_pixels: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try file.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    storeBigEndianU32(ihdr[0..4], width);
    storeBigEndianU32(ihdr[4..8], height);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writePngChunk(file, "IHDR".*, &ihdr);

    const row_bytes = @as(usize, width) * 3 + 1;
    const scanline_bytes = row_bytes * @as(usize, height);
    const scanlines = try allocator.alloc(u8, scanline_bytes);
    defer allocator.free(scanlines);

    var src_index: usize = 0;
    var dst_index: usize = 0;
    for (0..height) |_| {
        scanlines[dst_index] = 0;
        dst_index += 1;
        for (0..width) |_| {
            scanlines[dst_index + 0] = bgra_pixels[src_index + 2];
            scanlines[dst_index + 1] = bgra_pixels[src_index + 1];
            scanlines[dst_index + 2] = bgra_pixels[src_index + 0];
            src_index += 4;
            dst_index += 3;
        }
    }

    try writePngIdatStored(file, scanlines);
    try writePngChunk(file, "IEND".*, &.{});
}

fn writePngChunk(file: *std.fs.File, chunk_type: [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    storeBigEndianU32(&len_buf, @intCast(data.len));
    try file.writeAll(&len_buf);
    try file.writeAll(&chunk_type);
    try file.writeAll(data);

    var crc = crc32Init();
    crc = crc32Update(crc, &chunk_type);
    crc = crc32Update(crc, data);
    var crc_buf: [4]u8 = undefined;
    storeBigEndianU32(&crc_buf, crc32Final(crc));
    try file.writeAll(&crc_buf);
}

fn writePngIdatStored(file: *std.fs.File, data: []const u8) !void {
    const block_count = if (data.len == 0) 1 else (data.len + 65534) / 65535;
    const compressed_len = 2 + data.len + block_count * 5 + 4;

    var len_buf: [4]u8 = undefined;
    storeBigEndianU32(&len_buf, @intCast(compressed_len));
    try file.writeAll(&len_buf);

    const chunk_type = "IDAT".*;
    try file.writeAll(&chunk_type);

    var crc = crc32Init();
    crc = crc32Update(crc, &chunk_type);

    const zlib_header = [_]u8{ 0x78, 0x01 };
    try file.writeAll(&zlib_header);
    crc = crc32Update(crc, &zlib_header);

    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len: u16 = @intCast(@min(remaining, 65535));
        const final_block = remaining <= 65535;
        const block_header = [_]u8{if (final_block) 0x01 else 0x00};
        try file.writeAll(&block_header);
        crc = crc32Update(crc, &block_header);

        const len_bytes = [_]u8{
            @truncate(block_len),
            @truncate(block_len >> 8),
            @truncate(~block_len),
            @truncate((~block_len) >> 8),
        };
        try file.writeAll(&len_bytes);
        crc = crc32Update(crc, &len_bytes);

        if (block_len > 0) {
            const block = data[offset .. offset + block_len];
            try file.writeAll(block);
            crc = crc32Update(crc, block);
            offset += block_len;
        }

        if (final_block) {
            break;
        }
    }

    var adler_buf: [4]u8 = undefined;
    storeBigEndianU32(&adler_buf, adler32(data));
    try file.writeAll(&adler_buf);
    crc = crc32Update(crc, &adler_buf);

    var crc_buf: [4]u8 = undefined;
    storeBigEndianU32(&crc_buf, crc32Final(crc));
    try file.writeAll(&crc_buf);
}

fn storeBigEndianU32(buf: []u8, value: u32) void {
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate(value >> 16);
    buf[2] = @truncate(value >> 8);
    buf[3] = @truncate(value);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn crc32Init() u32 {
    return 0xFFFF_FFFF;
}

fn crc32Update(initial: u32, data: []const u8) u32 {
    var crc = initial;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask: u32 = @bitCast(-@as(i32, @intCast(crc & 1)));
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return crc;
}

fn crc32Final(crc: u32) u32 {
    return ~crc;
}

const OverlayMove = enum {
    up,
    down,
    page_up,
    page_down,
    home,
    end,
};

fn visibleOverlayEntryCountForWindow(hwnd: c.HWND, entry_count: usize) usize {
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) {
        return 0;
    }
    return visibleHistoryEntryCount(client, entry_count);
}

fn applyOverlayMove(
    entry_count: usize,
    visible_count: usize,
    selected_index: *usize,
    scroll_index: *usize,
    move: OverlayMove,
) bool {
    if (entry_count == 0 or visible_count == 0) {
        return false;
    }

    const current_selected = clampOverlaySelectedIndex(entry_count, selected_index.*);
    const current_scroll = ensureSelectionVisible(entry_count, current_selected, scroll_index.*, visible_count);
    const page_step = @max(@as(usize, 1), visible_count);
    const next_selected = switch (move) {
        .up => if (current_selected == 0) 0 else current_selected - 1,
        .down => @min(current_selected + 1, entry_count - 1),
        .page_up => if (current_selected > page_step) current_selected - page_step else 0,
        .page_down => @min(current_selected + page_step, entry_count - 1),
        .home => 0,
        .end => entry_count - 1,
    };
    const next_scroll = ensureSelectionVisible(entry_count, next_selected, current_scroll, visible_count);
    const changed = next_selected != selected_index.* or next_scroll != scroll_index.*;
    selected_index.* = next_selected;
    scroll_index.* = next_scroll;
    return changed;
}

fn scrollOverlayRows(
    entry_count: usize,
    visible_count: usize,
    selected_index: *usize,
    scroll_index: *usize,
    delta_rows: isize,
) bool {
    if (entry_count == 0 or visible_count == 0) {
        return false;
    }
    const current_scroll_signed: isize = @intCast(clampOverlayScrollIndex(entry_count, scroll_index.*, visible_count));
    const max_scroll_signed: isize = @intCast(clampOverlayScrollIndex(entry_count, entry_count, visible_count));
    const next_scroll_signed = std.math.clamp(current_scroll_signed + delta_rows, @as(isize, 0), max_scroll_signed);
    const next_scroll: usize = @intCast(next_scroll_signed);
    const next_selected = blk: {
        const clamped_selected = clampOverlaySelectedIndex(entry_count, selected_index.*);
        if (clamped_selected < next_scroll) break :blk next_scroll;
        if (clamped_selected >= next_scroll + visible_count) break :blk @min(next_scroll + visible_count - 1, entry_count - 1);
        break :blk clamped_selected;
    };
    const changed = next_scroll != scroll_index.* or next_selected != selected_index.*;
    scroll_index.* = next_scroll;
    selected_index.* = next_selected;
    return changed;
}

fn handleHistoryOverlayMove(hwnd: c.HWND, backend: *Win32Backend, move: OverlayMove) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open) {
        return false;
    }
    return applyOverlayMove(
        backend.presentation_history_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_history_entries.items.len),
        &backend.history_overlay_selected_index,
        &backend.history_overlay_scroll_index,
        move,
    );
}

fn handleBookmarkOverlayMove(hwnd: c.HWND, backend: *Win32Backend, move: OverlayMove) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open) {
        return false;
    }
    return applyOverlayMove(
        backend.presentation_bookmark_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_bookmark_entries.items.len),
        &backend.bookmark_overlay_selected_index,
        &backend.bookmark_overlay_scroll_index,
        move,
    );
}

fn handleDownloadOverlayMove(hwnd: c.HWND, backend: *Win32Backend, move: OverlayMove) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.download_overlay_open) {
        return false;
    }
    return applyOverlayMove(
        backend.presentation_download_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_download_entries.items.len),
        &backend.download_overlay_selected_index,
        &backend.download_overlay_scroll_index,
        move,
    );
}

fn scrollHistoryOverlayByWheel(hwnd: c.HWND, backend: *Win32Backend, raw_delta: i16) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open) {
        return false;
    }
    const rows: isize = if (raw_delta > 0) -1 else if (raw_delta < 0) 1 else 0;
    if (rows == 0) {
        return false;
    }
    return scrollOverlayRows(
        backend.presentation_history_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_history_entries.items.len),
        &backend.history_overlay_selected_index,
        &backend.history_overlay_scroll_index,
        rows,
    );
}

fn scrollBookmarkOverlayByWheel(hwnd: c.HWND, backend: *Win32Backend, raw_delta: i16) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open) {
        return false;
    }
    const rows: isize = if (raw_delta > 0) -1 else if (raw_delta < 0) 1 else 0;
    if (rows == 0) {
        return false;
    }
    return scrollOverlayRows(
        backend.presentation_bookmark_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_bookmark_entries.items.len),
        &backend.bookmark_overlay_selected_index,
        &backend.bookmark_overlay_scroll_index,
        rows,
    );
}

fn scrollDownloadOverlayByWheel(hwnd: c.HWND, backend: *Win32Backend, raw_delta: i16) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.download_overlay_open) {
        return false;
    }
    const rows: isize = if (raw_delta > 0) -1 else if (raw_delta < 0) 1 else 0;
    if (rows == 0) {
        return false;
    }
    return scrollOverlayRows(
        backend.presentation_download_entries.items.len,
        visibleOverlayEntryCountForWindow(hwnd, backend.presentation_download_entries.items.len),
        &backend.download_overlay_selected_index,
        &backend.download_overlay_scroll_index,
        rows,
    );
}

fn activateHistoryOverlaySelection(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.history_overlay_open or backend.presentation_history_entries.items.len == 0) {
        return false;
    }
    const index = clampOverlaySelectedIndex(
        backend.presentation_history_entries.items.len,
        backend.history_overlay_selected_index,
    );
    backend.history_overlay_open = false;
    queueBrowserCommand(backend, .{ .history_traverse = index });
    return true;
}

fn activateBookmarkOverlaySelection(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open or backend.presentation_bookmark_entries.items.len == 0) {
        return false;
    }
    const index = clampOverlaySelectedIndex(
        backend.presentation_bookmark_entries.items.len,
        backend.bookmark_overlay_selected_index,
    );
    const url = backend.presentation_bookmark_entries.items[index];
    const owned = backend.allocator.dupe(u8, url) catch |err| {
        log.warn(.app, "win bm nav", .{ .err = err });
        return false;
    };
    backend.bookmark_overlay_open = false;
    queueBrowserCommand(backend, .{ .navigate = owned });
    return true;
}

fn deleteSelectedBookmark(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.bookmark_overlay_open or backend.presentation_bookmark_entries.items.len == 0) {
        return false;
    }
    const index = clampOverlaySelectedIndex(
        backend.presentation_bookmark_entries.items.len,
        backend.bookmark_overlay_selected_index,
    );
    const removed = backend.presentation_bookmark_entries.orderedRemove(index);
    backend.allocator.free(removed);
    backend.bookmark_overlay_selected_index = clampOverlaySelectedIndex(
        backend.presentation_bookmark_entries.items.len,
        index,
    );
    backend.bookmark_overlay_scroll_index = clampOverlayScrollIndex(
        backend.presentation_bookmark_entries.items.len,
        backend.bookmark_overlay_scroll_index,
        backend.presentation_bookmark_entries.items.len,
    );
    if (backend.presentation_bookmark_entries.items.len == 0) {
        backend.bookmark_overlay_open = false;
        backend.bookmark_overlay_selected_index = 0;
        backend.bookmark_overlay_scroll_index = 0;
    }
    backend.saveBookmarksToDiskLocked();
    _ = backend.presentation_seq.fetchAdd(1, .acq_rel);
    return true;
}

fn deleteSelectedDownload(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.download_overlay_open or backend.presentation_download_entries.items.len == 0) {
        return false;
    }
    const index = clampOverlaySelectedIndex(
        backend.presentation_download_entries.items.len,
        backend.download_overlay_selected_index,
    );
    const entry = backend.presentation_download_entries.items[index];
    if (!entry.removable) {
        return false;
    }
    queueBrowserCommand(backend, .{ .download_remove = index });
    return true;
}

fn handlePresentationScrollKey(hwnd: c.HWND, backend: *Win32Backend, vk: u32) bool {
    if (!presentationHasContent(backend)) {
        return false;
    }

    const changed = switch (vk) {
        c.VK_UP => scrollPresentationBy(backend, -PRESENTATION_SCROLL_STEP),
        c.VK_DOWN => scrollPresentationBy(backend, PRESENTATION_SCROLL_STEP),
        c.VK_PRIOR => scrollPresentationBy(backend, -PRESENTATION_PAGE_STEP),
        c.VK_NEXT => scrollPresentationBy(backend, PRESENTATION_PAGE_STEP),
        c.VK_HOME => scrollPresentationTo(backend, 0),
        c.VK_END => scrollPresentationTo(backend, std.math.maxInt(i32)),
        else => false,
    };
    if (changed) {
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
    }
    return changed;
}

fn presentationAddressEditing(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.address_input_active;
}

fn handlePresentationShortcutKey(
    hwnd: c.HWND,
    backend: *Win32Backend,
    vk: u32,
    modifiers: Page.KeyboardModifiers,
) bool {
    if (!presentationHasContent(backend)) {
        return false;
    }

    if (modifiers.ctrl and modifiers.shift and vk == 'S') {
        return savePresentationBitmapAuto(backend);
    }
    if (modifiers.ctrl and modifiers.shift and vk == 'P') {
        return savePresentationPngAuto(backend);
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and vk == c.VK_TAB) {
        queueBrowserCommand(backend, if (modifiers.shift) .tab_previous else .tab_next);
        return true;
    }
    if (modifiers.ctrl and modifiers.shift and !modifiers.alt and !modifiers.meta and vk == 'T') {
        queueBrowserCommand(backend, .tab_reopen_closed);
        return true;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == 'T') {
        queueBrowserCommand(backend, .tab_new);
        return true;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == 'W') {
        if (presentationTabEntryCount(backend) == 0) {
            return false;
        }
        queueBrowserCommand(backend, .{ .tab_close = presentationActiveTabIndex(backend) });
        return true;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk >= '1' and vk <= '9') {
        const index: usize = @intCast(vk - '1');
        if (index >= presentationTabEntryCount(backend)) {
            return false;
        }
        queueBrowserCommand(backend, .{ .tab_activate = index });
        return true;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == c.VK_OEM_COMMA) {
        _ = setSettingsOverlayOpen(backend, !presentationSettingsOverlayOpen(backend));
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return true;
    }
    if ((modifiers.alt or modifiers.meta) and !modifiers.ctrl and !modifiers.shift and vk == c.VK_HOME) {
        queueBrowserCommand(backend, .home);
        return true;
    }

    if (presentationAddressEditing(backend)) {
        const handled = switch (vk) {
            c.VK_ESCAPE => cancelAddressEdit(backend),
            c.VK_RETURN => commitAddressEdit(hwnd, backend),
            c.VK_BACK => deleteLastAddressCodepoint(backend),
            'A' => modifiers.ctrl and selectAllAddressInput(backend),
            'V' => modifiers.ctrl and appendClipboardToAddress(backend),
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return handled;
    }

    if (presentationFindEditing(backend)) {
        if (modifiers.ctrl and vk == 'L') {
            if (beginAddressEdit(backend)) {
                _ = c.InvalidateRect(hwnd, null, c.TRUE);
                return true;
            }
            return false;
        }

        const handled = switch (vk) {
            c.VK_ESCAPE => cancelFindEdit(backend),
            c.VK_RETURN => updateFindSelection(hwnd, backend, if (modifiers.shift) .previous else .next),
            c.VK_F3 => updateFindSelection(hwnd, backend, if (modifiers.shift) .previous else .next),
            c.VK_BACK => blk: {
                if (!deleteLastFindCodepoint(backend)) break :blk false;
                _ = updateFindSelection(hwnd, backend, .preserve);
                break :blk true;
            },
            'A' => modifiers.ctrl and selectAllFindInput(backend),
            'F' => modifiers.ctrl and selectAllFindInput(backend),
            'V' => blk: {
                if (!(modifiers.ctrl and appendClipboardToFind(backend))) break :blk false;
                _ = updateFindSelection(hwnd, backend, .preserve);
                break :blk true;
            },
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return handled;
    }

    if (presentationSettingsOverlayOpen(backend)) {
        const selected_index = currentSettingsOverlaySelectedIndex(backend);
        const handled = switch (vk) {
            c.VK_ESCAPE => setSettingsOverlayOpen(backend, false),
            c.VK_UP => handleSettingsOverlayMove(hwnd, backend, .up),
            c.VK_DOWN => handleSettingsOverlayMove(hwnd, backend, .down),
            c.VK_HOME => handleSettingsOverlayMove(hwnd, backend, .home),
            c.VK_END => handleSettingsOverlayMove(hwnd, backend, .end),
            c.VK_LEFT => if (settingsActionForSelectedRow(selected_index, .secondary)) |action|
                queueSettingsOverlayAction(backend, action)
            else
                false,
            c.VK_RIGHT => if (settingsActionForSelectedRow(selected_index, .primary)) |action|
                queueSettingsOverlayAction(backend, action)
            else
                false,
            c.VK_RETURN => if (settingsActionForSelectedRow(selected_index, .tertiary)) |action|
                queueSettingsOverlayAction(backend, action)
            else
                false,
            c.VK_SPACE => if (settingsActionForSelectedRow(selected_index, .primary)) |action|
                queueSettingsOverlayAction(backend, action)
            else
                false,
            c.VK_DELETE => if (settingsActionForSelectedRow(selected_index, .clear)) |action|
                queueSettingsOverlayAction(backend, action)
            else
                false,
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }

    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == 'D') {
        if (toggleCurrentBookmark(backend)) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }
    if (modifiers.ctrl and modifiers.shift and !modifiers.alt and !modifiers.meta and vk == 'B') {
        if (setBookmarkOverlayOpen(backend, !presentationBookmarkOverlayOpen(backend))) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        } else {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return true;
    }

    if (presentationBookmarkOverlayOpen(backend)) {
        const handled = switch (vk) {
            c.VK_ESCAPE => setBookmarkOverlayOpen(backend, false),
            c.VK_DELETE => deleteSelectedBookmark(backend),
            c.VK_RETURN => activateBookmarkOverlaySelection(backend),
            c.VK_UP => handleBookmarkOverlayMove(hwnd, backend, .up),
            c.VK_DOWN => handleBookmarkOverlayMove(hwnd, backend, .down),
            c.VK_PRIOR => handleBookmarkOverlayMove(hwnd, backend, .page_up),
            c.VK_NEXT => handleBookmarkOverlayMove(hwnd, backend, .page_down),
            c.VK_HOME => handleBookmarkOverlayMove(hwnd, backend, .home),
            c.VK_END => handleBookmarkOverlayMove(hwnd, backend, .end),
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return handled;
    }

    if (presentationDownloadOverlayOpen(backend)) {
        const handled = switch (vk) {
            c.VK_ESCAPE => setDownloadOverlayOpen(backend, false),
            c.VK_DELETE => deleteSelectedDownload(backend),
            c.VK_UP => handleDownloadOverlayMove(hwnd, backend, .up),
            c.VK_DOWN => handleDownloadOverlayMove(hwnd, backend, .down),
            c.VK_PRIOR => handleDownloadOverlayMove(hwnd, backend, .page_up),
            c.VK_NEXT => handleDownloadOverlayMove(hwnd, backend, .page_down),
            c.VK_HOME => handleDownloadOverlayMove(hwnd, backend, .home),
            c.VK_END => handleDownloadOverlayMove(hwnd, backend, .end),
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
    }

    if (presentationHistoryOverlayOpen(backend)) {
        const handled = switch (vk) {
            c.VK_ESCAPE => setHistoryOverlayOpen(backend, false),
            c.VK_RETURN => activateHistoryOverlaySelection(backend),
            c.VK_UP => handleHistoryOverlayMove(hwnd, backend, .up),
            c.VK_DOWN => handleHistoryOverlayMove(hwnd, backend, .down),
            c.VK_PRIOR => handleHistoryOverlayMove(hwnd, backend, .page_up),
            c.VK_NEXT => handleHistoryOverlayMove(hwnd, backend, .page_down),
            c.VK_HOME => handleHistoryOverlayMove(hwnd, backend, .home),
            c.VK_END => handleHistoryOverlayMove(hwnd, backend, .end),
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        if (handled) {
            return true;
        }
    }

    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == 'H') {
        if (presentationHistoryEntryCount(backend) == 0) {
            return false;
        }
        if (setHistoryOverlayOpen(backend, !presentationHistoryOverlayOpen(backend))) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        } else {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return true;
    }

    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and vk == 'J') {
        _ = setDownloadOverlayOpen(backend, !presentationDownloadOverlayOpen(backend));
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return true;
    }

    if (modifiers.ctrl and vk == 'L') {
        if (beginAddressEdit(backend)) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and vk == 'F') {
        if (beginFindEdit(backend)) {
            _ = updateFindSelection(hwnd, backend, .preserve);
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }
    if (vk == c.VK_F3) {
        if (updateFindSelection(hwnd, backend, if (modifiers.shift) .previous else .next)) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }
    if (vk == c.VK_ESCAPE and presentationChromeShowsStop(backend)) {
        queueBrowserCommand(backend, .stop);
        return true;
    }
    if ((modifiers.alt or modifiers.meta) and vk == c.VK_LEFT) {
        queueBrowserCommand(backend, .back);
        return true;
    }
    if ((modifiers.alt or modifiers.meta) and vk == c.VK_RIGHT) {
        queueBrowserCommand(backend, .forward);
        return true;
    }
    if (vk == c.VK_F5 or (modifiers.ctrl and vk == 'R')) {
        queueBrowserCommand(backend, .reload);
        return true;
    }
    if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift) {
        switch (vk) {
            c.VK_OEM_PLUS, c.VK_ADD => {
                queueBrowserCommand(backend, .zoom_in);
                return true;
            },
            c.VK_OEM_MINUS, c.VK_SUBTRACT => {
                queueBrowserCommand(backend, .zoom_out);
                return true;
            },
            '0' => {
                queueBrowserCommand(backend, .zoom_reset);
                return true;
            },
            else => {},
        }
    }

    return false;
}

const ClipboardShortcutAction = enum {
    copy,
    cut,
    paste,
};

fn clipboardShortcutAction(vk: u32, modifiers: Page.KeyboardModifiers) ?ClipboardShortcutAction {
    const only_primary_accel = (modifiers.ctrl or modifiers.meta) and !modifiers.alt and !modifiers.shift;
    if (only_primary_accel) {
        return switch (vk) {
            'C' => .copy,
            'X' => .cut,
            'V' => .paste,
            c.VK_INSERT => .copy,
            else => null,
        };
    }

    const only_shift = modifiers.shift and !modifiers.ctrl and !modifiers.meta and !modifiers.alt;
    if (only_shift) {
        return switch (vk) {
            c.VK_INSERT => .paste,
            c.VK_DELETE => .cut,
            else => null,
        };
    }

    return null;
}

fn handleClipboardShortcut(allocator: std.mem.Allocator, page: *Page, action: ClipboardShortcutAction) !void {
    switch (action) {
        .copy => {
            if (!(try page.triggerClipboardEvent("copy"))) {
                return;
            }
            const selection = page.getActiveTextSelection() orelse return;
            _ = try writeClipboardTextUtf8(allocator, selection);
        },
        .cut => {
            if (!(try page.triggerClipboardEvent("cut"))) {
                return;
            }
            const selection = page.getActiveTextSelection() orelse return;
            if (try writeClipboardTextUtf8(allocator, selection)) {
                _ = try page.deleteActiveTextSelection();
            }
        },
        .paste => {
            if (!(try page.triggerClipboardEvent("paste"))) {
                return;
            }
            const text = try readClipboardTextUtf8(allocator) orelse return;
            defer allocator.free(text);
            try page.insertText(text);
        },
    }
}

fn writeClipboardTextUtf8(allocator: std.mem.Allocator, text: []const u8) !bool {
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(utf16);

    const utf16_full = utf16[0 .. utf16.len + 1];
    const utf16_bytes = std.mem.sliceAsBytes(utf16_full);

    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, utf16_bytes.len);
    if (handle == null) {
        return false;
    }

    var ownership_transferred = false;
    defer if (!ownership_transferred) {
        _ = c.GlobalFree(handle);
    };

    const data = c.GlobalLock(handle) orelse return false;
    defer _ = c.GlobalUnlock(handle);

    const dst: [*]u8 = @ptrCast(data);
    @memcpy(dst[0..utf16_bytes.len], utf16_bytes);

    if (c.OpenClipboard(null) == 0) {
        return false;
    }
    defer _ = c.CloseClipboard();

    if (c.EmptyClipboard() == 0) {
        return false;
    }

    if (c.SetClipboardData(c.CF_UNICODETEXT, handle) == null) {
        return false;
    }

    ownership_transferred = true;
    return true;
}

fn readClipboardTextUtf8(allocator: std.mem.Allocator) !?[]u8 {
    if (c.OpenClipboard(null) == 0) {
        return null;
    }
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT);
    if (handle == null) {
        return null;
    }

    const data = c.GlobalLock(handle) orelse return null;
    defer _ = c.GlobalUnlock(handle);

    const utf16_ptr: [*:0]const u16 = @ptrCast(@alignCast(data));
    const utf16 = std.mem.span(utf16_ptr);
    if (utf16.len == 0) {
        return null;
    }
    return try std.unicode.utf16LeToUtf8Alloc(allocator, utf16);
}

fn mapVirtualKey(vk: u32, shift: bool, key_buf: *[2]u8) ?[]const u8 {
    switch (vk) {
        c.VK_SHIFT, c.VK_LSHIFT, c.VK_RSHIFT => return "Shift",
        c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL => return "Control",
        c.VK_MENU, c.VK_LMENU, c.VK_RMENU => return "Alt",
        c.VK_LWIN, c.VK_RWIN => return "Meta",
        c.VK_CAPITAL => return "CapsLock",
        c.VK_NUMLOCK => return "NumLock",
        c.VK_SCROLL => return "ScrollLock",
        c.VK_PAUSE => return "Pause",
        c.VK_RETURN => return "Enter",
        c.VK_TAB => return "Tab",
        c.VK_BACK => return "Backspace",
        c.VK_DELETE => return "Delete",
        c.VK_INSERT => return "Insert",
        c.VK_CLEAR => return "Clear",
        c.VK_SNAPSHOT => return "PrintScreen",
        c.VK_APPS => return "ContextMenu",
        c.VK_ESCAPE => return "Escape",
        c.VK_SPACE => return " ",
        c.VK_LEFT => return "ArrowLeft",
        c.VK_RIGHT => return "ArrowRight",
        c.VK_UP => return "ArrowUp",
        c.VK_DOWN => return "ArrowDown",
        c.VK_HOME => return "Home",
        c.VK_END => return "End",
        c.VK_PRIOR => return "PageUp",
        c.VK_NEXT => return "PageDown",
        c.VK_F1 => return "F1",
        c.VK_F2 => return "F2",
        c.VK_F3 => return "F3",
        c.VK_F4 => return "F4",
        c.VK_F5 => return "F5",
        c.VK_F6 => return "F6",
        c.VK_F7 => return "F7",
        c.VK_F8 => return "F8",
        c.VK_F9 => return "F9",
        c.VK_F10 => return "F10",
        c.VK_F11 => return "F11",
        c.VK_F12 => return "F12",
        else => {},
    }

    if (vk >= 0x41 and vk <= 0x5A) {
        const upper: u8 = @intCast(vk);
        key_buf[0] = if (shift) upper else std.ascii.toLower(upper);
        return key_buf[0..1];
    }
    if (vk >= 0x30 and vk <= 0x39) {
        const digit: u8 = @intCast(vk);
        key_buf[0] = if (shift) mapShiftedDigit(digit) else digit;
        return key_buf[0..1];
    }
    if (vk >= c.VK_NUMPAD0 and vk <= c.VK_NUMPAD9) {
        key_buf[0] = @intCast('0' + (vk - c.VK_NUMPAD0));
        return key_buf[0..1];
    }

    switch (vk) {
        c.VK_OEM_MINUS => {
            key_buf[0] = if (shift) '_' else '-';
            return key_buf[0..1];
        },
        c.VK_OEM_PLUS => {
            key_buf[0] = if (shift) '+' else '=';
            return key_buf[0..1];
        },
        c.VK_OEM_COMMA => {
            key_buf[0] = if (shift) '<' else ',';
            return key_buf[0..1];
        },
        c.VK_OEM_PERIOD => {
            key_buf[0] = if (shift) '>' else '.';
            return key_buf[0..1];
        },
        c.VK_OEM_1 => {
            key_buf[0] = if (shift) ':' else ';';
            return key_buf[0..1];
        },
        c.VK_OEM_2 => {
            key_buf[0] = if (shift) '?' else '/';
            return key_buf[0..1];
        },
        c.VK_OEM_3 => {
            key_buf[0] = if (shift) '~' else '`';
            return key_buf[0..1];
        },
        c.VK_OEM_4 => {
            key_buf[0] = if (shift) '{' else '[';
            return key_buf[0..1];
        },
        c.VK_OEM_5 => {
            key_buf[0] = if (shift) '|' else '\\';
            return key_buf[0..1];
        },
        c.VK_OEM_6 => {
            key_buf[0] = if (shift) '}' else ']';
            return key_buf[0..1];
        },
        c.VK_OEM_7 => {
            key_buf[0] = if (shift) '"' else '\'';
            return key_buf[0..1];
        },
        c.VK_MULTIPLY => {
            key_buf[0] = '*';
            return key_buf[0..1];
        },
        c.VK_ADD => {
            key_buf[0] = '+';
            return key_buf[0..1];
        },
        c.VK_SUBTRACT => {
            key_buf[0] = '-';
            return key_buf[0..1];
        },
        c.VK_DECIMAL => {
            key_buf[0] = '.';
            return key_buf[0..1];
        },
        c.VK_DIVIDE => {
            key_buf[0] = '/';
            return key_buf[0..1];
        },
        else => {},
    }
    return null;
}

fn mapShiftedDigit(digit: u8) u8 {
    return switch (digit) {
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        else => digit,
    };
}

fn keyStateDown(vk: c_int) bool {
    return (@as(u16, @bitCast(c.GetKeyState(vk))) & 0x8000) != 0;
}

fn keyboardModifiersFromKeyState() Page.KeyboardModifiers {
    return .{
        .ctrl = keyStateDown(c.VK_CONTROL),
        .shift = keyStateDown(c.VK_SHIFT),
        .alt = keyStateDown(c.VK_MENU),
        .meta = keyStateDown(c.VK_LWIN) or keyStateDown(c.VK_RWIN),
    };
}

fn mouseButtonsFromWParam(wparam: c.WPARAM) u16 {
    var buttons: u16 = 0;
    if ((wparam & c.MK_LBUTTON) != 0) buttons |= 1;
    if ((wparam & c.MK_RBUTTON) != 0) buttons |= 2;
    if ((wparam & c.MK_MBUTTON) != 0) buttons |= 4;
    if ((wparam & c.MK_XBUTTON1) != 0) buttons |= 8;
    if ((wparam & c.MK_XBUTTON2) != 0) buttons |= 16;
    return buttons;
}

fn mouseModifiersFromWParam(wparam: c.WPARAM) Page.MouseModifiers {
    const key_mods = keyboardModifiersFromKeyState();
    return .{
        .alt = key_mods.alt,
        .ctrl = key_mods.ctrl,
        .meta = key_mods.meta,
        .shift = key_mods.shift,
        .buttons = mouseButtonsFromWParam(wparam),
    };
}

fn clientCoordFromLParam(lparam: c.LPARAM) ClientPoint {
    const raw: usize = @bitCast(lparam);
    const x_word: u16 = @intCast(raw & 0xFFFF);
    const y_word: u16 = @intCast((raw >> 16) & 0xFFFF);
    const x: i16 = @bitCast(x_word);
    const y: i16 = @bitCast(y_word);
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
    };
}

fn clientCoordForWheel(hwnd: c.HWND, lparam: c.LPARAM) ClientPoint {
    const raw: usize = @bitCast(lparam);
    const x_word: u16 = @intCast(raw & 0xFFFF);
    const y_word: u16 = @intCast((raw >> 16) & 0xFFFF);

    var point = c.POINT{
        .x = @as(i16, @bitCast(x_word)),
        .y = @as(i16, @bitCast(y_word)),
    };
    _ = c.ScreenToClient(hwnd, &point);
    return .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    };
}

fn wheelDeltaFromWParam(wparam: c.WPARAM) f64 {
    const delta_word: u16 = @intCast((wparam >> 16) & 0xFFFF);
    const delta: i16 = @bitCast(delta_word);
    return @floatFromInt(delta);
}

fn keyRepeatFromLParam(lparam: c.LPARAM) bool {
    const raw: usize = @bitCast(lparam);
    return ((raw >> 30) & 1) != 0;
}

fn xButtonFromWParam(wparam: c.WPARAM) ?Page.MouseButton {
    const xbtn_word: u16 = @intCast((wparam >> 16) & 0xFFFF);
    return switch (xbtn_word) {
        c.XBUTTON1 => .fourth,
        c.XBUTTON2 => .fifth,
        else => null,
    };
}

fn queueTextCodePoint(backend: *Win32Backend, cp_in: u32) void {
    if (cp_in == 0) {
        return;
    }
    if (cp_in > 0x10FFFF) {
        return;
    }

    const cp: u21 = @intCast(if (cp_in == '\r') @as(u32, '\n') else cp_in);
    if (cp < 0x20 and cp != '\n') {
        return;
    }
    if (cp == 0x7F) {
        return;
    }
    if (!std.unicode.utf8ValidCodepoint(cp)) {
        return;
    }

    var text_input: Win32Backend.TextInputEvent = .{
        .bytes = undefined,
        .len = 0,
    };
    const len = std.unicode.utf8Encode(cp, &text_input.bytes) catch return;
    text_input.len = @intCast(len);
    queueInputEvent(backend, .{ .text_input = text_input });
}

fn queueTextFromUtf16Unit(backend: *Win32Backend, code_unit: u16) void {
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        backend.pending_high_surrogate = code_unit;
        return;
    }
    if (std.unicode.utf16IsLowSurrogate(code_unit)) {
        const high = backend.pending_high_surrogate orelse return;
        backend.pending_high_surrogate = null;
        queueTextCodePoint(backend, std.unicode.utf16DecodeSurrogatePair(&.{ high, code_unit }) catch return);
        return;
    }

    backend.pending_high_surrogate = null;
    queueTextCodePoint(backend, code_unit);
}

fn queueImeResultString(hwnd: c.HWND, backend: *Win32Backend, lparam: c.LPARAM) void {
    const flags: usize = @bitCast(lparam);
    if ((flags & c.GCS_RESULTSTR) == 0) {
        return;
    }

    const himc = c.ImmGetContext(hwnd);
    if (himc == null) {
        return;
    }
    defer _ = c.ImmReleaseContext(hwnd, himc);

    const bytes_len_long = c.ImmGetCompositionStringW(himc, c.GCS_RESULTSTR, null, 0);
    if (bytes_len_long <= 0) {
        return;
    }

    const bytes_len: usize = @intCast(bytes_len_long);
    if (bytes_len == 0) {
        return;
    }

    const unit_count = bytes_len / @sizeOf(u16);
    if (unit_count == 0) {
        return;
    }

    backend.ime_composing = true;
    backend.pending_high_surrogate = null;

    var stack_units: [64]u16 = undefined;
    if (unit_count <= stack_units.len) {
        const written_long = c.ImmGetCompositionStringW(
            himc,
            c.GCS_RESULTSTR,
            @ptrCast(stack_units[0..unit_count].ptr),
            @intCast(bytes_len),
        );
        if (written_long <= 0) {
            return;
        }
        const written_units = @as(usize, @intCast(written_long)) / @sizeOf(u16);
        for (stack_units[0..written_units]) |unit| {
            queueTextFromUtf16Unit(backend, unit);
        }
        backend.suppress_wm_char_units +|= @intCast(written_units);
        return;
    }

    const units = backend.allocator.alloc(u16, unit_count) catch return;
    defer backend.allocator.free(units);

    const written_long = c.ImmGetCompositionStringW(
        himc,
        c.GCS_RESULTSTR,
        @ptrCast(units.ptr),
        @intCast(bytes_len),
    );
    if (written_long <= 0) {
        return;
    }
    const written_units = @as(usize, @intCast(written_long)) / @sizeOf(u16);
    for (units[0..written_units]) |unit| {
        queueTextFromUtf16Unit(backend, unit);
    }
    backend.suppress_wm_char_units +|= @intCast(written_units);
}

fn hasImeCompositionString(lparam: c.LPARAM) bool {
    const flags: usize = @bitCast(lparam);
    return (flags & c.GCS_COMPSTR) != 0;
}

const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("LightpandaHeadedWindowClass");
const WINDOW_TITLE = std.unicode.utf8ToUtf16LeStringLiteral("Lightpanda Browser");

const WINDOW_STYLE: c.DWORD = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;
const WINDOW_EX_STYLE: c.DWORD = c.WS_EX_APPWINDOW;

fn registerWindowClass() !void {
    const hinstance = c.GetModuleHandleW(null);
    if (hinstance == null) {
        return error.MissingModuleHandle;
    }

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = loadCursorResource(32512);
    wc.hIcon = null;
    wc.hIconSm = null;
    wc.hbrBackground = null;
    wc.lpszClassName = WINDOW_CLASS_NAME.ptr;

    if (c.RegisterClassExW(&wc) == 0) {
        const err = c.GetLastError();
        if (err != c.ERROR_CLASS_ALREADY_EXISTS) {
            return error.RegisterClassFailed;
        }
    }
}

fn createWindow(backend: *Win32Backend, width: u32, height: u32) !c.HWND {
    try registerWindowClass();

    const hinstance = c.GetModuleHandleW(null);
    if (hinstance == null) {
        return error.MissingModuleHandle;
    }

    const size = adjustedWindowSize(width, height);
    const hwnd = c.CreateWindowExW(
        WINDOW_EX_STYLE,
        WINDOW_CLASS_NAME.ptr,
        WINDOW_TITLE.ptr,
        WINDOW_STYLE,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        size.width,
        size.height,
        null,
        null,
        hinstance,
        @ptrCast(backend),
    );

    if (hwnd == null) {
        return error.CreateWindowFailed;
    }

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetActiveWindow(hwnd);
    _ = c.SetFocus(hwnd);

    return hwnd;
}

fn destroyWindow(hwnd: c.HWND) void {
    if (c.IsWindow(hwnd) != 0) {
        _ = c.DestroyWindow(hwnd);
    }
}

fn setClientSize(hwnd: c.HWND, width: u32, height: u32) void {
    const size = adjustedWindowSize(width, height);
    _ = c.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        size.width,
        size.height,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_NOACTIVATE,
    );
}

fn adjustedWindowSize(width: u32, height: u32) struct { width: c_int, height: c_int } {
    var rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = clampU32ToCInt(width),
        .bottom = clampU32ToCInt(height),
    };
    _ = c.AdjustWindowRectEx(&rect, WINDOW_STYLE, c.FALSE, WINDOW_EX_STYLE);

    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

fn clampU32ToCInt(v: u32) c_int {
    const max = @as(u32, @intCast(std.math.maxInt(c_int)));
    return @intCast(@min(v, max));
}

fn pumpMessages() void {
    var msg: c.MSG = undefined;
    while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

fn getBackendPtr(hwnd: c.HWND) ?*Win32Backend {
    const value = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const backend_ptr = cs.lpCreateParams orelse return 0;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @intCast(@intFromPtr(backend_ptr)));
            return 1;
        },
        c.WM_CLOSE => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.user_closed.store(true, .release);
                backend.pending_high_surrogate = null;
                backend.ime_composing = false;
                backend.suppress_wm_char_units = 0;
            }
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_KILLFOCUS => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.pending_high_surrogate = null;
                backend.ime_composing = false;
                backend.suppress_wm_char_units = 0;
                queueInputEvent(backend, .window_blur);
            }
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_MBUTTONDOWN, c.WM_RBUTTONDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (msg == c.WM_LBUTTONDOWN and presentationHasContent(backend)) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);

                    if (presentationSettingsOverlayOpen(backend)) {
                        cancelPendingPresentationCommand(backend);
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        if (handleSettingsOverlayChromeClick(hwnd, backend, client, client_pos.x, client_pos.y)) {
                            return 0;
                        }
                        if (settingsPanelHitTest(backend, client, client_pos.x, client_pos.y)) {
                            if (selectSettingsRowAtClientPoint(backend, client, client_pos.x, client_pos.y)) {
                                _ = c.InvalidateRect(hwnd, null, c.TRUE);
                            }
                            return 0;
                        }
                        if (setSettingsOverlayOpen(backend, false)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }

                    if (presentationDownloadOverlayOpen(backend)) {
                        cancelPendingPresentationCommand(backend);
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        if (handleDownloadOverlayChromeClick(hwnd, backend, client, client_pos.x, client_pos.y)) {
                            return 0;
                        }
                        if (downloadPanelHitTest(backend, client, client_pos.x, client_pos.y)) {
                            return 0;
                        }
                        if (setDownloadOverlayOpen(backend, false)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }

                    if (presentationBookmarkOverlayOpen(backend)) {
                        cancelPendingPresentationCommand(backend);
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        if (handleBookmarkOverlayChromeClick(hwnd, backend, client, client_pos.x, client_pos.y)) {
                            return 0;
                        }
                        if (bookmarkPanelHitTest(backend, client, client_pos.x, client_pos.y)) {
                            if (beginPendingPresentationCommand(backend, hwnd, client_pos.x, client_pos.y)) {
                                _ = setBookmarkOverlayOpen(backend, false);
                                _ = c.SetCapture(hwnd);
                            }
                            return 0;
                        }
                        if (setBookmarkOverlayOpen(backend, false)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }

                    if (presentationHistoryOverlayOpen(backend)) {
                        cancelPendingPresentationCommand(backend);
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        if (handleHistoryOverlayChromeClick(hwnd, backend, client, client_pos.x, client_pos.y)) {
                            return 0;
                        }
                        if (historyPanelHitTest(backend, client, client_pos.x, client_pos.y)) {
                            if (beginPendingPresentationCommand(backend, hwnd, client_pos.x, client_pos.y)) {
                                _ = setHistoryOverlayOpen(backend, false);
                                _ = c.SetCapture(hwnd);
                            }
                            return 0;
                        }
                        if (setHistoryOverlayOpen(backend, false)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }

                    if (handleFindChromeClick(hwnd, backend, client, client_pos.x, client_pos.y)) {
                        backend.presentation_left_mouse_consumed = true;
                        return 0;
                    }

                    if (addressBarHitTest(client_pos.x, client_pos.y)) {
                        cancelPendingPresentationCommand(backend);
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        if (beginAddressEdit(backend)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }

                    if (beginPendingPresentationCommand(backend, hwnd, client_pos.x, client_pos.y)) {
                        backend.presentation_left_mouse_consumed = true;
                        _ = c.SetFocus(hwnd);
                        _ = c.SetCapture(hwnd);
                        return 0;
                    }
                }
                cancelPendingPresentationCommand(backend);
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                const button: Page.MouseButton = switch (msg) {
                    c.WM_MBUTTONDOWN => .auxiliary,
                    c.WM_RBUTTONDOWN => .secondary,
                    else => .main,
                };
                _ = c.SetFocus(hwnd);
                _ = c.SetCapture(hwnd);
                queueInputEvent(backend, .{ .mouse_down = .{
                    .x = pos.x,
                    .y = pos.y,
                    .button = button,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_XBUTTONDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                if (xButtonFromWParam(wparam)) |button| {
                    const client_pos = clientCoordFromLParam(lparam);
                    const pos = if (presentationHasContent(backend))
                        presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 1
                    else
                        client_pos;
                    _ = c.SetFocus(hwnd);
                    _ = c.SetCapture(hwnd);
                    queueInputEvent(backend, .{ .mouse_down = .{
                        .x = pos.x,
                        .y = pos.y,
                        .button = button,
                        .modifiers = mouseModifiersFromWParam(wparam),
                    } });
                }
            }
            return 1;
        },
        c.WM_LBUTTONUP, c.WM_MBUTTONUP, c.WM_RBUTTONUP => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (msg == c.WM_LBUTTONUP and presentationHasContent(backend)) {
                    const consumed = backend.presentation_left_mouse_consumed;
                    backend.presentation_left_mouse_consumed = false;
                    if (takePendingPresentationCommand(backend)) |command| {
                        _ = c.ReleaseCapture();
                        queueBrowserCommand(backend, command);
                        return 0;
                    }
                    if (consumed) {
                        _ = c.ReleaseCapture();
                        return 0;
                    }
                }
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                const button: Page.MouseButton = switch (msg) {
                    c.WM_MBUTTONUP => .auxiliary,
                    c.WM_RBUTTONUP => .secondary,
                    else => .main,
                };
                _ = c.ReleaseCapture();
                queueInputEvent(backend, .{ .mouse_up = .{
                    .x = pos.x,
                    .y = pos.y,
                    .button = button,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            if (getBackendPtr(hwnd)) |backend| {
                cancelPendingPresentationCommand(backend);
            }
            return 0;
        },
        c.WM_XBUTTONUP => {
            if (getBackendPtr(hwnd)) |backend| {
                if (xButtonFromWParam(wparam)) |button| {
                    const client_pos = clientCoordFromLParam(lparam);
                    const pos = if (presentationHasContent(backend))
                        presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 1
                    else
                        client_pos;
                    _ = c.ReleaseCapture();
                    queueInputEvent(backend, .{ .mouse_up = .{
                        .x = pos.x,
                        .y = pos.y,
                        .button = button,
                        .modifiers = mouseModifiersFromWParam(wparam),
                    } });
                }
            }
            return 1;
        },
        c.WM_MOUSEMOVE => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (presentationHasContent(backend)) {
                    setPresentationCursor(hwnd, backend, client_pos.x, client_pos.y);
                    if (presentationHistoryOverlayOpen(backend) or presentationBookmarkOverlayOpen(backend) or presentationDownloadOverlayOpen(backend)) {
                        return 0;
                    }
                }
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                queueInputEvent(backend, .{ .mouse_move = .{
                    .x = pos.x,
                    .y = pos.y,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationHasContent(backend)) {
                    const raw_delta: i16 = @intFromFloat(wheelDeltaFromWParam(wparam));
                    const modifiers = mouseModifiersFromWParam(wparam);
                    if (modifiers.ctrl) {
                        if (zoomCommandForWheelDelta(raw_delta)) |command| {
                            queueBrowserCommand(backend, command);
                            return 0;
                        }
                    }
                    if (presentationBookmarkOverlayOpen(backend)) {
                        if (scrollBookmarkOverlayByWheel(hwnd, backend, raw_delta)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }
                    if (presentationDownloadOverlayOpen(backend)) {
                        if (scrollDownloadOverlayByWheel(hwnd, backend, raw_delta)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }
                    if (presentationHistoryOverlayOpen(backend)) {
                        if (scrollHistoryOverlayByWheel(hwnd, backend, raw_delta)) {
                            _ = c.InvalidateRect(hwnd, null, c.TRUE);
                        }
                        return 0;
                    }
                    const delta = -@divTrunc(@as(i32, raw_delta), @as(i32, c.WHEEL_DELTA)) * PRESENTATION_SCROLL_STEP;
                    if (scrollPresentationBy(backend, delta)) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                const coord = clientCoordForWheel(hwnd, lparam);
                const wheel_delta = wheelDeltaFromWParam(wparam);
                queueInputEvent(backend, .{ .mouse_wheel = .{
                    .x = coord.x,
                    .y = coord.y,
                    .delta_x = 0,
                    .delta_y = -wheel_delta,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_MOUSEHWHEEL => {
            if (getBackendPtr(hwnd)) |backend| {
                const coord = clientCoordForWheel(hwnd, lparam);
                const wheel_delta = wheelDeltaFromWParam(wparam);
                queueInputEvent(backend, .{ .mouse_wheel = .{
                    .x = coord.x,
                    .y = coord.y,
                    .delta_x = wheel_delta,
                    .delta_y = 0,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                const vk: u32 = @intCast(wparam & 0xFFFF);
                const modifiers = keyboardModifiersFromKeyState();
                if (handlePresentationShortcutKey(hwnd, backend, vk, modifiers)) {
                    return 0;
                }
                if (presentationAddressEditing(backend) or presentationFindEditing(backend) or presentationHistoryOverlayOpen(backend) or presentationBookmarkOverlayOpen(backend) or presentationDownloadOverlayOpen(backend)) {
                    return 0;
                }
                if (handlePresentationScrollKey(hwnd, backend, vk)) {
                    return 0;
                }
                const key_down: Win32Backend.InputEvent = .{ .key_down = .{
                    .vk = vk,
                    .modifiers = modifiers,
                    .repeat = keyRepeatFromLParam(lparam),
                } };
                queueInputEvent(backend, key_down);
            }
            return 0;
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend) or presentationFindEditing(backend) or presentationHistoryOverlayOpen(backend) or presentationBookmarkOverlayOpen(backend) or presentationDownloadOverlayOpen(backend)) {
                    return 0;
                }
                const vk: u32 = @intCast(wparam & 0xFFFF);
                const key_up: Win32Backend.InputEvent = .{ .key_up = .{
                    .vk = vk,
                    .modifiers = keyboardModifiersFromKeyState(),
                } };
                queueInputEvent(backend, key_up);
            }
            return 0;
        },
        c.WM_IME_COMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend) or presentationFindEditing(backend) or presentationHistoryOverlayOpen(backend) or presentationBookmarkOverlayOpen(backend) or presentationDownloadOverlayOpen(backend)) {
                    return 0;
                }
                if (hasImeCompositionString(lparam)) {
                    backend.ime_composing = true;
                }
                queueImeResultString(hwnd, backend, lparam);
            }
            return 0;
        },
        c.WM_IME_STARTCOMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.ime_composing = true;
                backend.pending_high_surrogate = null;
                backend.suppress_wm_char_units = 0;
            }
            return 0;
        },
        c.WM_IME_ENDCOMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.ime_composing = false;
                backend.pending_high_surrogate = null;
                backend.suppress_wm_char_units = 0;
            }
            return 0;
        },
        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend)) {
                    const code_unit: u16 = @intCast(wparam & 0xFFFF);
                    if (code_unit != '\r' and code_unit != 0x0008 and appendAddressUtf16Unit(backend, code_unit)) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                if (presentationFindEditing(backend)) {
                    const code_unit: u16 = @intCast(wparam & 0xFFFF);
                    if (code_unit != '\r' and code_unit != 0x0008 and appendFindUtf16Unit(backend, code_unit)) {
                        _ = updateFindSelection(hwnd, backend, .preserve);
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                if (presentationHistoryOverlayOpen(backend) or
                    presentationBookmarkOverlayOpen(backend) or
                    presentationDownloadOverlayOpen(backend) or
                    presentationSettingsOverlayOpen(backend))
                {
                    return 0;
                }
                if (backend.suppress_wm_char_units > 0) {
                    backend.suppress_wm_char_units -= 1;
                    return 0;
                }
                const code_unit: u16 = @intCast(wparam & 0xFFFF);
                queueTextFromUtf16Unit(backend, code_unit);
            }
            return 0;
        },
        c.WM_IME_CHAR => return 0,
        c.WM_UNICHAR => {
            if (@as(u32, @intCast(wparam)) == 0xFFFF) {
                return 1;
            }
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend)) {
                    if (appendAddressCodePoint(backend, @intCast(wparam))) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 1;
                }
                if (presentationFindEditing(backend)) {
                    if (appendFindCodePoint(backend, @intCast(wparam))) {
                        _ = updateFindSelection(hwnd, backend, .preserve);
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 1;
                }
                if (presentationHistoryOverlayOpen(backend) or
                    presentationBookmarkOverlayOpen(backend) or
                    presentationDownloadOverlayOpen(backend) or
                    presentationSettingsOverlayOpen(backend))
                {
                    return 1;
                }
                queueTextCodePoint(backend, @intCast(wparam));
            }
            return 1;
        },
        c.WM_PAINT => {
            if (getBackendPtr(hwnd)) |backend| {
                renderWindowPresentation(hwnd, backend);
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_DESTROY => return 0,
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "win32 mapVirtualKey includes modifiers and shifted digits" {
    var key_buf: [2]u8 = undefined;

    try std.testing.expectEqualStrings("Control", mapVirtualKey(c.VK_CONTROL, false, &key_buf).?);
    try std.testing.expectEqualStrings("Shift", mapVirtualKey(c.VK_SHIFT, false, &key_buf).?);
    try std.testing.expectEqualStrings("Alt", mapVirtualKey(c.VK_MENU, false, &key_buf).?);
    try std.testing.expectEqualStrings("Meta", mapVirtualKey(c.VK_LWIN, false, &key_buf).?);
    try std.testing.expectEqualStrings("!", mapVirtualKey('1', true, &key_buf).?);
    try std.testing.expectEqualStrings(")", mapVirtualKey('0', true, &key_buf).?);
}

test "win32 mouse button mask includes xbuttons" {
    const wparam: c.WPARAM = c.MK_LBUTTON | c.MK_XBUTTON1 | c.MK_XBUTTON2;
    try std.testing.expectEqual(@as(u16, 25), mouseButtonsFromWParam(wparam));
    try std.testing.expectEqual(Page.MouseButton.fourth, xButtonFromWParam(c.XBUTTON1 << 16).?);
    try std.testing.expectEqual(Page.MouseButton.fifth, xButtonFromWParam(c.XBUTTON2 << 16).?);
}

test "win32 utf16 text queue normalizes enter and decodes surrogate pair" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    queueTextFromUtf16Unit(&backend, 0x0003);
    queueTextFromUtf16Unit(&backend, '\r');
    queueTextFromUtf16Unit(&backend, 0xD83D);
    queueTextFromUtf16Unit(&backend, 0xDE00);

    try std.testing.expectEqual(@as(usize, 2), backend.input_events.items.len);

    const first = backend.input_events.items[0];
    const second = backend.input_events.items[1];

    switch (first) {
        .text_input => |input| try std.testing.expectEqualStrings("\n", input.bytes[0..input.len]),
        else => return error.TestUnexpectedEventType,
    }
    switch (second) {
        .text_input => |input| try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", input.bytes[0..input.len]),
        else => return error.TestUnexpectedEventType,
    }
}

test "win32 ime helpers decode flags" {
    try std.testing.expect(hasImeCompositionString(@bitCast(@as(isize, c.GCS_COMPSTR))));
    try std.testing.expect(!hasImeCompositionString(0));
}

test "win32 clipboard shortcut detection" {
    try std.testing.expectEqual(ClipboardShortcutAction.copy, clipboardShortcutAction('C', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.cut, clipboardShortcutAction('X', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.paste, clipboardShortcutAction('V', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.copy, clipboardShortcutAction(c.VK_INSERT, .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.paste, clipboardShortcutAction(c.VK_INSERT, .{ .shift = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.cut, clipboardShortcutAction(c.VK_DELETE, .{ .shift = true }).?);
    try std.testing.expectEqual(@as(?ClipboardShortcutAction, null), clipboardShortcutAction('V', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(@as(?ClipboardShortcutAction, null), clipboardShortcutAction('C', .{ .meta = true, .alt = true }));
}

test "win32 address edit select-all replaces existing value" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    try std.testing.expect(beginAddressEdit(&backend));
    try std.testing.expect(backend.address_input_select_all);
    try std.testing.expect(appendAddressCodePoint(&backend, 'x'));
    try std.testing.expectEqualStrings("x", backend.address_input.items);
    try std.testing.expect(!backend.address_input_select_all);
}

test "win32 address edit ctrl+a then backspace clears all" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    try std.testing.expect(beginAddressEdit(&backend));
    try std.testing.expect(selectAllAddressInput(&backend));
    try std.testing.expect(deleteLastAddressCodepoint(&backend));
    try std.testing.expectEqual(@as(usize, 0), backend.address_input.items.len);
    try std.testing.expect(!backend.address_input_select_all);
}

test "win32 find match collector finds case-insensitive text commands" {
    var display_list = DisplayList{};
    defer display_list.deinit(std.testing.allocator);

    try display_list.addText(std.testing.allocator, .{
        .x = 10,
        .y = 20,
        .width = 120,
        .font_size = 18,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .text = @constCast("First target hit"),
    });
    try display_list.addFillRect(std.testing.allocator, .{
        .x = 0,
        .y = 0,
        .width = 10,
        .height = 10,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    });
    try display_list.addText(std.testing.allocator, .{
        .x = 10,
        .y = 80,
        .width = 120,
        .font_size = 18,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .text = @constCast("SECOND TARGET HIT"),
    });

    var matches = try collectFindMatchesForDisplayList(std.testing.allocator, &display_list, "target");
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].command_index);
    try std.testing.expectEqual(@as(i32, 20), matches.items[0].y);
    try std.testing.expectEqual(@as(usize, 2), matches.items[1].command_index);
    try std.testing.expectEqual(@as(i32, 80), matches.items[1].y);
}

test "win32 find match index wraps forward and backward" {
    try std.testing.expectEqual(@as(usize, 0), normalizeFindMatchIndex(5, 0));
    try std.testing.expectEqual(@as(usize, 1), normalizeFindMatchIndex(3, 2));
    try std.testing.expectEqual(@as(usize, 0), stepFindMatchIndex(2, 3, true));
    try std.testing.expectEqual(@as(usize, 2), stepFindMatchIndex(0, 3, false));
}

test "win32 find collects multiple matches within one text run" {
    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);

    try display_list.addText(std.testing.allocator, .{
        .x = 24,
        .y = 32,
        .width = 240,
        .font_size = 18,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .text = @constCast("target gap target"),
    });

    var matches = try collectFindMatchesForDisplayList(std.testing.allocator, &display_list, "target");
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].command_index);
    try std.testing.expectEqual(@as(usize, 0), matches.items[1].command_index);
    try std.testing.expect(matches.items[0].x < matches.items[1].x);
    try std.testing.expect(matches.items[0].width > 0);
    try std.testing.expect(matches.items[1].width > 0);
}

test "win32 chrome button hit test maps back forward reload" {
    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(ChromeButtonKind.back, chromeCommandKindAtClientPoint(24, mid_y).?);
    try std.testing.expectEqual(ChromeButtonKind.forward, chromeCommandKindAtClientPoint(56, mid_y).?);
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPoint(88, mid_y).?);
}

test "win32 tab strip hit test maps activate close and new" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const tabs = [_]struct {
        title: []const u8,
        url: []const u8,
        is_loading: bool,
    }{
        .{ .title = "One", .url = "http://one.test/", .is_loading = false },
        .{ .title = "Two", .url = "http://two.test/", .is_loading = true },
    };
    backend.setTabEntries(tabs[0..], 1);

    const client = c.RECT{ .left = 0, .top = 0, .right = 960, .bottom = 540 };
    const first_tab = tabRect(client, tabs.len, 0);
    const second_tab = tabRect(client, tabs.len, 1);
    const close_rect = tabCloseButtonRect(second_tab);
    const new_rect = tabNewButtonRect(client);

    try std.testing.expectEqual(
        BrowserCommand{ .tab_activate = 0 },
        presentationCommandAtClientPointWithClient(
            &backend,
            client,
            @as(f64, @floatFromInt(first_tab.left + 8)),
            @as(f64, @floatFromInt(first_tab.top + 8)),
        ).?,
    );
    try std.testing.expectEqual(
        BrowserCommand{ .tab_close = 1 },
        presentationCommandAtClientPointWithClient(
            &backend,
            client,
            @as(f64, @floatFromInt(close_rect.left + 2)),
            @as(f64, @floatFromInt(close_rect.top + 2)),
        ).?,
    );
    try std.testing.expectEqual(
        BrowserCommand.tab_new,
        presentationCommandAtClientPointWithClient(
            &backend,
            client,
            @as(f64, @floatFromInt(new_rect.left + 2)),
            @as(f64, @floatFromInt(new_rect.top + 2)),
        ).?,
    );
}

test "win32 tab shortcuts enqueue commands" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const tabs = [_]struct {
        title: []const u8,
        url: []const u8,
        is_loading: bool,
    }{
        .{ .title = "One", .url = "http://one.test/", .is_loading = false },
        .{ .title = "Two", .url = "http://two.test/", .is_loading = false },
        .{ .title = "Three", .url = "http://three.test/", .is_loading = false },
    };
    backend.setTabEntries(tabs[0..], 1);
    backend.presentation_title = try std.testing.allocator.dupe(u8, "Tabs");

    try std.testing.expect(handlePresentationShortcutKey(null, &backend, 'T', .{ .ctrl = true }));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, 'T', .{ .ctrl = true, .shift = true }));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_TAB, .{ .ctrl = true }));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_TAB, .{ .ctrl = true, .shift = true }));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, '2', .{ .ctrl = true }));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, 'W', .{ .ctrl = true }));

    try std.testing.expectEqual(BrowserCommand.tab_new, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_reopen_closed, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_next, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_previous, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand{ .tab_activate = 1 }, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand{ .tab_close = 1 }, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "win32 ctrl+j toggles downloads overlay" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_title = try std.testing.allocator.dupe(u8, "Downloads");

    try std.testing.expect(handlePresentationShortcutKey(null, &backend, 'J', .{ .ctrl = true }));
    try std.testing.expect(presentationDownloadOverlayOpen(&backend));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, 'J', .{ .ctrl = true }));
    try std.testing.expect(!presentationDownloadOverlayOpen(&backend));
}

test "win32 ctrl+comma toggles settings overlay" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_title = try std.testing.allocator.dupe(u8, "Settings");

    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_OEM_COMMA, .{ .ctrl = true }));
    try std.testing.expect(presentationSettingsOverlayOpen(&backend));
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_OEM_COMMA, .{ .ctrl = true }));
    try std.testing.expect(!presentationSettingsOverlayOpen(&backend));
}

test "win32 settings overlay keyboard queues settings commands" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_title = try std.testing.allocator.dupe(u8, "Settings");
    backend.presentation_homepage_url = try std.testing.allocator.dupe(u8, "http://home.test/");
    backend.settings_overlay_open = true;

    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_SPACE, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_toggle_restore_session, backend.nextBrowserCommand().?);

    backend.settings_overlay_open = true;
    backend.settings_overlay_selected_index = 1;
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_RIGHT, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_default_zoom_in, backend.nextBrowserCommand().?);

    backend.settings_overlay_open = true;
    backend.settings_overlay_selected_index = 1;
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_LEFT, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_default_zoom_out, backend.nextBrowserCommand().?);

    backend.settings_overlay_open = true;
    backend.settings_overlay_selected_index = 1;
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_RETURN, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_default_zoom_reset, backend.nextBrowserCommand().?);

    backend.settings_overlay_open = true;
    backend.settings_overlay_selected_index = 2;
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_RETURN, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_set_homepage_to_current, backend.nextBrowserCommand().?);

    backend.settings_overlay_open = true;
    backend.settings_overlay_selected_index = 2;
    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_DELETE, .{}));
    try std.testing.expectEqual(BrowserCommand.settings_clear_homepage, backend.nextBrowserCommand().?);
}

test "win32 alt+home queues home command" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_title = try std.testing.allocator.dupe(u8, "Home");

    try std.testing.expect(handlePresentationShortcutKey(null, &backend, c.VK_HOME, .{ .alt = true }));
    try std.testing.expectEqual(BrowserCommand.home, backend.nextBrowserCommand().?);
}

test "win32 disabled chrome buttons are not interactive" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");
    backend.presentation_can_go_back = false;
    backend.presentation_can_go_forward = false;

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expect(chromeCommandKindAtClientPointEnabled(&backend, 24, mid_y) == null);
    try std.testing.expect(chromeCommandKindAtClientPointEnabled(&backend, 56, mid_y) == null);
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPointEnabled(&backend, 88, mid_y).?);
}

test "win32 reload slot becomes stop while loading" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_is_loading = true;

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPointEnabled(&backend, 88, mid_y).?);
    try std.testing.expectEqual(BrowserCommand.stop, presentationCommandAtClientPointWithClient(&backend, null, 88, mid_y).?);
}

test "win32 reload slot stays reload when idle" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(BrowserCommand.reload, presentationCommandAtClientPointWithClient(&backend, null, 88, mid_y).?);
}

test "win32 history window start keeps current entry visible" {
    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = 960,
        .bottom = PRESENTATION_HISTORY_PANEL_TOP + PRESENTATION_MARGIN + 44 + (PRESENTATION_HISTORY_PANEL_ROW_HEIGHT * 3),
    };
    try std.testing.expectEqual(@as(usize, 0), historyEntryWindowStart(client, 2, 0, 1));
    try std.testing.expectEqual(@as(usize, 2), historyEntryWindowStart(client, 6, 0, 4));
}

test "win32 overlay move keeps selection visible" {
    var selected: usize = 4;
    var scroll: usize = 0;
    try std.testing.expect(applyOverlayMove(6, 3, &selected, &scroll, .down));
    try std.testing.expectEqual(@as(usize, 5), selected);
    try std.testing.expectEqual(@as(usize, 3), scroll);
}

test "win32 history overlay hit test maps row to absolute traverse index" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const entries = [_][]const u8{
        "http://one.test/",
        "http://two.test/",
        "http://three.test/",
        "http://four.test/",
        "http://five.test/",
        "http://six.test/",
    };
    backend.setHistoryEntries(entries[0..], 4);
    backend.history_overlay_open = true;
    backend.history_overlay_selected_index = 4;
    backend.history_overlay_scroll_index = 0;

    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = 960,
        .bottom = PRESENTATION_HISTORY_PANEL_TOP + PRESENTATION_MARGIN + 44 + (PRESENTATION_HISTORY_PANEL_ROW_HEIGHT * 3),
    };
    const visible_entries = visibleHistoryEntryCount(client, entries.len);
    try std.testing.expectEqual(@as(usize, 3), visible_entries);

    const top_row = historyEntryRect(client, visible_entries, 0);
    const bottom_row = historyEntryRect(client, visible_entries, 2);

    const top_command = historyEntryCommandAtClientPoint(
        &backend,
        client,
        @as(f64, @floatFromInt(top_row.left + 4)),
        @as(f64, @floatFromInt(top_row.top + 4)),
    ).?;
    const bottom_command = historyEntryCommandAtClientPoint(
        &backend,
        client,
        @as(f64, @floatFromInt(bottom_row.left + 4)),
        @as(f64, @floatFromInt(bottom_row.top + 4)),
    ).?;

    try std.testing.expectEqual(BrowserCommand{ .history_traverse = 2 }, top_command);
    try std.testing.expectEqual(BrowserCommand{ .history_traverse = 4 }, bottom_command);
}

test "win32 history overlay close button hit test maps action" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const entries = [_][]const u8{
        "http://one.test/",
        "http://two.test/",
    };
    backend.setHistoryEntries(entries[0..], 1);
    backend.history_overlay_open = true;

    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = 960,
        .bottom = 540,
    };
    const rect = historyOverlayCloseButtonRect(historyPanelRect(client, entries.len));
    try std.testing.expectEqual(
        HistoryOverlayChromeAction.close,
        historyOverlayChromeActionAtClientPoint(
            &backend,
            client,
            @as(f64, @floatFromInt(rect.left + 2)),
            @as(f64, @floatFromInt(rect.top + 2)),
        ).?,
    );
}

test "win32 bookmark overlay chrome buttons map close and delete" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    try backend.presentation_bookmark_entries.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "http://one.test/"));
    backend.bookmark_overlay_open = true;

    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = 960,
        .bottom = 540,
    };
    const panel = historyPanelRect(client, backend.presentation_bookmark_entries.items.len);
    const delete_rect = bookmarkOverlayDeleteButtonRect(panel);
    const close_rect = bookmarkOverlayCloseButtonRect(panel);
    try std.testing.expectEqual(
        BookmarkOverlayChromeAction.delete,
        bookmarkOverlayChromeActionAtClientPoint(
            &backend,
            client,
            @as(f64, @floatFromInt(delete_rect.left + 2)),
            @as(f64, @floatFromInt(delete_rect.top + 2)),
        ).?,
    );
    try std.testing.expectEqual(
        BookmarkOverlayChromeAction.close,
        bookmarkOverlayChromeActionAtClientPoint(
            &backend,
            client,
            @as(f64, @floatFromInt(close_rect.left + 2)),
            @as(f64, @floatFromInt(close_rect.top + 2)),
        ).?,
    );
}

test "win32 overlay status label includes range and markers" {
    const label = try formatOverlayStatusLabel(std.testing.allocator, 2, 3, 8, 4, 4);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("3-5/8  Sel 5  Current 5  ^  v", label);
}

test "win32 bookmark toggle persists to app dir" {
    const rel_dir = ".zig-cache/tmp/win32-bookmark-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);

    var dir = try std.fs.openDirAbsolute(abs_dir, .{});
    defer dir.close();
    dir.deleteFile(BOOKMARKS_FILE) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();
    backend.setAppDataPath(abs_dir);
    backend.presentation_lock.lock();
    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com/test");
    backend.presentation_lock.unlock();
    try std.testing.expect(toggleCurrentBookmark(&backend));

    var restored = Win32Backend.init(std.testing.allocator, 1, 1);
    defer restored.deinit();
    restored.setAppDataPath(abs_dir);

    restored.presentation_lock.lock();
    defer restored.presentation_lock.unlock();
    try std.testing.expectEqual(@as(usize, 1), restored.presentation_bookmark_entries.items.len);
    try std.testing.expectEqualStrings("http://example.com/test", restored.presentation_bookmark_entries.items[0]);
}

test "win32 history overlay enter enqueues traverse command" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const entries = [_][]const u8{
        "http://one.test/",
        "http://two.test/",
        "http://three.test/",
    };
    backend.setHistoryEntries(entries[0..], 1);
    backend.history_overlay_open = true;
    backend.history_overlay_selected_index = 2;

    try std.testing.expect(activateHistoryOverlaySelection(&backend));
    try std.testing.expect(!backend.history_overlay_open);
    try std.testing.expectEqual(BrowserCommand{ .history_traverse = 2 }, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "win32 bookmark overlay enter enqueues navigate command" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    try backend.presentation_bookmark_entries.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "http://one.test/"));
    try backend.presentation_bookmark_entries.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "http://two.test/"));
    backend.bookmark_overlay_open = true;
    backend.bookmark_overlay_selected_index = 1;

    try std.testing.expect(activateBookmarkOverlaySelection(&backend));
    try std.testing.expect(!backend.bookmark_overlay_open);
    const command = backend.nextBrowserCommand().?;
    defer switch (command) {
        .navigate => |url| std.testing.allocator.free(url),
        else => {},
    };
    try std.testing.expectEqualStrings("http://two.test/", command.navigate);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "win32 bookmark overlay delete removes persisted entry" {
    const rel_dir = ".zig-cache/tmp/win32-bookmark-delete-test";
    std.fs.cwd().makePath(rel_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const abs_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, rel_dir);
    defer std.testing.allocator.free(abs_dir);

    var dir = try std.fs.openDirAbsolute(abs_dir, .{});
    defer dir.close();
    dir.deleteFile(BOOKMARKS_FILE) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();
    backend.setAppDataPath(abs_dir);
    backend.presentation_lock.lock();
    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://delete.test/");
    backend.presentation_lock.unlock();
    try std.testing.expect(toggleCurrentBookmark(&backend));

    backend.bookmark_overlay_open = true;
    backend.bookmark_overlay_selected_index = 0;
    try std.testing.expect(deleteSelectedBookmark(&backend));
    try std.testing.expect(!backend.bookmark_overlay_open);
    try std.testing.expectEqual(@as(usize, 0), backend.presentation_bookmark_entries.items.len);

    const file = try dir.openFile(BOOKMARKS_FILE, .{});
    defer file.close();
    const data = try file.readToEndAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "win32 download overlay delete enqueues remove command" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    const entries = [_]Display.DownloadEntry{
        .{
            .filename = "example.txt",
            .path = "C:\\tmp\\example.txt",
            .status = "Complete 10 B",
            .removable = true,
        },
    };
    backend.setDownloadEntries(entries[0..]);
    backend.download_overlay_open = true;

    try std.testing.expect(deleteSelectedDownload(&backend));
    try std.testing.expectEqual(BrowserCommand{ .download_remove = 0 }, backend.nextBrowserCommand().?);
}

test "win32 presentation scaling helpers round-trip coordinates" {
    try std.testing.expectEqual(@as(i32, 150), scalePresentationValue(100, 150));
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), unscalePresentationValue(150.0, 150), 0.001);
}

test "win32 wheel zoom command maps sign to zoom action" {
    try std.testing.expectEqual(BrowserCommand.zoom_in, zoomCommandForWheelDelta(120).?);
    try std.testing.expectEqual(BrowserCommand.zoom_out, zoomCommandForWheelDelta(-120).?);
    try std.testing.expectEqual(@as(?BrowserCommand, null), zoomCommandForWheelDelta(0));
}

test "win32 address bar hit test excludes chrome buttons" {
    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expect(!addressBarHitTest(24, mid_y));
    try std.testing.expect(addressBarHitTest(120, mid_y));
}

test "win32 key repeat detection from lparam" {
    try std.testing.expect(!keyRepeatFromLParam(0));
    try std.testing.expect(keyRepeatFromLParam(@bitCast(@as(isize, 1 << 30))));
}

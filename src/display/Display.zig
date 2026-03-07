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
const Config = @import("../Config.zig");
const log = @import("../log.zig");
const builtin = @import("builtin");
pub const BrowserCommand = @import("BrowserCommand.zig").BrowserCommand;
const DisplayList = @import("../render/DisplayList.zig").DisplayList;

const Win32Backend = if (builtin.os.tag == .windows) @import("win32_backend.zig").Win32Backend else struct {
    page_count: u32 = 0,

    pub fn init(_: anytype, _: u32, _: u32) @This() {
        return .{};
    }

    pub fn onPageCreated(_: *@This()) bool {
        return false;
    }
    pub fn onPageRemoved(_: *@This()) bool {
        return false;
    }
    pub fn onViewportChanged(_: *@This(), _: u32, _: u32) void {}
    pub fn setNavigationState(_: *@This(), _: bool, _: bool, _: bool, _: i32) void {}
    pub fn setHistoryEntries(_: *@This(), _: []const []const u8, _: usize) void {}
    pub fn setDownloadEntries(_: *@This(), _: []const DownloadEntry) void {}
    pub fn setTabEntries(_: *@This(), _: []const TabEntry, _: usize) void {}
    pub fn setSettingsState(_: *@This(), _: SettingsState) void {}
    pub fn setAppDataPath(_: *@This(), _: ?[]const u8) void {}
    pub fn dispatchInput(_: *@This(), _: anytype) !void {}
    pub fn presentDocument(_: *@This(), _: []const u8, _: []const u8, _: []const u8) !void {}
    pub fn presentPageView(_: *@This(), _: []const u8, _: []const u8, _: []const u8, _: ?*const DisplayList) !void {}
    pub fn saveBitmap(_: *@This(), _: []const u8) bool {
        return false;
    }
    pub fn savePng(_: *@This(), _: []const u8) bool {
        return false;
    }
    pub fn nextBrowserCommand(_: *@This()) ?BrowserCommand {
        return null;
    }
    pub fn userClosed(_: *const @This()) bool {
        return false;
    }
    pub fn deinit(_: *@This()) void {}
};

pub const Display = @This();

pub const Viewport = struct {
    width: u32,
    height: u32,
    device_pixel_ratio: f64 = 1.0,

    pub fn availHeight(self: Viewport) u32 {
        // Reserve some space for browser UI chrome semantics.
        return if (self.height > 40) self.height - 40 else self.height;
    }
};

pub const TabEntry = struct {
    title: []const u8,
    url: []const u8,
    is_loading: bool,
};

pub const DownloadEntry = struct {
    filename: []const u8,
    path: []const u8,
    status: []const u8,
    removable: bool,
};

pub const SettingsState = struct {
    restore_previous_session: bool,
    default_zoom_percent: i32,
    homepage_url: []const u8,
};

pub const Backend = union(enum) {
    headless: HeadlessBackend,
    headed_stub: HeadedStubBackend,
    headed_windows: Win32Backend,
};

pub const HeadlessBackend = struct {
    page_count: u32 = 0,
};

pub const HeadedStubBackend = struct {
    page_count: u32 = 0,
    window_open: bool = false,
    last_resize_seq: u64 = 0,
};

requested_mode: Config.BrowserMode,
runtime_mode: Config.BrowserMode,
backend: Backend,
default_viewport: Viewport,
viewport: Viewport,
browse_screenshot_bmp_path: ?[]const u8 = null,
browse_screenshot_bmp_attempted: bool = false,
browse_screenshot_png_path: ?[]const u8 = null,
browse_screenshot_png_attempted: bool = false,

pub fn init(allocator: std.mem.Allocator, config: *const Config) Display {
    const requested_mode = config.browserMode();
    const default_viewport: Viewport = .{
        .width = config.windowWidth(),
        .height = config.windowHeight(),
        .device_pixel_ratio = 1.0,
    };

    const runtime_mode: Config.BrowserMode = switch (requested_mode) {
        .headless => .headless,
        .headed => if (builtin.os.tag == .windows) .headed else .headless,
    };

    return .{
        .requested_mode = requested_mode,
        .runtime_mode = runtime_mode,
        .backend = switch (requested_mode) {
            .headless => .{ .headless = .{} },
            .headed => if (runtime_mode == .headed)
                .{ .headed_windows = Win32Backend.init(allocator, default_viewport.width, default_viewport.height) }
            else
                .{ .headed_stub = .{} },
        },
        .default_viewport = default_viewport,
        .viewport = default_viewport,
        .browse_screenshot_bmp_path = switch (config.mode) {
            .browse => |opts| if (opts.screenshot_bmp_path) |path| path else null,
            else => null,
        },
        .browse_screenshot_png_path = switch (config.mode) {
            .browse => |opts| if (opts.screenshot_png_path) |path| path else null,
            else => null,
        },
    };
}

pub fn onPageCreated(self: *Display) void {
    switch (self.backend) {
        .headless => |*backend| backend.page_count += 1,
        .headed_stub => |*backend| {
            backend.page_count += 1;
            if (!backend.window_open) {
                backend.window_open = true;
                log.info(.app, "headed stub window", .{
                    .event = "open",
                    .width = self.viewport.width,
                    .height = self.viewport.height,
                    .dpr = self.viewport.device_pixel_ratio,
                });
            }
        },
        .headed_windows => |*backend| {
            if (backend.onPageCreated()) {
                log.info(.app, "headed windows window", .{
                    .event = "open",
                    .width = self.viewport.width,
                    .height = self.viewport.height,
                    .dpr = self.viewport.device_pixel_ratio,
                });
            }
        },
    }
}

pub fn onPageRemoved(self: *Display) void {
    switch (self.backend) {
        .headless => |*backend| {
            if (backend.page_count > 0) {
                backend.page_count -= 1;
            }
        },
        .headed_stub => |*backend| {
            if (backend.page_count > 0) backend.page_count -= 1;
            if (backend.page_count == 0 and backend.window_open) {
                backend.window_open = false;
                log.info(.app, "headed stub window", .{ .event = "close" });
            }
        },
        .headed_windows => |*backend| {
            if (backend.onPageRemoved()) {
                log.info(.app, "headed windows window", .{ .event = "close" });
            }
        },
    }
}

pub fn setViewport(self: *Display, width: u32, height: u32, device_pixel_ratio: f64) void {
    self.viewport = .{
        .width = if (width == 0) 1 else width,
        .height = if (height == 0) 1 else height,
        .device_pixel_ratio = if (device_pixel_ratio <= 0) 1.0 else device_pixel_ratio,
    };
    switch (self.backend) {
        .headless => {},
        .headed_stub => |*backend| backend.last_resize_seq += 1,
        .headed_windows => |*backend| backend.onViewportChanged(self.viewport.width, self.viewport.height),
    }
}

pub fn resetViewport(self: *Display) void {
    self.setViewport(
        self.default_viewport.width,
        self.default_viewport.height,
        self.default_viewport.device_pixel_ratio,
    );
}

pub fn setNavigationState(self: *Display, can_go_back: bool, can_go_forward: bool, is_loading: bool, zoom_percent: i32) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setNavigationState(can_go_back, can_go_forward, is_loading, zoom_percent),
        else => {},
    }
}

pub fn setHistoryEntries(self: *Display, entries: []const []const u8, current_index: usize) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setHistoryEntries(entries, current_index),
        else => {},
    }
}

pub fn setDownloadEntries(self: *Display, entries: []const DownloadEntry) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setDownloadEntries(entries),
        else => {},
    }
}

pub fn setTabEntries(self: *Display, entries: []const TabEntry, active_index: usize) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setTabEntries(entries, active_index),
        else => {},
    }
}

pub fn setSettingsState(self: *Display, settings: SettingsState) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setSettingsState(settings),
        else => {},
    }
}

pub fn setAppDataPath(self: *Display, path: ?[]const u8) void {
    switch (self.backend) {
        .headed_windows => |*backend| backend.setAppDataPath(path),
        else => {},
    }
}

pub fn dispatchNativeInput(self: *Display, page: anytype) !void {
    switch (self.backend) {
        .headed_windows => |*backend| try backend.dispatchInput(page),
        else => {},
    }
}

pub fn presentDocument(self: *Display, title: []const u8, url: []const u8, body: []const u8) !void {
    switch (self.backend) {
        .headed_windows => |*backend| try backend.presentDocument(title, url, body),
        else => {},
    }
}

pub fn presentPageView(self: *Display, title: []const u8, url: []const u8, body: []const u8, display_list: ?*const DisplayList) !void {
    switch (self.backend) {
        .headed_windows => |*backend| {
            try backend.presentPageView(title, url, body, display_list);
            if (self.browse_screenshot_bmp_path) |path| {
                if (!self.browse_screenshot_bmp_attempted) {
                    self.browse_screenshot_bmp_attempted = true;
                    if (!backend.saveBitmap(path)) {
                        log.warn(.app, "headed bmp export failed", .{ .path = path });
                    }
                }
            }
            if (self.browse_screenshot_png_path) |path| {
                if (!self.browse_screenshot_png_attempted) {
                    self.browse_screenshot_png_attempted = true;
                    if (!backend.savePng(path)) {
                        log.warn(.app, "headed png export failed", .{ .path = path });
                    }
                }
            }
        },
        else => {},
    }
}

pub fn nextBrowserCommand(self: *Display) ?BrowserCommand {
    return switch (self.backend) {
        .headed_windows => |*backend| backend.nextBrowserCommand(),
        else => null,
    };
}

pub fn userClosed(self: *const Display) bool {
    return switch (self.backend) {
        .headed_windows => |*backend| backend.userClosed(),
        else => false,
    };
}

pub fn deinit(self: *Display) void {
    if (self.requested_mode == .headed and self.runtime_mode == .headless) {
        log.info(.app, "headed stub shutdown", .{});
    }
    switch (self.backend) {
        .headed_windows => |*backend| {
            backend.deinit();
            log.info(.app, "headed windows shutdown", .{});
        },
        else => {},
    }
}
